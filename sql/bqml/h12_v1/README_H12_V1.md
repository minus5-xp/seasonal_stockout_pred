# BQML Pipeline: h=12 v1

Probabilistic 12-week-ahead OOS and demand forecast for the **oos_seasonal_fillrate** project.

---

## Target definition

> **Critical**: `y_true_12w` is the **cumulative sum** of 12 future weekly sales — NOT a point forecast at week t+12.

```
y_true_12w            = SUM(y_sales for weeks t+1 .. t+12)
stockout_event_12w    = MAX(stockout_event_week for weeks t+1 .. t+12)  -- binary
n_stockout_weeks_12w  = SUM(stockout_event_week for weeks t+1 .. t+12)  -- 0..12
lost_units_proxy_12w  = SUM(MAX(expected_baseline - y_sales, 0) where OOS, for t+1..t+12)
```

This matches `target_12w_ahead = sum(lead(1:12))` in `30_Dense_Panel_12W_Unified_Best.R`.

---

## Temporal alignment

| Set     | Decision week range        | Maps to R          |
|---------|----------------------------|--------------------|
| TRAIN   | 2021-01-04 → 2023-06-30   | Train years 2021–2023 |
| CALIB   | 2023-07-01 → 2023-12-31   | Train years 2021–2023 |
| VAL     | 2024-01-01 → 2024-12-29   | Test year 2024     |

VAL rows are included only when all 12 future weeks are observable (`n_future_obs = 12`). This is equivalent to `drop_na(target_12w_ahead)` in R.

---

## Pipeline steps

| Step  | File                                         | Description                             |
|-------|----------------------------------------------|-----------------------------------------|
| 00    | `00_config_h12_v1.sql`                       | Config documentation (not executed)     |
| 01    | `01_build_weekly_features_h12_v1.sql`        | Dense spine + features + 12W labels     |
| 02    | `02_train_models_h12_v1.sql`                 | OOS classifier + Platt + demand regressor |
| 02b   | `02b_score_models_h12_v1.sql`                | Score all splits                        |
| 03    | `03_residuals_quantile_lookup_h12_v1.sql`    | Mondrian conformal residuals + lookup   |
| 04    | `04_conformal_calibration_h12_v1.sql`        | Two-stage correction factors            |
| 05    | `05_forecast_h12_v1.sql`                     | Forecast (monotone, capped, non-negative) |
| 06    | `06_policy_sweep_alerts_h12_v1.sql`          | Policy sweep (A/B/C/D/E) + alerts       |
| 07    | `07_coverage_gate_h12_v1.sql`                | Coverage evaluation + Gate B3           |
| 08    | `08_alerts_eval_leakage_h12_v1.sql`          | Eval + leakage checks + comparison scope |
| 09    | `09_run_summary_h12_v1.sql`                  | Run summary + deployment decision       |

---

## Execution

### Dry run (no BigQuery access required)
```bash
python sql/bqml/h12_v1/run_h12_v1_pipeline.py --dry-run
```

### Full run (bash)
```bash
BASE_SALES_TABLE=thequantitativeledger.dataset_cruzber.fact_lineas_albaran \
python sql/bqml/h12_v1/run_h12_v1_pipeline.py
```

### Full run (PowerShell)
```powershell
$env:BASE_SALES_TABLE = "thequantitativeledger.dataset_cruzber.fact_lineas_albaran"
python sql/bqml/h12_v1/run_h12_v1_pipeline.py
```

### Skip training (reuse existing models)
```bash
BASE_SALES_TABLE=... python sql/bqml/h12_v1/run_h12_v1_pipeline.py --skip-training
```

### Start from step 03 (features already built)
```bash
BASE_SALES_TABLE=... python sql/bqml/h12_v1/run_h12_v1_pipeline.py --start-step 03
```

---

## Output tables

All tables live in `cruzber_models_eu` with suffix `_h12_v1`.

| Table | Description |
|-------|-------------|
| `sales_weekly_base_h12_v1` | Dense SKU × week spine |
| `weekly_features_h12_v1` | Features + 12W labels (all SKUs, all weeks) |
| `train_calib_split_h12_v1` | Filtered to complete labels + split assignment |
| `enriched_base_h12_v1` | Training spine with p_oos_h12 as exogenous |
| `m_oos_h12_v1` | BQML OOS classifier |
| `m_platt_oos_h12_v1` | Platt calibration model |
| `m_demand_h12_v1` | BQML demand regressor |
| `score_oos_h12_calibrated_v1` | Calibrated OOS probabilities |
| `base_scores_h12_v1` | All-splits scores (p_oos_h12, yhat_p50_12w, scale) |
| `residuals_h12_v1` | Conformal residuals on CALIB |
| `quantile_lookup_h12_v1` | Mondrian q75/q80/q85/q90/q95/q99 per segment |
| `quantile_factors_h12_v1` | Two-stage correction factors |
| `forecast_h12_v1` | Full forecast with monotone quantiles |
| `alerts_top100_h12_v1` | Top-100 weekly alerts (best policy) |
| `eval_coverage_summary_h12_v1_conditional` | Coverage stats (active demand) |
| `gate_b3_verdict_h12_v1` | Gate B3 PASS/FAIL |
| `eval_alerts_top100_h12_pooled_v1` | precision/recall/lift@100 |
| `eval_demand_h12_v1` | MAE/WMAPE/bias on 12W demand |
| `leakage_check_h12_v1` | Anti-leakage assertions |
| `comparison_scope_h12_vs_R_v11` | BQML vs R script alignment |
| `run_summary_h12_v1` | Single audit row + deployment_decision |

---

## Models

### OOS classifier: `m_oos_h12_v1`
- Type: `BOOSTED_TREE_CLASSIFIER`
- Label: `stockout_event_12w` (binary — any OOS in 12-week horizon)
- `AUTO_CLASS_WEIGHTS=TRUE`, `DATA_SPLIT_METHOD=CUSTOM`

### Demand regressor: `m_demand_h12_v1`
- Type: `BOOSTED_TREE_REGRESSOR`
- Label: `y_true_12w` (cumulative 12-week demand)
- Uses `p_oos_h12` as exogenous feature

---

## Key design differences from H4

| Aspect | H4 v4 | H12 v1 |
|--------|--------|--------|
| Target | `y_sales` at week t+4 | `SUM(y_sales, t+1..t+12)` |
| OOS label | `stockout_event` at t+4 | `MAX(stockout_event_week, t+1..t+12)` |
| Scale | `GREATEST(1, roll13_std, √(roll13_mean+1))` | `GREATEST(1, roll13_std·√12, √(roll13_mean·12+1))` |
| Active demand threshold | 5 units | 10 units |
| FACTOR_CLIP_HI | 1.50 | 2.00 |
| Quantiles | q90, q95, q99 | q75, q80, q85, q90, q95, q99 |
| Policies | A, B, C (3 gamma) | A, B, C (3 gamma), D, E |
| Builds from | pre-existing `weekly_features_h4` | `{BASE_SALES_TABLE}` directly |

---

## Anti-leakage guarantees

1. All features use data up to and including `decision_week` only.
2. Labels aggregate future weeks `decision_week+1` through `decision_week+12`.
3. Rows with `n_future_obs < 12` are excluded before any model sees the data.
4. CALIB split is used for Platt calibration and conformal quantile derivation only.
5. VAL_TUNE (first 2/3 of VAL) used for correction factor selection; VAL_TEST (last 1/3) for paper-clean evaluation.
6. `leakage_check_h12_v1` asserts 0 violations at runtime.

---

## H4 compatibility

This pipeline does **not** modify, read from, or depend on any H4 table.  
H12 tables use the `_h12_v1` suffix throughout.
