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
echo "→ 1/5  seed_canonical"
python scripts/seed_canonical.py

echo "→ 2/5  load_efsa_drvs"
python scripts/load_efsa_drvs.py

echo "→ 3/5  load_ciqual"
python scripts/load_ciqual.py

echo "→ 4/5  load_interactions"
python scripts/load_interactions.py

echo "→ 5/5  load_food_display_profile"
python scripts/load_food_display_profile.py

echo ""
echo "── Validations ──────────────────────────────────────"
python scripts/validate_canonical.py
python scripts/validate_data_jsons.py

echo ""
echo "✅  Seeding complete!"
