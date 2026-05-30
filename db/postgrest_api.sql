-- PostgREST API setup for NutriVerse
-- Applies:
--   1) API schema + RPC functions for viz queries
--   2) Least-privilege roles/grants for read-only API access
--
-- Run with:
--   psql nutriverse -f db/postgrest_api.sql

BEGIN;

DROP SCHEMA IF EXISTS api CASCADE;
CREATE SCHEMA api;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
        -- Change this password immediately in local/dev usage.
        CREATE ROLE authenticator LOGIN PASSWORD 'change-me';
    END IF;
END
$$;

GRANT web_anon TO authenticator;

GRANT USAGE ON SCHEMA public TO web_anon;
GRANT USAGE ON SCHEMA api TO web_anon;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO web_anon;

-- Used
CREATE OR REPLACE FUNCTION api.viz1_graph_edges()
RETURNS TABLE (
    source_nutrient text,
    source_category text,
    target_nutrient text,
    target_category text,
    relationship_type text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        ig.source_nutrient,
        ig.source_category,
        ig.target_nutrient,
        ig.target_category,
        ig.relationship_type
    FROM public.v_interaction_graph ig
    ORDER BY ig.relationship_type, ig.source_nutrient, ig.target_nutrient;
$$;


--Used
CREATE OR REPLACE FUNCTION api.viz1_degree_summary()
RETURNS TABLE (
    nutrient_name text,
    category text,
    total_degree bigint,
    outgoing_synergies bigint,
    outgoing_antagonisms bigint,
    outgoing_varies bigint
)
LANGUAGE sql
STABLE
AS $$
    WITH edges AS (
        SELECT source_nutrient AS nutrient_name FROM public.v_interaction_graph
        UNION ALL
        SELECT target_nutrient AS nutrient_name FROM public.v_interaction_graph
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
    FROM public.nutrient n
    LEFT JOIN degree_counts dc ON dc.nutrient_name = n.canonical_name
    LEFT JOIN public.v_interaction_graph ig ON ig.source_nutrient = n.canonical_name
    -- Removed the WHERE clause to include nutrients with 0 degree
    GROUP BY n.canonical_name, n.category, dc.degree
    ORDER BY total_degree DESC, nutrient_name;
$$;

--Used
CREATE OR REPLACE FUNCTION api.viz1_food_anchors(
    p_selected_nutrient text DEFAULT 'Iron',
    p_top_n integer DEFAULT 10
)
RETURNS TABLE (
    nutrient_name text,
    is_selected boolean,
    food_name text,
    value numeric,
    unit text,
    rank bigint
)
LANGUAGE sql
STABLE
AS $$
    WITH selected AS (
        SELECT p_selected_nutrient::text AS nutrient_name
    ),
    neighbors AS (
        SELECT target_nutrient AS nutrient_name
        FROM public.v_interaction_graph ig
        JOIN selected s ON s.nutrient_name = ig.source_nutrient
        UNION
        SELECT source_nutrient AS nutrient_name
        FROM public.v_interaction_graph ig
        JOIN selected s ON s.nutrient_name = ig.target_nutrient
    ),
    targets AS (
        SELECT nutrient_name, TRUE AS is_selected FROM selected
        UNION
        SELECT nutrient_name, FALSE AS is_selected FROM neighbors
    )
    SELECT
        t.nutrient_name,
        t.is_selected,
        tpn.food_name,
        tpn.value,
        tpn.unit,
        tpn.rank::bigint
    FROM targets t
    JOIN public.v_top_foods_per_nutrient tpn ON tpn.nutrient_name = t.nutrient_name
    WHERE tpn.rank <= GREATEST(p_top_n, 1)
    ORDER BY t.nutrient_name, tpn.rank, tpn.food_name;
$$;

-- Used
CREATE OR REPLACE FUNCTION api.viz1_option_nutrients()
RETURNS TABLE (
    nutrient_name text,
    category text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        n.canonical_name AS nutrient_name,
        n.category
    FROM public.nutrient n
    WHERE EXISTS (
        SELECT 1
        FROM public.v_interaction_graph ig
        WHERE ig.source_nutrient = n.canonical_name
           OR ig.target_nutrient = n.canonical_name
    )
      AND EXISTS (
        SELECT 1
        FROM public.v_top_foods_per_nutrient t
        WHERE t.nutrient_name = n.canonical_name
    )
    ORDER BY n.canonical_name;
$$;

--Used
CREATE OR REPLACE FUNCTION api.calculate_meal_nutrition(
    p_age_years numeric,
    p_sex text,
    p_food_items JSONB,
    p_life_stage text DEFAULT NULL,
    p_pal numeric DEFAULT 1.6,
    p_body_weight_kg numeric DEFAULT 70.0,
    p_population_label text DEFAULT NULL
)
RETURNS TABLE (
    nutrient_name text,
    nutrient_category text,
    consumed_value numeric,
    target_value numeric,
    max_value numeric,
    unit text,
    percentage_met numeric
)
LANGUAGE sql
STABLE
AS $$
    WITH input_context AS (
        SELECT
            CASE
                WHEN p_sex IS NULL THEN NULL
                WHEN lower(trim(p_sex)) = 'male' THEN 'Male'
                WHEN lower(trim(p_sex)) = 'female' THEN 'Female'
                WHEN lower(trim(p_sex)) IN ('both genders', 'both', 'all') THEN 'Both genders'
                ELSE p_sex
            END AS normalized_sex,
            COALESCE(
                NULLIF(trim(p_life_stage), ''),
                CASE
                    WHEN p_age_years < 1 THEN 'infant'
                    WHEN p_age_years < 18 THEN 'child'
                    ELSE 'adult'
                END
            ) AS effective_life_stage,
            NULLIF(trim(p_population_label), '') AS effective_population_label
    ),
    parsed_foods AS (
        SELECT 
            (item->>'food_id')::INT AS food_id,
            (item->>'amount_g')::NUMERIC AS amount_g
        FROM jsonb_array_elements(p_food_items) AS item
    ),
    consumed_nutrients AS (
        SELECT 
            fnv.nutrient_id,
            fnv.nutrient_name AS canonical_name,
            fnv.nutrient_category AS category,
            SUM(fnv.value * (pf.amount_g / 100.0)) AS total_consumed,
            MAX(fnv.unit) AS unit
        FROM parsed_foods pf
        JOIN public.v_food_nutrient_ranked fnv ON pf.food_id = fnv.food_id
        GROUP BY fnv.nutrient_id, fnv.nutrient_name, fnv.nutrient_category
    ),
    best_reference AS (
        SELECT 
            drv.nutrient_name,
            drv.value_numeric,
            drv.unit,
            ROW_NUMBER() OVER (
                PARTITION BY drv.nutrient_name
                ORDER BY 
                    -- 1. Prefer PRI > AI > AR...
                    CASE drv.ref_type
                        WHEN 'PRI' THEN 1
                        WHEN 'AI' THEN 2
                        WHEN 'AR' THEN 3
                        ELSE 4
                    END,
                    -- 2. Prefer exact cohort label when explicitly requested.
                    CASE
                        WHEN ic.effective_population_label IS NOT NULL
                             AND drv.population_label = ic.effective_population_label THEN 0
                        WHEN ic.effective_population_label IS NOT NULL THEN 1
                        WHEN drv.population_label = 'Adults' THEN 0
                        WHEN drv.population_label = 'Children' THEN 0
                        WHEN drv.population_label = 'Infants' THEN 0
                        WHEN POSITION('(' IN drv.population_label) = 0 THEN 1
                        WHEN drv.population_label ILIKE '%LPI 600 mg/day%' THEN 2
                        WHEN drv.population_label ILIKE '%LPI 900 mg/day%' THEN 3
                        WHEN drv.population_label ILIKE '%LPI 300 mg/day%' THEN 4
                        WHEN drv.population_label ILIKE '%LPI 1200 mg/day%' THEN 5
                        ELSE 6
                    END,
                    -- 3. Prefer exact sex match
                    CASE WHEN drv.sex = ic.normalized_sex THEN 1 ELSE 2 END,
                    -- 4. Prefer closest PAL match (if applicable, e.g. Energy)
                    ABS(COALESCE(drv.pal, p_pal) - p_pal),
                    -- 5. Prefer narrowest age band
                    (COALESCE(drv.age_max, 150) - COALESCE(drv.age_min, 0)) ASC,
                    drv.population_label
            ) as rnk
        FROM public.v_drv_lookup drv
        CROSS JOIN input_context ic
        WHERE drv.status = 'value'
          AND drv.ref_type IN ('PRI', 'AI', 'AR')
          AND drv.value_numeric IS NOT NULL
          AND (drv.sex = ic.normalized_sex OR drv.sex = 'Both genders' OR drv.sex IS NULL)
          AND (drv.life_stage = ic.effective_life_stage OR drv.life_stage IS NULL)
          AND (drv.age_unit = 'years' AND p_age_years >= COALESCE(drv.age_min, 0) AND p_age_years <= COALESCE(drv.age_max, 150))
          AND (
              ic.effective_population_label IS NULL
              OR drv.population_label = ic.effective_population_label
          )
    ),
    ul_reference AS (
        SELECT 
            drv.nutrient_name,
            drv.value_numeric,
            drv.unit,
            ROW_NUMBER() OVER (
                PARTITION BY drv.nutrient_name
                ORDER BY 
                    -- 1. Prefer exact cohort label when explicitly requested.
                    CASE
                        WHEN ic.effective_population_label IS NOT NULL
                             AND drv.population_label = ic.effective_population_label THEN 0
                        WHEN ic.effective_population_label IS NOT NULL THEN 1
                        WHEN drv.population_label = 'Adults' THEN 0
                        WHEN drv.population_label = 'Children' THEN 0
                        WHEN drv.population_label = 'Infants' THEN 0
                        WHEN POSITION('(' IN drv.population_label) = 0 THEN 1
                        WHEN drv.population_label ILIKE '%LPI 600 mg/day%' THEN 2
                        WHEN drv.population_label ILIKE '%LPI 900 mg/day%' THEN 3
                        WHEN drv.population_label ILIKE '%LPI 300 mg/day%' THEN 4
                        WHEN drv.population_label ILIKE '%LPI 1200 mg/day%' THEN 5
                        ELSE 6
                    END,
                    -- 2. Prefer exact sex match
                    CASE WHEN drv.sex = ic.normalized_sex THEN 1 ELSE 2 END,
                    -- 3. Prefer narrowest age band
                    (COALESCE(drv.age_max, 150) - COALESCE(drv.age_min, 0)) ASC,
                    drv.population_label
            ) as rnk
        FROM public.v_drv_lookup drv
        CROSS JOIN input_context ic
        WHERE drv.status = 'value'
          AND drv.ref_type = 'UL'
          AND drv.value_numeric IS NOT NULL
          AND (drv.sex = ic.normalized_sex OR drv.sex = 'Both genders' OR drv.sex IS NULL)
          AND (drv.life_stage = ic.effective_life_stage OR drv.life_stage IS NULL)
          AND (drv.age_unit = 'years' AND p_age_years >= COALESCE(drv.age_min, 0) AND p_age_years <= COALESCE(drv.age_max, 150))
          AND (
              ic.effective_population_label IS NULL
              OR drv.population_label = ic.effective_population_label
          )
    ),
    raw_results AS (
        SELECT 
            cn.canonical_name AS nutrient_name,
            cn.category AS nutrient_category,
            cn.total_consumed AS consumed_value,
            CASE
                WHEN cn.unit = 'kJ' AND ir.unit = 'MJ/day' THEN ir.value_numeric * 1000
                WHEN cn.unit = 'mg' AND ir.unit = 'g/day'  THEN ir.value_numeric * 1000
                WHEN cn.unit = 'g' AND ir.unit = 'mg/day'  THEN ir.value_numeric / 1000
                WHEN cn.unit = 'g' AND ir.unit = 'L/day' THEN ir.value_numeric * 1000
                WHEN cn.unit = 'g' AND ir.unit LIKE 'mg/day%' THEN ir.value_numeric / 1000
                WHEN cn.unit IN ('µg', 'μg', 'µg DFE', 'μg DFE', 'µg RE', 'μg RE') AND ir.unit = 'mg/day' THEN ir.value_numeric * 1000
                WHEN cn.unit = 'g' AND ir.unit = 'g/kg bw per day' THEN ir.value_numeric * p_body_weight_kg
                WHEN cn.unit = 'mg' AND ir.unit = 'mg/MJ' THEN ir.value_numeric * et.mj
                WHEN cn.unit LIKE 'mg%' AND ir.unit = 'mg NE/MJ' THEN ir.value_numeric * et.mj
                WHEN cn.unit = 'g' AND ir.unit = 'E%' AND cn.category = 'lipid' THEN (ir.value_numeric / 100.0) * (et.mj * 1000.0) / 37.0
                WHEN cn.unit = 'g' AND ir.unit = 'E%' AND cn.category = 'macro' THEN (ir.value_numeric / 100.0) * (et.mj * 1000.0) / 17.0
                ELSE ir.value_numeric
            END AS target_value,
            CASE
                WHEN cn.unit = 'kJ' AND ul.unit = 'MJ/day' THEN ul.value_numeric * 1000
                WHEN cn.unit = 'mg' AND ul.unit = 'g/day'  THEN ul.value_numeric * 1000
                WHEN cn.unit = 'g' AND ul.unit = 'mg/day'  THEN ul.value_numeric / 1000
                WHEN cn.unit = 'g' AND ul.unit = 'L/day' THEN ul.value_numeric * 1000
                WHEN cn.unit = 'g' AND ul.unit LIKE 'mg/day%' THEN ul.value_numeric / 1000
                WHEN cn.unit IN ('µg', 'μg', 'µg DFE', 'μg DFE', 'µg RE', 'μg RE') AND ul.unit = 'mg/day' THEN ul.value_numeric * 1000
                WHEN cn.unit = 'g' AND ul.unit = 'g/kg bw per day' THEN ul.value_numeric * p_body_weight_kg
                WHEN cn.unit = 'mg' AND ul.unit = 'mg/MJ' THEN ul.value_numeric * et.mj
                WHEN cn.unit LIKE 'mg%' AND ul.unit = 'mg NE/MJ' THEN ul.value_numeric * et.mj
                WHEN cn.unit = 'g' AND ul.unit = 'E%' AND cn.category = 'lipid' THEN (ul.value_numeric / 100.0) * (et.mj * 1000.0) / 37.0
                WHEN cn.unit = 'g' AND ul.unit = 'E%' AND cn.category = 'macro' THEN (ul.value_numeric / 100.0) * (et.mj * 1000.0) / 17.0
                ELSE ul.value_numeric
            END AS max_value,
            cn.unit AS unit
        FROM consumed_nutrients cn
        LEFT JOIN best_reference ir 
            ON cn.canonical_name = ir.nutrient_name AND ir.rnk = 1
        LEFT JOIN ul_reference ul 
            ON cn.canonical_name = ul.nutrient_name AND ul.rnk = 1
        CROSS JOIN (
            SELECT COALESCE((SELECT value_numeric FROM best_reference WHERE nutrient_name = 'Energy' AND rnk = 1 LIMIT 1), 0) AS mj
        ) et
    )
    SELECT 
        nutrient_name,
        nutrient_category,
        CASE 
            WHEN nutrient_name = 'Energy' THEN ROUND(consumed_value / 4.184, 0)
            ELSE ROUND(consumed_value, 2)
        END AS consumed_value,
        CASE 
            WHEN nutrient_name = 'Energy' THEN ROUND(target_value / 4.184, 0)
            ELSE ROUND(target_value, 2)
        END AS target_value,
        CASE 
            WHEN nutrient_name = 'Energy' THEN ROUND(max_value / 4.184, 0)
            ELSE ROUND(max_value, 2)
        END AS max_value,
        CASE 
            WHEN nutrient_name = 'Energy' THEN 'kcal'
            ELSE unit
        END AS unit,
        CASE 
            WHEN target_value > 0 THEN ROUND((consumed_value / NULLIF(target_value, 0)) * 100, 2)
            ELSE NULL 
        END AS percentage_met
    FROM raw_results
    ORDER BY 
        nutrient_category, nutrient_name;
$$;

--Used
CREATE OR REPLACE VIEW api.food_options AS
SELECT 
    id AS food_id,
    name AS food_name,
    group_name AS food_category
FROM public.food
ORDER BY name;

GRANT SELECT ON api.food_options TO web_anon;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA api
    GRANT EXECUTE ON FUNCTIONS TO web_anon;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- PostgREST API setup for NutriVerse Viz 3
-- =============================================================================
BEGIN;

-- ---------------------------------------------------------------------------
-- api.viz3_country_profiles
-- Main endpoint for the Choropleth map and Paradox Panel. 
-- Joins the latest deficiency data with poverty data and UN track statuses
-- ---------------------------------------------------------------------------
-- Used
CREATE OR REPLACE FUNCTION api.viz3_country_profiles(
    p_indicator text DEFAULT 'anaemia'
)
RETURNS TABLE (
    iso3 text,
    country_name text,
    region text,
    latest_value numeric,
    latest_year int,
    track_status text,
    poverty_190 numeric,
    poverty_190_year int,
    trend_data jsonb,
    production_data jsonb
)
LANGUAGE sql
STABLE
AS $$
    WITH latest_deficiency AS (
        SELECT 
            country_id, 
            value AS latest_value,
            year AS latest_year
        FROM (
            SELECT 
                country_id, 
                value, 
                year,
                ROW_NUMBER() OVER (PARTITION BY country_id ORDER BY year DESC) as rn
            FROM public.country_deficiency_indicator
            WHERE indicator = p_indicator
        ) r WHERE rn = 1
    ),
    trend AS (
        SELECT 
            country_id, 
            jsonb_object_agg(year::text, value ORDER BY year) as trend_data
        FROM public.country_deficiency_indicator
        WHERE indicator = p_indicator
        GROUP BY country_id
    ),
    latest_poverty AS (
        SELECT 
            country_id, 
            value AS poverty_190,
            year AS poverty_190_year
        FROM (
            SELECT 
                country_id, 
                value, 
                year,
                ROW_NUMBER() OVER (PARTITION BY country_id ORDER BY year DESC) as rn
            FROM public.country_poverty_indicator
            WHERE poverty_line = '1.90'
        ) r WHERE rn = 1
    ),
    latest_food_production AS (
        SELECT
            country_id,
            jsonb_agg(
                jsonb_build_object(
                    'food', faostat_item,
                    'mapped_food_id', mapped_food_id,
                    'tonnes', value_tonnes,
                    'year', year
                ) ORDER BY value_tonnes DESC
            ) as production_data
        FROM (
            SELECT 
                country_id,
                faostat_item,
                mapped_food_id,
                value_tonnes,
                year,
                ROW_NUMBER() OVER (PARTITION BY country_id, faostat_item ORDER BY year DESC) as rn
            FROM public.country_food_production
        ) r WHERE rn = 1
        GROUP BY country_id
    )
    SELECT 
        c.iso3,
        c.name AS country_name,
        c.region,
        ld.latest_value,
        ld.latest_year,
        cnt.track_status,
        lp.poverty_190,
        lp.poverty_190_year,
        t.trend_data,
        lfp.production_data
    FROM public.country c
    JOIN latest_deficiency ld ON c.id = ld.country_id
    LEFT JOIN trend t ON c.id = t.country_id
    LEFT JOIN public.country_nutrition_track cnt ON c.id = cnt.country_id AND cnt.indicator = p_indicator
    LEFT JOIN latest_poverty lp ON c.id = lp.country_id
    LEFT JOIN latest_food_production lfp ON c.id = lfp.country_id
    ORDER BY c.name;
$$;

GRANT EXECUTE ON FUNCTION api.viz3_country_profiles(text) TO web_anon;

-- ---------------------------------------------------------------------------
-- api.viz3_region_comparison
-- Endpoint for Rich vs Poor region comparison
-- ---------------------------------------------------------------------------
--Used
CREATE OR REPLACE FUNCTION api.viz3_region_comparison(
    p_indicator text DEFAULT 'stunting'
)
RETURNS TABLE (
    region text,
    latest_deficiency_value numeric,
    latest_deficiency_year int,
    latest_poverty_190 numeric,
    latest_poverty_190_year int
)
LANGUAGE sql
STABLE
AS $$
    WITH latest_defic AS (
        SELECT r.region, SUM(c.latest_value * 1) / COUNT(c.latest_value) as latest_deficiency_value, MAX(c.latest_year) as latest_deficiency_year
        FROM public.country r
        JOIN (
             SELECT country_id, value AS latest_value, year AS latest_year,
                    ROW_NUMBER() OVER (PARTITION BY country_id ORDER BY year DESC) as rn
             FROM public.country_deficiency_indicator WHERE indicator = p_indicator
        ) c on r.id = c.country_id and c.rn = 1
        GROUP BY r.region
    ),
    latest_pov AS (
        SELECT r.region, SUM(c.poverty_190 * 1) / COUNT(c.poverty_190) as latest_poverty_190, MAX(c.poverty_190_year) as latest_poverty_190_year
        FROM public.country r
        JOIN (
             SELECT country_id, value AS poverty_190, year AS poverty_190_year,
                    ROW_NUMBER() OVER (PARTITION BY country_id ORDER BY year DESC) as rn
             FROM public.country_poverty_indicator WHERE poverty_line = '1.90'
        ) c on r.id = c.country_id and c.rn = 1
        GROUP BY r.region
    )
    SELECT
        COALESCE(ld.region, lp.region) as region,
        ld.latest_deficiency_value,
        ld.latest_deficiency_year,
        lp.latest_poverty_190,
        lp.latest_poverty_190_year
    FROM latest_defic ld
    FULL OUTER JOIN latest_pov lp ON ld.region = lp.region
    WHERE COALESCE(ld.region, lp.region) IS NOT NULL
    ORDER BY lp.latest_poverty_190 DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION api.viz3_region_comparison(text) TO web_anon;

-- ---------------------------------------------------------------------------
-- api.viz3_all_country_deficiencies
-- Endpoint to fetch all country deficiency indicator data over time
-- ---------------------------------------------------------------------------
--Used
CREATE OR REPLACE FUNCTION api.viz3_all_country_deficiencies(
    p_indicator text DEFAULT NULL
)
RETURNS TABLE (
    iso3 text,
    country_name text,
    region text,
    indicator text,
    year int,
    value numeric,
    disaggregation text
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        c.iso3,
        c.name AS country_name,
        c.region,
        cdi.indicator,
        cdi.year,
        cdi.value,
        cdi.disaggregation
    FROM public.country_deficiency_indicator cdi
    JOIN public.country c ON c.id = cdi.country_id
    WHERE (p_indicator IS NULL OR cdi.indicator = p_indicator)
    ORDER BY c.name, cdi.indicator, cdi.year DESC;
$$;

GRANT EXECUTE ON FUNCTION api.viz3_all_country_deficiencies(text) TO web_anon;

-- ---------------------------------------------------------------------------
-- api.get_ga_data
-- Endpoint to fetch food catalog and nutrient matrix for the GA meal builder
-- ---------------------------------------------------------------------------
--Used
CREATE OR REPLACE FUNCTION api.get_ga_data()
RETURNS json AS $$
DECLARE
    v_catalog json;
    v_matrix json;
BEGIN
    SELECT json_agg(json_build_object(
        'id', f.id,
        'name', f.name,
        'ranking_category', fdp.ranking_category,
        'target_age_group', fdp.target_age_group,
        'serving_size_g', fdp.serving_size_g,
        'serving_label', fdp.serving_label
    )) INTO v_catalog
    FROM public.food f
    JOIN public.food_display_profile fdp ON f.id = fdp.food_id
    WHERE fdp.include_in_rankings = true
      AND fdp.ranking_category IS NOT NULL
      AND fdp.serving_size_g > 0;

    SELECT json_object_agg(sub.food_id, sub.nutrients) INTO v_matrix
    FROM (
        SELECT v.food_id, json_object_agg(v.nutrient_name, COALESCE(v.value, 0.0)) as nutrients
        FROM public.v_food_nutrient_ranked v
        JOIN public.food_display_profile fdp ON fdp.food_id = v.food_id
        WHERE fdp.include_in_rankings = true
        GROUP BY v.food_id
    ) sub;

    RETURN json_build_object('catalog', v_catalog, 'matrix', v_matrix);
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION api.get_ga_data() TO web_anon;

COMMIT;

NOTIFY pgrst, 'reload schema';
