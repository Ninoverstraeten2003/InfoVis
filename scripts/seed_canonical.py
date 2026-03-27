#!/usr/bin/env python3
"""
Seed the nutrient, nutrient_alias, and reference_type tables.

Run this FIRST before any data loaders.

This script reconciles the canonical nutrient seed against the database:
it updates existing rows, synchronizes aliases, and removes stale nutrients
that are no longer present in the seed.

Usage:
    python scripts/seed_canonical.py
    # Requires: DATABASE_URL env var or defaults to localhost nutriverse db
"""

import json
import os
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values

ROOT = Path(__file__).resolve().parents[1]
SEED_PATH = ROOT / "db" / "seed_nutrients.json"

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://localhost:5432/nutriverse",
)

REFERENCE_TYPES = [
    ("AI", "Adequate Intake"),
    ("AR", "Average Requirement"),
    ("PRI", "Population Reference Intake"),
    ("RI", "Reference Intake range"),
    ("UL", "Tolerable Upper Intake Level"),
    ("safe_and_adequate_intake", "Safe and adequate intake"),
]


def resolve_existing_nutrient_id(cur, entry):
    """Resolve an existing nutrient row for a seed entry using stable identifiers."""
    infoods_tag = entry.get("infoods_tag")
    if infoods_tag:
        cur.execute(
            "SELECT id FROM nutrient WHERE infoods_tag = %s LIMIT 1",
            (infoods_tag,),
        )
        row = cur.fetchone()
        if row is not None:
            return row[0]

    cur.execute(
        "SELECT id FROM nutrient WHERE canonical_name = %s LIMIT 1",
        (entry["canonical_name"],),
    )
    row = cur.fetchone()
    if row is not None:
        return row[0]

    for source_system, alias_list in entry.get("aliases", {}).items():
        for alias in alias_list:
            cur.execute(
                """
                SELECT nutrient_id
                FROM nutrient_alias
                WHERE alias = %s AND source_system = %s
                LIMIT 1
                """,
                (alias, source_system),
            )
            row = cur.fetchone()
            if row is not None:
                return row[0]

    return None


def sync_nutrient_aliases(cur, nutrient_id, aliases_by_source):
    """Make nutrient_alias rows match the seed exactly for this nutrient."""
    desired_pairs = {
        (source_system, alias)
        for source_system, alias_list in aliases_by_source.items()
        for alias in alias_list
    }
    desired_sources = set(aliases_by_source.keys())

    cur.execute(
        """
        SELECT id, alias, source_system
        FROM nutrient_alias
        WHERE nutrient_id = %s
        """,
        (nutrient_id,),
    )
    existing_rows = cur.fetchall()
    existing_pairs = {(source_system, alias) for _, alias, source_system in existing_rows}

    for alias_id, alias, source_system in existing_rows:
        if source_system not in desired_sources or (source_system, alias) not in desired_pairs:
            cur.execute("DELETE FROM nutrient_alias WHERE id = %s", (alias_id,))

    missing_pairs = desired_pairs - existing_pairs
    for source_system, alias in sorted(missing_pairs):
        cur.execute(
            """
            INSERT INTO nutrient_alias (nutrient_id, alias, source_system)
            VALUES (%s, %s, %s)
            ON CONFLICT (alias, source_system) DO UPDATE
                SET nutrient_id = EXCLUDED.nutrient_id
            """,
            (nutrient_id, alias, source_system),
        )


def delete_stale_nutrients(cur, keep_ids):
    """Delete nutrients not present in the current seed, plus dependent rows."""
    cur.execute(
        "SELECT id, canonical_name FROM nutrient WHERE NOT (id = ANY(%s))",
        (keep_ids,),
    )
    stale_rows = cur.fetchall()
    if not stale_rows:
        return 0

    stale_ids = [row[0] for row in stale_rows]

    cur.execute(
        "DELETE FROM nutrient_relationship WHERE left_nutrient_id = ANY(%s) OR right_nutrient_id = ANY(%s)",
        (stale_ids, stale_ids),
    )
    cur.execute("DELETE FROM food_nutrient_value WHERE nutrient_id = ANY(%s)", (stale_ids,))
    cur.execute("DELETE FROM intake_reference WHERE nutrient_id = ANY(%s)", (stale_ids,))
    cur.execute("DELETE FROM nutrient_alias WHERE nutrient_id = ANY(%s)", (stale_ids,))
    cur.execute("DELETE FROM nutrient WHERE id = ANY(%s)", (stale_ids,))

    return len(stale_rows)


def seed_reference_types(cur):
    """Insert the six EFSA reference type codes."""
    execute_values(
        cur,
        """
        INSERT INTO reference_type (code, label)
        VALUES %s
        ON CONFLICT (code) DO UPDATE
            SET label = EXCLUDED.label
        """,
        REFERENCE_TYPES,
    )
    print(f"  reference_type: {len(REFERENCE_TYPES)} codes seeded")


def seed_nutrients_and_aliases(cur):
    """Load seed_nutrients.json and populate nutrient + nutrient_alias."""
    with SEED_PATH.open() as f:
        nutrients = json.load(f)

    nutrient_count = 0
    alias_count = 0
    kept_nutrient_ids = []

    for entry in nutrients:
        nutrient_id = resolve_existing_nutrient_id(cur, entry)
        if nutrient_id is None:
            cur.execute(
                """
                INSERT INTO nutrient (canonical_name, category, default_unit, infoods_tag)
                VALUES (%s, %s, %s, %s)
                RETURNING id
                """,
                (
                    entry["canonical_name"],
                    entry["category"],
                    entry.get("default_unit"),
                    entry.get("infoods_tag"),
                ),
            )
            nutrient_id = cur.fetchone()[0]
        else:
            cur.execute(
                """
                UPDATE nutrient
                SET canonical_name = %s,
                    category = %s,
                    default_unit = %s,
                    infoods_tag = %s
                WHERE id = %s
                """,
                (
                    entry["canonical_name"],
                    entry["category"],
                    entry.get("default_unit"),
                    entry.get("infoods_tag"),
                    nutrient_id,
                ),
            )

        kept_nutrient_ids.append(nutrient_id)
        nutrient_count += 1

        aliases_by_source = entry.get("aliases", {})
        sync_nutrient_aliases(cur, nutrient_id, aliases_by_source)
        alias_count += sum(len(alias_list) for alias_list in aliases_by_source.values())

    stale_count = delete_stale_nutrients(cur, kept_nutrient_ids)

    print(f"  nutrient: {nutrient_count} nutrients seeded")
    print(f"  nutrient_alias: {alias_count} aliases synced")
    if stale_count:
        print(f"  nutrient: removed {stale_count} stale nutrient(s)")


def main():
    print(f"Connecting to {DATABASE_URL}")
    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            print("Seeding reference_type...")
            seed_reference_types(cur)
            print("Seeding nutrient + nutrient_alias...")
            seed_nutrients_and_aliases(cur)
        conn.commit()
        print("Done.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
