#!/usr/bin/env bash
# Creates web_anon + authenticator roles on first DB initialisation.
# Uses psql --set to safely pass the password (handles special chars).

set -e

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname   "$POSTGRES_DB"  \
     --set      "authenticator_password=${AUTHENTICATOR_PASSWORD:-change-me}" \
     <<-'EOSQL'
        -- Roles (idempotent)
        DO $$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'web_anon') THEN
                CREATE ROLE web_anon NOLOGIN;
            END IF;
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticator') THEN
                CREATE ROLE authenticator NOINHERIT LOGIN;
            END IF;
        END
        $$;

        -- Set / reset password safely via psql variable (handles special chars)
        ALTER ROLE authenticator PASSWORD :'authenticator_password';

        GRANT web_anon TO authenticator;
EOSQL
