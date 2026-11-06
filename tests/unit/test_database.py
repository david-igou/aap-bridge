import pytest

from aap_migration.migration.database import create_database_engine, normalize_database_url


def test_explicit_postgresql_driver_is_preserved() -> None:
    """A driver-qualified DSN must reach PostgreSQL rather than become a SQLite path."""
    database_url = "postgresql+psycopg2://bridge@localhost/bridge"
    engine = create_database_engine(normalize_database_url(database_url))
    try:
        assert engine.dialect.name == "postgresql"
        assert engine.dialect.driver == "psycopg2"
    finally:
        engine.dispose()


@pytest.mark.parametrize("path", ["migration_state.db", "/data/migration_state.db"])
def test_sqlite_paths_remain_supported(path: str) -> None:
    assert normalize_database_url(path) == f"sqlite:///{path}"
