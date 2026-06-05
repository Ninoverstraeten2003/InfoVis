#!/usr/bin/env python3
"""
generate_embeddings.py

Fetches all foods from the database that don't have a vector embedding yet,
requests an embedding from an AI model (via OpenRouter), and saves the 
vector back to the database for ultra-fast semantic barcode matching.
"""

import os
import json
import logging
import requests
import psycopg2
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(threadName)s] %(message)s")
log = logging.getLogger(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5433/nutriverse")
OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY")

# High-quality, extremely cheap embedding model
MODEL = "openai/text-embedding-3-small"

def get_foods_without_embeddings(conn):
    with conn.cursor() as cur:
        # Get foods that need embeddings
        cur.execute("""
            SELECT id, name, group_name 
            FROM food 
            WHERE search_embedding IS NULL
            ORDER BY id
        """)
        return cur.fetchall()

def get_embeddings(batch):
    """
    Sends a batch of text strings to OpenRouter's embedding endpoint.
    """
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "Content-Type": "application/json"
    }

    # We embed a combination of the food name and its category for better semantic matching
    texts_to_embed = [f"{f[1]} (Category: {f[2]})" for f in batch]

    payload = {
        "model": MODEL,
        "input": texts_to_embed
    }

    try:
        response = requests.post("https://openrouter.ai/api/v1/embeddings", headers=headers, json=payload, timeout=30)
    except requests.exceptions.Timeout:
        log.error("OpenRouter API timed out.")
        return None

    if response.status_code != 200:
        log.error(f"Error from OpenRouter: {response.text}")
        return None

    try:
        data = response.json()["data"]
        # Match the returned embeddings back to the food IDs
        results = []
        for i, item in enumerate(data):
            results.append({
                "food_id": batch[i][0],
                "embedding": item["embedding"] # This is the list of 1536 floats
            })
        return results
    except Exception as e:
        log.error(f"Failed to parse embedding JSON: {e}")
        return None

def save_embeddings(conn, results):
    """Saves the generated vectors back to the database."""
    for res in results:
        try:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE food 
                    SET search_embedding = %s 
                    WHERE id = %s
                """, (res["embedding"], res["food_id"]))
            conn.commit()
        except Exception as e:
            log.error(f"DB Update Error for ID {res['food_id']}: {e}")
            conn.rollback()

def main():
    if not OPENROUTER_API_KEY:
        log.error("OPENROUTER_API_KEY environment variable is not set.")
        return

    conn = psycopg2.connect(DATABASE_URL)
    foods = get_foods_without_embeddings(conn)

    if not foods:
        log.info("All foods already have vector embeddings. Nothing to do!")
        conn.close()
        return

    log.info(f"Found {len(foods)} foods needing embeddings.")

    # The OpenAI embedding endpoint can take large batches (up to 2048 at once)
    # But we'll use 100 to be safe and avoid payload size limits on OpenRouter
    BATCH_SIZE = 100
    batches = [foods[i:i + BATCH_SIZE] for i in range(0, len(foods), BATCH_SIZE)]

    log.info(f"Divided into {len(batches)} batches. Generating vectors...")

    # We can use multiple threads since it's network-bound
    MAX_WORKERS = 3
    STAGGER_DELAY_S = 0.5

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_batch = {}
        for i, batch in enumerate(batches):
            future = executor.submit(get_embeddings, batch)
            future_to_batch[future] = batch
            if i < len(batches) - 1:
                time.sleep(STAGGER_DELAY_S)

        for count, future in enumerate(as_completed(future_to_batch), 1):
            log.info(f"Batch {count}/{len(batches)} finished. Saving to DB...")
            results = future.result()
            if results:
                save_embeddings(conn, results)

    conn.close()
    log.info("Done! Vector database is fully populated.")

if __name__ == "__main__":
    main()
