-- NutriVerse Core Query Views
-- =====================================================================
-- These materialized views answer the core NutriVerse questions:
--   1. "Top foods for nutrient X for population Y"
--   2. "Target-first tradeoff ranking (target nutrient vs antagonists)"
--   3. "Best foods to support a nutrient cluster"
--   4. Nutrient interaction graph (for visualization)
--   5. Coverage dashboard
-- =====================================================================

BEGIN;

DROP MATERIALIZED VIEW IF EXISTS v_food_drv_coverage;
DROP MATERIALIZED VIEW IF EXISTS v_top_foods_per_nutrient;
DROP MATERIALIZED VIEW IF EXISTS v_interaction_graph;
DROP MATERIALIZED VIEW IF EXISTS v_drv_lookup;
DROP MATERIALIZED VIEW IF EXISTS v_food_nutrient_ranked;

-- =====================================================================
-- VIEW 1: v_food_nutrient_ranked
-- Flattened food × nutrient data with per-nutrient percentile rankings.
-- Core building block for all "top foods for X" queries.
-- =====================================================================
CREATE MATERIALIZED VIEW v_food_nutrient_ranked AS
WITH fnv_measured AS (
    SELECT
        fnv.id,
        fnv.food_id,
        fnv.nutrient_id,
        fnv.value,
        fnv.unit,
        fnv.raw_column_name,
        n.canonical_name,
        n.default_unit
    FROM food_nutrient_value fnv
    JOIN nutrient n ON n.id = fnv.nutrient_id
    WHERE fnv.quality_flag = 'measured'
      AND fnv.value IS NOT NULL
      AND fnv.value > 0
),
fnv_ranked AS (
    SELECT
        fm.*,
        ROW_NUMBER() OVER (
            PARTITION BY fm.food_id, fm.nutrient_id
            ORDER BY
                CASE WHEN fm.unit = fm.default_unit THEN 0 ELSE 1 END,
                CASE WHEN fm.raw_column_name ILIKE fm.canonical_name || ' (%' THEN 0 ELSE 1 END,
                CASE WHEN fm.raw_column_name ILIKE '%jones%' THEN 1 ELSE 0 END,
                CASE WHEN fm.raw_column_name ILIKE '%crude%' THEN 1 ELSE 0 END,
                LENGTH(fm.raw_column_name),
                fm.raw_column_name,
                fm.id
        ) AS value_rank
    FROM fnv_measured fm
),
fnv_resolved AS (
    -- EPA+DHA is represented in CIQUAL as two component columns; sum them.
    SELECT
        fm.food_id,
        fm.nutrient_id,
        SUM(fm.value) AS value,
        MIN(fm.default_unit) AS unit
    FROM fnv_measured fm
    WHERE fm.canonical_name = 'EPA+DHA'
    GROUP BY fm.food_id, fm.nutrient_id

    UNION ALL

    -- Other nutrients: keep one deterministic canonical value per food+nutrient.
    SELECT
        fr.food_id,
        fr.nutrient_id,
        fr.value,
        fr.unit
    FROM fnv_ranked fr
    WHERE fr.canonical_name <> 'EPA+DHA'
      AND fr.value_rank = 1
)
SELECT
    f.id                    AS food_id,
    f.name                  AS food_name,
    f.group_name,
    f.subgroup_name,
    n.id                    AS nutrient_id,
    n.canonical_name        AS nutrient_name,
    n.category              AS nutrient_category,
    r.value,
    r.unit,
    'measured'::text        AS quality_flag,
    -- Percentile rank within each nutrient (only among measured values)
    PERCENT_RANK() OVER (
        PARTITION BY n.id
        ORDER BY r.value
    )                       AS pctile
FROM food f
JOIN fnv_resolved r ON r.food_id = f.id
JOIN nutrient n ON n.id = r.nutrient_id;

CREATE INDEX idx_vfnr_nutrient  ON v_food_nutrient_ranked(nutrient_id);
CREATE INDEX idx_vfnr_food      ON v_food_nutrient_ranked(food_id);
CREATE INDEX idx_vfnr_pctile    ON v_food_nutrient_ranked(nutrient_id, pctile DESC);


-- =====================================================================
-- VIEW 2: v_drv_lookup
-- Flattened DRV lookup: nutrient × population × age → reference values.
-- Makes "what's the DRV for Iron for adult females?" a one-liner.
-- =====================================================================
CREATE MATERIALIZED VIEW v_drv_lookup AS
SELECT
    n.canonical_name        AS nutrient_name,
    n.category              AS nutrient_category,
    pg.label                AS population_label,
    pg.sex,
    pg.life_stage,
    ab.min_value            AS age_min,
    ab.max_value            AS age_max,
    ab.unit                 AS age_unit,
    ab.raw_label            AS age_label,
    rt.code                 AS ref_type,
    rt.label                AS ref_type_label,
    ir.value_numeric,
    ir.value_min,
    ir.value_max,
    ir.unit,
    ir.status,
    ir.pal
FROM intake_reference ir
JOIN nutrient n             ON n.id = ir.nutrient_id
JOIN population_group pg    ON pg.id = ir.population_group_id
JOIN age_band ab            ON ab.id = ir.age_band_id
JOIN reference_type rt      ON rt.id = ir.reference_type_id;

CREATE INDEX idx_vdl_nutrient ON v_drv_lookup(nutrient_name);
CREATE INDEX idx_vdl_pop      ON v_drv_lookup(population_label, sex);


-- =====================================================================
-- VIEW 3: v_interaction_graph
-- Directed nutrient interaction edges with full names.
-- Ready for graph visualization (D3, Cytoscape, etc.)
-- =====================================================================
CREATE MATERIALIZED VIEW v_interaction_graph AS
SELECT
    nl.id                   AS source_id,
    nl.canonical_name       AS source_nutrient,
    nl.category             AS source_category,
    nr.id                   AS target_id,
    nr.canonical_name       AS target_nutrient,
    nr.category             AS target_category,
    nrel.relationship_type,
    nrel.evidence_scope
FROM nutrient_relationship nrel
JOIN nutrient nl ON nl.id = nrel.left_nutrient_id
JOIN nutrient nr ON nr.id = nrel.right_nutrient_id;


-- =====================================================================
-- VIEW 4: v_top_foods_per_nutrient
-- Pre-computed top 20 foods per nutrient (measured values only).
-- Powers "top foods for iron" dashboards without repeatedly sorting.
-- =====================================================================
CREATE MATERIALIZED VIEW v_top_foods_per_nutrient AS
WITH ranked AS (
    SELECT
        nutrient_id,
        nutrient_name,
        nutrient_category,
        food_id,
        food_name,
        group_name,
        value,
        unit,
        ROW_NUMBER() OVER (
            PARTITION BY nutrient_id
            ORDER BY value DESC
        ) AS rank
    FROM v_food_nutrient_ranked
)
SELECT * FROM ranked
WHERE rank <= 20;

CREATE INDEX idx_vtfpn_nutrient ON v_top_foods_per_nutrient(nutrient_id);
CREATE INDEX idx_vtfpn_name     ON v_top_foods_per_nutrient(nutrient_name);


-- =====================================================================
-- VIEW 5: v_food_drv_coverage
-- For each food, shows what % of a baseline adult DRV it provides
-- per 100g. Adult DRVs are ranked so nutrients like Calcium that use
-- age bands such as "18-24 years" or ">= 25 years" still resolve.
-- Powers "nutritional density" rankings and radar charts.
-- =====================================================================
CREATE MATERIALIZED VIEW v_food_drv_coverage AS
WITH adult_drv_ranked AS (
    SELECT
        drv.*,
        ROW_NUMBER() OVER (
            -- One adult baseline per nutrient + sex + reference type.
            PARTITION BY drv.nutrient_name, drv.sex, drv.ref_type
            ORDER BY
                CASE
                    WHEN drv.age_label = '≥ 18 years' THEN 0
                    WHEN drv.age_min = 18 AND drv.age_max IS NOT NULL THEN 1
                    WHEN drv.age_min = 18 THEN 2
                    WHEN drv.age_min IS NOT NULL THEN 3
                    ELSE 4
                END,
                CASE
                    WHEN drv.population_label = 'Adults' THEN 0
                    WHEN POSITION('(' IN drv.population_label) = 0 THEN 1
                    WHEN drv.population_label ILIKE '%LPI 600 mg/day%' THEN 2
                    WHEN drv.population_label ILIKE '%LPI 900 mg/day%' THEN 3
                    WHEN drv.population_label ILIKE '%LPI 300 mg/day%' THEN 4
                    WHEN drv.population_label ILIKE '%LPI 1200 mg/day%' THEN 5
                    ELSE 6
                END,
                drv.age_min NULLS LAST,
                drv.age_max NULLS LAST,
                drv.age_label,
                drv.value_numeric NULLS LAST,
                drv.population_label
        ) AS baseline_rank
    FROM v_drv_lookup drv
    WHERE drv.status = 'value'
      AND drv.ref_type IN ('PRI', 'AI')
      AND drv.life_stage = 'adult'
),
adult_drv_baseline AS (
    SELECT
        nutrient_name,
        nutrient_category,
        population_label,
        sex,
        life_stage,
        age_min,
        age_max,
        age_unit,
        age_label,
        ref_type,
        ref_type_label,
        value_numeric,
        value_min,
        value_max,
        unit,
        status,
        pal
    FROM adult_drv_ranked
    WHERE baseline_rank = 1
)
SELECT
    vfnr.food_id,
    vfnr.food_name,
    vfnr.group_name,
    vfnr.nutrient_name,
    vfnr.nutrient_category,
    vfnr.value              AS food_value_per_100g,
    vfnr.unit               AS food_unit,
    drv.population_label,
    drv.ref_type,
    drv.sex                 AS drv_sex,
    drv.value_numeric       AS drv_value,
    drv.unit                AS drv_unit,
    drv.age_label,
    -- % of DRV covered by 100g of this food
    CASE
        WHEN drv.value_numeric IS NOT NULL AND drv.value_numeric > 0
        THEN ROUND(100.0 * vfnr.value / drv.value_numeric, 1)
        ELSE NULL
    END                     AS pct_drv_per_100g,
    -- Capped display-friendly variant for charts where >100% is not useful.
    CASE
        WHEN drv.value_numeric IS NOT NULL AND drv.value_numeric > 0
        THEN LEAST(ROUND(100.0 * vfnr.value / drv.value_numeric, 1), 100.0)
        ELSE NULL
    END                     AS pct_drv_per_100g_capped
FROM v_food_nutrient_ranked vfnr
JOIN adult_drv_baseline drv ON drv.nutrient_name = vfnr.nutrient_name;

CREATE INDEX idx_vfdc_food     ON v_food_drv_coverage(food_id);
CREATE INDEX idx_vfdc_nutrient ON v_food_drv_coverage(nutrient_name);
CREATE INDEX idx_vfdc_pct      ON v_food_drv_coverage(pct_drv_per_100g DESC NULLS LAST);


COMMIT;

-- =====================================================================
-- Useful ad-hoc queries using these views:
-- =====================================================================

-- Q1: "Top foods for iron for adult females"
-- SELECT food_name, food_value_per_100g, pct_drv_per_100g, pct_drv_per_100g_capped, ref_type
-- FROM v_food_drv_coverage
-- WHERE nutrient_name = 'Iron'
--   AND drv_sex = 'Female'
-- ORDER BY pct_drv_per_100g DESC NULLS LAST
-- LIMIT 15;

-- Q2: "Tradeoff ranking for iron (target coverage minus antagonist burden)"
-- WITH antagonists AS (
--   SELECT DISTINCT CASE WHEN ig.source_nutrient = 'Iron' THEN ig.target_nutrient ELSE ig.source_nutrient END AS nutrient_name
--   FROM v_interaction_graph ig
--   WHERE ig.relationship_type = 'antagonistic'
--     AND (ig.source_nutrient = 'Iron' OR ig.target_nutrient = 'Iron')
-- )
-- SELECT t.food_name,
--        t.food_value_per_100g AS iron_mg,
--        t.pct_drv_per_100g AS iron_pct_drv,
--        ROUND(t.pct_drv_per_100g_capped - (0.35 * COALESCE(a.antagonist_pct_drv_penalty, 0)), 1) AS tradeoff_score
-- FROM v_food_drv_coverage t
-- LEFT JOIN (
--   SELECT v.food_id, SUM(COALESCE(v.pct_drv_per_100g_capped, 0)) AS antagonist_pct_drv_penalty
--   FROM v_food_drv_coverage v
--   JOIN antagonists a ON a.nutrient_name = v.nutrient_name
--   WHERE v.drv_sex = 'Female' AND v.ref_type = 'PRI'
--   GROUP BY v.food_id
-- ) a ON a.food_id = t.food_id
-- WHERE t.nutrient_name = 'Iron' AND t.drv_sex = 'Female' AND t.ref_type = 'PRI'
-- ORDER BY tradeoff_score DESC NULLS LAST, iron_pct_drv DESC NULLS LAST
-- LIMIT 15;

-- Q3: "Best foods to support Vitamin D-related nutrients"
-- WITH vd_cluster AS (
--     SELECT target_nutrient
--     FROM v_interaction_graph
--     WHERE source_nutrient = 'Vitamin D'
--       AND relationship_type = 'synergistic'
-- )
-- SELECT food_name,
--        nutrient_name,
--        food_value_per_100g,
--        pct_drv_per_100g,
--        drv_sex
-- FROM v_food_drv_coverage
-- WHERE nutrient_name IN (SELECT target_nutrient FROM vd_cluster)
--   AND drv_sex = 'Female'
-- ORDER BY nutrient_name, pct_drv_per_100g DESC NULLS LAST;

-- Q4: "Nutrient interaction graph data (for D3/Cytoscape)"
-- SELECT * FROM v_interaction_graph ORDER BY source_nutrient;

-- REFRESH materialized views (run after reloading data):
-- REFRESH MATERIALIZED VIEW v_food_nutrient_ranked;
-- REFRESH MATERIALIZED VIEW v_drv_lookup;
-- REFRESH MATERIALIZED VIEW v_interaction_graph;
-- REFRESH MATERIALIZED VIEW v_top_foods_per_nutrient;
-- REFRESH MATERIALIZED VIEW v_food_drv_coverage;
