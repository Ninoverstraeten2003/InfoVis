#!/usr/bin/env bash
# One-shot seeder entrypoint — mirrors setup_db.sh but targets Docker env.
set -e

echo "====================================================="
echo " NutriVerse Data Seeder"
echo " DATABASE_URL = $DATABASE_URL"
echo "====================================================="

echo ""
echo "── Data Transformations ─────────────────────────────"
python scripts/transform_drvs.py

echo ""
echo "── Data Loaders ─────────────────────────────────────"
echo "→ 1/6  seed_canonical"
python scripts/seed_canonical.py

echo "→ 2/6  load_efsa_drvs"
python scripts/load_efsa_drvs.py

echo "→ 3/6  load_ciqual"
python scripts/load_ciqual.py

echo "→ 4/6  load_interactions"
python scripts/load_interactions.py

echo "→ 5/6  load_food_display_profile"
python scripts/load_food_display_profile.py

echo "→ 6/7  load_gnr"
python scripts/load_gnr.py

echo "→ 7/7  load_faostat"
python scripts/load_faostat.py

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
echo "→ REFRESH v_food_drv_coverage"
psql "$DATABASE_URL" -c "REFRESH MATERIALIZED VIEW v_food_drv_coverage;"

echo ""
echo "── Validations ──────────────────────────────────────"
python scripts/validate_canonical.py
python scripts/validate_data_jsons.py

echo ""
echo "✅  Seeding complete!"
