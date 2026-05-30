#!/usr/bin/env python3
"""
generate_display_profiles.py

This script fetches foods from the database that don't have a display profile yet,
batches them, and sends them to an LLM via OpenRouter to generate realistic
serving sizes and culinary categories.
"""

import os
import json
import requests
import psycopg2
import time

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
    - "serving_size_g": A realistic integer portion size in grams for a normal meal.
    - "serving_label": A human-friendly label (e.g., "1 clove", "1 fillet", "1 medium piece", "1 tbsp", "1 cup").
    - "ranking_category": Must be one of:
                  - "main" (A central component of a meal, e.g., a chicken breast, a steak, a lentil stew)
                  - "side" (A complementary dish, e.g., steamed carrots, a small salad, sauteed spinach)
                  - "carb_base" (A staple carbohydrate source, e.g., rice, pasta, bread, potatoes)
                  - "beverage" (A drink, e.g., apple juice, milk, coffee)
                  - "ingredient" (Raw components rarely eaten alone, e.g., raw flour, baking soda, spices)
                  - "other" (Snacks, condiments, desserts)
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
        print("Error: OpenRouter API timed out after 60 seconds.")
        return None
    
    if response.status_code != 200:
        print(f"Error from OpenRouter: {response.text}")
        return None

    try:
        content = response.json()["choices"][0]["message"]["content"]
        # Strip markdown if the model ignored instructions
        if content.startswith("```json"):
            content = content.replace("```json", "").replace("```", "")
        return json.loads(content.strip())
    except Exception as e:
        print(f"Failed to parse JSON: {e}")
        return None

def main():
    if not OPENROUTER_API_KEY:
        print("Error: OPENROUTER_API_KEY environment variable is not set.")
        return

    conn = psycopg2.connect(DATABASE_URL)
    foods = get_foods_without_profile(conn)
    print(f"Found {len(foods)} foods needing profiles.")

    # Process in batches of 20 to save API calls and keep context windows manageable
    BATCH_SIZE = 20
    
    for i in range(0, len(foods), BATCH_SIZE):
        batch = foods[i:i + BATCH_SIZE]
        print(f"\nProcessing batch {i} to {i + len(batch)}...")
        
        results = ask_openrouter(batch)
        
        if results:
            with conn.cursor() as cur:
                for res in results:
                    try:
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
                    except Exception as e:
                        print(f"DB Insert Error for ID {res.get('food_id')}: {e}")
                        conn.rollback()
                        continue
                conn.commit()
            print("Batch saved successfully.")
        
        # Be polite to the API rate limits
        time.sleep(2)
        
    conn.close()
    print("Done!")

if __name__ == "__main__":
    main()
