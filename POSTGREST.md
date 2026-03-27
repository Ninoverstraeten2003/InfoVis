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
- RPC functions for dropdown/filter option lists used by the client
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

### Dropdown / filter option endpoints

- Viz 1 nutrient options (`p_selected_nutrient`):
  - `GET /rpc/viz1_option_nutrients`

- Viz 2 nutrient options (`p_nutrient`, `p_nutrients`) with optional scope:
  - `GET /rpc/viz2_option_nutrients`
  - `GET /rpc/viz2_option_nutrients?p_drv_sex=Female&p_ref_type=PRI`
  - `GET /rpc/viz2_option_nutrients?p_curated_only=true`

- Viz 2 food options (`p_food_name`) with optional scope:
  - `GET /rpc/viz2_option_foods`
  - `GET /rpc/viz2_option_foods?p_nutrient=Iron&p_drv_sex=Female&p_ref_type=PRI`
  - `GET /rpc/viz2_option_foods?p_curated_only=true`

- Viz 2 DRV sex options (`p_drv_sex`, `p_drv_sexes`):
  - `GET /rpc/viz2_option_drv_sexes`
  - `GET /rpc/viz2_option_drv_sexes?p_nutrient=Iron`

- Viz 2 reference type options (`p_ref_type`, `p_ref_types`):
  - `GET /rpc/viz2_option_ref_types`
  - `GET /rpc/viz2_option_ref_types?p_nutrient=Iron&p_drv_sex=Female`

- Relationship type options (`p_relationship_type`):
  - `GET /rpc/viz2_option_relationship_types`

- Viz 2 source nutrient options (`p_source_nutrient`) for support clusters:
  - `GET /rpc/viz2_option_source_nutrients`
  - `GET /rpc/viz2_option_source_nutrients?p_relationship_type=synergistic`

- Viz 2 target nutrient options (`p_target_nutrient`) for conflict-aware ranking:
  - `GET /rpc/viz2_option_target_nutrients`
  - `GET /rpc/viz2_option_target_nutrients?p_requires_antagonists=false`

## Notes

- `postgrest.conf` uses `authenticator/change-me`; change this password for anything beyond local dev.
- Viz 3 endpoints are intentionally not added yet because country-level tables are not loaded.
