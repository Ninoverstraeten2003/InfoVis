#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Defaults (everything is opt-in)
RUN_SCHEMA=0
RUN_TRANSFORM=0
RUN_REFRESH=0
RUN_VALIDATE=0

# Arrays to hold specific loaders/validators
LOADERS=()

# Parse arguments
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --schema                 Run Database Schema Setup"
    echo "  --transform              Run Data Transformations"
    echo "  --load <loader>          Run specific loader (e.g. seed_canonical, load_ciqual). Can be specified multiple times."
    echo "  --load-all               Run all data loaders"
    echo "  --refresh                Refresh Materialized Views"
    echo "  --validate               Run Validations"
    echo "  --all                    Run everything (schema, transform, load-all, refresh, validate)"
    echo "  --seeder                 Standard Docker Seeder Run (transform, load-all, refresh)"
    echo ""
    echo "Loaders available: seed_canonical, load_efsa_drvs, load_ciqual, load_interactions, load_food_display_profile, load_gnr, load_faostat"
    echo ""
    echo "Defaulting to NO actions. You must explicitly opt-in."
    exit 0
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --schema) RUN_SCHEMA=1 ;;
    --transform) RUN_TRANSFORM=1 ;;
    --load)
      shift
      LOADERS+=("$1")
      ;;
    --load-all)
      LOADERS=("seed_canonical" "load_efsa_drvs" "load_ciqual" "load_interactions" "load_food_display_profile" "load_gnr" "load_faostat")
      ;;
    --refresh) RUN_REFRESH=1 ;;
    --validate) RUN_VALIDATE=1 ;;
    --all)
      RUN_SCHEMA=1
      RUN_TRANSFORM=1
      LOADERS=("seed_canonical" "load_efsa_drvs" "load_ciqual" "load_interactions" "load_food_display_profile" "load_gnr" "load_faostat")
      RUN_REFRESH=1
      RUN_VALIDATE=1
      ;;
    --seeder)
      RUN_TRANSFORM=1
      LOADERS=("seed_canonical" "load_efsa_drvs" "load_ciqual" "load_interactions" "load_food_display_profile" "load_gnr" "load_faostat")
      RUN_REFRESH=1
      ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Default to local db if not set
export DATABASE_URL=${DATABASE_URL:-"postgresql://postgres:postgres@localhost:5433/nutriverse"}

echo "====================================================="
echo " NutriVerse Setup / Seeder"
echo " DATABASE_URL = $DATABASE_URL"
echo "====================================================="

if [ $RUN_SCHEMA -eq 1 ]; then
    echo ""
    echo "── Database Schema Setup ────────────────────────────"
    echo "→ 1/5  db/schema.sql"
    psql "$DATABASE_URL" -f db/schema.sql
    echo "→ 2/5  db/add_food_display_profile.sql"
    psql "$DATABASE_URL" -f db/add_food_display_profile.sql
    echo "→ 3/5  db/views.sql"
    psql "$DATABASE_URL" -f db/views.sql
    echo "→ 4/5  db/postgrest_api.sql"
    psql "$DATABASE_URL" -f db/postgrest_api.sql
    echo "→ 5/5  db/postgrest_grants.sql"
    psql "$DATABASE_URL" -f db/postgrest_grants.sql
fi

if [ $RUN_TRANSFORM -eq 1 ]; then
    echo ""
    echo "── Data Transformations ─────────────────────────────"
    python scripts/transform_drvs.py
fi

if [ ${#LOADERS[@]} -gt 0 ]; then
    echo ""
    echo "── Data Loaders ─────────────────────────────────────"
    # Deduplicate array if necessary (just running in order provided)
    for loader in "${LOADERS[@]}"; do
        echo "→ scripts/${loader}.py"
        python "scripts/${loader}.py"
    done
fi

if [ $RUN_REFRESH -eq 1 ]; then
    echo ""
    echo "── Refresh Materialized Views ──────────────────────"
    echo "→ REFRESH v_food_nutrient_ranked"
    psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_food_nutrient_ranked;"
    echo "→ REFRESH v_drv_lookup"
    psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_drv_lookup;"
    echo "→ REFRESH v_interaction_graph"
    psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_interaction_graph;"
    echo "→ REFRESH v_top_foods_per_nutrient"
    psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_top_foods_per_nutrient;"
fi

if [ $RUN_VALIDATE -eq 1 ]; then
    echo ""
    echo "── Validations ──────────────────────────────────────"
    echo "→ scripts/validate_canonical.py"
    python scripts/validate_canonical.py
    echo "→ scripts/validate_data_jsons.py"
    python scripts/validate_data_jsons.py
fi

echo ""
echo "✅  Execution complete!"
