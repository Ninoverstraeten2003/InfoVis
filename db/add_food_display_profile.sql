BEGIN;

CREATE TABLE IF NOT EXISTS food_display_profile (
    food_id              INT PRIMARY KEY REFERENCES food(id) ON DELETE CASCADE,
    serving_size_g       NUMERIC,
    serving_label        TEXT,
    include_in_rankings  BOOLEAN NOT NULL DEFAULT TRUE,
    ranking_category     TEXT,
    display_priority     INT NOT NULL DEFAULT 100,
    notes                TEXT
);

CREATE INDEX IF NOT EXISTS idx_fdp_include
    ON food_display_profile(include_in_rankings);

CREATE INDEX IF NOT EXISTS idx_fdp_category
    ON food_display_profile(ranking_category);

CREATE INDEX IF NOT EXISTS idx_fdp_priority
    ON food_display_profile(display_priority);

COMMIT;
