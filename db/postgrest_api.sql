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

CREATE OR REPLACE FUNCTION api.viz2_top_foods(
    p_nutrient text DEFAULT 'Iron',
    p_drv_sex text DEFAULT 'Female',
    p_ref_type text DEFAULT 'PRI',
    p_limit integer DEFAULT 20
)
RETURNS TABLE (
    food_name text,
    nutrient_name text,
    food_value_per_100g numeric,
    pct_drv_per_100g numeric,
    pct_drv_per_100g_capped numeric,
    drv_sex text,
    age_label text,
    ref_type text
)
LANGUAGE sql
STABLE
AS $$
    WITH ranked_foods AS (
        SELECT
            v.food_name,
            v.nutrient_name,
            v.food_value_per_100g,
            v.pct_drv_per_100g,
            v.pct_drv_per_100g_capped,
            v.drv_sex,
            v.age_label,
            v.ref_type,
            lower(trim(split_part(v.food_name, ',', 1))) as base_food_name
        FROM public.v_food_drv_coverage v
        WHERE v.nutrient_name = p_nutrient
          AND v.drv_sex = p_drv_sex
          AND v.ref_type = p_ref_type
    ),
    deduplicated_foods AS (
        SELECT DISTINCT ON (base_food_name)
            food_name,
            nutrient_name,
            food_value_per_100g,
            pct_drv_per_100g,
            pct_drv_per_100g_capped,
            drv_sex,
            age_label,
            ref_type
        FROM ranked_foods
        ORDER BY base_food_name, pct_drv_per_100g DESC NULLS LAST
    )
    SELECT 
        food_name,
        nutrient_name,
        food_value_per_100g,
        pct_drv_per_100g,
        pct_drv_per_100g_capped,
        drv_sex,
        age_label,
        ref_type
    FROM deduplicated_foods
    ORDER BY pct_drv_per_100g DESC NULLS LAST
    LIMIT GREATEST(p_limit, 1);
$$;

CREATE OR REPLACE FUNCTION api.viz2_food_panel(
    p_food_name text,
    p_nutrients text[] DEFAULT ARRAY['Iron', 'Calcium', 'Magnesium', 'Vitamin A', 'Vitamin C', 'Folate'],
    p_drv_sex text DEFAULT 'Female',
    p_ref_type text DEFAULT 'PRI'
)
RETURNS TABLE (
    food_name text,
    nutrient_name text,
    food_value_per_100g numeric,
    food_unit text,
    pct_drv_per_100g numeric,
    pct_drv_per_100g_capped numeric,
    drv_sex text,
    age_label text,
    ref_type text
)
LANGUAGE sql
STABLE
AS $$
    WITH sex_scope AS (
        SELECT p_drv_sex::text AS drv_sex
        UNION
        SELECT 'Both genders'::text
        WHERE p_drv_sex <> 'Both genders'
    ),
    ranked AS (
        SELECT
            v.food_name,
            v.nutrient_name,
            v.food_value_per_100g,
            v.food_unit,
            v.pct_drv_per_100g,
            v.pct_drv_per_100g_capped,
            v.drv_sex,
            v.age_label,
            v.ref_type,
            ROW_NUMBER() OVER (
                PARTITION BY v.nutrient_name, v.drv_sex
                ORDER BY
                    CASE
                        WHEN v.ref_type = p_ref_type THEN 0
                        WHEN p_ref_type = 'PRI' AND v.ref_type = 'AI' THEN 1
                        ELSE 2
                    END,
                    v.ref_type
            ) AS ref_rank
        FROM public.v_food_drv_coverage v
        JOIN sex_scope s ON s.drv_sex = v.drv_sex
        WHERE v.food_name = p_food_name
          AND v.nutrient_name = ANY (p_nutrients)
          AND (
              v.ref_type = p_ref_type
              OR (p_ref_type = 'PRI' AND v.ref_type = 'AI')
          )
    )
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
    FROM ranked
    WHERE ref_rank = 1
    ORDER BY
        nutrient_name,
        CASE WHEN drv_sex = p_drv_sex THEN 0 ELSE 1 END,
        drv_sex,
        ref_type;
$$;

CREATE OR REPLACE FUNCTION api.viz2_support_cluster(
    p_source_nutrient text DEFAULT 'Vitamin D',
    p_relationship_type text DEFAULT 'synergistic',
    p_drv_sexes text[] DEFAULT ARRAY['Female', 'Both genders'],
    p_ref_types text[] DEFAULT ARRAY['PRI', 'AI'],
    p_per_nutrient_limit integer DEFAULT 5
)
RETURNS TABLE (
    food_name text,
    nutrient_name text,
    food_value_per_100g numeric,
    pct_drv_per_100g numeric,
    pct_drv_per_100g_capped numeric,
    drv_sex text,
    age_label text,
    ref_type text,
    nutrient_rank bigint
)
LANGUAGE sql
STABLE
AS $$
    WITH cluster AS (
        SELECT DISTINCT target_nutrient AS nutrient_name
        FROM public.v_interaction_graph
        WHERE source_nutrient = p_source_nutrient
          AND relationship_type = p_relationship_type
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
        FROM public.v_food_drv_coverage vfdc
        JOIN cluster c ON c.nutrient_name = vfdc.nutrient_name
        WHERE vfdc.drv_sex = ANY (p_drv_sexes)
          AND vfdc.ref_type = ANY (p_ref_types)
    )
    SELECT
        r.food_name,
        r.nutrient_name,
        r.food_value_per_100g,
        r.pct_drv_per_100g,
        r.pct_drv_per_100g_capped,
        r.drv_sex,
        r.age_label,
        r.ref_type,
        r.nutrient_rank::bigint
    FROM ranked r
    WHERE r.nutrient_rank <= GREATEST(p_per_nutrient_limit, 1)
    ORDER BY r.nutrient_name, r.nutrient_rank, r.food_name;
$$;

CREATE OR REPLACE FUNCTION api.viz2_conflict_aware(
    p_target_nutrient text DEFAULT 'Iron',
    p_drv_sex text DEFAULT 'Female',
    p_ref_type text DEFAULT 'PRI',
    p_penalty_weight numeric DEFAULT 0.35,
    p_limit integer DEFAULT 20,
    p_source_nutrient text DEFAULT NULL
)
RETURNS TABLE (
    food_name text,
    target_nutrient text,
    target_food_value_per_100g numeric,
    target_pct_drv_per_100g numeric,
    target_pct_drv_per_100g_capped numeric,
    antagonist_pct_drv_penalty numeric,
    antagonist_nutrient_count bigint,
    antagonist_nutrients text[],
    tradeoff_score numeric,
    drv_sex text,
    age_label text,
    ref_type text
)
LANGUAGE sql
STABLE
AS $$
    WITH antagonists AS (
        SELECT DISTINCT
            CASE
                WHEN ig.source_nutrient = p_target_nutrient THEN ig.target_nutrient
                ELSE ig.source_nutrient
            END AS nutrient_name
        FROM public.v_interaction_graph ig
        WHERE ig.relationship_type = 'antagonistic'
          AND (ig.source_nutrient = p_target_nutrient OR ig.target_nutrient = p_target_nutrient)
          AND ig.source_nutrient <> ig.target_nutrient
    ),
    target_rows AS (
        SELECT
            v.food_id,
            v.food_name,
            v.nutrient_name,
            v.food_value_per_100g,
            v.pct_drv_per_100g,
            v.pct_drv_per_100g_capped,
            v.drv_sex,
            v.age_label,
            v.ref_type
        FROM public.v_food_drv_coverage v
        WHERE v.nutrient_name = p_target_nutrient
          AND v.drv_sex = p_drv_sex
          AND v.ref_type = p_ref_type
    ),
    antagonist_rows AS (
        SELECT
            v.food_id,
            ROUND(SUM(COALESCE(v.pct_drv_per_100g_capped, 0)), 1) AS antagonist_pct_drv_penalty,
            COUNT(*) AS antagonist_nutrient_count,
            ARRAY_AGG(
                v.nutrient_name
                ORDER BY v.pct_drv_per_100g_capped DESC NULLS LAST, v.nutrient_name
            ) AS antagonist_nutrients
        FROM public.v_food_drv_coverage v
        JOIN antagonists a ON a.nutrient_name = v.nutrient_name
        WHERE v.drv_sex = p_drv_sex
          AND v.ref_type = p_ref_type
          AND COALESCE(v.pct_drv_per_100g_capped, 0) > 0
        GROUP BY v.food_id
    )
    SELECT
        t.food_name,
        t.nutrient_name AS target_nutrient,
        t.food_value_per_100g AS target_food_value_per_100g,
        t.pct_drv_per_100g AS target_pct_drv_per_100g,
        t.pct_drv_per_100g_capped AS target_pct_drv_per_100g_capped,
        COALESCE(a.antagonist_pct_drv_penalty, 0) AS antagonist_pct_drv_penalty,
        COALESCE(a.antagonist_nutrient_count, 0)::bigint AS antagonist_nutrient_count,
        COALESCE(a.antagonist_nutrients, ARRAY[]::text[]) AS antagonist_nutrients,
        ROUND(
            COALESCE(t.pct_drv_per_100g_capped, 0) -
            (GREATEST(p_penalty_weight, 0) * COALESCE(a.antagonist_pct_drv_penalty, 0)),
            1
        ) AS tradeoff_score,
        t.drv_sex,
        t.age_label,
        t.ref_type
    FROM target_rows t
    LEFT JOIN antagonist_rows a ON a.food_id = t.food_id
    ORDER BY
        tradeoff_score DESC NULLS LAST,
        t.pct_drv_per_100g DESC NULLS LAST,
        t.food_name
    LIMIT GREATEST(p_limit, 1);
$$;

CREATE OR REPLACE FUNCTION api.viz2_curated_rank(
    p_nutrient text DEFAULT 'Iron',
    p_drv_sex text DEFAULT 'Female',
    p_ref_type text DEFAULT 'PRI',
    p_limit integer DEFAULT 20
)
RETURNS TABLE (
    food_name text,
    nutrient_name text,
    food_value_per_100g numeric,
    pct_drv_per_100g numeric,
    pct_drv_per_100g_capped numeric,
    serving_size_g numeric,
    serving_label text,
    pct_drv_per_serving numeric,
    ranking_category text,
    display_priority integer,
    age_label text,
    ref_type text
)
LANGUAGE sql
STABLE
AS $$
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
        v.ref_type
    FROM public.v_food_drv_coverage v
    JOIN public.food_display_profile fdp ON fdp.food_id = v.food_id
    WHERE fdp.include_in_rankings = TRUE
      AND v.nutrient_name = p_nutrient
      AND v.drv_sex = p_drv_sex
      AND v.ref_type = p_ref_type
    ORDER BY
        fdp.display_priority ASC,
        COALESCE(
            CASE
                WHEN fdp.serving_size_g IS NOT NULL
                THEN ROUND(v.pct_drv_per_100g * fdp.serving_size_g / 100.0, 1)
                ELSE NULL
            END,
            v.pct_drv_per_100g
        ) DESC NULLS LAST,
        v.food_name
    LIMIT GREATEST(p_limit, 1);
$$;

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

CREATE OR REPLACE FUNCTION api.viz2_option_nutrients(
    p_drv_sex text DEFAULT NULL,
    p_ref_type text DEFAULT NULL,
    p_curated_only boolean DEFAULT FALSE
)
RETURNS TABLE (
    nutrient_name text,
    nutrient_category text
)
LANGUAGE sql
STABLE
AS $$
    SELECT DISTINCT
        v.nutrient_name,
        v.nutrient_category
    FROM public.v_food_drv_coverage v
    LEFT JOIN public.food_display_profile fdp ON fdp.food_id = v.food_id
    WHERE (p_drv_sex IS NULL OR v.drv_sex = p_drv_sex)
      AND (p_ref_type IS NULL OR v.ref_type = p_ref_type)
      AND (NOT p_curated_only OR COALESCE(fdp.include_in_rankings, FALSE) = TRUE)
    ORDER BY v.nutrient_name;
$$;

CREATE OR REPLACE FUNCTION api.viz2_option_foods(
    p_nutrient text DEFAULT NULL,
    p_drv_sex text DEFAULT NULL,
    p_ref_type text DEFAULT NULL,
    p_curated_only boolean DEFAULT FALSE
)
RETURNS TABLE (
    food_name text,
    ranking_category text,
    include_in_rankings boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        v.food_name,
        MIN(fdp.ranking_category) AS ranking_category,
        COALESCE(BOOL_OR(fdp.include_in_rankings), FALSE) AS include_in_rankings
    FROM public.v_food_drv_coverage v
    LEFT JOIN public.food_display_profile fdp ON fdp.food_id = v.food_id
    WHERE (p_nutrient IS NULL OR v.nutrient_name = p_nutrient)
      AND (p_drv_sex IS NULL OR v.drv_sex = p_drv_sex)
      AND (p_ref_type IS NULL OR v.ref_type = p_ref_type)
      AND (NOT p_curated_only OR COALESCE(fdp.include_in_rankings, FALSE) = TRUE)
    GROUP BY v.food_name
    ORDER BY v.food_name;
$$;

CREATE OR REPLACE FUNCTION api.viz2_option_drv_sexes(
    p_nutrient text DEFAULT NULL,
    p_ref_type text DEFAULT NULL,
    p_curated_only boolean DEFAULT FALSE
)
RETURNS TABLE (
    drv_sex text
)
LANGUAGE sql
STABLE
AS $$
    WITH values_pool AS (
        SELECT DISTINCT
            v.drv_sex
        FROM public.v_food_drv_coverage v
        LEFT JOIN public.food_display_profile fdp ON fdp.food_id = v.food_id
        WHERE (p_nutrient IS NULL OR v.nutrient_name = p_nutrient)
          AND (p_ref_type IS NULL OR v.ref_type = p_ref_type)
          AND (NOT p_curated_only OR COALESCE(fdp.include_in_rankings, FALSE) = TRUE)
    )
    SELECT
        values_pool.drv_sex
    FROM values_pool
    ORDER BY
        CASE values_pool.drv_sex
            WHEN 'Female' THEN 0
            WHEN 'Male' THEN 1
            WHEN 'Both genders' THEN 2
            ELSE 3
        END,
        values_pool.drv_sex;
$$;

CREATE OR REPLACE FUNCTION api.viz2_option_ref_types(
    p_nutrient text DEFAULT NULL,
    p_drv_sex text DEFAULT NULL,
    p_curated_only boolean DEFAULT FALSE
)
RETURNS TABLE (
    ref_type text
)
LANGUAGE sql
STABLE
AS $$
    WITH values_pool AS (
        SELECT DISTINCT
            v.ref_type
        FROM public.v_food_drv_coverage v
        LEFT JOIN public.food_display_profile fdp ON fdp.food_id = v.food_id
        WHERE (p_nutrient IS NULL OR v.nutrient_name = p_nutrient)
          AND (p_drv_sex IS NULL OR v.drv_sex = p_drv_sex)
          AND (NOT p_curated_only OR COALESCE(fdp.include_in_rankings, FALSE) = TRUE)
    )
    SELECT
        values_pool.ref_type
    FROM values_pool
    ORDER BY
        CASE values_pool.ref_type
            WHEN 'PRI' THEN 0
            WHEN 'AI' THEN 1
            ELSE 2
        END,
        values_pool.ref_type;
$$;

CREATE OR REPLACE FUNCTION api.viz2_option_relationship_types()
RETURNS TABLE (
    relationship_type text
)
LANGUAGE sql
STABLE
AS $$
    WITH values_pool AS (
        SELECT DISTINCT
            ig.relationship_type
        FROM public.v_interaction_graph ig
    )
    SELECT
        values_pool.relationship_type
    FROM values_pool
    ORDER BY
        CASE values_pool.relationship_type
            WHEN 'synergistic' THEN 0
            WHEN 'antagonistic' THEN 1
            WHEN 'varies' THEN 2
            ELSE 3
        END,
        values_pool.relationship_type;
$$;

CREATE OR REPLACE FUNCTION api.viz2_option_source_nutrients(
    p_relationship_type text DEFAULT NULL
)
RETURNS TABLE (
    source_nutrient text,
    target_count bigint
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        ig.source_nutrient,
        COUNT(DISTINCT ig.target_nutrient)::bigint AS target_count
    FROM public.v_interaction_graph ig
    WHERE (p_relationship_type IS NULL OR ig.relationship_type = p_relationship_type)
    GROUP BY ig.source_nutrient
    ORDER BY ig.source_nutrient;
$$;

CREATE OR REPLACE FUNCTION api.viz2_option_target_nutrients(
    p_requires_antagonists boolean DEFAULT TRUE
)
RETURNS TABLE (
    nutrient_name text,
    has_antagonists boolean
)
LANGUAGE sql
STABLE
AS $$
    WITH nutrient_pool AS (
        SELECT DISTINCT v.nutrient_name
        FROM public.v_food_drv_coverage v
    )
    SELECT
        n.nutrient_name,
        EXISTS (
            SELECT 1
            FROM public.v_interaction_graph ig
            WHERE ig.relationship_type = 'antagonistic'
              AND (
                  ig.source_nutrient = n.nutrient_name
                  OR ig.target_nutrient = n.nutrient_name
              )
        ) AS has_antagonists
    FROM nutrient_pool n
    WHERE (
        NOT p_requires_antagonists
        OR EXISTS (
            SELECT 1
            FROM public.v_interaction_graph ig
            WHERE ig.relationship_type = 'antagonistic'
              AND (
                  ig.source_nutrient = n.nutrient_name
                  OR ig.target_nutrient = n.nutrient_name
              )
        )
    )
    ORDER BY n.nutrient_name;
$$;

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
            n.id AS nutrient_id,
            n.canonical_name,
            n.category,
            SUM(fnv.value * (pf.amount_g / 100.0)) AS total_consumed,
            MAX(n.default_unit) AS unit
        FROM parsed_foods pf
        JOIN public.food_nutrient_value fnv ON pf.food_id = fnv.food_id
        JOIN public.nutrient n ON fnv.nutrient_id = n.id
        GROUP BY n.id, n.canonical_name, n.category
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
            cn.unit AS unit
        FROM consumed_nutrients cn
        LEFT JOIN best_reference ir 
            ON cn.canonical_name = ir.nutrient_name AND ir.rnk = 1
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
-- Run AFTER db/postgrest_api.sql:
--   psql nutriverse -f db/postgrest_api_viz3.sql
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- api.viz3_country_profiles
-- Main endpoint for the Choropleth map and Paradox Panel. 
-- Joins the latest deficiency data with poverty data and UN track statuses
-- ---------------------------------------------------------------------------
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

COMMIT;

NOTIFY pgrst, 'reload schema';
