-- NutriVerse Core Query Views
-- =====================================================================
-- These materialized views answer the core NutriVerse questions:
--   1. "Top foods for nutrient X for population Y"
--   2. "Target-first tradeoff ranking (target nutrient vs antagonists)"
--   3. "Best foods to support a nutrient cluster"
--   4. Nutrient interaction graph (for visualization)
-- =====================================================================

BEGIN;

DROP MATERIALIZED VIEW IF EXISTS v_top_foods_per_nutrient;
DROP MATERIALIZED VIEW IF EXISTS v_interaction_graph;
DROP MATERIALIZED VIEW IF EXISTS v_drv_lookup;
DROP MATERIALIZED VIEW IF EXISTS v_food_nutrient_ranked;
DROP MATERIALIZED VIEW IF EXISTS v_food_drv_coverage;


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
-- Pre-computed top 20 foods per nutrient (measured values only), deduplicated by base ingredient.
-- Powers "top foods for iron" dashboards without repeatedly sorting.
-- =====================================================================
CREATE MATERIALIZED VIEW v_top_foods_per_nutrient AS
WITH ranked_foods AS (
    SELECT
        nutrient_id,
        nutrient_name,
        nutrient_category,
        food_id,
        food_name,
        group_name,
        value,
        unit,
        lower(trim(split_part(food_name, ',', 1))) AS base_food_name
    FROM v_food_nutrient_ranked
),
deduplicated_foods AS (
    SELECT DISTINCT ON (nutrient_id, base_food_name)
        nutrient_id,
        nutrient_name,
        nutrient_category,
        food_id,
        food_name,
        group_name,
        value,
        unit
    FROM ranked_foods
    ORDER BY nutrient_id, base_food_name, value DESC NULLS LAST
),
final_ranked AS (
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
            ORDER BY value DESC NULLS LAST
        ) AS rank
    FROM deduplicated_foods
)
SELECT 
    nutrient_id,
    nutrient_name,
    nutrient_category,
    food_id,
    food_name,
    group_name,
    value,
    unit,
    rank
FROM final_ranked
WHERE rank <= 20;

CREATE INDEX idx_vtfpn_nutrient ON v_top_foods_per_nutrient(nutrient_id);
CREATE INDEX idx_vtfpn_name     ON v_top_foods_per_nutrient(nutrient_name);


COMMIT;