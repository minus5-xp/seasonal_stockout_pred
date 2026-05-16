# h12_v4_2: Quantile Overlay on v3_2 (Strict Protocol)

## Overview

**Model**: h12_v4_2_quantile_overlay_on_v3_2_strict  
**Purpose**: Add calibrated quantiles (q80, q90, q95) to v3_2's frozen p50 forecast  
**Key Principle**: **p50 is FROZEN from v3_2. Only quantile spreads are learned.**  
**Status**: Ready for execution

---

## Background: Why v4_2?

### v3_2 Baseline Performance (LOCKED_TEST)
- ✅ **Best operational p50**: WMAPE(y>0) = 0.864
- ✅ **Proven efficiency**: Gated forecast with careful zero handling
- ❌ **Problem**: Quantiles collapsed (viol_p80/p90/p95 = 0.000)
- ❌ **Impact**: No uncertainty quantification, no inventory safety buffers

### v4 Failure (Quantile Regression)
- Attempted pure quantile regression with 3 candidates (QR_DIRECT, QR_RESIDUAL, QR_ZERO_AWARE)
- Selected QR_RESIDUAL on DEV_SELECT
- **Catastrophic failure on LOCKED_TEST**: WMAPE degraded 51.6% (0.864 → 1.310)
- **Root cause**: Quantile regression destroyed point forecast efficiency

### v4_1 Failure (Efficient Conformal Quantiles)
- Designed 3-layer hybrid system: point forecast candidates × spread methods
- Selected A0_BASE_B3_HYBRID_ADAPTIVE on DEV_SELECT
- **Catastrophic failure on LOCKED_TEST**: WMAPE degraded 50.7% (0.864 → 1.302)
- **Root cause**: Selected A0_BASE (raw ungated BQML) instead of v3_2's gated forecast
- **Lesson learned**: DO NOT attempt to "improve" p50. v3_2 is already optimal.

### v4_2 Design Philosophy
**Directive**: "v4_2 no debe intentar ganar en predicción puntual. v3_2 ya es el mejor p50 operativo. v4_2 solo debe añadir cuantiles monotónicos, segmentados y moderadamente calibrados encima de v3_2, sin destruir su eficiencia."

**Approach**:
1. **FREEZE p50** from v3_2 (yhat_p50_season_state_12w) - NEVER MODIFY
2. **Learn spreads** from residuals on DEV_TUNE: `residual_upper = GREATEST(y_true - p50_frozen, 0)`
3. **Overlay quantiles**: q80 = p50 + spread_80, q90 = p50 + spread_90, q95 = p50 + spread_95
4. **Select** best overlay method on DEV_SELECT
5. **Evaluate** on LOCKED_TEST (one-time use)

---

## Architecture

### Phase 0: Reproduce v3_2 Baseline
- **File**: `00_reproduce_v3_2_baseline_h12_v4_2.sql`
- **Purpose**: Establish exact v3_2 metrics on LOCKED_TEST for comparison
- **Output**: `v3_2_baseline_reproduced_h12_v4_2_strict`

### Phase 1: Build Overlay Feature Matrix
- **File**: `01_build_overlay_feature_matrix_h12_v4_2.sql`
- **Purpose**: Join v3_2 forecasts with features, freeze p50
- **Key**: `p50_frozen_v3_2 = f.yhat_p50_season_state_12w` (v3_2 gated forecast)
- **Output**: `overlay_feature_matrix_h12_v4_2_strict` (119,857 rows)
- **Temporal coverage**: DEV_TUNE, DEV_SELECT, LOCKED_TEST

### Phase 2: Calibrate Residual Spreads (DEV_TUNE Only)
- **File**: `02_calibrate_residual_spreads_dev_tune_h12_v4_2.sql`
- **Purpose**: Compute empirical quantiles of upper residuals
- **Split**: DEV_TUNE ONLY (W01-W08, 33,064 obs)
- **Residuals**:
  - `residual_upper_abs = GREATEST(y_true - p50_frozen, 0.0)`
  - `residual_upper_log = GREATEST(LN(1+y_true) - LN(1+p50_frozen), 0.0)`
- **Calibration**: By sku_season_state, season_group, global (hierarchical fallback)
- **Zero regimes**: EXTREME_ZERO (≥80%), HIGH_ZERO (≥65%), MODERATE_ZERO (≥50%), LOW_ZERO
- **Output**: `residual_spread_calibration_h12_v4_2_strict`

### Phase 3: Score Overlay Candidates (DEV_SELECT Only)
- **File**: `03_score_overlay_candidates_dev_select_h12_v4_2.sql`
- **Purpose**: Generate and evaluate 36 overlay candidates
- **Split**: DEV_SELECT ONLY (W09-W16, 33,064 obs)
- **Candidates**: 4 methods × 3 caps × 3 min_n_segment = 36 total

#### Overlay Methods
1. **C1_ABS_SEGMENTED**: `q = p50 + spread_abs`
2. **C2_LOG_SEGMENTED**: `q = exp(ln(p50+1) + spread_log) - 1`
3. **C3_HYBRID_ZERO_AWARE**: ABS for OFF_SEASON/REST, LOG for HIGH_SEASON/ALWAYS_ON
4. **C4_MINIMAL_SPREAD**: `q = p50 + (spread_abs × 0.5)` (conservative baseline)

#### Cap Strategies
1. **NO_CAP**: No upper limit
2. **CAP_2X**: `q95 ≤ max(p50 × 2.0, p50 + hist_p95_segment)`
3. **CAP_3X**: `q95 ≤ max(p50 × 3.0, p50 + hist_p95_segment)`

#### Minimum Segment Size
- **300**: Use segment spreads if n ≥ 300, else global
- **500**: Use segment spreads if n ≥ 500, else global
- **1000**: Use segment spreads if n ≥ 1000, else global

#### Composite Loss (Selection Objective)
```
loss = 1.5 × coverage_penalty
     + 1.0 × spread_efficiency
     + 1.0 × rest_overspread
     + 1.0 × highseason_undercoverage
     + 2.0 × stability
     + 100.0 × p50_change_penalty
     + 100.0 × monotonicity_penalty
```

**Key**: 100× penalty on any p50 deviation to enforce frozen p50 constraint

- **Output**: `overlay_candidate_scores_dev_select_h12_v4_2_strict`

### Phase 4: Select and Freeze Best Overlay Policy
- **File**: `04_select_frozen_overlay_policy_h12_v4_2.sql`
- **Purpose**: Select candidate with minimum composite loss
- **Constraint**: `monotonicity_violation_rate = 0` (hard requirement)
- **Frozen flags**:
  - `selected_using_split = 'DEV_SELECT'`
  - `selected_without_locked_test = TRUE`
  - `post_selection_bias = FALSE`
- **Output**: `frozen_overlay_policy_h12_v4_2_strict` (1 row)

### Phase 5: Build Final Forecast
- **File**: `05_build_final_forecast_h12_v4_2.sql`
- **Purpose**: Apply frozen policy to ALL data (DEV_TUNE, DEV_SELECT, LOCKED_TEST)
- **Process**:
  1. Read frozen policy configuration (method, cap_strategy, min_n_segment)
  2. Join feature matrix with spreads (hierarchical fallback)
  3. Generate raw quantiles using frozen method
  4. Apply frozen cap strategy
  5. Enforce monotonicity: p50 ≤ q80 ≤ q90 ≤ q95
- **Output**: `forecast_final_h12_v4_2_strict`
- **Columns**: sku_id, decision_week, eval_split_v3, season_group, sku_season_state, y_true_12w, yhat_p50_v4_2_12w, q80/90/95_v4_2_12w, spread80/90/95_v4_2, overlay_method, cap_strategy, zero_regime, model_version

### Phase 6: Final LOCKED_TEST Metrics (One-Time Use)
- **File**: `06_final_locked_test_metrics_h12_v4_2.sql`
- **Purpose**: Evaluate v4_2 on LOCKED_TEST
- **Split**: LOCKED_TEST ONLY (W28-W40, 53,729 obs)
- **Metrics**: WMAPE, bias, quantile coverage, spreads, monotonicity
- **Aggregation**: global, by_season, by_state
- **Output**: `final_locked_test_metrics_h12_v4_2_strict`

### Phase 7: Compare v3_2 vs v4_2
- **File**: `07_compare_v3_2_vs_v4_2_h12.sql`
- **Purpose**: Side-by-side comparison
- **Metrics**: WMAPE_ypos, viol_p80/p90/p95, spreads, deltas
- **Verdict Logic**:
  - **WIN_QUANTILES**: p50 identical + WMAPE no degradation + quantiles improved
  - **KEEP_V3_2_STILL_COLLAPSED**: Quantiles still collapsed (viol_p90 < 0.01)
  - **EXPERIMENTAL_LARGE_SPREADS**: Quantiles improved but spreads > 50 units
  - **REJECT_P50_CHANGED**: p50 changed (should never happen with 100× penalty)
  - **REJECT_MONOTONICITY**: Monotonicity violations (should never happen)
- **Output**: `compare_v3_2_vs_v4_2_h12_strict`

### Phase 99: Comprehensive Leakage Audit
- **File**: `99_leakage_audit_h12_v4_2.sql`
- **Purpose**: Verify anti-leakage protocol compliance
- **Checks** (10 total):
  1. LOCKED_TEST never used for training
  2. Calibration only on DEV_TUNE
  3. Selection only on DEV_SELECT
  4. LOCKED_TEST metrics computed exactly once
  5. Frozen policy has correct flags
  6. No future leakage in rolling features
  7. **p50_v4_2 identical to p50_v3_2** (critical)
  8. Quantiles monotonic in final forecast
  9. Model version correctly tagged
  10. All tables non-empty
- **Output**: `leakage_audit_h12_v4_2_strict`
- **Required**: All checks must PASS

---

## Anti-Leakage Protocol

### Temporal Contract
- **DEV_TUNE (W01-W08)**: Calibrate residual spreads
- **DEV_SELECT (W09-W16)**: Select overlay method
- **EMBARGO (W17-W27)**: NEVER USED
- **LOCKED_TEST (W28-W40)**: Final evaluation ONLY (one-time use)

### Hard Rules
1. ⛔ LOCKED_TEST data NEVER used before Phase 6
2. ⛔ Calibration must use DEV_TUNE only
3. ⛔ Selection must use DEV_SELECT only
4. ⛔ No retrospective tuning after seeing LOCKED_TEST
5. ⛔ No model retraining (v3_2 frozen, BQML models frozen from 2023)
6. ✅ p50 from v3_2 is IMMUTABLE (100× penalty enforces this)

### Audit Enforcement
- Pipeline will **abort** if any audit check fails
- Phase 99 must return "PASS" verdict
- Check 7 (p50 identity) is critical for v4_2

---

## Tables Created

| Table | Phase | Rows | Description |
|-------|-------|------|-------------|
| `v3_2_baseline_reproduced_h12_v4_2_strict` | 0 | ~10 | v3_2 metrics on LOCKED_TEST |
| `overlay_feature_matrix_h12_v4_2_strict` | 1 | 119,857 | v3_2 p50 + features (all splits) |
| `residual_spread_calibration_h12_v4_2_strict` | 2 | ~30 | Empirical quantiles by segment |
| `overlay_candidate_scores_dev_select_h12_v4_2_strict` | 3 | 36 | Candidate evaluation on DEV_SELECT |
| `frozen_overlay_policy_h12_v4_2_strict` | 4 | 1 | Selected overlay configuration |
| `forecast_final_h12_v4_2_strict` | 5 | 119,857 | Final quantile forecasts |
| `final_locked_test_metrics_h12_v4_2_strict` | 6 | ~10 | v4_2 metrics on LOCKED_TEST |
| `compare_v3_2_vs_v4_2_h12_strict` | 7 | ~10 | Side-by-side comparison |
| `leakage_audit_h12_v4_2_strict` | 99 | 10 | Audit checks (must all PASS) |

---

## Promotion Criteria

### PROMOTE to Production
✅ All audit checks PASS (10/10)  
✅ p50 identical to v3_2: `|WMAPE_v4_2 - WMAPE_v3_2| ≤ 0.005` (0.5%)  
✅ Quantiles uncollapsed: `viol_p90 ≥ 0.02` (at least 2% violations, better than v3_2's 0%)  
✅ WMAPE no degradation: `WMAPE_v4_2 ≤ 0.864 × 1.05` (5% tolerance)  
✅ Monotonicity: `monotonicity_violation_rate = 0.0`  
✅ Verdict: `WIN_QUANTILES` on global or HIGH_SEASON segment

### EXPERIMENTAL (Consider)
⚠️ Quantiles uncollapsed but spreads seem large (avg_spread_p90 > 50 units)  
⚠️ Mixed segment performance (HIGH_SEASON improved, REST degraded)  
⚠️ Verdict: `EXPERIMENTAL_LARGE_SPREADS` or `EXPERIMENTAL_REVIEW`

### KEEP v3_2 (No Change)
❌ Quantiles still collapsed: `viol_p90 < 0.01`  
❌ No meaningful improvement over v3_2  
❌ Verdict: `KEEP_V3_2_STILL_COLLAPSED`  
**Conclusion**: Problem requires different framing (not solvable with conformal prediction on this dataset)

### REJECT v4_2
🚫 Audit failed (any check failed)  
🚫 p50 changed: `|WMAPE_v4_2 - WMAPE_v3_2| > 0.01`  
🚫 WMAPE degraded materially: `WMAPE_v4_2 > 0.864 × 1.05`  
🚫 Monotonicity violations: `monotonicity_violation_rate > 0`  
🚫 Verdict: `REJECT_P50_CHANGED` or `REJECT_MONOTONICITY`

---

## Usage

### Execute Pipeline
```bash
cd sql/bqml/h12_v4_2_quantile_overlay_on_v3_2_strict/
python run_h12_v4_2_quantile_overlay_on_v3_2_strict_pipeline.py
```

### Review Results
```sql
-- 1. Check frozen policy
SELECT * FROM `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict`;

-- 2. Review comparison
SELECT 
  segment,
  n_obs,
  ROUND(v3_2_wmape_ypos, 3) AS v3_2_wmape,
  ROUND(v4_2_wmape_ypos, 3) AS v4_2_wmape,
  ROUND(v3_2_viol_p90, 3) AS v3_2_p90,
  ROUND(v4_2_viol_p90, 3) AS v4_2_p90,
  ROUND(v4_2_avg_spread_p90, 2) AS spread90,
  verdict
FROM `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_2_h12_strict`
WHERE segment IN ('GLOBAL', 'HIGH_SEASON', 'REST')
ORDER BY CASE segment WHEN 'GLOBAL' THEN 1 WHEN 'HIGH_SEASON' THEN 2 ELSE 3 END;

-- 3. Check audit
SELECT * FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_2_strict`;

-- 4. Verify p50 identity
SELECT
  COUNT(*) AS total_obs,
  COUNTIF(ABS(f.yhat_p50_v4_2_12w - m.p50_frozen_v3_2) > 0.001) AS identity_violations,
  ROUND(AVG(ABS(f.yhat_p50_v4_2_12w - m.p50_frozen_v3_2)), 6) AS avg_abs_diff
FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict` f
JOIN `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict` m
  ON f.sku_id = m.sku_id AND f.decision_week = m.decision_week;
```

---

## Limitations

### Dataset Difficulty
- **71.5% zeros** in LOCKED_TEST (extreme intermittency)
- **CV = 7.5** (very high variability)
- **Distributional shift**: mean_y -72.3%, pct_zeros +35.4% (DEV_SELECT → LOCKED_TEST)
- **OFF_SEASON**: 87.2% zeros, CV = 18.19

### Known Issues
- **REST segment**: Extremely difficult (mean = 0.67 units, 87.2% zeros)
- **Overfitting risk**: DEV_SELECT metrics may not generalize to LOCKED_TEST
- **Spread calibration**: Empirical quantiles on 33K obs may be unstable for small segments
- **Zero regime**: Even with segmentation, extreme zero-inflation limits quantile quality

### What v4_2 Does NOT Do
- ❌ Does not modify p50 (frozen from v3_2)
- ❌ Does not retrain BQML models (frozen from 2023)
- ❌ Does not use LOCKED_TEST for calibration or selection
- ❌ Does not attempt to "beat" v3_2 on point forecast efficiency
- ❌ Does not solve the fundamental intermittency problem (just adds spreads)

---

## Next Steps (If v4_2 Succeeds)

### If Verdict = WIN_QUANTILES
1. ✅ **Deploy** v4_2 to production
2. Document frozen policy configuration for operations team
3. Monitor LOCKED_TEST performance monthly
4. Consider retraining spreads quarterly on new data (but keep p50 frozen)

### If Verdict = EXPERIMENTAL
1. 🔬 **Pilot test** on HIGH_SEASON SKUs only
2. Gather stakeholder feedback on spread magnitudes
3. Consider hybrid: v4_2 for HIGH_SEASON, v3_2 for REST
4. Revisit spread cap strategies (maybe tighter than CAP_2X/CAP_3X)

### If Verdict = KEEP_V3_2
1. 📝 **Document** that quantile overlay approach insufficient for this dataset
2. Accept that collapsed quantiles are a feature, not a bug (extreme zero-inflation)
3. Consider alternative problem framing:
   - Binary classification (OOS vs in-stock) instead of quantile regression
   - Inventory rules based on p50 only (no quantile safety buffers)
   - Scenario-based forecasting (optimistic/pessimistic) instead of statistical quantiles
4. **Do not attempt v4_3** with same methodology

---

## References

- **v3_2 baseline**: `sql/bqml/h12_v3_2_gated_season_state_strict/`
- **v4 failure analysis**: See LOCKED_TEST comparison in v4 pipeline
- **v4_1 failure analysis**: See `compare_v3_2_vs_v4_1_h12_strict` table
- **User specification**: 18-section design document (conversation history)
- **Dataset characteristics**: See `diagnostics_distributional_shift_by_segment_h12_v4_1` table

---

## Contact

For questions about this pipeline:
- **Model version**: h12_v4_2_quantile_overlay_on_v3_2_strict
- **Author**: Generated from user specification (18-section design)
- **Date**: 2024
- **Status**: Ready for execution, pending LOCKED_TEST evaluation
