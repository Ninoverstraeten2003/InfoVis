# PostgREST Setup (NutriVerse)

This project can expose JSON endpoints directly from Postgres views/functions through PostgREST.

## 1) Apply DB API objects and grants

```bash
psql nutriverse -f db/postgrest_api.sql
psql nutriverse -f db/postgrest_grants.sql
```

This creates:
- `api` schema
- read-only API roles (`web_anon`, `authenticator`)
- RPC functions for Viz 1 and Viz 2 query shapes
- grants for `web_anon` on all current/future tables in `public`
- grants for `web_anon` on all current/future functions in `api`

If you see `permission denied for table ...` errors after schema/view changes,
re-run:

```bash
psql nutriverse -f db/postgrest_grants.sql
```

## 2) Start PostgREST

Install PostgREST locally, then run:

```bash
postgrest postgrest.conf
```

Default URL:

```text
http://127.0.0.1:3000
```

## 3) Example endpoints

### Viz 1 (Nutrient Cosmos)

- Graph edges:
  - `GET /rpc/viz1_graph_edges`
- Degree summary:
  - `GET /rpc/viz1_degree_summary`
- Food anchors for a nutrient:
  - `GET /rpc/viz1_food_anchors?p_selected_nutrient=Iron&p_top_n=20`

### Viz 2 (Perfect Plate)

- Top foods:
  - `GET /rpc/viz2_top_foods?p_nutrient=Iron&p_drv_sex=Female&p_ref_type=PRI&p_limit=20`
- Food nutrient panel:
  - `POST /rpc/viz2_food_panel`
  - body: `{"p_food_name":"Spinach, raw","p_nutrients":["Iron","Calcium","Magnesium","Vitamin A","Vitamin C","Folate"],"p_drv_sex":"Female","p_ref_type":"PRI"}`
  - behavior: when `p_drv_sex` is `Male`/`Female`, returns both that sex and `Both genders` rows (up to two rows per nutrient); within each sex bucket, when `p_ref_type='PRI'` it falls back to `AI` if no `PRI` row exists
- Support cluster:
  - `GET /rpc/viz2_support_cluster?p_source_nutrient=Vitamin%20D&p_relationship_type=synergistic`
- Conflict-aware:
  - `GET /rpc/viz2_conflict_aware?p_target_nutrient=Iron&p_drv_sex=Female&p_ref_type=PRI&p_penalty_weight=0.35&p_limit=20`
  - behavior: target-first tradeoff ranking (`target_pct_drv_per_100g_capped - penalty_weight * antagonist_pct_drv_penalty`) where the antagonist penalty is the sum of capped %DRV contributions from nutrients antagonistic to the target
  - compatibility: legacy `p_source_nutrient` is accepted but ignored
- Curated ranking:
  - `GET /rpc/viz2_curated_rank?p_nutrient=Iron&p_drv_sex=Female&p_ref_type=PRI&p_limit=20`

## Notes

- `postgrest.conf` uses `authenticator/change-me`; change this password for anything beyond local dev.
- Viz 3 endpoints are intentionally not added yet because country-level tables are not loaded.
