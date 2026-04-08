#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default to local db if not set
export DATABASE_URL=${DATABASE_URL:-"postgresql://localhost:5432/nutriverse"}

echo "Running Database Schema Setup..."
echo "-> 1/5: db/schema.sql"
psql "$DATABASE_URL" -f db/schema.sql
echo "-> 2/5: db/add_food_display_profile.sql"
psql "$DATABASE_URL" -f db/add_food_display_profile.sql
echo "-> 3/5: db/views.sql"
psql "$DATABASE_URL" -f db/views.sql
echo "-> 4/5: db/postgrest_api.sql"
psql "$DATABASE_URL" -f db/postgrest_api.sql
echo "-> 5/5: db/postgrest_grants.sql"
psql "$DATABASE_URL" -f db/postgrest_grants.sql

echo ""
echo "Running Data Transformations..."
echo "-> scripts/transform_drvs.py"
python scripts/transform_drvs.py

echo ""
echo "Running Data Loaders..."
echo "-> 1/6: scripts/seed_canonical.py"
python scripts/seed_canonical.py
echo "-> 2/6: scripts/load_efsa_drvs.py"
python scripts/load_efsa_drvs.py
echo "-> 3/6: scripts/load_ciqual.py"
python scripts/load_ciqual.py
echo "-> 4/6: scripts/load_interactions.py"
python scripts/load_interactions.py
echo "-> 5/6: scripts/load_food_display_profile.py"
python scripts/load_food_display_profile.py
echo "-> 6/7: scripts/load_gnr.py"
python scripts/load_gnr.py
echo "-> 7/7: scripts/load_faostat.py"
python scripts/load_faostat.py

echo ""
echo "Refreshing Materialized Views..."
echo "-> REFRESH MATERIALIZED VIEW v_food_nutrient_ranked"
psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_food_nutrient_ranked;"
echo "-> REFRESH MATERIALIZED VIEW v_drv_lookup"
psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_drv_lookup;"
echo "-> REFRESH MATERIALIZED VIEW v_interaction_graph"
psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_interaction_graph;"
echo "-> REFRESH MATERIALIZED VIEW v_top_foods_per_nutrient"
psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_top_foods_per_nutrient;"
echo "-> REFRESH MATERIALIZED VIEW v_food_drv_coverage"
psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_food_drv_coverage;"

echo ""
echo "Running Validations..."
echo "-> scripts/validate_canonical.py"
python scripts/validate_canonical.py
echo "-> scripts/validate_data_jsons.py"
python scripts/validate_data_jsons.py

echo ""
echo "Setup Complete!"
