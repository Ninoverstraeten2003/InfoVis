#!/usr/bin/env python3
import os
import random
import json
import psycopg2
import time

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5433/nutriverse")

# Define the structure of our Daily Meal Plan
MEAL_TEMPLATE = [
    {"meal": "Breakfast", "category": "breakfast_carb"},
    {"meal": "Breakfast", "category": "beverage"},
    {"meal": "Lunch", "category": "main"},
    {"meal": "Lunch", "category": "side"},
    {"meal": "Dinner", "category": "main"},
    {"meal": "Dinner", "category": "carb_base"},
    {"meal": "Dinner", "category": "side"},
]

# These nutrients have EFSA ULs that apply only to supplements or synthetic fortificants.
# If tracking whole foods, exceeding these targets is biologically safe.
SUPPLEMENT_ONLY_ULS = [
    'Magnesium', 
    'Folate', 
    'Vitamin B3', 
    'Vitamin E (total)'
]

def get_food_catalog(conn):
    """Loads all valid foods categorized by their culinary ranking_category."""
    cur = conn.cursor()
    cur.execute("""
        SELECT f.id, f.name, fdp.ranking_category, fdp.serving_size_g, fdp.serving_label
        FROM food f
        JOIN food_display_profile fdp ON f.id = fdp.food_id
        WHERE fdp.include_in_rankings = true
          AND fdp.ranking_category IS NOT NULL
          AND fdp.serving_size_g > 0
    """)
    catalog = {}
    for row in cur.fetchall():
        cat = row[2]
        if cat not in catalog:
            catalog[cat] = []
        catalog[cat].append({
            "id": row[0],
            "name": row[1],
            "serving_size_g": float(row[3]),
            "serving_label": row[4]
        })
    return catalog

def get_nutrient_matrix(conn):
    """Loads the deduplicated canonical nutrient matrix into Python memory."""
    cur = conn.cursor()
    cur.execute("""
        SELECT v.food_id, v.nutrient_name, v.value 
        FROM v_food_nutrient_ranked v
        JOIN food_display_profile fdp ON fdp.food_id = v.food_id
        WHERE fdp.include_in_rankings = true
    """)
    matrix = {}
    for food_id, nut_name, val in cur.fetchall():
        if food_id not in matrix:
            matrix[food_id] = {}
        matrix[food_id][nut_name] = float(val) if val is not None else 0.0
    return matrix

def get_user_targets(conn, catalog, age, sex, pal=1.6, weight=70.0):
    """
    Fetches the personalized targets and toxicity limits for the user ONCE.
    We trick the database by passing a 'fake meal' containing 0.0001g of every food,
    which forces api.calculate_meal_nutrition to return the targets for every possible nutrient.
    """
    fake_meal = []
    for cat_foods in catalog.values():
        for f in cat_foods:
            fake_meal.append({"food_id": f["id"], "amount_g": 0.0001})
            
    cur = conn.cursor()
    cur.execute("""
        SELECT nutrient_name, target_value, max_value 
        FROM api.calculate_meal_nutrition(
            p_age_years := %s::numeric, 
            p_sex := %s::text, 
            p_food_items := %s::jsonb, 
            p_pal := %s::numeric, 
            p_body_weight_kg := %s::numeric
        )
    """, (age, sex, json.dumps(fake_meal), pal, weight))
    
    targets = {}
    for row in cur.fetchall():
        targets[row[0]] = {
            "target": float(row[1]) if row[1] else 0,
            "max": float(row[2]) if row[2] else None
        }
    return targets

def evaluate_fitness_in_memory(genome, targets, matrix):
    """Scores a meal plan instantly in local Python RAM."""
    consumed = {}
    for food in genome:
        food_id = food["id"]
        amount = food["serving_size_g"]
        if food_id in matrix:
            for nut_name, val_per_100g in matrix[food_id].items():
                consumed[nut_name] = consumed.get(nut_name, 0) + val_per_100g * (amount / 100.0)
                
    score = 0
    stats = []
    
    for nut_name, t_data in targets.items():
        cons = consumed.get(nut_name, 0)
        
        # Energy in the database is standardized to kJ. 
        # The EFSA target returned by the DB is in kcal. We must convert kJ -> kcal.
        if nut_name == 'Energy':
            cons = cons / 4.184
            
        target_val = t_data["target"]
        max_val = t_data["max"]
        
        # If there is no recommended minimum for this nutrient (e.g., Lactose, Arachidonic acid)
        # we don't penalize it and we don't report it as deficient!
        if target_val == 0 and max_val is None:
            continue
            
        pct = (cons / target_val * 100) if target_val > 0 else 0
        stats.append((nut_name, round(cons, 2), target_val, max_val, round(pct, 2)))
        
        if max_val and cons > max_val:
            if nut_name not in SUPPLEMENT_ONLY_ULS:
                score -= 1000
                
        if target_val > 0:
            if 90 <= pct <= 110:
                score += 10
            elif pct > 110:
                score += 5
            elif pct >= 50:
                score += 2
            else:
                score -= 5
            
        if nut_name == 'Energy' and target_val > 0:
            if pct < 85:
                score -= 50
            elif pct > 115:
                score -= 100
                
    return score, stats

def generate_random_genome(catalog):
    """Creates a random daily meal plan based on the template slots."""
    genome = []
    for slot in MEAL_TEMPLATE:
        cat = slot["category"]
        valid_foods = catalog.get(cat, [])
        
        # --- CULINARY FILTERS ---
        if valid_foods:
            if slot["meal"] == "Dinner" or slot["meal"] == "Lunch":
                valid_foods = [f for f in valid_foods if "cereal" not in f["name"].lower() and "muesli" not in f["name"].lower()]
            if slot["meal"] == "Breakfast":
                valid_foods = [f for f in valid_foods if "flour" not in f["name"].lower() and "potato" not in f["name"].lower()]
        
        if valid_foods:
            food = random.choice(valid_foods)
            genome.append(food)
        else:
             # Fallback if category is empty
            genome.append(random.choice(catalog[list(catalog.keys())[0]]))
    return genome

def mutate(genome, catalog):
    """Randomly swaps out one ingredient in the meal plan."""
    new_genome = list(genome)
    mutate_idx = random.randint(0, len(new_genome) - 1)
    cat = MEAL_TEMPLATE[mutate_idx]["category"]
    
    if cat in catalog and catalog[cat]:
        new_genome[mutate_idx] = random.choice(catalog[cat])
        
    return new_genome

def main():
    print("Connecting to database and loading data into memory...")
    start_load = time.time()
    
    conn = psycopg2.connect(DATABASE_URL)
    catalog = get_food_catalog(conn)
    
    if not catalog:
        print("Error: No foods found in food_display_profile. Run the generator script first!")
        return

    matrix = get_nutrient_matrix(conn)
    
    # You can now easily pass Activity Level (pal) and Weight!
    # pal: 1.4 = Sedentary, 1.6 = Moderate, 1.8 = Active
    targets = get_user_targets(conn, catalog, age=30, sex='male', pal=1.6, weight=70.0)
    conn.close()
    
    print(f"Data loaded in {time.time() - start_load:.2f} seconds. Running High-Speed GA...")
    
    start_ga = time.time()
    POPULATION_SIZE = 100
    GENERATIONS = 50
    
    population = [generate_random_genome(catalog) for _ in range(POPULATION_SIZE)]
    
    best_genome = None
    best_score = -99999
    best_stats = None
    
    for gen in range(GENERATIONS):
        # 1. Evaluate fitness of all meal plans (in memory)
        scored_population = []
        for ind in population:
            score, stats = evaluate_fitness_in_memory(ind, targets, matrix)
            scored_population.append((score, ind, stats))
            
        # 2. Sort to find the best
        scored_population.sort(key=lambda x: x[0], reverse=True)
        
        if scored_population[0][0] > best_score:
            best_score = scored_population[0][0]
            best_genome = scored_population[0][1]
            best_stats = scored_population[0][2]
            
        # 3. Keep top 20% (Survival of the Fittest)
        survivors = [x[1] for x in scored_population[:int(POPULATION_SIZE * 0.2)]]
        
        # 4. Repopulate through Mutation
        new_population = list(survivors)
        while len(new_population) < POPULATION_SIZE:
            parent = random.choice(survivors)
            child = mutate(parent, catalog)
            new_population.append(child)
            
        population = new_population

    print(f"GA completed {POPULATION_SIZE * GENERATIONS} evaluations in {time.time() - start_ga:.3f} seconds!\n")
    print("=========================================")
    print(f"🏆 BEST DAILY MEAL PLAN FOUND (Score: {best_score})")
    print("=========================================")
    
    for idx, slot in enumerate(MEAL_TEMPLATE):
        food = best_genome[idx]
        print(f"[{slot['meal']}] {food['name']} ({food['serving_size_g']}g - {food['serving_label']})")
        
    print("\n📊 Nutritional Overview:")
    for row in best_stats:
        if row[0] == 'Energy':
            print(f"   Calories: {row[1]} kcal (Target: {row[2]} kcal)")
            
    print("\n⚠️  Nutrient Deficiencies (Under 50% Target):")
    deficiencies = 0
    for row in best_stats:
        if row[0] != 'Energy' and row[4] is not None and row[4] < 50:
             print(f"   - {row[0]}: {row[4]}%")
             deficiencies += 1
    
    if deficiencies == 0:
        print("   None! This meal plan is incredibly balanced.")

if __name__ == "__main__":
    main()
