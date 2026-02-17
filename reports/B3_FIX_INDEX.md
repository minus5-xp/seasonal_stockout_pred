# B3 Gate Fix v2 - Implementation Index

## Overview
Complete implementation of paper-grade solution to fix Gate B3 (conditional coverage) using:
- Volatility-aware Mondrian conformal prediction
- Hierarchical fallback for sparse segments
- Nested tuning on CALIB_B (never touches VAL)

---

## File Structure

### SQL Pipeline (7 files)

#### Stage 1: Feature Engineering
- **30_build_volatility_bucket.sql**
  - Computes CV (coefficient of variation) per SKU
  - Assigns 4-bin stratification: LOW_VOL / MED_VOL / HIGH_VOL / EXTREME_VOL
  - Output: `volatility_buckets_h4`

#### Stage 2: Calibration Management
- **31_define_calibration_windows.sql**
  - Splits 26-week calibration into:
    - CALIB_A (first 13w): score estimation
    - CALIB_B (last 13w): nested tuning
  - Joins volatility buckets
  - Output: `calibration_windows_h4` with `split_refined`

#### Stage 3: Conformal Quantiles
- **32_mondrian_conformal_quantiles_v2.sql**
  - Hierarchical segmentation: seg3 → seg2 → seg1 → global
  - Fallback logic: N_MIN thresholds (200/150/100)
  - Computes qhat_p90 per segment from CALIB_A
  - Output: `mondrian_quantiles_v2_h4`

#### Stage 4: Hyperparameter Tuning
- **33_tune_segment_coverage_target.sql**
  - Grid search over coverage_target ∈ [0.88, 0.98]
  - Optimizes per seg2 (season × HHI) using CALIB_B
  - Selects target minimizing |viol_rate - 0.10|
  - Output: `segment_coverage_targets_v2_h4`

#### Stage 5: VAL Scoring
- **34_apply_targets_and_score_val.sql**
  - Applies tuned targets to VAL split
  - Generates pred_p90, pred_p95
  - Evaluates coverage flags
  - Output: `pred_quantiles_v2_h4`

#### Stage 6: Evaluation
- **40_eval_quantiles_conditional_v2.sql**
  - Computes conditional violation rates per segment
  - Measures sharpness, pinball loss
  - Gate check: viol_rate ∈ [0.08, 0.12]
  - Output: `eval_quantiles_conditional_v2_h4`

- **41_b3_fix_summary.sql**
  - Global + seg2 summary
  - PASS/FAIL verdicts
  - Output: `b3_fix_gate_summary_h4`

---

### Python Runner

- **src/bq/run_optionB_b3_fix.py**
  - Orchestrates 7 SQL files in sequence
  - Queries gate summary
  - Prints detailed verdict with segment breakdown
  - Exit code: 0 (PASS) / 1 (FAIL)

---

### Documentation

- **reports/B3_fix_report_v2.md**
  - Complete methodology explanation
  - Execution instructions
  - Expected outcomes (scenarios A/B/C)
  - Diagnostic queries for troubleshooting
  - References for paper writeup
  - Reproducibility checklist

- **reports/B3_FIX_INDEX.md** (this file)
  - Quick reference for navigating implementation

---

## Execution Command

```bash
conda run -n jupyter-ai python src/bq/run_optionB_b3_fix.py \
  --project-id thequantitativeledger \
  --dataset-id cruzber_models_eu \
  --location EU \
  --verbose
```

---

## Key Design Principles

1. **Nested holdout discipline**: CALIB_B tuning never contaminates VAL
2. **Hierarchical fallback**: Graceful degradation for sparse segments
3. **Reproducibility**: Pure SQL, deterministic, no hardcoded credentials
4. **Publishability**: Methods align with conformal prediction literature
5. **Transparency**: All decisions pre-specified, not data-driven

---

## Success Criteria

**Gate B3 PASS**: All seg2 segments (season × HHI) achieve conditional violation rate ∈ [8%, 12%]

**Target segments**:
- HIGH_SEASON|HIGH
- HIGH_SEASON|LOW
- HIGH_SEASON|MEDIUM
- REST|HIGH
- REST|LOW (largest segment, 66% of data)
- REST|MEDIUM

---

## Troubleshooting Guide

### If gate still fails:

1. **Check fallback distribution**:
   ```sql
   SELECT fallback_level, COUNT(*) 
   FROM cruzber_models_eu.mondrian_quantiles_v2_h4 
   WHERE split='val' GROUP BY 1;
   ```
   - If too much "global" → lower N_MIN thresholds

2. **Check tuning effectiveness**:
   ```sql
   SELECT seg2, tuned_coverage_target, calibb_viol_rate
   FROM cruzber_models_eu.segment_coverage_targets_v2_h4;
   ```
   - If CALIB_B rates outside [8%,12%] → expand grid search range

3. **Check volatility distribution**:
   ```sql
   SELECT volatility_bucket, COUNT(*) 
   FROM cruzber_models_eu.volatility_buckets_h4 
   GROUP BY 1;
   ```
   - If too unbalanced → adjust quartile computation or use fixed thresholds

---

## Next Steps After Execution

### If PASS ✅:
1. Update `submission_readiness_h4` table
2. Rerun B4 policy simulation with new quantiles
3. Generate final submission report
4. Prepare paper figures (coverage plots, ablation tables)

### If FAIL ❌:
1. Run diagnostic queries (see B3_fix_report_v2.md)
2. Review fallback rates and tuning outcomes
3. Consider alternative strategies:
   - Lower N_MIN thresholds
   - Add product category dimension
   - Expand calibration window to 39 weeks
   - Implement adaptive α adjustment

---

**End of Index**
