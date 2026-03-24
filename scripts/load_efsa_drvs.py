#!/usr/bin/env python3
"""
Load EFSA DRV data from drvs_eu_normalized.json into canonical tables.

Populates: source_file, source_row, population_group, age_band, intake_reference.

Idempotent: re-running clears previous EFSA source_rows (and cascading
intake_reference rows) before re-inserting.

Prerequisites:
    - Schema created (db/schema.sql)
    - Nutrients + reference types seeded (scripts/seed_canonical.py)

Usage:
    python scripts/load_efsa_drvs.py
"""

import json
import os
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]
INPUT_PATH = ROOT / "data" / "drvs_eu_normalized.json"

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://localhost:5432/nutriverse",
)

# Map target_population → life_stage
LIFE_STAGE_MAP = {
    "Infants": "infant",
    "Children": "child",
    "Adults": "adult",
    "Postmenopausal women": "adult",
    "Premenopausal women": "adult",
    "Pregnant women": "pregnant",
    "Lactating women": "lactating",
}


def derive_life_stage(label):
    """Derive life_stage from population label."""
    for prefix, stage in LIFE_STAGE_MAP.items():
        if label.startswith(prefix):
            return stage
    return "adult"


def get_or_create_source_file(cur, source_system, file_name, dataset_name):
    cur.execute(
        """
        INSERT INTO source_file (source_system, file_name, dataset_name)
        VALUES (%s, %s, %s)
        ON CONFLICT (source_system, file_name)
        DO UPDATE SET dataset_name = EXCLUDED.dataset_name
        RETURNING id
        """,
        (source_system, file_name, dataset_name),
    )
    return cur.fetchone()[0]


def clear_previous_load(cur, source_file_id):
    """Delete all source_rows (and cascading intake_reference rows) for this source file."""
    cur.execute(
        "DELETE FROM source_row WHERE source_file_id = %s",
        (source_file_id,),
    )
    deleted = cur.rowcount
    if deleted > 0:
        print(f"  Cleared {deleted} previous source_row(s) (+ cascaded intake_reference)")


def upsert_source_row(cur, source_file_id, row_number, raw_payload):
    cur.execute(
        """
        INSERT INTO source_row (source_file_id, sheet_name, row_number, raw_payload)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (source_file_id, sheet_name, row_number)
        DO UPDATE SET raw_payload = EXCLUDED.raw_payload
        RETURNING id
        """,
        (source_file_id, None, row_number, json.dumps(raw_payload)),
    )
    return cur.fetchone()[0]


def get_or_create_population_group(cur, label, sex):
    life_stage = derive_life_stage(label)
    cur.execute(
        """
        INSERT INTO population_group (label, sex, life_stage)
        VALUES (%s, %s, %s)
        ON CONFLICT (label, sex) DO UPDATE SET life_stage = EXCLUDED.life_stage
        RETURNING id
        """,
        (label, sex, life_stage),
    )
    return cur.fetchone()[0]


def get_or_create_age_band(cur, age_obj):
    min_val = age_obj.get("min")
    max_val = age_obj.get("max")
    unit = age_obj.get("unit")
    comparator = age_obj.get("comparator")
    raw_label = age_obj.get("raw")

    cur.execute(
        """
        INSERT INTO age_band (min_value, max_value, unit, comparator, raw_label)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (min_value, max_value, unit, comparator)
        DO UPDATE SET raw_label = EXCLUDED.raw_label
        RETURNING id
        """,
        (min_val, max_val, unit, comparator, raw_label),
    )
    return cur.fetchone()[0]


def resolve_nutrient_id(cur, efsa_name, cache):
    """Resolve EFSA nutrient name → nutrient.id via nutrient_alias lookup."""
    if efsa_name in cache:
        return cache[efsa_name]

    cur.execute(
        """
        SELECT n.id FROM nutrient n
        JOIN nutrient_alias na ON na.nutrient_id = n.id
        WHERE na.alias = %s AND na.source_system = 'EFSA'
        LIMIT 1
        """,
        (efsa_name,),
    )
    row = cur.fetchone()
    if row is None:
        # Fallback: try canonical_name directly
        cur.execute(
            "SELECT id FROM nutrient WHERE canonical_name = %s",
            (efsa_name,),
        )
        row = cur.fetchone()
    if row is None:
        raise ValueError(f"No nutrient mapping found for EFSA name: {efsa_name!r}")

    cache[efsa_name] = row[0]
    return row[0]


def resolve_reference_type_id(cur, code, cache):
    if code in cache:
        return cache[code]
    cur.execute("SELECT id FROM reference_type WHERE code = %s", (code,))
    row = cur.fetchone()
    if row is None:
        raise ValueError(f"Unknown reference_type code: {code!r}")
    cache[code] = row[0]
    return row[0]


REFERENCE_CODES = ["AI", "AR", "PRI", "RI", "UL", "safe_and_adequate_intake"]


def load():
    with INPUT_PATH.open() as f:
        data = json.load(f)

    print(f"Loaded {data['record_count']} records from {INPUT_PATH.name}")

    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            # Source file
            source_file_id = get_or_create_source_file(
                cur, "EFSA", data["source_file"], data["dataset"]
            )

            # Clear previous load for idempotence
            # CASCADE on source_row → intake_reference handles dependent rows
            clear_previous_load(cur, source_file_id)

            nutrient_cache = {}
            reftype_cache = {}
            intake_ref_inserted = 0
            intake_ref_updated = 0

            for row_idx, record in enumerate(data["records"], start=2):
                # Source row (upsert for safety, though we just cleared)
                source_row_id = upsert_source_row(
                    cur, source_file_id, row_idx, record
                )

                # Resolve dimensions
                nutrient_id = resolve_nutrient_id(
                    cur, record["nutrient"], nutrient_cache
                )
                pop_group_id = get_or_create_population_group(
                    cur, record["target_population"], record["gender"]
                )
                age_band_id = get_or_create_age_band(cur, record["age"])

                # Extract PAL from age object
                pal = record["age"].get("pal")

                # One intake_reference row per reference type that has data
                for ref_code in REFERENCE_CODES:
                    ref_value = record["references"].get(ref_code)
                    if ref_value is None:
                        continue

                    ref_type_id = resolve_reference_type_id(
                        cur, ref_code, reftype_cache
                    )

                    status = ref_value.get("status", "value")
                    if status in ("ND", "NA"):
                        value_numeric = None
                        value_min = None
                        value_max = None
                        unit = None
                    else:
                        kind = ref_value.get("kind")
                        value_numeric = ref_value.get("value") if kind == "scalar" else None
                        value_min = ref_value.get("min") if kind == "range" else None
                        value_max = ref_value.get("max") if kind == "range" else None
                        unit = ref_value.get("unit")
                        status = "value"

                    cur.execute(
                        """
                        INSERT INTO intake_reference
                            (source_row_id, nutrient_id, population_group_id,
                             age_band_id, reference_type_id,
                             value_numeric, value_min, value_max,
                             unit, status, raw_value, pal)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (nutrient_id, population_group_id, age_band_id, reference_type_id, pal)
                        DO UPDATE SET
                            source_row_id = EXCLUDED.source_row_id,
                            value_numeric = EXCLUDED.value_numeric,
                            value_min     = EXCLUDED.value_min,
                            value_max     = EXCLUDED.value_max,
                            unit          = EXCLUDED.unit,
                            status        = EXCLUDED.status,
                            raw_value     = EXCLUDED.raw_value
                        RETURNING (xmax = 0) AS inserted
                        """,
                        (
                            source_row_id, nutrient_id, pop_group_id,
                            age_band_id, ref_type_id,
                            value_numeric, value_min, value_max,
                            unit, status, ref_value.get("raw"), pal,
                        ),
                    )
                    was_insert = cur.fetchone()[0]
                    if was_insert:
                        intake_ref_inserted += 1
                    else:
                        intake_ref_updated += 1

            conn.commit()
            print(f"intake_reference: {intake_ref_inserted} inserted, {intake_ref_updated} updated")
            print(f"From {len(data['records'])} EFSA records × {len(REFERENCE_CODES)} ref types")

    finally:
        conn.close()


if __name__ == "__main__":
    load()
