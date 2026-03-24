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

The Linus Pauling Institute Micronutrient Information Center and NIH ODS Fact Sheets both document **which interactions occur at dietary vs. supplemental levels**, so you can filter accordingly. The Deanna Minich chart already focuses on clinically-relevant interactions.

For this project, the clean split is:
- **EFSA DRVs** for the intake/reference values shown in the project
- **LPI / NIH ODS / literature** for the interaction evidence and mechanism descriptions

That works because interaction evidence is a biology question, while DRVs are a policy/reference-framework question. The interaction itself does not depend on which regional intake framework you use. What matters is that any thresholds or intake comparisons in the project should be expressed against **EFSA** values.

**Verdict: ✅ Valid — just curate your edge list to dietary-dose interactions only. You have plenty.**

---

## Viz 2: "The Perfect Plate" — Is there enough data?

**Short answer: Yes, this has the *best* data availability of all three.**

### Data you need and where it comes from

| What you need | Source | Availability |
|---|---|---|
| Nutritional profile per food (all macros + micros) | **CIQUAL** food composition data | ✅ Strong availability and aligned with the European framing of the project |
| Daily reference values (the "target shape") | **EFSA DRVs** | ✅ Available and now already converted into project JSON from the EU workbook |
| Curated food list (~80-100 items) | You select from your chosen food database | ✅ Trivially done — just pick common foods and pre-fetch their nutrient profiles |
| Food group categorization | Usually included in the food database or can be added manually | ✅ Straightforward |

### Why this is the easiest one data-wise

- **CIQUAL** is the key food composition source here. It fits the European framing of the project and gives you the nutrient composition data needed for food-level comparisons.
- You don't need any country-level or population data — it's purely **composition data per food item**.
- The reference values should now come from your **EFSA-derived normalized dataset**.
- If you later need broader food coverage, you can add another European-compatible food composition source, but CIQUAL is enough for the current scope.

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
3. **Food composition data** (from Viz 2; CIQUAL) → "What these foods contain" ✅
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
| **1 — Nutrient Cosmos** | ✅ Valid | Curate edges to food-dose interactions only and express any thresholds against EFSA values |
| **2 — Perfect Plate** | ✅ Excellent | Use EFSA for reference values and CIQUAL for food nutrient profiles |
| **3 — What the World Is Missing** | ⚠️ Doable with pivot | Use production + deficiency data (not consumption). Drop Vitamin D. Focus on 4 nutrients. |
