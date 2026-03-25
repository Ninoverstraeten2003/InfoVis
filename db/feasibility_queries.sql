-- NutriVerse Visualization Queries
-- Derived from viz_feasibility_analysis.md
-- Run pieces of this file with:
--   psql nutriverse -f db/feasibility_queries.sql

-- ================================================================
-- VIZ 1: The Nutrient Cosmos
-- Goal: show dietary-level nutrient interaction graph + food anchors
-- ================================================================

-- V1.1 Graph edges for the interaction network.
SELECT
    source_nutrient,
    source_category,
    target_nutrient,
    target_category,
    relationship_type
FROM v_interaction_graph
ORDER BY relationship_type, source_nutrient, target_nutrient;

-- V1.2 Degree summary for sizing nodes in the graph.
WITH edges AS (
    SELECT source_nutrient AS nutrient_name FROM v_interaction_graph
    UNION ALL
    SELECT target_nutrient AS nutrient_name FROM v_interaction_graph
),
degree_counts AS (
    SELECT nutrient_name, COUNT(*) AS degree
    FROM edges
    GROUP BY nutrient_name
)
SELECT
    n.canonical_name AS nutrient_name,
    n.category,
    COALESCE(dc.degree, 0) AS total_degree,
    COUNT(*) FILTER (WHERE ig.source_nutrient = n.canonical_name AND ig.relationship_type = 'synergistic') AS outgoing_synergies,
    COUNT(*) FILTER (WHERE ig.source_nutrient = n.canonical_name AND ig.relationship_type = 'antagonistic') AS outgoing_antagonisms,
    COUNT(*) FILTER (WHERE ig.source_nutrient = n.canonical_name AND ig.relationship_type = 'varies') AS outgoing_varies
FROM nutrient n
LEFT JOIN degree_counts dc ON dc.nutrient_name = n.canonical_name
LEFT JOIN v_interaction_graph ig ON ig.source_nutrient = n.canonical_name
WHERE COALESCE(dc.degree, 0) > 0
GROUP BY n.canonical_name, n.category, dc.degree
ORDER BY total_degree DESC, nutrient_name;

-- V1.3 Food anchors for a selected nutrient.
-- Example: foods richest in Iron plus its interaction neighbors.
WITH selected AS (
    SELECT 'Iron'::text AS nutrient_name
),
neighbors AS (
    SELECT target_nutrient AS nutrient_name, relationship_type
    FROM v_interaction_graph ig
    JOIN selected s ON s.nutrient_name = ig.source_nutrient
    UNION ALL
    SELECT source_nutrient AS nutrient_name, relationship_type
    FROM v_interaction_graph ig
    JOIN selected s ON s.nutrient_name = ig.target_nutrient
),
top_foods AS (
    SELECT
        tpn.nutrient_name,
        tpn.food_name,
        tpn.value,
        tpn.unit,
        tpn.rank
    FROM v_top_foods_per_nutrient tpn
    JOIN (
        SELECT nutrient_name FROM selected
        UNION
        SELECT nutrient_name FROM neighbors
    ) x ON x.nutrient_name = tpn.nutrient_name
)
SELECT *
FROM top_foods
ORDER BY nutrient_name, rank, food_name;


-- ================================================================
-- VIZ 2: The Perfect Plate
-- Goal: compare foods to EFSA-derived DRV targets
-- ================================================================

-- V2.1 Top foods for a target nutrient / demographic.
SELECT
    food_name,
    nutrient_name,
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
LIMIT 20;

-- V2.2 Nutrient density panel for a single food across core micronutrients.
SELECT
    food_name,
    nutrient_name,
    food_value_per_100g,
    food_unit,
    pct_drv_per_100g,
    pct_drv_per_100g_capped,
    drv_sex,
    age_label,
    ref_type
FROM v_food_drv_coverage
WHERE food_name = 'Spinach, raw'
  AND nutrient_name IN ('Iron', 'Calcium', 'Magnesium', 'Vitamin A', 'Vitamin C', 'Folate')
ORDER BY nutrient_name, drv_sex, ref_type;

-- V2.3 "Support cluster" query: best foods for Vitamin D-related synergistic nutrients.
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

-- V2.4 "Conflict-aware" tradeoff rank: maximize target nutrient while
-- penalizing foods that are also rich in antagonists of that target.
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

-- V2.5 Curated display query
-- Uses food_display_profile as a presentation layer for viz-facing rankings.
-- Sort by serving-based contribution when available, otherwise fall back
-- to per-100g density.
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


-- ================================================================
-- VIZ 3: What the World Is Missing
-- Goal: deficiency + production/supply paradox
-- Status: scaffold only; requires country-level tables not yet loaded
-- Suggested tables:
--   country
--   country_nutrient_deficiency
--   country_food_supply
--   food_supply_nutrient_bridge
-- ================================================================

-- V3.1 Example target shape for a choropleth-backed nutrient dropdown.
-- Replace table names once country data exists.
-- SELECT
--     c.country_name,
--     d.nutrient_name,
--     d.measure_year,
--     d.prevalence_pct
-- FROM country_nutrient_deficiency d
-- JOIN country c ON c.id = d.country_id
-- WHERE d.nutrient_name IN ('Iron', 'Vitamin A', 'Zinc', 'Iodine')
-- ORDER BY d.nutrient_name, d.prevalence_pct DESC;

-- V3.2 Example paradox query:
-- "Countries with high iron deficiency but strong iron-rich food supply"
-- SELECT
--     c.country_name,
--     d.prevalence_pct AS iron_deficiency_pct,
--     SUM(fs.supply_amount * b.iron_mg_per_unit) AS iron_supply_score
-- FROM country_nutrient_deficiency d
-- JOIN country c ON c.id = d.country_id
-- JOIN country_food_supply fs ON fs.country_id = c.id
-- JOIN food_supply_nutrient_bridge b ON b.food_item_id = fs.food_item_id
-- WHERE d.nutrient_name = 'Iron'
-- GROUP BY c.country_name, d.prevalence_pct
-- ORDER BY d.prevalence_pct DESC, iron_supply_score DESC;
