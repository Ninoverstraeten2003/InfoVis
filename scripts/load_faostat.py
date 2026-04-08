#!/usr/bin/env python3
"""
Load FAOSTAT food production data into Viz3 canonical tables.
Bridges FAOSTAT commodities to CIQUAL food mappings.
"""

import csv
import json
import os
import glob
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://localhost:5432/nutriverse",
)

# Canonical mapping of FAOSTAT items to exactly known CIQUAL names
FAO_TO_CIQUAL_MAPPING = {
    # Cereals
    "Wheat": "Wheat grain, whole",
    "Maize (corn)": "Sweet corn, raw",
    "Rice": "Rice, brown, raw",
    "Triticale": "Wheat grain, whole",
    "Millet": "Millet, raw",
    "Sorghum": "Sorghum, raw",
    
    # Root & Tubers
    "Potatoes": "Potato, raw",
    "Cassava, fresh": "Cassava or manioc, root, raw",
    "Sweet potatoes": "Sweet potato, raw",
    "Yams": "Yam, raw",
    
    # Pulses & Nuts
    "Soya beans": "Soybean, raw",
    "Beans, dry": "Kidney bean, raw",
    "Peas, dry": "Pea, split, raw",
    "Chick peas, dry": "Chickpea, raw",
    "Lentils, dry": "Lentil, green, raw",
    "Groundnuts, excluding shelled": "Peanut, raw",
    
    # Seeds
    "Sunflower seed": "Sunflower seed",
    "Sesame seed": "Sesame seed",
    "Mustard seed": "Mustard seed",
    
    # Vegetables & Fruits
    "Tomatoes": "Tomato, raw",
    "Cabbages": "Cabbage, green, raw",
    "Carrots and turnips": "Carrot, raw",
    "Onions and shallots, dry (excluding dehydrated)": "Onion, raw",
    "Apples": "Apple, raw",
    "Bananas": "Banana, raw",
    "Plantains and others": "Plantain, raw",
    "Mangoes, guavas and mangosteens": "Mango, raw",
    "Papayas": "Papaya, raw",
    "Oranges": "Orange, raw",
    
    # Animal Products
    "Raw milk of cattle": "Cow milk, whole, raw",
    "Raw milk of goats": "Goat milk, whole, raw",
    "Raw milk of sheep": "Sheep milk, whole, raw",
    "Hen eggs in shell, fresh": "Egg, chicken, whole, raw",
    "Meat of cattle with the bone, fresh or chilled": "Beef, meat, raw",
    "Meat of pig with the bone, fresh or chilled": "Pork, meat, raw",
    "Meat of chickens, fresh or chilled": "Chicken, meat, raw",
    "Meat of sheep, fresh or chilled": "Mutton, meat, raw",
    "Meat of goat, fresh or chilled": "Goat, meat, raw"
}

def load():
    print("Loading FAOSTAT bridge...")
    
    csv_files = glob.glob(str(DATA_DIR / "FAOSTAT_data_*.csv"))
    if not csv_files:
        print("No FAOSTAT files found in data/")
        return

    conn = psycopg2.connect(DATABASE_URL)
    try:
        with conn.cursor() as cur:
            # 1. Resolve Mapping IDs once
            resolved_map = {}
            for fao, ciqual_name in FAO_TO_CIQUAL_MAPPING.items():
                # We use ILIKE because CIQUAL has subtle name changes
                cur.execute("SELECT id FROM food WHERE name ILIKE %s LIMIT 1", (f"%{ciqual_name}%",))
                res = cur.fetchone()
                if res:
                    resolved_map[fao] = res[0]
                else:
                    print(f"Warning: Could not resolve CIQUAL mapping for '{ciqual_name}' (from {fao})")

            # 2. Source file tracking - bundle them as one abstract "Dataset" source
            cur.execute(
                """
                INSERT INTO source_file (source_system, file_name, dataset_name)
                VALUES (%s, %s, %s)
                ON CONFLICT (source_system, file_name)
                DO UPDATE SET dataset_name = EXCLUDED.dataset_name
                RETURNING id
                """,
                ("FAOSTAT", "Bulk Production (Various CSVs)", "FAOSTAT Production Crops and Livestock"),
            )
            source_file_id = cur.fetchone()[0]

            cur.execute("DELETE FROM source_row WHERE source_file_id = %s", (source_file_id,))
            print(f"Cleared previous FAOSTAT source rows.")

            # Load actual CSV data
            row_idx = 0
            inserted = 0
            skipped = 0
            
            for csv_file in csv_files:
                print(f"Reading: {os.path.basename(csv_file)}")
                with open(csv_file, 'r', encoding='utf-8') as fp:
                    reader = csv.reader(fp)
                    headers = next(reader)
                    
                    # Resolve indices
                    try:
                        iso3_idx = headers.index('Area Code (ISO3)')
                        item_idx = headers.index('Item')
                        year_idx = headers.index('Year')
                        val_idx = headers.index('Value')
                    except ValueError as e:
                        print(f"Skipping {csv_file}: Missing expected header columns: {e}")
                        continue

                    for row in reader:
                        row_idx += 1
                        if len(row) <= val_idx:
                            continue
                            
                        iso3 = row[iso3_idx]
                        item = row[item_idx]
                        
                        try:
                            year = int(row[year_idx])
                            val_tonnes = float(row[val_idx])
                        except ValueError:
                            continue
                            
                        # We only care if we have this ISO3 in our country table
                        cur.execute("SELECT id FROM country WHERE iso3 = %s", (iso3,))
                        country_res = cur.fetchone()
                        if not country_res:
                            skipped += 1
                            continue
                            
                        country_id = country_res[0]
                        mapped_food_id = resolved_map.get(item)

                        # Only store if we mapped it, to save DB space and strictly support Paradox
                        if mapped_food_id:
                            # Insert source row
                            # Just a lightweight subset to save space
                            payload = json.dumps({'iso3': iso3, 'item': item, 'year': year, 'value': val_tonnes})
                            cur.execute(
                                "INSERT INTO source_row (source_file_id, sheet_name, row_number, raw_payload) VALUES (%s, %s, %s, %s) RETURNING id",
                                (source_file_id, "FAOSTAT", row_idx, payload)
                            )
                            source_row_id = cur.fetchone()[0]

                            cur.execute(
                                """
                                INSERT INTO country_food_production (source_row_id, country_id, faostat_item, mapped_food_id, year, value_tonnes)
                                VALUES (%s, %s, %s, %s, %s, %s)
                                ON CONFLICT DO NOTHING
                                """,
                                (source_row_id, country_id, item, mapped_food_id, year, val_tonnes)
                            )
                            inserted += 1

            conn.commit()
            print(f"Success! Inserted {inserted} mapped production entries.")
            print(f"Skipped {skipped} rows (unmapped iso3 or missing items).")

    finally:
        conn.close()


if __name__ == "__main__":
    load()
