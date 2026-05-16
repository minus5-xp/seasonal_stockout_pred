# h12_v4_quantile_regression_strict

## Overview

**h12_v4_quantile_regression_strict** implements a **quantile regression post-processing layer** to solve the persistent quantile collapse problem (viol_p80 = viol_p90 = viol_p95 = 0.000) observed in v3_strict and v3_2.

Instead of relying on BQML's raw quantiles or grid-based offset calibration, v4 **learns new quantiles from scratch** using `sklearn.ensemble.GradientBoostingRegressor` with `loss='quantile'`.

## Problem Statement

**v3_strict** and **v3_2** suffered from:

1. **Collapsed quantiles**: viol_p90 = 0.000 (should be ~0.10)
   - BQML raw quantiles likely already collapsed (q80 ≈ q90 ≈ q95 ≈ p50)
   - Grid-based calibration with offsets cannot fix upstream collapse
   
2. **REST WMAPE explosion**: WMAPE(y>0) = 4.761 for REST segment
   - OFF_SEASON gate reduced bias but not WMAPE
   - Zero over-forecast rate remains high (87.2% in REST)

3. **Trade-offs**: v3_2 gate helped REST bias but degraded HIGH_SEASON slightly

## Solution Architecture

v4 implements **three candidate quantile regression approaches**, trains them on DEV_TUNE, selects the winner on DEV_SELECT, and applies frozen config to LOCKED_TEST.

### Candidate Approaches

#### A) QR_DIRECT
- **Method**: Learn quantiles directly from y_true_12w
- **Models**: 4 separate GradientBoostingRegressor (q50, q80, q90, q95)
- **Use case**: When base BQML predictions are unreliable

#### B) QR_RESIDUAL  
- **Method**: Learn residual from yhat_p50_gated, add back
- **Formula**: q_final = yhat_p50_gated + residual_quantile
- **Use case**: When base predictions are good, just need better uncertainty

#### C) QR_ZERO_AWARE
- **Method**: Hurdle model with separate zero/positive treatment
- **Formula**: q_final = (1 - p_oos_calibrated) * q_positive
- **Use case**: When zero-inflation is main problem

### Feature Matrix

Combines features from multiple sources:

**Base BQML**: yhat_p50, q80/90/95 (raw), p_oos_raw/calibrated, scale, stockout_event

**Seasonal (v3_2)**: sku_season_state, hist_avg/p90, seasonal_index, transition_slope

**v3_2 gated**: yhat_p50_gated (post OFF_SEASON cap), gate_applied, gate_reduction

**Derived**: log transformations, zero_prob_signal, demand_cv, is_transition, is_off_peak, seasonal_strength

### Model Selection

Uses **composite loss function** on DEV_SELECT:

```
loss = 2.0 * |viol_p80 - 0.20|
     + 3.0 * |viol_p90 - 0.10|
     + 2.0 * |viol_p95 - 0.05|
     + 1.0 * WMAPE(y>0)
     + 0.5 * zero_overforecast_rate
     + 10.0 * (pct_q90_lt_q80 + pct_q95_lt_q90)  -- monotonicity penalty
     + 5.0 * MAX(0, HIGH_SEASON_WMAPE_ypos - 0.700)  -- degradation penalty
```

Winner is frozen and applied to LOCKED_TEST without further tuning.

## Pipeline Phases

| Phase | File | Description | Type |
|-------|------|-------------|------|
| 0 | `00_diagnose_quantile_collapse_h12_v4_qr_strict.sql` | Diagnose collapse at source (raw BQML vs v3_2) | SQL |
| 1 | `01_build_qr_feature_matrix_h12_v4_qr_strict.sql` | Build comprehensive feature matrix | SQL |
| 2 | `02_train_quantile_regression_h12_v4_qr_strict.py` | Train 3 candidate approaches on DEV_TUNE | Python |
| 3 | `03_score_quantile_regression_h12_v4_qr_strict.py` | Score DEV_SELECT + LOCKED_TEST | Python |
| 4 | `04_select_frozen_qr_policy_dev_select_h12_v4_qr_strict.sql` | Select winner on DEV_SELECT | SQL |
| 5 | `05_final_locked_test_metrics_h12_v4_qr_strict.sql` | Final evaluation on LOCKED_TEST | SQL |
| 6 | `99_leakage_audit_h12_v4_qr_strict.sql` | Verify anti-leakage guarantees | SQL |

## Anti-Leakage Guarantees

✅ **Temporal separation**: DEV_TUNE (train) → DEV_SELECT (select) → LOCKED_TEST (eval)

✅ **Feature matrix** built from v3_2, which enforces anti-leakage on historical features (TRAIN+CALIB only, prior years)

✅ **QR training** uses ONLY DEV_TUNE labels

✅ **Model selection** uses ONLY DEV_SELECT metrics

✅ **LOCKED_TEST** is read-only, one-time use

✅ **Frozen policy** has:
- `selected_without_locked_test = TRUE`
- `post_selection_bias = FALSE`
- `selected_using_split = 'DEV_SELECT'`

✅ **Leakage audit** must return `PASS` or pipeline fails

## Success Targets

| Metric | Target | v3_2 Baseline | v4 Goal |
|--------|--------|---------------|---------|
| **viol_p80** | 0.15 - 0.25 | 0.000 | ✓ in range |
| **viol_p90** | 0.05 - 0.15 | 0.000 | ✓ in range |
| **viol_p95** | 0.02 - 0.08 | 0.000 | ✓ in range |
| **WMAPE (global, y>0)** | ≤ 1.000 | 0.864 | Maintain or improve |
| **REST WMAPE (y>0)** | < 3.000 | 4.761 | Significant improvement |
| **Zero overforecast rate** | < 0.70 | 0.715 | Reduce |
| **Brier (calibrated)** | ≤ 0.060 | 0.0585 | No degradation |
| **HIGH_SEASON WMAPE (y>0)** | ≤ 0.700 | 0.624 | No degradation |

## Usage

### Prerequisites

1. **v3_2 pipeline** must be run first:
   ```bash
   python sql/bqml/h12_v3_2_season_state_strict/run_h12_v3_2_season_state_strict_pipeline.py
   ```

2. **sklearn** must be installed:
   ```bash
   pip install scikit-learn>=1.8.0
   ```

3. **BigQuery authentication**:
   ```bash
   gcloud auth application-default login
   ```

### Run Full Pipeline

```bash
# Dry-run (validate without executing)
python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --dry-run

# Live run (all phases)
python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py
```

### Run Specific Phases

```bash
# Run only diagnostic
python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --start-phase 0 --stop-after-phase 0

# Run training and scoring (skip diagnostic and feature matrix if already done)
python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --start-phase 2 --stop-after-phase 3

# Run final evaluation (assumes training/scoring complete)
python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --start-phase 4
```

### Environment Variables

```bash
export PROJECT_ID=thequantitativeledger
export BQ_DATASET=cruzber_models_eu
export BQ_LOCATION=EU
```

## Output Tables

### Training Artifacts (local)

```
outputs/h12_v4_qr/
  ├── qr_direct_q50.pkl
  ├── qr_direct_q80.pkl
  ├── qr_direct_q90.pkl
  ├── qr_direct_q95.pkl
  ├── qr_residual_q50.pkl
  ├── qr_residual_q80.pkl
  ├── qr_residual_q90.pkl
  ├── qr_residual_q95.pkl
  ├── qr_zero_aware_q50.pkl
  ├── qr_zero_aware_q80.pkl
  ├── qr_zero_aware_q90.pkl
  ├── qr_zero_aware_q95.pkl
  ├── label_encoders.pkl
  └── feature_names.txt
```

### BigQuery Tables

| Table | Description |
|-------|-------------|
| `diagnostics_quantile_collapse_h12_v4_qr_strict` | Collapse diagnosis (raw BQML vs v3_2) |
| `qr_feature_matrix_h12_v4_qr_strict` | Feature matrix for QR training |
| `qr_trained_models_metadata_h12_v4_qr_strict` | Training metadata (MAE, feature importance) |
| `qr_predictions_h12_v4_qr_strict` | Predictions for all 3 candidates |
| `qr_candidate_evaluation_dev_select_h12_v4_qr_strict` | Candidate evaluation metrics |
| `frozen_qr_policy_h12_v4_qr_strict` | Winning model configuration |
| `final_locked_test_metrics_h12_v4_qr_strict` | Final LOCKED_TEST metrics |
| `leakage_audit_h12_v4_qr_strict` | Anti-leakage audit results |

## Model Configuration

### GradientBoostingRegressor Hyperparameters

```python
{
    "loss": "quantile",
    "alpha": 0.50 / 0.80 / 0.90 / 0.95,  # Quantile value
    "n_estimators": 100,
    "max_depth": 4,
    "learning_rate": 0.05,
    "min_samples_leaf": 20,
    "subsample": 0.8,
    "random_state": 42
}
```

**Rationale**:
- **n_estimators=100**: Balanced accuracy vs training time
- **max_depth=4**: Prevents overfitting on ~8k DEV_TUNE samples
- **learning_rate=0.05**: Conservative to avoid overshooting
- **min_samples_leaf=20**: Ensures stable leaf statistics
- **subsample=0.8**: Stochastic gradient boosting for robustness

## Diagnostic Queries

### Check if quantiles are collapsed at source

```sql
SELECT 
  source,
  eval_split_v3,
  season_group,
  avg_spread_p50_to_p90,
  viol_p90,
  pct_q90_equals_p50
FROM `thequantitativeledger.cruzber_models_eu.diagnostics_quantile_collapse_h12_v4_qr_strict`
WHERE eval_split_v3 = 'DEV_TUNE'
  AND season_group IN ('HIGH_SEASON', 'REST')
ORDER BY source, season_group;
```

### Compare candidate models

```sql
SELECT
  model_type,
  ROUND(composite_loss, 4) AS loss,
  viol_p80,
  viol_p90,
  viol_p95,
  wmape_y_positive
FROM `thequantitativeledger.cruzber_models_eu.qr_candidate_evaluation_dev_select_h12_v4_qr_strict`
WHERE breakdown = 'GLOBAL'
ORDER BY composite_loss ASC;
```

### View final LOCKED_TEST results

```sql
SELECT
  breakdown_level,
  season_group,
  sku_season_state,
  n_obs,
  wmape_y_positive,
  viol_rate_p90,
  zero_demand_overforecast_rate
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_qr_strict`
WHERE breakdown_level IN ('GLOBAL', 'BY_SEASON_GROUP')
ORDER BY breakdown_level, season_group;
```

### Check audit status

```sql
SELECT
  check_name,
  status,
  detail
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_qr_strict`
ORDER BY check_number;
```

## Comparison with Previous Versions

| Version | Approach | viol_p90 (LOCKED_TEST) | REST WMAPE(y>0) | Status |
|---------|----------|------------------------|-----------------|--------|
| **v3_strict** | Grid-based quantile calibration | 0.000 (collapsed) | - | Baseline |
| **v3_2** | + OFF_SEASON gate + state calibration | 0.000 (still collapsed) | 4.761 | v3_strict + seasonal |
| **v4** | **Quantile regression layer** | **TBD** | **TBD** | **Current** |

## Troubleshooting

### sklearn not found

```bash
pip install scikit-learn==1.8.0
```

### BigQuery authentication error

```bash
gcloud auth application-default login
gcloud config set project thequantitativeledger
```

### Memory error during training

Reduce batch size or sample DEV_TUNE:

```sql
-- In 02_train_quantile_regression_h12_v4_qr_strict.py, modify query:
WHERE eval_split_v3 = 'DEV_TUNE'
  AND has_label = TRUE
  AND RAND() < 0.8  -- Sample 80% of training data
```

### Audit FAIL

Check specific failure:

```sql
SELECT check_name, detail
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_qr_strict`
WHERE status = 'FAIL';
```

## Next Steps

After v4 execution:

1. **Compare metrics** with v3_2 baseline using `COMPARACION_V3_2_VS_V4.md`
2. **Analyze quantile spreads** to verify collapse is solved
3. **Segment analysis** to identify which states improved most
4. **Feature importance** to understand what drives quantile prediction
5. **If v4 successful**: Package as production-ready model
6. **If v4 insufficient**: Consider v5 with deep learning or mixture models

## References

- **v3_strict**: Clean baseline with strict temporal separation
- **v3_2**: Seasonal state classification + OFF_SEASON gate
- **INFORME_DEFICIENCIAS_H12_V3_2.md**: Comprehensive problem diagnosis
- **sklearn GradientBoostingRegressor**: [scikit-learn.org/stable/modules/generated/sklearn.ensemble.GradientBoostingRegressor.html](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.GradientBoostingRegressor.html)

## Authors

- **Pipeline design**: Senior ML Engineer + Data Scientist (quantile regression specialist)
- **Implementation**: GitHub Copilot (Claude Sonnet 4.5)
- **Validation**: Anti-leakage audit + temporal contract enforcement

## License

Internal use only - ISDI MDA / Hugo de Val Roig
