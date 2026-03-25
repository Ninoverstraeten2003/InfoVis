-- NutriVerse Example Queries
-- Run with:
--   psql nutriverse -f db/examples.sql

-- Refresh materialized views after data reloads.
REFRESH MATERIALIZED VIEW v_food_nutrient_ranked;
REFRESH MATERIALIZED VIEW v_drv_lookup;
REFRESH MATERIALIZED VIEW v_interaction_graph;
REFRESH MATERIALIZED VIEW v_top_foods_per_nutrient;
REFRESH MATERIALIZED VIEW v_food_drv_coverage;

-- Q1: Top foods for Iron for adult females (PRI baseline)
SELECT
    food_name,
    food_value_per_100g,
    pct_drv_per_100g,
    pct_drv_per_100g_capped,
    drv_sex,
    age_label,
    ref_type
FROM v_food_drv_coverage
WHERE nutrient_name = 'Iron'
  AND drv_sex = 'Female'
  AND ref_type = 'PRI'
ORDER BY pct_drv_per_100g DESC NULLS LAST
LIMIT 15;

-- Q2: Target-first tradeoff ranking for Iron with antagonist penalty.
WITH antagonists AS (
    SELECT DISTINCT
        CASE
            WHEN ig.source_nutrient = 'Iron' THEN ig.target_nutrient
            ELSE ig.source_nutrient
        END AS nutrient_name
    FROM v_interaction_graph ig
    WHERE ig.relationship_type = 'antagonistic'
      AND (ig.source_nutrient = 'Iron' OR ig.target_nutrient = 'Iron')
),
target_rows AS (
    SELECT
        v.food_id,
        v.food_name,
        v.food_value_per_100g,
        v.pct_drv_per_100g,
        v.pct_drv_per_100g_capped,
        v.drv_sex,
        v.age_label,
        v.ref_type
    FROM v_food_drv_coverage v
    WHERE v.nutrient_name = 'Iron'
      AND v.drv_sex = 'Female'
      AND v.ref_type = 'PRI'
),
antagonist_rows AS (
    SELECT
        v.food_id,
        ROUND(SUM(COALESCE(v.pct_drv_per_100g_capped, 0)), 1) AS antagonist_pct_drv_penalty
    FROM v_food_drv_coverage v
    JOIN antagonists a ON a.nutrient_name = v.nutrient_name
    WHERE v.drv_sex = 'Female'
      AND v.ref_type = 'PRI'
      AND COALESCE(v.pct_drv_per_100g_capped, 0) > 0
    GROUP BY v.food_id
)
SELECT
    t.food_name,
    t.food_value_per_100g AS iron_mg,
    t.pct_drv_per_100g AS iron_pct_drv,
    t.pct_drv_per_100g_capped AS iron_pct_drv_capped,
    COALESCE(a.antagonist_pct_drv_penalty, 0) AS antagonist_pct_drv_penalty,
    ROUND(
        t.pct_drv_per_100g_capped - (0.35 * COALESCE(a.antagonist_pct_drv_penalty, 0)),
        1
    ) AS tradeoff_score,
    t.drv_sex,
    t.age_label,
    t.ref_type
FROM target_rows t
LEFT JOIN antagonist_rows a ON a.food_id = t.food_id
ORDER BY tradeoff_score DESC NULLS LAST, iron_pct_drv DESC NULLS LAST
LIMIT 20;

-- Q3: Best foods to support Vitamin D-related synergistic nutrients
-- Balanced by nutrient: top 5 foods per synergistic nutrient, then ranked.
WITH vd_cluster AS (
    SELECT DISTINCT target_nutrient AS nutrient_name
    FROM v_interaction_graph
    WHERE source_nutrient = 'Vitamin D'
      AND relationship_type = 'synergistic'
),
ranked AS (
    SELECT
        vfdc.food_name,
        vfdc.nutrient_name,
        vfdc.food_value_per_100g,
        vfdc.pct_drv_per_100g,
        vfdc.pct_drv_per_100g_capped,
        vfdc.drv_sex,
        vfdc.age_label,
        vfdc.ref_type,
        ROW_NUMBER() OVER (
            PARTITION BY vfdc.nutrient_name
            ORDER BY vfdc.pct_drv_per_100g DESC NULLS LAST, vfdc.food_name
        ) AS nutrient_rank
    FROM v_food_drv_coverage vfdc
    JOIN vd_cluster c ON c.nutrient_name = vfdc.nutrient_name
    WHERE vfdc.drv_sex IN ('Female', 'Both genders')
      AND vfdc.ref_type IN ('PRI', 'AI')
)
SELECT
    food_name,
    nutrient_name,
    food_value_per_100g,
    pct_drv_per_100g,
    pct_drv_per_100g_capped,
    drv_sex,
    age_label,
    ref_type,
    nutrient_rank
FROM ranked
WHERE nutrient_rank <= 5
ORDER BY nutrient_name, nutrient_rank, food_name;

-- Q4: Curated ranking using food_display_profile
-- Only foods explicitly marked for rankings.
-- Sort by serving-based contribution when available, otherwise fall back
-- to the per-100g density metric.
WITH curated_ranked AS (
    SELECT
        v.food_name,
        v.nutrient_name,
        v.food_value_per_100g,
        v.pct_drv_per_100g,
        v.pct_drv_per_100g_capped,
        fdp.serving_size_g,
        fdp.serving_label,
        CASE
            WHEN fdp.serving_size_g IS NOT NULL
            THEN ROUND(v.pct_drv_per_100g * fdp.serving_size_g / 100.0, 1)
            ELSE NULL
        END AS pct_drv_per_serving,
        fdp.ranking_category,
        fdp.display_priority,
        v.age_label,
        v.ref_type,
        ROW_NUMBER() OVER (
            PARTITION BY v.food_id, v.nutrient_name, v.drv_sex, v.ref_type
            ORDER BY
                CASE
                    WHEN v.age_label = '≥ 18 years' THEN 0
                    WHEN v.age_label = '18-24 years' THEN 1
                    ELSE 2
                END,
                v.age_label
        ) AS baseline_rank
    FROM v_food_drv_coverage v
    JOIN food_display_profile fdp ON fdp.food_id = v.food_id
    WHERE fdp.include_in_rankings = TRUE
      AND v.nutrient_name = 'Iron'
      AND v.drv_sex = 'Female'
      AND v.ref_type = 'PRI'
)
SELECT
    food_name,
    nutrient_name,
    food_value_per_100g,
    pct_drv_per_100g,
    pct_drv_per_100g_capped,
    serving_size_g,
    serving_label,
    pct_drv_per_serving,
    ranking_category,
    display_priority,
    age_label,
    ref_type
FROM curated_ranked
WHERE baseline_rank = 1
ORDER BY
    display_priority ASC,
    COALESCE(pct_drv_per_serving, pct_drv_per_100g) DESC NULLS LAST,
    food_name
LIMIT 20;
