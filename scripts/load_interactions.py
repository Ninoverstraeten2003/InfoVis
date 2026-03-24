#!/usr/bin/env python3
"""
Load nutrient interaction edges into canonical tables.

Populates: source_file, source_row, nutrient_relationship.

Idempotent: re-running clears previous INTERACTIONS source_rows (cascading
to nutrient_relationship) before re-inserting.

Prerequisites:
    - Schema created (db/schema.sql)
    - Nutrients + aliases seeded (scripts/seed_canonical.py)

Usage:
    python scripts/load_interactions.py
"""

import json
import os
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]
INPUT_PATH = ROOT / "data" / "interactions.json"

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://localhost:5432/nutriverse",
)


def resolve_nutrient_id(cur, interaction_name, cache):
    """Resolve interactions.json nutrient name → nutrient.id via alias lookup."""
    if interaction_name in cache:
        return cache[interaction_name]

    cur.execute(
        """
        SELECT n.id FROM nutrient n
        JOIN nutrient_alias na ON na.nutrient_id = n.id
        WHERE na.alias = %s AND na.source_system = 'INTERACTIONS'
        LIMIT 1
        """,
        (interaction_name,),
    )
    row = cur.fetchone()
    if row is None:
        # Fallback: try canonical_name directly
        cur.execute(
            "SELECT id FROM nutrient WHERE canonical_name = %s",
            (interaction_name,),
        )
        row = cur.fetchone()
    if row is None:
        raise ValueError(
            f"No nutrient mapping for interaction name: {interaction_name!r}"
        )

    cache[interaction_name] = row[0]
    return row[0]


def load():
    with INPUT_PATH.open() as f:
        interactions = json.load(f)

    print(f"Loaded {len(interactions)} interaction hub nutrients from {INPUT_PATH.name}")

    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            # Source file
            cur.execute(
                """
                INSERT INTO source_file (source_system, file_name, dataset_name)
                VALUES (%s, %s, %s)
                ON CONFLICT (source_system, file_name)
                DO UPDATE SET dataset_name = EXCLUDED.dataset_name
                RETURNING id
                """,
                ("INTERACTIONS", INPUT_PATH.name, "Nutrient Interaction Network"),
            )
            source_file_id = cur.fetchone()[0]

            # Clear previous load for idempotence
            # CASCADE: source_row → nutrient_relationship (via source_row_id)
            cur.execute(
                "DELETE FROM source_row WHERE source_file_id = %s",
                (source_file_id,),
            )
            cleared = cur.rowcount
            if cleared > 0:
                print(f"  Cleared {cleared} previous source_row(s) (+ cascaded nutrient_relationship)")

            nutrient_cache = {}
            edge_inserted = 0
            edge_updated = 0

            for row_idx, entry in enumerate(interactions):
                # Store source row
                cur.execute(
                    """
                    INSERT INTO source_row (source_file_id, sheet_name, row_number, raw_payload)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (source_file_id, sheet_name, row_number)
                    DO UPDATE SET raw_payload = EXCLUDED.raw_payload
                    RETURNING id
                    """,
                    (source_file_id, None, row_idx, json.dumps(entry)),
                )
                source_row_id = cur.fetchone()[0]

                left_name = entry["nutrient"]
                left_id = resolve_nutrient_id(cur, left_name, nutrient_cache)

                for rel_type in ("synergistic", "antagonistic", "varies"):
                    for right_name in entry.get(rel_type, []):
                        right_id = resolve_nutrient_id(
                            cur, right_name, nutrient_cache
                        )
                        cur.execute(
                            """
                            INSERT INTO nutrient_relationship
                                (left_nutrient_id, right_nutrient_id,
                                 relationship_type, evidence_scope, source_row_id)
                            VALUES (%s, %s, %s, %s, %s)
                            ON CONFLICT (left_nutrient_id, right_nutrient_id, relationship_type)
                            DO UPDATE SET
                                source_row_id  = EXCLUDED.source_row_id,
                                evidence_scope = EXCLUDED.evidence_scope
                            RETURNING (xmax = 0) AS inserted
                            """,
                            (left_id, right_id, rel_type, None, source_row_id),
                        )
                        if cur.fetchone()[0]:
                            edge_inserted += 1
                        else:
                            edge_updated += 1

            conn.commit()
            print(f"nutrient_relationship: {edge_inserted} inserted, {edge_updated} updated")

    finally:
        conn.close()


if __name__ == "__main__":
    load()
