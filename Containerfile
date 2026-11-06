FROM registry.redhat.io/ubi9/ubi-minimal:latest AS base

RUN microdnf install -y \
        python3.12 \
        python3.12-pip \
        python3.12-devel \
        libpq-devel \
        gcc \
        less \
        procps-ng \
        tar \
        vim-enhanced \
        which \
        shadow-utils \
    && microdnf clean all

RUN ln -sf /usr/bin/python3.12 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3.12 /usr/local/bin/python && \
    ln -sf /usr/bin/pip3.12 /usr/local/bin/pip3 && \
    ln -sf /usr/bin/pip3.12 /usr/local/bin/pip && \
    ln -sf /usr/bin/vim /usr/local/bin/vi

RUN groupadd -r -g 998 bridge && \
    useradd -r -u 998 -g bridge -m -d /app bridge
WORKDIR /app

COPY pyproject.toml README.md ./
COPY src/ src/
COPY config/ config/

RUN pip3.12 install --no-cache-dir .

RUN mkdir -p exports xformed reports logs schemas backups && \
    chgrp 0 /app && chmod g+rx /app && \
    chown -R 998:0 exports xformed reports logs schemas backups && \
    chmod -R g=u exports xformed reports logs schemas backups

USER 998:0

ENTRYPOINT ["aap-bridge"]


FROM base AS api

USER root

RUN pip3.12 install --no-cache-dir '.[api]'

USER 998:0

EXPOSE 8000

ENTRYPOINT ["aap-bridge", "serve", "--host", "0.0.0.0", "--port", "8000"]
