-- PostgREST role and privilege grants for team/dev environments.
-- Safe to re-run after schema changes.
--
-- Run with:
--   psql nutriverse -f db/postgrest_grants.sql

BEGIN;

CREATE SCHEMA IF NOT EXISTS api;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
        -- Change this password immediately in local/dev usage.
        CREATE ROLE authenticator LOGIN PASSWORD 'change-me';
    END IF;
END
$$;

GRANT web_anon TO authenticator;

GRANT USAGE ON SCHEMA public TO web_anon;
GRANT USAGE ON SCHEMA api TO web_anon;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO web_anon;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA api
    GRANT EXECUTE ON FUNCTIONS TO web_anon;

COMMIT;

NOTIFY pgrst, 'reload schema';
