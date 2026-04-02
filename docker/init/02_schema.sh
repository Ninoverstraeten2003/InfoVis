#!/usr/bin/env bash
# Applies all DDL SQL files in the correct order.
# Run by the postgres entrypoint as the superuser.
# ./db is mounted at /sql inside the container.

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -f /sql/schema.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -f /sql/add_food_display_profile.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -f /sql/views.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -f /sql/postgrest_api.sql

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -f /sql/postgrest_grants.sql

echo "✅  DB schema + API objects applied."
