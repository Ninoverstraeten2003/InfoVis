# NutriVerse

A high-performance personalized nutritional engine and Genetic Algorithm meal planner.

## Database Setup

Initialize the database. To refresh canonical data **without** dropping the `food_display_profile` (which preserves your LLM-generated culinary categories), run:

```bash
./setup_db.sh --transform --load seed_canonical --load load_efsa_drvs --load load_ciqual --refresh
```

## Generate Culinary Profiles

Automatically categorize raw CIQUAL foods into culinary categories (e.g., `main`, `side`, `carb_base`, `beverage`) using the LLM:

```bash
python scripts/generate_display_profiles.py
```

## Run the Genetic Algorithm

Test the in-memory GA engine to instantly generate a balanced, personalized 2500+ kcal daily meal plan:

```bash
python scripts/meal_generator_ga.py
```
