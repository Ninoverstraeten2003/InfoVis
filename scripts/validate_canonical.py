#!/usr/bin/env python3
"""
Validation queries against the canonical schema.

Verifies cross-dataset joins work and reports coverage statistics.

Usage:
    python scripts/validate_canonical.py
"""

import os
from pathlib import Path

import psycopg2

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://localhost:5432/nutriverse",
)

QUERIES = [
    (
        "Table row counts",
        """
        SELECT 'source_file'          AS t, COUNT(*) FROM source_file
        UNION ALL SELECT 'source_row',        COUNT(*) FROM source_row
        UNION ALL SELECT 'nutrient',          COUNT(*) FROM nutrient
        UNION ALL SELECT 'nutrient_alias',    COUNT(*) FROM nutrient_alias
        UNION ALL SELECT 'reference_type',    COUNT(*) FROM reference_type
        UNION ALL SELECT 'population_group',  COUNT(*) FROM population_group
        UNION ALL SELECT 'age_band',          COUNT(*) FROM age_band
        UNION ALL SELECT 'intake_reference',  COUNT(*) FROM intake_reference
        UNION ALL SELECT 'food',              COUNT(*) FROM food
        UNION ALL SELECT 'food_nutrient_value', COUNT(*) FROM food_nutrient_value
        UNION ALL SELECT 'nutrient_relationship', COUNT(*) FROM nutrient_relationship
        ORDER BY 1
        """,
    ),
    (
        "Nutrients with coverage across all 3 datasets",
        """
        SELECT n.canonical_name,
               COUNT(DISTINCT ir.id) > 0 AS has_efsa_drv,
               COUNT(DISTINCT fnv.id) > 0 AS has_ciqual_data,
               COUNT(DISTINCT nr.id) > 0 AS has_interactions
        FROM nutrient n
        LEFT JOIN intake_reference ir ON ir.nutrient_id = n.id
        LEFT JOIN food_nutrient_value fnv ON fnv.nutrient_id = n.id
        LEFT JOIN nutrient_relationship nr
            ON nr.left_nutrient_id = n.id OR nr.right_nutrient_id = n.id
        GROUP BY n.id, n.canonical_name
        HAVING COUNT(DISTINCT ir.id) > 0
            OR COUNT(DISTINCT fnv.id) > 0
            OR COUNT(DISTINCT nr.id) > 0
        ORDER BY n.canonical_name
        """,
    ),
    (
        "Top 10 iron-rich foods (cross-dataset join test)",
        """
        SELECT f.name, fnv.value, fnv.unit, fnv.quality_flag
        FROM food f
        JOIN food_nutrient_value fnv ON fnv.food_id = f.id
        JOIN nutrient n ON n.id = fnv.nutrient_id
        WHERE n.canonical_name = 'Iron'
          AND fnv.quality_flag = 'measured'
          AND fnv.value IS NOT NULL
        ORDER BY fnv.value DESC
        LIMIT 10
        """,
    ),
    (
        "Iron DRV for adult males (EFSA join test)",
        """
        SELECT pg.label, pg.sex, ab.raw_label,
               rt.code, ir.value_numeric, ir.unit, ir.status
        FROM intake_reference ir
        JOIN nutrient n ON n.id = ir.nutrient_id
        JOIN population_group pg ON pg.id = ir.population_group_id
        JOIN age_band ab ON ab.id = ir.age_band_id
        JOIN reference_type rt ON rt.id = ir.reference_type_id
        WHERE n.canonical_name = 'Iron'
          AND pg.label = 'Adults'
          AND pg.sex = 'Male'
          AND ir.status = 'value'
        ORDER BY rt.code, ab.min_value
        """,
    ),
    (
        "Iron interaction network (relationship join test)",
        """
        SELECT nl.canonical_name AS left_nutrient,
               nr_rel.relationship_type,
               nright.canonical_name AS right_nutrient
        FROM nutrient_relationship nr_rel
        JOIN nutrient nl ON nl.id = nr_rel.left_nutrient_id
        JOIN nutrient nright ON nright.id = nr_rel.right_nutrient_id
        WHERE nl.canonical_name = 'Iron' OR nright.canonical_name = 'Iron'
        ORDER BY nr_rel.relationship_type, nl.canonical_name
        """,
    ),
    (
        "Full cross-dataset query: foods + DRV + interactions for Iron",
        """
        WITH iron_foods AS (
            SELECT f.name, fnv.value AS mg_per_100g
            FROM food f
            JOIN food_nutrient_value fnv ON fnv.food_id = f.id
            JOIN nutrient n ON n.id = fnv.nutrient_id
            WHERE n.canonical_name = 'Iron'
              AND fnv.quality_flag = 'measured'
              AND fnv.value IS NOT NULL
            ORDER BY fnv.value DESC
            LIMIT 5
        ),
        iron_drv AS (
            SELECT rt.code, ir.value_numeric, ir.unit
            FROM intake_reference ir
            JOIN nutrient n ON n.id = ir.nutrient_id
            JOIN reference_type rt ON rt.id = ir.reference_type_id
            JOIN population_group pg ON pg.id = ir.population_group_id
            WHERE n.canonical_name = 'Iron'
              AND pg.label = 'Adults' AND pg.sex = 'Male'
              AND ir.status = 'value'
            LIMIT 3
        ),
        iron_interactions AS (
            SELECT nr_rel.relationship_type,
                   nright.canonical_name AS interacts_with
            FROM nutrient_relationship nr_rel
            JOIN nutrient nl ON nl.id = nr_rel.left_nutrient_id
            JOIN nutrient nright ON nright.id = nr_rel.right_nutrient_id
            WHERE nl.canonical_name = 'Iron'
        )
        SELECT 'top_food' AS section, name AS detail, mg_per_100g::text AS value FROM iron_foods
        UNION ALL
        SELECT 'drv', code, value_numeric::text || ' ' || unit FROM iron_drv
        UNION ALL
        SELECT 'interaction', relationship_type, interacts_with FROM iron_interactions
        ORDER BY section, detail
        """,
    ),
    (
        "Alias coverage check — nutrients without any alias",
        """
        SELECT n.canonical_name, n.category
        FROM nutrient n
        LEFT JOIN nutrient_alias na ON na.nutrient_id = n.id
        WHERE na.id IS NULL
        ORDER BY n.canonical_name
        """,
    ),
    (
        "Ciqual quality_flag distribution",
        """
        SELECT quality_flag, COUNT(*) AS cnt,
               ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
        FROM food_nutrient_value
        GROUP BY quality_flag
        ORDER BY cnt DESC
        """,
    ),
]


def validate():
    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            for title, sql in QUERIES:
                print(f"\n{'=' * 70}")
                print(f"  {title}")
                print(f"{'=' * 70}")
                try:
                    cur.execute(sql)
                    rows = cur.fetchall()
                    if not rows:
                        print("  (no rows)")
                        continue
                    # Get column names
                    col_names = [desc[0] for desc in cur.description]
                    # Print header
                    header = " | ".join(f"{c:>20s}" for c in col_names)
                    print(f"  {header}")
                    print(f"  {'-' * len(header)}")
                    for row in rows:
                        line = " | ".join(f"{str(v):>20s}" for v in row)
                        print(f"  {line}")
                except Exception as exc:
                    print(f"  ERROR: {exc}")
    finally:
        conn.close()


if __name__ == "__main__":
    validate()
