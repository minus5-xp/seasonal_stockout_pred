# BQML Pipeline: h=12 v2

Recalibration of h=12 v1 — improved conformal coverage without retraining.

---

## What changed vs v1

| Aspect | h12_v1 | h12_v2 |
|---|---|---|
| Models | Trained | **Reused (no retraining)** |
| VAL partition | TUNE=2/3, TEST=1/3 | **TUNE=W1-20, GATE=W21-27, BLIND=W28-40** |
| Scale | `roll13_std × √12` | **+ `segment_vif` + `scale_multiplier`** |
| Quantile offset | Fixed OFFSET(90) | **Grid: OFFSET(90..93)** |
| Correction factor clip | 3.00 (fixed) | **Grid: {3.0, 3.5, 4.0}** |
| Gate evaluation | VAL_TEST | **VAL_GATE (W21-27 only)** |
| Provincial forecast | None | **Dirichlet smoothing (52 provinces)** |
| Blind forecast | None | **W28-W40 2024 (if DEPLOY)** |
| CSV download | None | **`outputs/h12_v2/`** |

---

## Calibration grid

216 configurations evaluated on VAL_TUNE (W1-W20 of 2024):

```
scale_multiplier  ∈ {1.00, 1.03, 1.05, 1.08, 1.10, 1.15}
q90_offset        ∈ {90, 91, 92, 93}
q95_offset        ∈ {95, 96, 97}
factor_clip_hi    ∈ {3.0, 3.5, 4.0}
```

**Scale formula**:
```sql
scale_h12_v2 = scale_h12_v1
             * LEAST(1.50, GREATEST(1.00, segment_vif))
             * scale_multiplier
```

**Calibration loss** (minimised over VAL_TUNE):
```
10×|viol_p90 − 0.10| + 20×max(viol_p90−0.12, 0) + 5×max(0.08−viol_p90, 0)
+ 3×max(q90/p50_median−3, 0) + 2×max(cap_rate−0.05, 0) + 1×|viol_p80−0.20|
```

---

## Gates (evaluated on VAL_GATE = W21-27)

| Gate | Criterion | Required |
|---|---|---|
| B1 | leakage_status = PASS | ✅ DEPLOY required |
| B2 | scope_vs_R = OK | ✅ DEPLOY required |
| B3 | viol_rate_p90 ∈ [0.08, 0.12] | ✅ DEPLOY required |
| B3c | monotonicity_violations = 0 | ✅ DEPLOY required |
| B4 | lift@100 > 1.5 | ✅ DEPLOY required |
| B3b | viol_rate_p95 ∈ [0.03, 0.08] | WARN |
| B3d | q90_cap_rate ≤ 0.05 | WARN |
| B3e | median(q90/p50) ≤ 3.0 | WARN |
| B5 | brier_cal ≤ brier_raw | WARN |
| B6 | WMAPE ≤ v1 × 1.10 | WARN |
| B7 | over_under_ratio ≤ 3.0 | WARN |

---

## Execution

### Dry run
```cmd
python sql/bqml/h12_v2/run_h12_v2_pipeline.py --dry-run
```

### Phase 1 only (diagnostics)
```cmd
set BASE_SALES_TABLE=thequantitativeledger.dataset_cruzber.fact_lineas_albaran
set BQ_SOURCE_LOCATION=US
python sql/bqml/h12_v2/run_h12_v2_pipeline.py --stop-after-phase 1
```

### Recalibration + gates (no download)
```cmd
python sql/bqml/h12_v2/run_h12_v2_pipeline.py --start-phase 2 --stop-after-phase 3 --no-download
```

### Full run
```cmd
set BASE_SALES_TABLE=thequantitativeledger.dataset_cruzber.fact_lineas_albaran
set BQ_SOURCE_LOCATION=US
python sql/bqml/h12_v2/run_h12_v2_pipeline.py
```

### Download CSV only
```cmd
python sql/bqml/h12_v2/07_local_csv_download_h12_v2.py --output-dir outputs/h12_v2
```

---

## CSV outputs (`outputs/h12_v2/`)

| File | Content |
|---|---|
| `forecast_national_h12_v2.csv` | National forecast all splits |
| `forecast_provincial_dirichlet_h12_v2.csv` | 52-province disaggregation |
| `provincial_allocation_base_h12_v2.csv` | Dirichlet weights |
| `alerts_top100_h12_v2.csv` | Top-100 alerts |
| `forecast_scorecard_h12_v2.csv` | All gate metrics |
| `gate_verdict_h12_v2.csv` | Deployment decision |
| `dirichlet_reconciliation_check_h12_v2.csv` | Reconciliation errors |
| **If DEPLOY:** | |
| `blind_forecast_national_w28_w40_h12_v2.csv` | Blind W28-W40 national |
| `blind_forecast_provincial_w28_w40_h12_v2.csv` | Blind W28-W40 provincial |
| `blind_alerts_top100_w28_w40_h12_v2.csv` | Blind top-100 alerts |
| `blind_leakage_check_h12_v2.csv` | Blind leakage assertion |
| **If HOLD:** | |
| `blind_forecast_NOT_GENERATED_HOLD.csv` | HOLD status |

---

## Provincial allocation

- Source: `dim_provincia` (filter `codigonacion = 108` → 52 provinces)
- Join key: `codigo_provincia` on `fact_lineas_albaran` (adjust if different)
- 52-week lookback per decision_week
- Prior hierarchy: sku_prov → family_prov → global_prov → uniform
- Dirichlet alpha: 10 (sku), 25 (family), 50 (global)
- Reconciliation assert: `|SUM(prov) − national| ≤ 0.001`

---

## Blind forecast guarantees

- `y_true_12w = NULL` always
- `stockout_event_12w = NULL` always
- `labels_included = FALSE`
- `iso_week BETWEEN 28 AND 40, iso_year = 2024`
- Generated **only** if `gate_verdict_h12_v2.deployment_decision = 'DEPLOY'`

---

## Limitations

1. No model retraining — improvements are calibration-only. Lift and WMAPE are bounded by v1 model quality.
2. Provincial join key (`codigo_provincia`) may need adjustment to match your fact table schema.
3. `segment_vif` is estimated from CALIB (H2 2023) — if 2024 volatility differs structurally, VIF may not fully compensate.
4. Grid search is over VAL_TUNE (W1-W20). If seasonal patterns in W21-W27 differ, the selected config may not generalise perfectly.
5. h12_v1 tables are read-only from v2. Do not drop or modify them while v2 is running.
