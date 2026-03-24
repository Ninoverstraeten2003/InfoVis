#!/usr/bin/env python3
"""
Seed the nutrient, nutrient_alias, and reference_type tables.

Run this FIRST before any data loaders.

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


def seed_reference_types(cur):
    """Insert the six EFSA reference type codes."""
    execute_values(
        cur,
        """
        INSERT INTO reference_type (code, label)
        VALUES %s
        ON CONFLICT (code) DO NOTHING
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

    for entry in nutrients:
        # Upsert nutrient
        cur.execute(
            """
            INSERT INTO nutrient (canonical_name, category, default_unit, infoods_tag)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (canonical_name) DO UPDATE
                SET category    = EXCLUDED.category,
                    default_unit = EXCLUDED.default_unit,
                    infoods_tag  = EXCLUDED.infoods_tag
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
        nutrient_count += 1

        # Insert aliases per source system
        for source_system, alias_list in entry.get("aliases", {}).items():
            for alias in alias_list:
                cur.execute(
                    """
                    INSERT INTO nutrient_alias (nutrient_id, alias, source_system)
                    VALUES (%s, %s, %s)
                    ON CONFLICT (alias, source_system) DO NOTHING
                    """,
                    (nutrient_id, alias, source_system),
                )
                alias_count += 1

    print(f"  nutrient: {nutrient_count} nutrients seeded")
    print(f"  nutrient_alias: {alias_count} aliases seeded")


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
