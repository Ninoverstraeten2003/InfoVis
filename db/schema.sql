-- NutriVerse Canonical Schema
-- Postgres DDL — raw/staging provenance + canonical query model
-- Requires Postgres 15+ for NULLS NOT DISTINCT
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. source_file — provenance: which file was ingested
-- ---------------------------------------------------------------------------
CREATE TABLE source_file (
    id              SERIAL PRIMARY KEY,
    source_system   TEXT NOT NULL,                          -- 'EFSA', 'CIQUAL', 'INTERACTIONS'
    file_name       TEXT NOT NULL,
    dataset_name    TEXT,
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source_system, file_name)
);

-- ---------------------------------------------------------------------------
-- 2. source_row — raw payload per row for re-processing
-- ---------------------------------------------------------------------------
CREATE TABLE source_row (
    id              SERIAL PRIMARY KEY,
    source_file_id  INT NOT NULL REFERENCES source_file(id) ON DELETE CASCADE,
    sheet_name      TEXT,
    row_number      INT,
    raw_payload     JSONB NOT NULL,
    UNIQUE NULLS NOT DISTINCT (source_file_id, sheet_name, row_number)
);

CREATE INDEX idx_source_row_file ON source_row(source_file_id);

-- ---------------------------------------------------------------------------
-- 3. nutrient — the reconciliation layer / bridge table
-- ---------------------------------------------------------------------------
CREATE TABLE nutrient (
    id              SERIAL PRIMARY KEY,
    canonical_name  TEXT NOT NULL UNIQUE,
    category        TEXT NOT NULL                            -- 'vitamin', 'mineral', 'macro', 'energy', 'lipid', 'other'
                    CHECK (category IN (
                        'vitamin', 'mineral', 'macro', 'energy', 'lipid', 'other'
                    )),
    default_unit    TEXT,                                    -- 'mg', 'µg', 'g', 'MJ/day', 'kcal', etc.
    infoods_tag     TEXT                                     -- INFOODS tagname when available
);

-- ---------------------------------------------------------------------------
-- 4. nutrient_alias — separate table for matching, auditing, curation
-- ---------------------------------------------------------------------------
CREATE TABLE nutrient_alias (
    id              SERIAL PRIMARY KEY,
    nutrient_id     INT NOT NULL REFERENCES nutrient(id),
    alias           TEXT NOT NULL,
    source_system   TEXT NOT NULL,                          -- 'EFSA', 'CIQUAL', 'INTERACTIONS', 'INFOODS'
    UNIQUE (alias, source_system)
);

CREATE INDEX idx_nutrient_alias_nutrient ON nutrient_alias(nutrient_id);
CREATE INDEX idx_nutrient_alias_lookup   ON nutrient_alias(alias);

-- ---------------------------------------------------------------------------
-- 5. reference_type — EFSA DRV reference categories
-- ---------------------------------------------------------------------------
CREATE TABLE reference_type (
    id      SERIAL PRIMARY KEY,
    code    TEXT NOT NULL UNIQUE,                            -- 'AI', 'AR', 'PRI', 'RI', 'UL', 'safe_and_adequate_intake'
    label   TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- 6. population_group — target populations from EFSA
-- ---------------------------------------------------------------------------
CREATE TABLE population_group (
    id          SERIAL PRIMARY KEY,
    label       TEXT NOT NULL,                               -- full original string, e.g. 'Pregnant women (2nd trimester)'
    sex         TEXT,                                        -- 'Male', 'Female', 'Both genders'
    life_stage  TEXT,                                        -- derived: 'infant', 'child', 'adult', 'pregnant', 'lactating', etc.
    UNIQUE (label, sex)
);

-- ---------------------------------------------------------------------------
-- 7. age_band — parsed age ranges
-- ---------------------------------------------------------------------------
CREATE TABLE age_band (
    id          SERIAL PRIMARY KEY,
    min_value   NUMERIC,
    max_value   NUMERIC,
    unit        TEXT,                                        -- 'months', 'years'
    comparator  TEXT,                                        -- '>=', null for ranges
    raw_label   TEXT,                                        -- original string for debugging
    notes       TEXT,
    UNIQUE NULLS NOT DISTINCT (min_value, max_value, unit, comparator)
);

-- ---------------------------------------------------------------------------
-- 8. intake_reference — canonical EFSA DRV records
-- ---------------------------------------------------------------------------
CREATE TABLE intake_reference (
    id                  SERIAL PRIMARY KEY,
    source_row_id       INT REFERENCES source_row(id) ON DELETE CASCADE,
    nutrient_id         INT NOT NULL REFERENCES nutrient(id),
    population_group_id INT NOT NULL REFERENCES population_group(id),
    age_band_id         INT NOT NULL REFERENCES age_band(id),
    reference_type_id   INT NOT NULL REFERENCES reference_type(id),
    value_numeric       NUMERIC,                             -- scalar value when kind='scalar'
    value_min           NUMERIC,                             -- range lower bound when kind='range'
    value_max           NUMERIC,                             -- range upper bound when kind='range'
    unit                TEXT,
    status              TEXT NOT NULL                         -- 'value', 'ND', 'NA'
                        CHECK (status IN ('value', 'ND', 'NA')),
    raw_value           TEXT,                                -- original cell text
    pal                 NUMERIC,                             -- physical activity level (Energy records only)
    UNIQUE NULLS NOT DISTINCT (nutrient_id, population_group_id, age_band_id, reference_type_id, pal)
);

CREATE INDEX idx_intake_ref_nutrient    ON intake_reference(nutrient_id);
CREATE INDEX idx_intake_ref_pop         ON intake_reference(population_group_id);
CREATE INDEX idx_intake_ref_age         ON intake_reference(age_band_id);
CREATE INDEX idx_intake_ref_reftype     ON intake_reference(reference_type_id);

-- ---------------------------------------------------------------------------
-- 9. food — canonical Ciqual food items
-- ---------------------------------------------------------------------------
CREATE TABLE food (
    id                  SERIAL PRIMARY KEY,
    source_row_id       INT REFERENCES source_row(id) ON DELETE CASCADE,
    source_food_code    TEXT NOT NULL,                        -- alim_code
    name                TEXT NOT NULL,                        -- alim_nom_eng
    scientific_name     TEXT,                                 -- alim_nom_sci
    group_code          TEXT,                                 -- alim_grp_code
    group_name          TEXT,                                 -- alim_grp_nom_eng
    subgroup_code       TEXT,                                 -- alim_ssgrp_code
    subgroup_name       TEXT,                                 -- alim_ssgrp_nom_eng
    subsubgroup_code    TEXT,                                 -- alim_ssssgrp_code
    subsubgroup_name    TEXT,                                 -- alim_ssssgrp_nom_eng
    UNIQUE (source_food_code)
);

CREATE INDEX idx_food_group ON food(group_name);

-- ---------------------------------------------------------------------------
-- 10. food_nutrient_value — pivoted nutrient values per food
-- ---------------------------------------------------------------------------
CREATE TABLE food_nutrient_value (
    id                  SERIAL PRIMARY KEY,
    food_id             INT NOT NULL REFERENCES food(id) ON DELETE CASCADE,
    nutrient_id         INT NOT NULL REFERENCES nutrient(id),
    value               NUMERIC,                             -- parsed numeric value (NULL if missing/trace)
    unit                TEXT,                                 -- 'mg', 'µg', 'g', 'kcal', 'kJ'
    basis               TEXT NOT NULL DEFAULT 'per_100g',    -- 'per_100g', 'per_serving', etc.
    raw_column_name     TEXT,                                -- original Ciqual header for provenance
    raw_cell_value      TEXT,                                -- original cell text before parsing
    quality_flag        TEXT                                  -- 'measured', 'less_than', 'traces', 'not_analyzed', 'missing'
                        CHECK (quality_flag IS NULL OR quality_flag IN (
                            'measured', 'less_than', 'traces', 'not_analyzed', 'missing'
                        )),
    UNIQUE NULLS NOT DISTINCT (food_id, nutrient_id, raw_column_name)
);

CREATE INDEX idx_fnv_food     ON food_nutrient_value(food_id);
CREATE INDEX idx_fnv_nutrient ON food_nutrient_value(nutrient_id);

-- ---------------------------------------------------------------------------
-- 11. nutrient_relationship — directed interaction edges
-- ---------------------------------------------------------------------------
CREATE TABLE nutrient_relationship (
    id                  SERIAL PRIMARY KEY,
    left_nutrient_id    INT NOT NULL REFERENCES nutrient(id),
    right_nutrient_id   INT NOT NULL REFERENCES nutrient(id),
    relationship_type   TEXT NOT NULL                         -- 'synergistic', 'antagonistic', 'varies'
                        CHECK (relationship_type IN (
                            'synergistic', 'antagonistic', 'varies'
                        )),
    evidence_scope      TEXT,                                 -- 'dietary', 'supplemental', 'both', NULL
    source_row_id       INT REFERENCES source_row(id) ON DELETE CASCADE,
    UNIQUE (left_nutrient_id, right_nutrient_id, relationship_type)
);

CREATE INDEX idx_nrel_left  ON nutrient_relationship(left_nutrient_id);
CREATE INDEX idx_nrel_right ON nutrient_relationship(right_nutrient_id);

COMMIT;
