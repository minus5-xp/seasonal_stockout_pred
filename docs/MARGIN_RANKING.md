# MARGIN RANKING — Operationalising €-at-Risk in the CRUZBER h=4 Alert System

## Overview

The margin-ranking extension adds a business-value layer on top of the existing
coverage-optimised alert pipeline (Option B, h=4). Instead of prioritising SKUs
purely by probability of stockout (OOS), it ranks by **expected gross margin at
risk** — the monetary cost of not replenishing the SKU in time.

---

## Score Definition

```
score_margin  =  p_oos_h4  ×  q90_h4  ×  margen_unit
```

| Component | Source | Meaning |
|-----------|--------|---------|
| `p_oos_h4` | `forecast_h4_v4.p_oos_h4` | Predicted probability of stockout in the target week (decision_week + 4) |
| `q90_h4` | `forecast_h4_v4.q90_h4` | 90th-percentile demand forecast (units) — proxy for replenishment qty needed |
| `margen_unit` | `kpi_por_articulo_snapshot.margen_unit` | Gross margin per unit sold (€), clamped ≥ 0 |

**Interpretation:** `score_margin` is the expected gross margin lost if this SKU
goes out-of-stock in the target week, given the model's demand forecast.

Stored as column `eur_at_risk` in `forecast_h4_v4_kpi` and `alerts_top100_h4_margin`.

---

## Tables Created

All tables in `thequantitativeledger.cruzber_models_eu`:

| Table | Created by | Description |
|-------|-----------|-------------|
| `kpi_por_articulo_snapshot` | `00_create_kpi_snapshot.sql` | Materialised copy of `v_kpi_por_articulo` with unit economics pre-computed |
| `forecast_h4_v4_kpi` | `10_enrich_forecast_with_kpi.sql` | `forecast_h4_v4` enriched with KPI fields + `eur_at_risk` |
| `alerts_top100_h4_margin` | `20_alerts_top100_h4_margin.sql` | Top-100 weekly alerts ranked by `eur_at_risk` |
| `eval_alerts_top100_h4_margin_pooled` | `30_eval_alerts_top100_h4_margin_pooled.sql` | Evaluation: precision/recall/lift + business aggregates |

All tables are **idempotent** (`CREATE OR REPLACE`) and do not modify any existing tables.

---

## Negative Margin Policy

`margen_articulo` in the source view can be negative for SKUs with active
returns (devoluciones), promotional items sold below cost, or data errors.

**Default policy:** `margen_unit = GREATEST(margen_unit_raw, 0)` — clamped at zero.

- `margen_unit_raw` is preserved in the snapshot for full auditability.
- SKUs with `margen_unit_raw < 0` appear in the snapshot with `margen_unit = 0`
  and will have `eur_at_risk = 0`. They rank at the bottom of the margin
  ordering but are **not excluded** — the coverage signal (`p_oos_h4`, `q90_h4`)
  still governs their position in tiebreaker.

To change the policy (e.g., exclude negative-margin SKUs entirely), modify
`GREATEST(..., 0)` in `00_create_kpi_snapshot.sql` and add a `WHERE margen_unit > 0`
filter in `20_alerts_top100_h4_margin.sql`.

---

## Obsolete / Inactive SKU Filter

The snapshot computes a `sku_active` flag (1 = active, 0 = inactive) based on:

```sql
CASE
  WHEN estado_articulo NOT IN (10, 100)                   THEN 0  -- non-active status codes
  WHEN UPPER(COALESCE(obsoleto, 'No')) IN ('SÍ','SI','YES','Y','1') THEN 0
  WHEN ultima_venta < DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY)   THEN 0
  ELSE 1
END AS sku_active
```

The margin-ranked alerts (`step 20`) sort active SKUs first:

```sql
ORDER BY
  CASE WHEN sku_active = 1 THEN 0 ELSE 1 END ASC,  -- active first
  COALESCE(eur_at_risk, 0) DESC,
  ...
```

Inactive SKUs are **not hard-excluded** from the table — they are visible in
the output but rank below all active SKUs.  Adjust `estado_articulo` codes to
match your actual catalogue coding if needed.

---

## Limitations

### 1. No stock position
`score_margin` does not account for current stock levels. A SKU may have
`p_oos_h4 = 0.9` and high margin but already be fully stocked — it would appear
high in the ranking despite no action being needed.

**Recommendation:** Join `alerts_top100_h4_margin` with your ERP stock projection
(stock-on-hand + pending orders) to filter out already-covered lines before
sending to the purchasing team.

### 2. Historical margin, not forward-looking
`margen_unit` is computed from the full sales history in `v_kpi_por_articulo`
(lifetime `margen_articulo / unidades_articulo`). It does not reflect
seasonally-adjusted margins, promotional pricing, or pending price changes.

### 3. Unit margin ≠ batch margin
`q90_h4` is a **unit** demand forecast. The `eur_at_risk` score assumes a
constant per-unit margin across the entire replenishment quantity. Bulk discount
effects are not modelled.

### 4. Recall vs. margin trade-off
The standard `alerts_top100_h4_v4` (policy_B) is calibrated to maximise coverage
(recall of stockouts). The margin ranking may select fewer true stockouts if
high-margin SKUs are not the most likely to stock out.  Both alert lists are
maintained in parallel — use the appropriate one depending on the objective:
- `alerts_top100_h4_v4` → maximise fill-rate coverage
- `alerts_top100_h4_margin` → maximise gross margin protected

---

## Running Locally

```bash
# With KPI_DATASET known:
KPI_DATASET=dataset_cruzber ENABLE_MARGIN_RANKING=1 \
  python sql/bqml/h4_v4/run_h4_v4_pipeline.py --skip-training

# With auto-discovery (requires INFORMATION_SCHEMA.VIEWS access):
ENABLE_MARGIN_RANKING=1 \
  python sql/bqml/h4_v4/run_h4_v4_pipeline.py --skip-training

# Dry-run (SQL only, no BQ execution):
python sql/bqml/h4_v4/run_h4_v4_pipeline.py \
  --skip-training --enable-margin-ranking --dry-run
```

## Running in Cloud Run Jobs

```bash
gcloud run jobs execute cruzber-h4-pipeline \
  --region europe-west1 \
  --update-env-vars \
    ENABLE_MARGIN_RANKING=1,\
    KPI_DATASET=dataset_cruzber
```

Or in the Cloud Run Job definition (`cloudbuild.yaml` / job spec):

```yaml
env:
  - name: ENABLE_MARGIN_RANKING
    value: "1"
  - name: KPI_DATASET
    value: "dataset_cruzber"   # or leave unset for auto-discovery
```

---

## Top-20 Alerts by €-at-Risk (example query)

```sql
-- Top 20 SKUs by expected margin at risk, in the most recent decision week
SELECT
  decision_week,
  target_week,
  rank_in_week,
  sku_id,
  descripcion_articulo,
  ROUND(p_oos_h4,       4)  AS p_oos,
  ROUND(q90_h4,         2)  AS q90_units,
  ROUND(margen_unit,    4)  AS margin_per_unit_eur,
  ROUND(eur_at_risk,    2)  AS eur_at_risk,
  ROUND(margen_pct,     4)  AS margin_pct,
  tipo_abc,
  codigo_familia,
  sku_active,
  ultima_venta
FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_margin`
WHERE decision_week = (
  SELECT MAX(decision_week)
  FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_margin`
)
ORDER BY eur_at_risk DESC
LIMIT 20;
```
