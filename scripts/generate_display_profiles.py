#!/usr/bin/env python3
"""
generate_display_profiles.py

This script fetches foods from the database that don't have a display profile yet,
batches them, and sends them to an LLM via OpenRouter to generate realistic
serving sizes and culinary categories.
"""

import os
import re
import json
import logging
import requests
import psycopg2
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

# Use logging instead of print() — it's thread-safe and won't produce garbled output
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(threadName)s] %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5433/nutriverse")
# Make sure you export this in your terminal before running:
# export OPENROUTER_API_KEY="your-key-here"
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY")

# You can change this to gpt-4o-mini or anthropic/claude-3-haiku for speed/cost
MODEL = "google/gemini-2.5-flash-lite"

def get_foods_without_profile(conn):
    with conn.cursor() as cur:
        # Get foods that aren't in the profile table yet
        cur.execute("""
            SELECT f.id, f.name, f.group_name 
            FROM food f
            LEFT JOIN food_display_profile fdp ON f.id = fdp.food_id
            WHERE fdp.food_id IS NULL
            ORDER BY f.id
        """)
        return cur.fetchall()

def ask_openrouter(batch):
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "Content-Type": "application/json"
    }

    # Format the batch for the prompt
    food_list = "\n".join([f"ID: {f[0]} | Name: {f[1]} | Group: {f[2]}" for f in batch])

    prompt = f"""
    You are a culinary data expert mapping scientific foods to realistic meal components.
    I will provide a list of foods with their ID, Name, and Scientific Group.
    
    For each food, return a JSON object in an array. Each object MUST have:
    - "food_id": The exact ID provided.
    - "serving_size_g": A realistic integer portion size in grams for a normal meal. BE CONSERVATIVE. For cooked beans/legumes use 80-100g. For raw beans/legumes use 30-50g. For spices use 1-5g. For meat use 100-150g.
    - "serving_label": A human-friendly label (e.g., "1 clove", "1 fillet", "1 medium piece", "1 tbsp", "1 cup").
    - "ranking_category": Must be one of:
                  - "main" (A central component of a meal, e.g., a chicken breast, a steak)
                  - "breakfast_protein" (Proteins specifically for breakfast, e.g., eggs, bacon, breakfast sausage)
                  - "composite_meal" (A full meal in one dish that doesn't need a side/carb, e.g., Lasagna, Pizza, mixed stews)
                  - "side" (A complementary dish, e.g., steamed carrots, a small salad, sauteed spinach)
                  - "carb_base" (A staple carbohydrate source for lunch/dinner, e.g., rice, pasta, bread, potatoes)
                  - "breakfast_carb" (Carbs specifically for breakfast, e.g., cereal, muesli, oats)
                  - "soup" (Any liquid-based soup, broth, or light stew)
                  - "fruit" (Fresh or dried fruits)
                  - "dairy_side" (A standalone dairy item, e.g., a pot of yogurt, a slice of cheese)
                  - "beverage" (A non-alcoholic drink, e.g., apple juice, milk, coffee)
                  - "alcoholic_beverage" (Beer, wine, spirits)
                  - "ingredient" (Raw components rarely eaten alone, e.g., raw flour, baking soda, spices, raw soybeans)
                  - "spread_or_fat" (Butter, jam, peanut butter, cooking oils, mayo)
                  - "snack" (Chips, nuts, energy bars, etc)
                  - "condiment" (Sauces, ketchup, mustard, dressings)
                  - "dessert" (Cakes, cookies, sweet treats)
                  - "other" (Things that don't fit anywhere else)
    - "target_age_group": Strictly one of ["infant", "child", "adult", "all"].
    - "include_in_rankings": MUST be false for "ingredient" items (like raw flour), weird obscure meats, or things not eaten as standalone foods. MUST be false for "infant" foods unless specifically designing baby food. True for standard, realistic meal components.
    - "display_priority": Integer from 1 to 100 (1 is ultra-common staple like Rice/Chicken, 50 is standard, 100 is rare).

    Foods:
    {food_list}
    
    Respond ONLY with a valid JSON array. Do not include markdown blocks like ```json.
    """

    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": "You output strict, raw JSON arrays."},
            {"role": "user", "content": prompt}
        ]
        # Removed "response_format": {"type": "json_object"} because it causes some OSS models to hang
    }

    try:
        # Added a 60-second timeout so it doesn't hang forever if the API is slow
        response = requests.post("https://openrouter.ai/api/v1/chat/completions", headers=headers, json=payload, timeout=60)
    except requests.exceptions.Timeout:
        log.error("OpenRouter API timed out after 60 seconds.")
        return None

    if response.status_code != 200:
        log.error(f"Error from OpenRouter: {response.text}")
        return None

    try:
        content = response.json()["choices"][0]["message"]["content"]
        # FIX 1: Robust markdown stripping — handles ```json\n...\n``` with any whitespace
        content = re.sub(r"```json\s*|\s*```", "", content)
        return json.loads(content.strip())
    except Exception as e:
        log.error(f"Failed to parse JSON: {e}")
        return None

def save_results(conn, results):
    """Saves a list of LLM results to the DB. Each row is committed independently
    so a single bad row doesn't roll back the entire batch. (FIX 2)"""
    for res in results:
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO food_display_profile 
                    (food_id, serving_size_g, serving_label, include_in_rankings, ranking_category, display_priority, target_age_group)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (food_id) DO NOTHING
                """, (
                    res.get("food_id"),
                    res.get("serving_size_g"),
                    res.get("serving_label"),
                    res.get("include_in_rankings", True),
                    res.get("ranking_category"),
                    res.get("display_priority", 50),
                    res.get("target_age_group", "all")
                ))
            conn.commit()
        except Exception as e:
            log.error(f"DB Insert Error for ID {res.get('food_id')}: {e}")
            conn.rollback()  # Now only rolls back THIS single row, not the whole batch

def main():
    if not OPENROUTER_API_KEY:
        log.error("OPENROUTER_API_KEY environment variable is not set.")
        return

    conn = psycopg2.connect(DATABASE_URL)
    foods = get_foods_without_profile(conn)

    # FIX 3: Early exit with friendly message if there's nothing to do
    if not foods:
        log.info("All foods already have profiles. Nothing to do!")
        conn.close()
        return

    log.info(f"Found {len(foods)} foods needing profiles.")

    BATCH_SIZE = 20
    batches = [foods[i:i + BATCH_SIZE] for i in range(0, len(foods), BATCH_SIZE)]

    log.info(f"Divided into {len(batches)} batches. Starting multithreaded processing...")

    # Use 5 concurrent threads to dramatically speed up API requests without hitting rate limits too hard
    MAX_WORKERS = 5
    # FIX 4: Stagger submissions so all 5 threads don't fire simultaneously at t=0
    STAGGER_DELAY_S = 0.3

    # We save to DB in the main thread to avoid sharing a psycopg2 connection across threads
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_batch = {}
        for i, batch in enumerate(batches):
            future = executor.submit(ask_openrouter, batch)
            future_to_batch[future] = batch
            # Stagger each submission slightly to avoid a thundering-herd on the API
            if i < len(batches) - 1:
                time.sleep(STAGGER_DELAY_S)

        for count, future in enumerate(as_completed(future_to_batch), 1):
            log.info(f"Batch {count}/{len(batches)} finished. Saving to DB...")
            results = future.result()
            if results:
                save_results(conn, results)

    conn.close()
    log.info("Done!")

if __name__ == "__main__":
    main()
