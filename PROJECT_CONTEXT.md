# Project Context

This document summarizes the current NutriVerse data model, query layer, and working conventions established in the repo.

## Current Goal

Build a nutrition-focused data/query layer that can support three visualization directions:

- Nutrient interaction graph
- Food-to-reference-value comparison
- Future country-level deficiency/production paradox view

The current implementation focuses on integrating:

- EFSA dietary reference values
- CIQUAL food composition data
- nutrient interaction data

## Data Architecture

The project uses a layered model:

1. Raw source files
2. Staging transforms
3. Canonical Postgres schema
4. Materialized views for analysis and visualization queries

This avoids forcing every source into one rigid universal JSON structure while still making cross-dataset querying possible.

## Current Sources

### EFSA DRVs

Source file:

- `data/DRVs_All_populations.xlsx`

Staging transform:

- `scripts/transform_drvs.py`
- output: `data/drvs_eu_normalized.json`
- schema: `data/drvs_eu_normalized.schema.json`

This transform already does meaningful normalization:

- parses age labels into structured age objects
- parses reference values into scalar/range/not-available shapes

### CIQUAL

Source file:

- `data/Table Ciqual 2025_ENG_2025_11_03.xlsx`

Used for:

- food identity
- nutrient composition per 100g

### Nutrient interactions

Source file:

- `data/interactions.json`

Used for:

- directed synergy / antagonism / varies edges

## Canonical Schema

Main schema file:

- [db/schema.sql](/Users/ninoverstraeten/Documents/InfoVisNutri/db/schema.sql)

Core tables:

- `source_file`
- `source_row`
- `nutrient`
- `nutrient_alias`
- `reference_type`
- `population_group`
- `age_band`
- `intake_reference`
- `food`
- `food_display_profile`
- `food_nutrient_value`
- `nutrient_relationship`

### Important roles

`nutrient` / `nutrient_alias`

- this is the reconciliation layer across EFSA, CIQUAL, and interactions
- aliases are essential for joins across datasets

`intake_reference`

- canonical EFSA DRV rows
- includes `pal` because PAL applies to energy rows

`food` + `food_nutrient_value`

- canonical CIQUAL food composition layer

`nutrient_relationship`

- directed nutrient interaction edges

`food_display_profile`

- presentation-layer table
- stores curated ranking/display settings without changing the raw nutrition data

Fields include:

- `serving_size_g`
- `serving_label`
- `include_in_rankings`
- `ranking_category`
- `display_priority`

## Key Terms

### PAL

`PAL` means Physical Activity Level.

It is mainly relevant to energy requirement rows and differentiates otherwise similar age/population entries by activity assumption.

### drv_value

`drv_value` is the numeric EFSA reference value selected in a query row.

It acts as the denominator for `%DRV` calculations.

### pct_drv_per_100g

This means:

- percent of the selected EFSA DRV provided by 100g of a food

Formula:

`100 * food_value_per_100g / drv_value`

This is a density metric, not a realistic serving metric.

### pct_drv_per_100g_capped

This is the same metric capped at `100`.

Used for display/chart situations where values above `100` become visually unhelpful.

### pct_drv_per_serving

Serving-aware metric derived in curated queries when `serving_size_g` exists:

`pct_drv_per_100g * serving_size_g / 100`

Used for more practical ranking outputs.

## Query Layer

Main views file:

- [db/views.sql](/Users/ninoverstraeten/Documents/InfoVisNutri/db/views.sql)

Current materialized views:

- `v_food_nutrient_ranked`
- `v_drv_lookup`
- `v_interaction_graph`
- `v_top_foods_per_nutrient`
- `v_food_drv_coverage`

### What the views are for

`v_food_nutrient_ranked`

- food × nutrient ranking layer

`v_drv_lookup`

- flattened EFSA DRV lookup layer

`v_interaction_graph`

- ready-to-use nutrient network edges

`v_top_foods_per_nutrient`

- top foods per nutrient

`v_food_drv_coverage`

- combines food nutrient values with EFSA DRVs
- exposes `%DRV` style metrics

## Important Query Files

- [db/examples.sql](/Users/ninoverstraeten/Documents/InfoVisNutri/db/examples.sql)
- [db/feasibility_queries.sql](/Users/ninoverstraeten/Documents/InfoVisNutri/db/feasibility_queries.sql)

These contain reusable example queries and queries derived from the visualization feasibility analysis.

## Feasibility Mapping

Source note:

- [viz_feasibility_analysis.md](/Users/ninoverstraeten/Documents/InfoVisNutri/viz_feasibility_analysis.md)

Current interpretation:

### Viz 1: Nutrient Cosmos

Use:

- `v_interaction_graph`
- nutrient degree summaries
- nutrient-anchor food queries

### Viz 2: Perfect Plate

Use:

- `v_food_drv_coverage`
- curated food queries through `food_display_profile`
- serving-aware ranking where available

### Viz 3: What the World Is Missing

Not implemented yet.

The agreed direction is:

- use country deficiency data
- use production/supply data
- bridge them through food/nutrient composition data

No country-level tables are loaded yet.

## Curated Food Display Layer

Starter CSV:

- [db/food_display_profile.sample.csv](/Users/ninoverstraeten/Documents/InfoVisNutri/db/food_display_profile.sample.csv)

Loader:

- [scripts/load_food_display_profile.py](/Users/ninoverstraeten/Documents/InfoVisNutri/scripts/load_food_display_profile.py)

The loader supports:

- insert/update mode
- replace-sync mode with `--replace`

Replace mode behavior:

- rows present in the CSV are inserted/updated
- rows removed from the CSV are deleted from `food_display_profile`

Current curated starter set includes practical foods such as:

- potato
- carrot
- onion
- spinach
- broccoli
- apple
- pear
- brown bread
- oat flakes
- lentils
- milk
- yogurt
- cheese
- egg
- chicken
- beef
- salmon
- mussels

## Important Behavior Notes

### Raw vs curated queries

Not all queries are curated.

Raw views and many example queries still use the full dataset.

Only curated ranking queries explicitly filter through:

- `JOIN food_display_profile`
- `WHERE include_in_rankings = TRUE`

### Duplicate adult baseline issue

The base view layer can still expose more than one adult baseline row for some nutrient/sex/ref type combinations.

This is not a loader/data corruption issue. It is a query-layer baseline-selection issue.

For the curated `Q4` / `V2.5` Iron ranking query, this was handled locally by selecting a preferred baseline row inside the query itself.

The broader view-level cleanup was intentionally postponed.

## Current Recommended Commands

Make sure Postgres 17 binaries are on PATH:

```bash
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"
```

Run the reusable example queries:

```bash
psql nutriverse -f db/examples.sql
```

Run the feasibility-oriented query set:

```bash
psql nutriverse -f db/feasibility_queries.sql
```

Reload the curated food display profile from CSV:

```bash
python3 scripts/load_food_display_profile.py --replace
```

Apply the display-profile table migration to an existing DB:

```bash
psql nutriverse < db/add_food_display_profile.sql
```

## Open Next Steps

Likely next useful tasks:

- expand `food_display_profile.sample.csv` into a larger curated ingredient list
- normalize or centralize adult baseline selection in `v_food_drv_coverage`
- add serving-aware curated views if needed
- add country-level deficiency / supply tables for Viz 3
- build API/UI queries directly against the current view layer
