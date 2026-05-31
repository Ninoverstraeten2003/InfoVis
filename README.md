# NutriVerse

A high-performance personalized nutritional engine and Genetic Algorithm meal planner.

## Start the Services

Run the PostgreSQL database and PostgREST API in the background before running any setup scripts:

```bash
docker compose up -d
```

## Database Setup

Initialize the database. To refresh canonical data **without** dropping the `food_display_profile` (which preserves your LLM-generated culinary categories), run:

```bash
# Local
./setup_db.sh --transform --load-all --refresh

# Docker
docker compose run --rm seeder --seeder
```

## Generate Culinary Profiles

Automatically categorize raw CIQUAL foods into culinary categories (e.g., `main`, `side`, `carb_base`, `beverage`) using the LLM. 
*(Make sure to run `pip install -r requirements.txt` first if running locally!)*
*(Make sure `OPENROUTER_API_KEY` is set in your `.env` file if running via Docker!)*

```bash
# Local
python scripts/generate_display_profiles.py

# Docker
docker compose run --rm --entrypoint="" seeder python scripts/generate_display_profiles.py
```

## Run the Genetic Algorithm

Test the in-memory GA engine to instantly generate a balanced, personalized 2500+ kcal daily meal plan:

```bash
# Local
python scripts/meal_generator_ga.py

# Docker
docker compose run --rm --entrypoint="" seeder python scripts/meal_generator_ga.py
```
