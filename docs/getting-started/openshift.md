# OpenShift

Build and run the Web UI and API using OpenShift BuildConfigs, ImageStreams,
Deployments, Services, and a TLS Route. The default installation includes a
single PostgreSQL 15 instance. An alternate layout uses an existing database.

**This deployment has no authentication.** Anyone who can reach its Route can
manage saved connections and start migrations or cleanup operations. Use it on
a trusted network with appropriate ingress restrictions.

## Prerequisites

- An OpenShift cluster with Builds and the integrated image registry enabled.
- Permission to create a project, builds, workloads, Routes, Secrets, and PVCs.
- `oc`, `kustomize`, `openssl`, and `podman` on the workstation.
- A Red Hat registry account with access to the UBI and PostgreSQL images.
- A default StorageClass supporting ReadWriteOnce volumes.
- Network access from builds to GitHub, the Red Hat registry, PyPI, and npm;
  network access from the API to the source and destination AAP instances.

BuildConfigs initially use the `feature/openshift` branch of
`https://github.com/david-igou/aap-bridge.git`. Update `spec.source.git.uri` and
`ref` in both files under `deploy/openshift/builds/` when using another fork,
branch, tag, or commit. Both builds must use the same source revision. The API
build uses the final `api` stage of `Containerfile`; the UI uses `Containerfile.ui`.

The manifests use namespace `aap-bridge`. To change it, edit `namespace` in the
selected top-level kustomization and replace the namespace in the commands below.
Adjust the PVC sizes or add `storageClassName` before installation if needed.
The API memory limit defaults to 4 GiB; increase its resource requests and limits
for larger migrations using the [hardware guidance](installation.md#hardware-requirements).

## Create the project and Secrets

Verify the target cluster and identity before creating resources:

```bash
oc whoami --show-server
oc whoami
oc new-project aap-bridge
```

Create a dedicated registry authentication file, then import it as the pull
Secret used by builds and the application ServiceAccount. `podman login` prompts
for credentials; do not put passwords in shell history.

```bash
(
  set -eu
  umask 077
  registry_auth=$(mktemp)
  trap 'rm -f "$registry_auth"' EXIT
  printf '{}\n' > "$registry_auth"
  podman login --authfile "$registry_auth" registry.redhat.io
  oc create secret generic redhat-registry -n aap-bridge \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$registry_auth"
)
```

For bundled PostgreSQL, generate the database credentials and a Fernet token
encryption key. The password uses URL-safe hex characters, so it can also be
included in the database connection URL. The files exist only in a temporary
directory, outside the checkout, and the commands do not print their contents.

```bash
(
  set -eu
  umask 077
  secret_dir=$(mktemp -d)
  trap 'rm -rf "$secret_dir"' EXIT
  db_password=$(openssl rand -hex 24)
  {
    printf 'POSTGRESQL_USER=aap_bridge\n'
    printf 'POSTGRESQL_DATABASE=aap_bridge\n'
    printf 'POSTGRESQL_PASSWORD=%s\n' "$db_password"
    printf 'MIGRATION_STATE_DB_PATH=postgresql+psycopg2://aap_bridge:%s@aap-bridge-postgresql:5432/aap_bridge\n' "$db_password"
  } > "$secret_dir/database.env"
  openssl rand -base64 32 | tr '/+' '_-' \
    > "$secret_dir/AAP_BRIDGE_TOKEN_ENCRYPTION_KEY"
  oc create secret generic aap-bridge-db -n aap-bridge \
    --from-env-file="$secret_dir/database.env"
  oc create secret generic aap-bridge-secrets -n aap-bridge \
    --from-file="AAP_BRIDGE_TOKEN_ENCRYPTION_KEY=$secret_dir/AAP_BRIDGE_TOKEN_ENCRYPTION_KEY"
)
```

Keep the encryption key in your secret manager and back it up with the database.
Replacing it makes existing encrypted connection tokens unreadable. Do not
regenerate these Secrets during upgrades. The database password and encryption
key protect stored data; they do not add login protection to the web application.

For an external database, create `aap-bridge-db` with just the
`MIGRATION_STATE_DB_PATH` key, using a protected file containing its PostgreSQL
connection URL. Percent-encode reserved characters in URL credentials. Create
`aap-bridge-secrets` with a Fernet key as above, then select
`deploy/openshift/external-db` in place of `deploy/openshift` below. The database
user needs permission to create and update the application's tables. Configure
TLS in the connection URL as required by your database service.
Use the `postgresql+psycopg2://` scheme to select the PostgreSQL driver installed
in the application image explicitly.

## Apply, build, and promote

Validate the rendered manifests against the active cluster's API schemas without
creating resources:

```bash
make openshift-validate
```

Apply the default layout:

```bash
kustomize build deploy/openshift | oc apply -n aap-bridge -f -
```

The API and UI pods will initially wait for their images. Start both builds
explicitly; there are no Git webhooks or automatic build triggers:

```bash
oc start-build aap-bridge-api -n aap-bridge --follow --wait
oc start-build aap-bridge-ui -n aap-bridge --follow --wait
```

Builds publish `:latest`. Deployments consume a separate `:deployed` tag through
OpenShift image lookup. Promote both successful builds and recreate the pods:

```bash
oc tag aap-bridge-api:latest aap-bridge-api:deployed -n aap-bridge
oc tag aap-bridge-ui:latest aap-bridge-ui:deployed -n aap-bridge
oc rollout restart deployment/aap-bridge-api deployment/aap-bridge-ui -n aap-bridge
oc rollout status deployment/aap-bridge-postgresql -n aap-bridge --timeout=300s
oc rollout status deployment/aap-bridge-api -n aap-bridge --timeout=300s
oc rollout status deployment/aap-bridge-ui -n aap-bridge --timeout=300s
oc get route aap-bridge -n aap-bridge \
  -o jsonpath='https://{.spec.host}{"\n"}'
```

Skip the PostgreSQL rollout check for the external database layout. Open the
printed HTTPS URL and add source and destination connections in the UI. The
Route uses the router's default certificate and redirects HTTP to HTTPS.

## Runtime behavior

- The API and nginx run in separate pods. Only nginx has a Route; it proxies
  `/api/` and `/ws/` to the API Service with WebSocket upgrade support.
- The API runs one process and one replica with a Recreate rollout strategy.
  Do not add workers, replicas, or an HPA: active tasks and live log buffers
  belong to one process. Restarting interrupts migrations; startup marks
  interrupted jobs as failed. Resume or rerun the appropriate phase after
  reviewing its state. Migrations do not continue automatically after restart.
- The migration PVC defaults to 20 GiB and stores exports, transformed data,
  schemas, reports, and backups under `/data`. PostgreSQL has a separate 10 GiB
  PVC. Size both for your workload and back them up together with the Secrets.
- ConfigMaps provide absolute data paths and nginx configuration. Source and
  destination URLs, AAP versions, and tokens are entered through the Web UI.
- Runtime pods use arbitrary non-root UIDs without custom SCC grants or fixed
  `runAsUser`/`fsGroup` settings. OpenShift supplies the volume group. The API
  and UI use read-only root filesystems and writable temporary volumes.
- API readiness calls the read-only, database-backed `/api/jobs?limit=1`
  endpoint. Liveness checks the TCP listener, so a database outage removes
  readiness without repeatedly restarting the API. nginx probes `/healthz`.
- nginx logs to stdout/stderr; API logs are available through `oc logs`.

If an AAP instance uses a private CA, mount its CA bundle and configure the
Python HTTP clients to trust it, for example with `SSL_CERT_FILE` and
`REQUESTS_CA_BUNDLE`. Keep connection TLS verification enabled.

## Updates and recovery

Wait for active migrations to finish before applying configuration changes,
promoting images, or restarting workloads. Kustomize hashes ConfigMaps, so
applying changed configuration also triggers a rollout.

Run the build and promotion commands again to deploy changes. A build alone
updates only `:latest`; it does not trigger a deployment. For reproducible
builds, pin both BuildConfigs to the same commit. Retain the previous image
digests so you can promote them back to `:deployed` and restart if needed.
Treat database schema compatibility separately when rolling back application code.

The integrated image registry must retain the built images. A registry backed
by `emptyDir` can lose them on restart; ImageStreams alone are not image backups.
Use persistent registry storage or plan to rebuild and promote the images.

Useful inspection commands:

```bash
oc get builds,pods,pvc,services,route -n aap-bridge
oc logs deployment/aap-bridge-api -n aap-bridge
oc logs deployment/aap-bridge-ui -n aap-bridge
oc logs deployment/aap-bridge-postgresql -n aap-bridge
oc get events -n aap-bridge --sort-by=.lastTimestamp
```

For `ImagePullBackOff`, check build completion, the `:deployed` tags, and the
`redhat-registry` Secret reference. For database startup failures, check the
database URL, PostgreSQL readiness, PVC status, and network access. If nginx
returns 502/503, check the API's readiness and logs.

## Layout and validation

- `deploy/openshift/builds/`: two BuildConfigs and two ImageStreams.
- `deploy/openshift/app/`: runtime workloads, Services, Route, configuration,
  ServiceAccount, and migration PVC.
- `deploy/openshift/postgresql/`: optional single-instance database and PVC.
- `deploy/openshift/external-db/`: application and builds without a database pod.

`make openshift-render` renders the default installation. Use
`make openshift-render OPENSHIFT_DIR=deploy/openshift/external-db` for an external
database. `make openshift-validate` renders and validates both layouts using
`oc apply --dry-run=client --validate=strict`; it needs an authenticated OpenShift
connection for API discovery and schemas, but does not persist resources or
test scheduling, SCC admission, builds, or runtime behavior.
