# h12_v4_1: Efficient Conformal Quantiles (Strict Anti-Leakage)

## Overview

**h12_v4_1** is a hybrid forecasting model that combines:
1. **v3_2's proven point forecast efficiency** (WMAPE(y>0) = 0.864)
2. **Conformal residual-based quantile spreads** (calibrated by segment)
3. **Zero-aware logic** to handle extreme intermittency (71.5% zeros)

**Key Philosophy:** Don't retrain what already works. Maintain v3_2's point forecast, add calibrated uncertainty intervals.

## Rationale

v4's independent quantile regression failed because:
- Degraded point forecast (WMAPE: 0.864 → 1.310)
- Overfitted to DEV_SELECT (viol_p90 fell 90% on LOCKED_TEST)
- Couldn't handle REST segment (87% zeros, CV=8.02)

v4_1 addresses this by:
- **Preserving v3_2 efficiency:** A1 candidate reuses v3_2_gated forecast
- **Learning only spreads:** Residuals calibrated by segment on DEV_TUNE
- **Robustness:** Hierarchical fallback (state → season → global)
- **Stability-aware selection:** Penalizes unstable weekly metrics
- **Relaxed targets:** Acknowledges dataset difficulty (71.5% zeros, CV=7.5)

## Architecture

### Layer A: Efficient Point Forecast (4 candidates)
- **A0_BASE:** Original BQML p50 without gate
- **A1_V3_2_GATED:** v3_2 gated forecast (baseline to beat)
- **A2_ZERO_AWARE_SHRINK:** v3_2 + segment-specific shrink factors
- **A3_HURDLE_CONSERVATIVE:** Allow p50=0 when segment_zero_rate >= 80%

### Layer B: Conformal Residual Spreads (4 methods)
- **B1_ABS_RESIDUAL:** q_tau = p50 + quantile(|res|)
- **B2_LOG_RESIDUAL:** q_tau = expm1(log1p(p50) + quantile(log1p(res)))
- **B3_HYBRID_ADAPTIVE:** Abs for OFF_SEASON/REST, log for HIGH/ALWAYS_ON
- **B4_CONFORMAL_CALIBRATED:** 0.8× adjustment to tighten spreads

### Layer C: Zero Regime Logic
- **EXTREME_ZERO (≥80%):** Cap spreads, allow p50=0
- **HIGH_ZERO (≥65%):** Moderate spreads
- **MODERATE_ZERO (≥50%):** Standard spreads
- **LOW_ZERO (<50%):** No restrictions

## Selection Loss Function

```
loss = 2.0×WMAPE_all + 2.0×WMAPE_ypos + 1.0×zero_overf 
     + 0.5×|bias| + 0.8×coverage_penalty 
     + 1.0×rest_penalty + 1.0×highseason_degradation 
     + 10.0×monotonicity_penalty + 0.5×stability_score
```

**Relaxed Targets:**
- viol_p80: [0.10, 0.25] (ideal 0.20)
- viol_p90: [0.04, 0.15] (ideal 0.10)
- viol_p95: [0.01, 0.08] (ideal 0.05)

## Prerequisites

1. **v3_2 must be run first** to generate:
   - `forecast_gated_h12_v3_2_season_state_strict`
   - `sku_season_state_h12_v3_2_season_state_strict`
   - `sku_week_seasonality_features_h12_v3_2_season_state_strict`

2. **BigQuery environment:**
   - Project: `thequantitativeledger`
   - Dataset: `cruzber_models_eu`
   - Location: `EU`
   - Authentication: ADC with permissions (roles/bigquery.dataEditor + jobUser)

3. **Python environment:**
   - `google-cloud-bigquery` installed
   - Python 3.8+

## Usage

### Standard execution (all phases):
```bash
python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py
```

### Dry run (validate SQL only):
```bash
python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py --dry-run
```

### Partial execution:
```bash
# Run phases 0-3 only (feature matrix + spreads calibration)
python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py --stop-after-phase 3

# Resume from phase 4
python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py --start-phase 4
```

## Pipeline Phases

| Phase | File | Purpose | Output Table |
|-------|------|---------|--------------|
| 0 | `00_diagnostics_eda_shift_h12_v4_1.sql` | Reproduce v3_2 baseline + shift analysis | `diagnostics_v3_2_baseline_reproduction_h12_v4_1` |
| 1 | `01_build_feature_matrix_h12_v4_1.sql` | Join v3_2 tables + rolling features | `feature_matrix_h12_v4_1_strict` |
| 2 | `02_build_point_forecast_candidates_h12_v4_1.sql` | Generate A0-A3 point forecasts | `point_forecast_candidates_h12_v4_1_strict` |
| 3 | `03_calibrate_segmented_residual_spreads_h12_v4_1.sql` | Compute residual quantiles by segment | `residual_spread_calibration_h12_v4_1_strict` |
| 4 | `04_score_conformal_quantile_candidates_h12_v4_1.sql` | Apply B1-B4 spreads to A0-A3 | `conformal_quantile_candidates_h12_v4_1_strict` |
| 5 | `05_select_frozen_efficient_policy_dev_select_h12_v4_1.sql` | Select best A×B via loss on DEV_SELECT | `frozen_efficient_policy_h12_v4_1_strict` |
| 6 | `06_final_locked_test_metrics_h12_v4_1.sql` | ONE-TIME LOCKED_TEST evaluation | `final_locked_test_metrics_h12_v4_1_strict` |
| 7 | `07_compare_v3_2_vs_v4_1_h12.sql` | Side-by-side comparison | `compare_v3_2_vs_v4_1_h12_strict` |
| 99 | `99_leakage_audit_h12_v4_1.sql` | 10-check anti-leakage audit | `leakage_audit_h12_v4_1_strict` |

## Success Criteria (vs v3_2)

### Minimum Requirements (to NOT degrade):
- WMAPE_all ≤ 1.215 (v3_2 baseline: 1.157)
- WMAPE_ypos ≤ 0.907 (v3_2 baseline: 0.864)
- viol_p90 > 0.02 (v3_2: 0.000 collapsed)

### Ideal Targets (to PROMOTE):
- WMAPE_ypos < 0.864 (improve point forecast)
- REST WMAPE < 4.761 (reduce overprediction)
- viol_p90 ∈ [0.04, 0.15] (calibrated quantiles)
- Zero overforecast (REST) < 87.2%

### Decision Rules:
- **PROMOTE v4_1:** WMAPE maintained + quantiles uncollapsed + REST improved
- **KEEP v3_2:** WMAPE degrades >10% OR quantiles still collapsed
- **EXPERIMENTAL:** Marginal improvement, needs business review

## Interpretation Guide

### Key Metrics to Monitor:

1. **WMAPE (y>0):** Most important. Must not degrade vs v3_2.
2. **viol_p90:** Should be 0.04-0.15. Too low = too tight (useless). Too high = too wide (waste).
3. **zero_overf:** Fraction of zeros where we predict >0. Lower is better for REST/OFF_SEASON.
4. **REST WMAPE:** Critical segment (87% zeros). v3_2 struggles here (WMAPE=4.761).
5. **Monotonicity violations:** Should be near 0. If high, spreads are miscalibrated.

### Expected Results:

Given dataset difficulty (71.5% zeros, CV=7.5, -72.3% shift):
- **Baseline (v3_2):** WMAPE_ypos=0.864, viol_p90=0.000 ❌
- **Target (v4_1):** WMAPE_ypos ≤ 0.90, viol_p90 ∈ [0.06, 0.12] ✓
- **Stretch:** WMAPE_ypos < 0.86, REST WMAPE < 4.0, viol_p90 ∈ [0.08, 0.12] ✓✓

If results show:
- **WMAPE_ypos > 1.0:** Likely overfitting to DEV_SELECT, check stability metrics
- **viol_p90 < 0.04:** Spreads too conservative, adjust B4 multiplier
- **viol_p90 > 0.20:** Spreads too wide, may hurt operational use
- **REST viol_p90 < 0.03:** Zero regime logic not working, increase EXTREME_ZERO threshold

## Known Limitations

1. **Dataset inherently difficult:**
   - 71.5% zeros (extreme intermittency)
   - CV = 7.50 (high variability)
   - Distributional shift -72.3% (DEV_SELECT → LOCKED_TEST)
   
2. **Trade-offs are inevitable:**
   - Tighter spreads (lower viol) → higher WMAPE
   - Looser spreads (lower WMAPE) → less useful quantiles
   
3. **REST segment will struggle:**
   - 87% zeros, CV=8.02
   - v3_2 already has WMAPE=4.761 here
   - v4_1 aims to maintain, not dramatically improve
   
4. **Segment-level spreads may fail for rare states:**
   - Minimum n=50 for state-level calibration
   - Falls back to season or global if insufficient data

## Anti-Leakage Guarantees

The pipeline enforces strict temporal and data isolation:

1. **DEV_TUNE (W01-W08):** Calibration only (shrink factors, spreads)
2. **DEV_SELECT (W09-W16):** Selection only (choose best A×B candidate)
3. **LOCKED_TEST (W28-W40):** ONE-TIME evaluation (no tuning, no re-selection)

**10-check audit verifies:**
- Temporal contract (TUNE < SELECT < TEST)
- Feature matrix isolation
- Calibration only on TUNE
- Selection only on SELECT
- LOCKED_TEST used once
- Frozen policy flags correct
- No hyperparameter tuning on TEST
- Metadata integrity

**Exit code:**
- `0` = Audit PASS (pipeline valid)
- `1` = Audit FAIL (results invalid)

## Troubleshooting

### "Feature matrix has NULL values"
- Check v3_2 tables exist and populated
- Verify sku_id joins work
- Inspect rolling_features window logic

### "Shrink grid search returns no results"
- DEV_TUNE may be too small
- Check eval_split_v3 column values
- Verify y_true_12w not NULL

### "Frozen policy shows poor metrics on DEV_SELECT"
- Expected if dataset difficult
- Compare to v3_2 baseline
- Check if all candidates fail (dataset issue) vs one candidate wins

### "LOCKED_TEST metrics dramatically different from DEV_SELECT"
- Distributional shift (documented in Phase 0)
- Check diagnostics_distributional_shift_by_segment_h12_v4_1
- May need to use DEV_TUNE+DEV_SELECT combined for more stable calibration

### "Audit FAILS"
- Review failed check details
- Common: frozen policy flags incorrect (manual fix)
- Rare: temporal contract violated (serious, re-run pipeline)

## Contact

For questions or issues:
- Check Phase 0 diagnostics first (reproduces v3_2 baseline)
- Verify v3_2 prerequisite tables exist
- Review INFORME_CONSOLIDADO_H12_V4_COMPLETO.md for context on v4 failure

---

**Version:** v4_1 (Efficient Conformal Quantiles, Strict Anti-Leakage)  
**Date:** 2024  
**Dependencies:** h12_v3_2_season_state_strict pipeline  
**Status:** Ready for execution
