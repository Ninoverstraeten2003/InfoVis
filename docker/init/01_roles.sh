#!/usr/bin/env bash
# docker/init/01_roles.sql is injected first so that the authenticator/web_anon
# roles exist before the main schema tries to grant on them.
# This file is run by the postgres entrypoint as the superuser.

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Roles (idempotent)
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'web_anon') THEN
            CREATE ROLE web_anon NOLOGIN;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
            CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '${AUTHENTICATOR_PASSWORD:-change-me}';
        END IF;
    END
    \$\$;

    GRANT web_anon TO authenticator;
EOSQL
