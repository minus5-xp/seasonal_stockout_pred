# B3 Gate Fix v2: Mondrian Split-Conformal with Volatility Refinement

**Status**: Implementation complete, awaiting execution  
**Date**: 2026-02-15  
**Approach**: Paper-grade nested tuning with hierarchical fallback

---

## Executive Summary

**Problem**: Gate B3 failed with 3 segments (out of 6) outside [8%, 12%] conditional coverage for P90:
- REST + LOW: 3.36% deviation (66.4% of population)
- HIGH_SEASON + MEDIUM: 2.82% deviation
- REST + HIGH: 2.06% deviation

**Root Cause**: Mondrian segmentation (season × HHI) too coarse; high heterogeneity within bins, especially in volatility.

**Solution Architecture**:
1. **Volatility bucketing**: Add CV-based 4-bin stratification (LOW/MED/HIGH/EXTREME_VOL)
2. **26-week calibration split**: CALIB_A (scores) + CALIB_B (nested tuning)
3. **Hierarchical fallback**: seg3 (season|hhi|vol) → seg2 → seg1 → global with N_MIN thresholds
4. **Nested tuning**: Optimize coverage_target ∈ [0.88, 0.98] per seg2 using CALIB_B (never touches VAL)
5. **Reproducibility**: Pure SQL pipeline in BigQuery

---

## Implementation Details

### Stage 1: Volatility Bucketing

**File**: `sql/bqml/quantiles_v2/30_build_volatility_bucket.sql`

**Logic**:
- Compute CV (coefficient of variation) per SKU over rolling 12-week window:
  $$ CV = \frac{\sigma_{12w}}{\mu_{12w}} $$
- Assign quartile buckets (LOW_VOL / MED_VOL / HIGH_VOL / EXTREME_VOL) using global quantiles
- Output table: `volatility_buckets_h4`

**Key Parameters**:
- Rolling window: 12 weeks
- Minimum observations: 8 weeks
- Minimum mean: 0.1 (avoid division by zero on near-zero demand)

---

### Stage 2: Calibration Window Refinement

**File**: `sql/bqml/quantiles_v2/31_define_calibration_windows.sql`

**Logic**:
- Split `calib` into:
  - **CALIB_A**: First 13 weeks (for conformity score estimation)
  - **CALIB_B**: Last 13 weeks (for nested tuning of coverage targets)
- Join with volatility buckets
- Compute residual: `y_true_uc - yhat_point`
- Output table: `calibration_windows_h4` with `split_refined` column

**Rationale**: CALIB_B acts as "pseudo-validation" for tuning hyperparameters (coverage_target per segment) without contaminating true VAL split.

---

### Stage 3: Mondrian Conformal with Hierarchical Fallback

**File**: `sql/bqml/quantiles_v2/32_mondrian_conformal_quantiles_v2.sql`

**Segment Hierarchy**:
1. **seg3** = `season_group|hhi_bucket|volatility_bucket` (finest)
2. **seg2** = `season_group|hhi_bucket`
3. **seg1** = `season_group`
4. **seg0** = `GLOBAL`

**Fallback Logic** (based on sample size per segment):
```
IF n_seg3 >= 200 THEN use qhat_seg3
ELSIF n_seg2 >= 150 THEN use qhat_seg2
ELSIF n_seg1 >= 100 THEN use qhat_seg1
ELSE use qhat_global
```

**Conformity Score**: Upper residual (one-sided):
$$ S_i = y_i - \hat{y}_i $$

**Quantile Computation**: P90 of conformity scores within each segment using CALIB_A data.

**Output**: `mondrian_quantiles_v2_h4` with:
- `pred_p90 = yhat_point + qhat_p90_final`
- `fallback_level` (seg3/seg2/seg1/global)
- Coverage flag per observation

---

### Stage 4: Nested Tuning of Coverage Targets

**File**: `sql/bqml/quantiles_v2/33_tune_segment_coverage_target.sql`

**Grid Search**:
- Coverage targets: [0.88, 0.90, 0.92, 0.94, 0.96, 0.98]
- Granularity: seg2 (season × HHI)

**Optimization**:
For each seg2 and each target:
1. Compute qhat from CALIB_A at that percentile
2. Apply to CALIB_B and measure conditional violation rate
3. Select target that minimizes `|viol_rate - 0.10|` subject to `viol_rate ∈ [0.08, 0.12]`

**Constraints**:
- Minimum support: 50 active demand observations in CALIB_B
- Preference: targets that fall within [8%, 12%] before considering out-of-bounds

**Output**: `segment_coverage_targets_v2_h4` with:
- `tuned_coverage_target` per seg2
- `tuned_qhat`
- `calibb_viol_rate` (achieved on CALIB_B)
- `calibb_gate_status` (PASS/FAIL)

**Publishability Note**: This is a **nested cross-validation** strategy commonly used in conformal prediction literature (Vovk et al., 2005; Angelopoulos & Bates, 2021). CALIB_B never touches VAL, maintaining proper holdout discipline.

---

### Stage 5: Apply Tuned Targets to VAL

**File**: `sql/bqml/quantiles_v2/34_apply_targets_and_score_val.sql`

**Logic**:
1. Recompute quantiles from CALIB_A using tuned coverage targets from Stage 4
2. Apply to VAL split:
   - If seg2 has tuned target → use it
   - Else fall back to default 0.90
3. Generate final predictions:
   - `pred_p50` = point forecast
   - `pred_p90` = point + qhat_tuned
   - `pred_p95` = point + qhat_tuned × 1.15 (heuristic for higher quantile)

**Output**: `pred_quantiles_v2_h4` with coverage evaluation on true VAL holdout.

---

### Stage 6: Evaluation and Gate Check

**Files**:
- `sql/bqml/eval/40_eval_quantiles_conditional_v2.sql`
- `sql/bqml/eval/41_b3_fix_summary.sql`

**Metrics**:
- **Conditional violation rate**: $\frac{\text{violations when demand > 0}}{\text{observations with demand > 0}}$
- **Deviation from 10%**: $|\text{viol\_rate} - 0.10|$
- **Sharpness**: Average interval width (P90 - P50)
- **Pinball loss**: Quantile regression loss for P90

**Gate Criteria**:
- **PASS** if all seg2 segments have `viol_rate_p90_cond ∈ [0.08, 0.12]`
- **FAIL** otherwise

**Output Tables**:
- `eval_quantiles_conditional_v2_h4`: Per-segment detailed metrics
- `b3_fix_gate_summary_h4`: Summary with PASS/FAIL verdicts

---

## Execution Instructions

### Prerequisites
- Python 3.9+ with Google Cloud SDK authenticated (ADC)
- BigQuery tables from Option B pipeline:
  - `pred_point_uc_h4` (point forecasts + true unconstrained demand)
  - `pred_oos_h4_canonical` (for segment keys if needed)

### Run Command

```bash
cd "C:\Users\hugod\OneDrive - Hugo de Val Roig\Documentos\Privado\Formación\ISDI - MDA\Troncal"

conda run -n jupyter-ai python src/bq/run_optionB_b3_fix.py \
  --project-id thequantitativeledger \
  --dataset-id cruzber_models_eu \
  --location EU \
  --verbose
```

### Expected Execution Time
- Stage 1-2: ~30 seconds
- Stage 3 (Mondrian v2): ~2 minutes (depends on data size)
- Stage 4 (Tuning): ~1 minute (grid search over 6 targets × N_seg2)
- Stage 5-6: ~30 seconds
- **Total**: ~4-5 minutes

---

## Expected Outcomes

### Scenario A: Gate PASS ✅

**Output**:
```
GATE B3 EVALUATION - FINAL VERDICT
====================================
Overall Status: ✅ PASS
Segments: 6/6 passed

Segment                    N_active      Viol_rate     Status
------------------------------------------------------------------------
GLOBAL                     231036        0.0950        PASS
HIGH_SEASON|HIGH           7451          0.1020        PASS
HIGH_SEASON|LOW            60449         0.0980        PASS
HIGH_SEASON|MEDIUM         3188          0.1050        PASS
REST|HIGH                  9474          0.0920        PASS
REST|LOW                   146822        0.0990        PASS
REST|MEDIUM                3652          0.0880        PASS
```

**Next Steps**:
1. Update `submission_readiness_h4` to reflect B3 PASS
2. Rerun B4 policy simulation with new quantiles
3. Generate submission-ready report

---

### Scenario B: Partial Improvement (Some segments still fail)

**Likely Causes**:
1. Insufficient calibration data (N_MIN too high → too much fallback to coarse segments)
2. Extreme heterogeneity within seg3 (need finer stratification)
3. Non-stationarity in calibration vs validation periods

**Remediation Options**:
- **Lower N_MIN thresholds**: Try 150/100/50 instead of 200/150/100
- **Add product category**: If available, refine seg4 = season|hhi|vol|category
- **Expand CALIB window**: Use 39 weeks (CALIB_A=26w, CALIB_B=13w)
- **Adaptive αᵢ**: Instead of grid search, use analytical solution:
  $$\alpha_{\text{seg}} = \alpha_{\text{nom}} \times \frac{0.10}{\text{calibb\_viol\_rate}}$$

---

### Scenario C: Gate FAIL (no improvement)

**Diagnostic Queries**:

```sql
-- Check fallback distribution
SELECT
  fallback_level,
  COUNT(*) AS n_obs,
  AVG(covered_p90) AS coverage_rate
FROM cruzber_models_eu.mondrian_quantiles_v2_h4
WHERE split = 'val'
GROUP BY fallback_level
ORDER BY n_obs DESC;

-- Check tuning effectiveness
SELECT
  seg2,
  tuned_coverage_target,
  calibb_viol_rate,
  calibb_gate_status
FROM cruzber_models_eu.segment_coverage_targets_v2_h4
ORDER BY calibb_gate_status, calibb_viol_rate;

-- Identify extreme SKUs
SELECT
  sku_id,
  cv_12w,
  volatility_bucket,
  n_obs_12w
FROM cruzber_models_eu.volatility_buckets_h4
ORDER BY cv_12w DESC
LIMIT 20;
```

**Fallback Plan**:
- Report current state as "Limitations" section in paper
- Claim: "Method achieves X% pass rate; remaining segments show heterogeneity requiring domain-specific priors"
- Position as "open challenge for community" (honest science)

---

## References for Writeup

1. **Conformal Prediction**:
   - Vovk, V., Gammerman, A., & Shafer, G. (2005). *Algorithmic Learning in a Random World*. Springer.
   - Angelopoulos, A. N., & Bates, S. (2021). A Gentle Introduction to Conformal Prediction and Distribution-Free Uncertainty Quantification. *arXiv:2107.07511*.

2. **Mondrian Conformal**:
   - Vovk, V. (2012). Conditional validity of inductive conformal predictors. *Machine Learning*.

3. **Lost-Sales Unconstraining**:
   - Kourentzes, N., & Trapero, J. R. (2018). The Bright Side of Retail Stockouts: Can Forecast Adjustments Correct Biases? *International Journal of Production Research*.

4. **Nested Cross-Validation**:
   - Varma, S., & Simon, R. (2006). Bias in error estimation when using cross-validation for model selection. *BMC Bioinformatics*.

---

## Reproducibility Checklist

- [x] All SQL deterministic (no RAND() without seed)
- [x] Version-controlled SQL files
- [x] Parameterized runner (project/dataset configurable)
- [x] ADC authentication (no hardcoded credentials)
- [x] Nested tuning uses proper holdout (CALIB_B ≠ VAL)
- [x] Gate criteria pre-specified (not data-driven)
- [x] Fallback logic explicit and documented
- [x] Execution log captures all stages
- [ ] **PENDING**: Actual execution results
- [ ] **PENDING**: Before/after comparison table
- [ ] **PENDING**: Final gate verdict

---

## Appendix: File Tree

```
sql/bqml/quantiles_v2/
├── 30_build_volatility_bucket.sql
├── 31_define_calibration_windows.sql
├── 32_mondrian_conformal_quantiles_v2.sql
├── 33_tune_segment_coverage_target.sql
└── 34_apply_targets_and_score_val.sql

sql/bqml/eval/
├── 40_eval_quantiles_conditional_v2.sql
└── 41_b3_fix_summary.sql

src/bq/
└── run_optionB_b3_fix.py

reports/
└── B3_fix_report_v2.md  (this file)
```

---

**End of Report**  
*Ready for execution. Proceed with caution and inspect results at each stage.*
