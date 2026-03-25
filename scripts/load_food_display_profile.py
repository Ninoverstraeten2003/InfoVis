#!/usr/bin/env python3
"""
Load curated food display profiles from CSV.

CSV columns:
    source_food_code,serving_size_g,serving_label,include_in_rankings,
    ranking_category,display_priority,notes

Usage:
    python scripts/load_food_display_profile.py
    python scripts/load_food_display_profile.py db/food_display_profile.sample.csv
    python scripts/load_food_display_profile.py --replace
"""

import csv
import os
import sys
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CSV_PATH = ROOT / "db" / "food_display_profile.sample.csv"

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://localhost:5432/nutriverse",
)


def parse_bool(value):
    if value is None:
        return True
    normalized = str(value).strip().lower()
    if normalized in {"true", "t", "1", "yes", "y"}:
        return True
    if normalized in {"false", "f", "0", "no", "n"}:
        return False
    raise ValueError(f"Invalid boolean value: {value!r}")


def parse_optional_decimal(value):
    if value is None or str(value).strip() == "":
        return None
    return float(str(value).strip().replace(",", "."))


def parse_optional_int(value):
    if value is None or str(value).strip() == "":
        return 100
    return int(str(value).strip())


def load(csv_path, replace=False):
    print(f"Connecting to {DATABASE_URL}")
    conn = psycopg2.connect(DATABASE_URL)
    inserted_or_updated = 0
    seen_food_ids = set()

    try:
        with csv_path.open(newline="", encoding="utf-8") as f, conn.cursor() as cur:
            reader = csv.DictReader(f)
            for row in reader:
                source_food_code = (row.get("source_food_code") or "").strip()
                if not source_food_code:
                    continue

                cur.execute(
                    "SELECT id FROM food WHERE source_food_code = %s",
                    (source_food_code,),
                )
                food_row = cur.fetchone()
                if food_row is None:
                    raise ValueError(
                        f"No food found for source_food_code={source_food_code!r}"
                    )

                food_id = food_row[0]
                seen_food_ids.add(food_id)
                cur.execute(
                    """
                    INSERT INTO food_display_profile
                        (food_id, serving_size_g, serving_label, include_in_rankings,
                         ranking_category, display_priority, notes)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (food_id) DO UPDATE
                    SET serving_size_g      = EXCLUDED.serving_size_g,
                        serving_label       = EXCLUDED.serving_label,
                        include_in_rankings = EXCLUDED.include_in_rankings,
                        ranking_category    = EXCLUDED.ranking_category,
                        display_priority    = EXCLUDED.display_priority,
                        notes               = EXCLUDED.notes
                    """,
                    (
                        food_id,
                        parse_optional_decimal(row.get("serving_size_g")),
                        (row.get("serving_label") or "").strip() or None,
                        parse_bool(row.get("include_in_rankings")),
                        (row.get("ranking_category") or "").strip() or None,
                        parse_optional_int(row.get("display_priority")),
                        (row.get("notes") or "").strip() or None,
                    ),
                )
                inserted_or_updated += 1

            deleted = 0
            if replace:
                if seen_food_ids:
                    cur.execute(
                        """
                        DELETE FROM food_display_profile
                        WHERE food_id <> ALL(%s)
                        """,
                        (list(seen_food_ids),),
                    )
                else:
                    cur.execute("DELETE FROM food_display_profile")
                deleted = cur.rowcount

        conn.commit()
        print(
            f"food_display_profile: {inserted_or_updated} row(s) inserted/updated from {csv_path.name}"
        )
        if replace:
            print(f"food_display_profile: {deleted} row(s) deleted during replace sync")
    finally:
        conn.close()


def main():
    args = sys.argv[1:]
    replace = False
    if "--replace" in args:
        replace = True
        args.remove("--replace")
    csv_path = Path(args[0]).resolve() if args else DEFAULT_CSV_PATH
    if not csv_path.exists():
        raise FileNotFoundError(csv_path)
    load(csv_path, replace=replace)


if __name__ == "__main__":
    main()
