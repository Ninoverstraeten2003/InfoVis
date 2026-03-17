# NutriVerse — Feasibility Analysis of the 3 Visualizations

Your three questions, addressed one by one:

---

## Viz 1: "The Nutrient Cosmos" — Are antagonisms/synergies valid at normal meal doses?

**Short answer: Yes, but you need to be precise about which interactions you include.**

Your concern is valid — some nutrient interactions (e.g. zinc vs copper toxicity) only kick in at **supplement-level mega-doses**, not from food. But many well-documented interactions absolutely happen at **normal dietary levels**:

### ✅ Interactions that ARE significant at food-level doses

| Interaction | Mechanism | Everyday example |
|---|---|---|
| **Vitamin C → Iron (synergy)** | Ascorbic acid reduces Fe³⁺ to Fe²⁺, dramatically improving non-heme iron absorption (2-6x) | Squeezing lemon on spinach |
| **Calcium → Iron (antagonism)** | Ca competes with Fe at the DMT1 transporter in the gut | Drinking milk with a steak |
| **Vitamin D → Calcium (synergy)** | Vit D upregulates calcium-binding proteins in the intestine | Fortified cereal + sunny morning |
| **Oxalates → Calcium (antagonism)** | Oxalic acid binds Ca, making it unabsorbable | Spinach (high oxalate) providing almost zero usable calcium |
| **Phytates → Zinc/Iron (antagonism)** | Phytic acid chelates minerals in the GI tract | Whole grain bread reducing zinc/iron uptake |
| **Vitamin C → Vitamin E (synergy)** | Vit C regenerates oxidized Vitamin E | Eating fruit with nuts |
| **Fat → Vitamins A/D/E/K (synergy)** | Fat-soluble vitamins need dietary fat for absorption | Eating carrots with olive oil vs. raw |
| **Caffeine → Calcium (antagonism)** | Caffeine increases urinary calcium excretion | Coffee with breakfast |
| **Vitamin K → Calcium (synergy)** | K2 activates osteocalcin, directing Ca to bones | Natto or cheese |

### ⚠️ Interactions that are mostly supplement-dose-only

| Interaction | Why it's less relevant |
|---|---|
| Zinc → Copper (antagonism) | Only at Zn supplementation >50mg/day, impossible from food alone |
| Vitamin A toxicity interactions | Only relevant at retinol supplement doses, not dietary β-carotene |
| Iron → Zinc (antagonism) | Mostly documented at supplemental iron doses >25mg |

### 💡 How to make it work

> [!TIP]
> **The fix is simple**: scope the visualization to explicitly say **"interactions at dietary/food-level doses"** and only include edges that are documented at food-relevant quantities. This is still ~20-30 well-documented interactions — more than enough for a rich network graph.

The Linus Pauling Institute and NIH ODS Fact Sheets both document **which interactions occur at dietary vs. supplemental levels**, so you can filter accordingly. The Deanna Minich chart already focuses on clinically-relevant interactions.

**Verdict: ✅ Valid — just curate your edge list to dietary-dose interactions only. You have plenty.**

---

## Viz 2: "The Perfect Plate" — Is there enough data?

**Short answer: Yes, this has the *best* data availability of all three.**

### Data you need and where it comes from

| What you need | Source | Availability |
|---|---|---|
| Nutritional profile per food (all macros + micros) | **USDA FoodData Central** | ✅ Free API, **380,000+ foods**, ~150 nutrients per item. Gold-standard data. |
| Daily Recommended Intakes (the "target shape") | **NCBI DRI Tables** | ✅ Publicly available, static tables. Already linked in your doc. |
| Curated food list (~80-100 items) | You select from USDA | ✅ Trivially done — just pick 80-100 common foods and pre-fetch their USDA profiles |
| Food group categorization | USDA already categorizes foods | ✅ Built into the USDA data |

### Why this is the easiest one data-wise

- **USDA FoodData Central** is arguably the most complete, freely-accessible nutrition database in the world. Each food entry has detailed breakdowns for: energy, protein, carbs, fat, fiber, all vitamins (A, B1-12, C, D, E, K), all minerals (Ca, Fe, Zn, Mg, K, Na, P, etc.), amino acids, fatty acids, and more.
- You don't need any country-level or population data — it's purely **composition data per food item**.
- The DRI tables are static reference data you just hardcode once.
- The [OpenNutrition](https://www.opennutrition.app/) API aggregates USDA + Canadian + Danish + Australian databases for even better coverage.

**Verdict: ✅ Plenty of data — this is the most data-rich visualization with zero data scarcity concerns.**

---

## Viz 3: "What the World Is Missing" — Is there per-country deficiency & consumption data?

**Short answer: Partial — deficiency data is good, but per-country *consumption* data is limited and you'll need to pivot the concept slightly.**

### What's available ✅

| Data | Source | Coverage |
|---|---|---|
| **Anemia/iron deficiency prevalence** by country | WHO GHO, Our World in Data | ✅ ~190 countries, time series |
| **Vitamin A deficiency** in children + pregnant women | WHO GHO, Our World in Data | ✅ ~130 countries |
| **Zinc deficiency** prevalence | Our World in Data (Wessells & Brown estimates) | ✅ ~180 countries |
| **Iodine deficiency** (iodized salt coverage) | UNICEF, Our World in Data | ✅ ~130 countries |
| **Hidden Hunger Index** (composite score) | Our World in Data | ✅ ~140 countries, pre-school children |
| **Food production** by country (what they grow) | FAOSTAT Food Balance Sheets | ✅ 245 countries, crops + livestock |
| **Food supply** (kcal/capita/day by food group) | FAOSTAT | ✅ 245 countries |
| **Country nutrition profiles** | Global Nutrition Report | ✅ ~190 countries with dietary intake estimates |

### What's limited / missing ⚠️

| Data | Issue |
|---|---|
| **Per-country consumption of specific nutrients** (e.g. "average mg of zinc consumed per day in Nigeria") | ❌ Very few countries run national dietary surveys. The **Global Dietary Database** (Tufts) has modeled estimates for adults 25+ for some dietary factors, but coverage is spotty and these are modeled, not measured. |
| **Vitamin D deficiency** by country | ⚠️ Limited — no systematic global dataset exists. Studies are country-by-country, not standardized. |
| **Per-country food consumption** at the food-item level | ⚠️ FAOSTAT has "food supply" (what's available) not "food consumption" (what people actually eat). These are different — supply includes waste. |

### 💡 How to make it work

> [!IMPORTANT]
> Your core question — *"Where are people deficient and do they grow foods that could solve it?"* — is actually **very doable** with what's available. Here's a pivot:

Instead of needing per-country consumption data (which is scarce), your "Paradox Panel" can use:

1. **Deficiency prevalence** (well-covered) → colors the choropleth map ✅
2. **Food production/supply data** from FAOSTAT → "What this country grows" ✅
3. **USDA nutrient data** (from Viz 2) → "What these foods contain" ✅
4. **The gap** = comparing production of nutrient-rich crops vs. deficiency rate → this is the "paradox" ✅

You don't actually *need* consumption data to tell the story. The paradox is: *"This country grows tons of iron-rich crops, yet has 40% anemia prevalence"* — which you can derive from **production + deficiency** data alone.

### Suggested scope refinement

Focus on the **4-5 nutrients with best global data**:
- 🩸 **Iron** (anemia) — best coverage
- 👁️ **Vitamin A** — strong coverage  
- 🧬 **Zinc** — good coverage
- 🧂 **Iodine** — good coverage (via iodized salt data)

Drop **Vitamin D** from the dropdown — the global data is too spotty for a proper choropleth.

**Verdict: ⚠️ Feasible with a slight pivot — use production vs. deficiency (not consumption vs. deficiency). Drop Vitamin D. Focus on Iron, Vitamin A, Zinc, Iodine.**

---

## Summary

| Viz | Feasibility | Action needed |
|---|---|---|
| **1 — Nutrient Cosmos** | ✅ Valid | Curate edges to food-dose interactions only (~20-30 still available) |
| **2 — Perfect Plate** | ✅ Excellent | USDA has everything you need, no concerns |
| **3 — What the World Is Missing** | ⚠️ Doable with pivot | Use production + deficiency data (not consumption). Drop Vitamin D. Focus on 4 nutrients. |
