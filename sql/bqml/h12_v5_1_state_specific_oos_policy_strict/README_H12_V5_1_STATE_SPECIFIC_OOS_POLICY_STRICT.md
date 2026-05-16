# h12_v5_1: State-Specific OOS Policy (Additive Difficult State Layer)

## 🎯 Executive Summary

**h12_v5_1** is an **ADDITIVE** OOS detection layer on top of **h12_v5 (POLICY_E1)**, specifically targeting difficult states where the frozen POLICY_E1 has zero flags despite ~12,000 true OOS events.

- **Stable Core**: POLICY_E1 (h12_v5) remains frozen and unchanged
- **Additive Layer**: New difficult state policy for OFF_SEASON, TRANSITION_UP, TRANSITION_DOWN, INTERMITTENT_RANDOM
- **Combination**: `combined_alert = stable_core_alert OR difficult_state_alert`
- **Anti-Leakage**: Policy selected on DEV_SELECT, evaluated once on LOCKED_TEST

---

## 📊 Problem Statement

### Difficult States (Zero Flags in POLICY_E1)

| State | Observations | True OOS | POLICY_E1 Flags | Coverage Gap |
|-------|-------------|----------|----------------|--------------|
| OFF_SEASON | 30,846 (57.4%) | ~7,000 | **0** | 0% |
| TRANSITION_UP | 1,773 (3.3%) | ~2,500 | **0** | 0% |
| TRANSITION_DOWN | 2,381 (4.4%) | ~2,000 | **0** | 0% |
| INTERMITTENT_RANDOM | 499 (0.9%) | ~500 | **0** | 0% |
| **Total Difficult** | **35,499 (66%)** | **~12,000** | **0** | **0%** |

**POLICY_E1 Characteristics:**
- Works well on high-signal states (IN_SEASON, RAMP_UP, etc.)
- Zero-run-based features ineffective in high-zero states
- Gap-based features diluted by extreme structural zeros
- Missed opportunities: ~12,000 true OOS events undetected

---

## 🏗️ Architecture

### Dual-Policy Design

```
┌─────────────────────────────────────────────────────────────┐
│                    h12_v5_1 Architecture                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────┐      ┌─────────────────────────┐ │
│  │  Stable Core Policy  │      │ Difficult State Policy   │ │
│  │   (POLICY_E1, v5)    │      │   (v5_1, NEW)           │ │
│  │                      │      │                         │ │
│  │  • Frozen weights    │      │  • Intra-state ranking  │ │
│  │  • Zero-run focus    │      │  • Weekly quotas        │ │
│  │  • Gap-based         │      │  • State-specific %ile  │ │
│  │  • Works on signal   │      │  • Targets high-zero    │ │
│  └──────────────────────┘      └─────────────────────────┘ │
│            │                              │                 │
│            └──────────┬───────────────────┘                 │
│                       ▼                                     │
│             ┌──────────────────┐                            │
│             │  Combined Alert  │                            │
│             │  (OR logic)      │                            │
│             └──────────────────┘                            │
│                                                              │
│  No overlap by design: difficult_state_candidates exclude   │
│  stable_core_alerts                                          │
└─────────────────────────────────────────────────────────────┘
```

### Difficult State Scoring Logic

For observations in difficult states NOT flagged by POLICY_E1:

1. **Apply Gates** (3 options: conservative/moderate/exploratory)
   - Min `yhat_p50`, `expected_lost_sales_if_oos`, `p_suspected_oos`, `p_oos`

2. **Compute Intra-State Percentile Ranks**
   ```sql
   PERCENT_RANK() OVER (
     PARTITION BY eval_split_v3, sku_season_state
     ORDER BY component_score
   )
   ```
   - Components: `p_suspected_oos`, `audit_priority_score`, `expected_lost_sales_if_oos`, `p_oos`, `yhat_p50`

3. **Composite Difficult State Score**
   ```
   difficult_state_score = 
     0.30 × pr_p_suspected_oos_state +
     0.25 × pr_audit_priority_state +
     0.20 × pr_expected_lost_sales_state +
     0.15 × pr_p_oos_state +
     0.10 × pr_yhat_p50_state
   ```

4. **Percentile Threshold** (state-specific, 3 configs)
   - OFF_SEASON: P99.5 / P99.0 / P98.5
   - TRANSITION: P99.0 / P98.0 / P95.0
   - INTERMITTENT: P99.5 / P99.0 / P98.0

5. **Weekly Quota** (top-K within state + week, 3 configs)
   - Conservative: 5 / 3 / 3 / 2 per week
   - Moderate: 10 / 5 / 5 / 3
   - Exploratory: 20 / 10 / 10 / 5

### Grid Search: 81 Candidates

- 3 **Gate Sets** (A, B, C)
- 3 **Percentile Configs** (P1, P2, P3) × 4 states = 12 rows
- 3 **Quota Configs** (Q1, Q2, Q3) × 4 states = 12 rows
- **Total**: 3 × 3 × 3 = **81 candidates**

### Selection Criterion

Minimize `selection_loss` on **DEV_SELECT** only:

```python
selection_loss = (
    2.0 - incremental_lift
    - 1.5 × (incremental_expected_lost_sales / 1000.0)
    - 1.0 × incremental_recall
    + 1.0 × incremental_fpr × 100.0
    + alert_volume_penalty
    + low_precision_penalty
    + instability_penalty
)
```

**LOCKED_TEST never used for selection.**

---

## 🚀 Usage

### Prerequisites

1. **BigQuery Access**
   - Project: `thequantitativeledger`
   - Dataset: `cruzber_models_eu`
   - Location: `EU`

2. **Input Tables** (from h12_v5)
   - `oos_final_scores_h12_v5_strict` (119,857 rows)
   - `oos_frozen_policy_h12_v5_strict` (POLICY_E1 specification)

3. **Python Environment**
   ```bash
   pip install google-cloud-bigquery
   gcloud auth application-default login
   ```

### Run Full Pipeline

```bash
cd sql/bqml/h12_v5_1_state_specific_oos_policy_strict

# Full pipeline (all phases)
python run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py

# Dry-run (see execution plan)
python run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py --dry-run

# Run specific phase
python run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py --phase 3
```

### Pipeline Phases

| Phase | File | Description | Output Table |
|-------|------|-------------|--------------|
| **0** | `00_prepare_v5_1_base_scores.sql` | Reproduce v5 scores + flags | `base_scores_h12_v5_1_strict` |
| **1** | `01_build_difficult_state_scores_h12_v5_1.sql` | Intra-state percentile ranks | `difficult_state_scored_h12_v5_1_strict` |
| **2** | `02_generate_difficult_policy_candidates_h12_v5_1.sql` | 81-candidate grid | `difficult_state_policy_candidates_h12_v5_1_strict` |
| **3** | `03_eval_difficult_candidates_dev_select_h12_v5_1.sql` | Evaluate on DEV_SELECT | `difficult_state_candidate_eval_dev_select_h12_v5_1_strict` |
| **4** | `04_select_frozen_difficult_policy_h12_v5_1.sql` | Select best (min loss) | `frozen_difficult_state_policy_h12_v5_1_strict` |
| **5** | `05_build_combined_oos_alerts_h12_v5_1.sql` | Apply to all splits | `combined_oos_alerts_h12_v5_1_strict` |
| **6** | `06_final_locked_test_metrics_h12_v5_1.sql` | LOCKED_TEST metrics | `final_locked_test_metrics_h12_v5_1_strict` |
| **7** | `07_incremental_uplift_analysis_h12_v5_1.sql` | Decision verdict | `incremental_uplift_analysis_h12_v5_1_strict` |
| **8** | `08_top_alerts_combined_h12_v5_1.sql` | Top actionable alerts | `top_alerts_combined_h12_v5_1_strict` |
| **99** | `99_leakage_audit_h12_v5_1.sql` | Anti-leakage checks | `leakage_audit_h12_v5_1_strict` |

### Phase Dependencies

```
Phase 0 (base scores)
  ↓
Phase 1 (difficult state scores)
  ↓
Phase 2 (candidate grid)
  ↓
Phase 3 (evaluate on DEV_SELECT) ← depends on 0, 1, 2
  ↓
Phase 4 (select frozen policy)
  ↓
Phase 5 (apply to all data) ← depends on 0, 1, 2, 4
  ↓
Phase 6 (LOCKED_TEST metrics)
  ↓
Phase 7, 8 (analysis, top alerts)
  ↓
Phase 99 (leakage audit) ← depends on all
```

---

## 📋 Interpretation Guide

### Phase 7: Decision Verdict

After pipeline completion, check the decision verdict:

```sql
SELECT
  decision_verdict,
  verdict_reasoning,
  recommendation,
  incremental_precision,
  incremental_recall,
  incremental_lift,
  incremental_alerts,
  incremental_els
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`;
```

#### Verdict Options

| Verdict | Meaning | Action |
|---------|---------|--------|
| **PROMOTE_ADDITIVE** | Strong incremental value (precision ≥1.5× base, recall ≥5%, ELS ≥100, stable) | Deploy to production |
| **EXPERIMENTAL_ADDITIVE** | Moderate value (precision ≥ base, recall ≥2%, ELS ≥50) | Test in shadow mode |
| **REJECT_ADDITIVE** | No value or harmful (precision < base, <5 TPs, <20 ELS) | Do not deploy |
| **KEEP_STABLE_ONLY** | Does not meet criteria | Keep h12_v5 only |

### Phase 99: Anti-Leakage Audit

```sql
SELECT
  check_name,
  check_status,
  check_value,
  check_description
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict`
WHERE check_status = 'FAIL';
```

**Expected**: All checks should be `PASS` or `WARNING`. Any `FAIL` indicates a critical anti-leakage violation.

### Key Metrics (Global, LOCKED_TEST)

```sql
SELECT
  n_obs,
  n_true_oos,
  
  -- Stable (v5 POLICY_E1)
  n_stable_alerts,
  stable_precision,
  stable_recall,
  stable_lift,
  
  -- Incremental (v5_1 difficult state)
  incremental_alerts,
  difficult_precision,
  difficult_recall,
  difficult_lift,
  incremental_els,
  
  -- Combined
  combined_alerts,
  combined_precision,
  combined_recall,
  combined_lift
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
WHERE segment_type = 'GLOBAL';
```

---

## 🔒 Anti-Leakage Framework

### Guarantees

1. ✅ Policy selected on **DEV_SELECT** only (Weeks 09-16)
2. ✅ **LOCKED_TEST** (Weeks 28-40) used only for final evaluation (one-time)
3. ✅ `PERCENT_RANK()` partitioned by `eval_split_v3` (no cross-split contamination)
4. ✅ No post-selection optimization
5. ✅ Temporal ordering preserved (no future information)
6. ✅ Frozen policy applied identically to all splits

### Verification

Phase 99 performs 16 checks:
- Policy selection split (must be DEV_SELECT)
- Post-selection bias flag (must be FALSE)
- Candidate evaluation split (must be DEV_SELECT only)
- Alert overlap (must be 0 by construction)
- Row count consistency
- Temporal ordering
- Model version consistency

**If Phase 99 FAILS**: Do not use results. Review errors and re-run from Phase 0.

---

## 🎯 Decision Criteria

### When to Deploy v5_1

#### ✅ PROMOTE_ADDITIVE (Production Deployment)
- Incremental precision ≥ 1.5× base rate
- Incremental recall ≥ 5 percentage points
- Incremental ELS ≥ 100 units
- Weekly alert volume stable (CV < 0.5)
- No contamination of stable core alerts

#### ⚠️ EXPERIMENTAL_ADDITIVE (Shadow Mode Testing)
- Incremental precision ≥ base rate
- Incremental recall ≥ 2 percentage points
- Incremental ELS ≥ 50 units
- Monitor for 2-4 weeks before full rollout

#### ❌ REJECT_ADDITIVE (Do Not Deploy)
- Incremental precision < base rate (noise)
- Fewer than 5 incremental TPs (insufficient evidence)
- Incremental ELS < 20 units (not actionable)
- High false positive rate diluting audit resources

#### 🔄 KEEP_STABLE_ONLY (Status Quo)
- None of the above criteria met
- Stable core (POLICY_E1) sufficient

---

## 📂 Output Tables

### Production-Ready Tables

1. **`combined_oos_alerts_h12_v5_1_strict`** (119,857 rows)
   - All observations with combined alerts (stable + difficult)
   - Fields: `combined_oos_alert`, `alert_source`, `is_stable_core_alert`, `is_difficult_state_alert`

2. **`frozen_difficult_state_policy_h12_v5_1_strict`** (1 row)
   - Selected policy parameters
   - DEV_SELECT performance metrics
   - Metadata: `selected_without_locked_test=TRUE`

3. **`final_locked_test_metrics_h12_v5_1_strict`** (multiple rows)
   - Segmented metrics (global, season_group, state)
   - Incremental and combined performance

4. **`top_alerts_combined_h12_v5_1_strict`**
   - Ranked actionable alerts for LOCKED_TEST
   - Top-50, Top-100, Top-200, Top-500, Top-1000 flags

### Audit Tables

5. **`leakage_audit_h12_v5_1_strict`** (16 rows)
   - 16 anti-leakage checks
   - Final verdict: PASS/FAIL

6. **`incremental_uplift_analysis_h12_v5_1_strict`** (1 row)
   - Decision verdict: PROMOTE / EXPERIMENTAL / REJECT / KEEP_STABLE_ONLY
   - Detailed reasoning and recommendations

---

## 🔧 Troubleshooting

### Common Issues

#### Issue: "Missing dependencies for Phase X"
**Solution**: Run phases in order starting from Phase 0, or run `--phase all`

#### Issue: "Policy selected using LOCKED_TEST"
**Solution**: Critical anti-leakage violation. Re-run from Phase 0. Do NOT use results.

#### Issue: "Candidate count ≠ 81"
**Solution**: Check Phase 2 SQL. Grid should be 3×3×3 = 81 rows.

#### Issue: "Incremental alerts = 0"
**Solution**: Gates may be too strict, or percentile thresholds too high. Review Phase 3 candidate evaluation.

### Performance Tips

- **Dry-run first**: `--dry-run` to verify SQL files exist and see execution plan
- **Run phases incrementally**: Test Phases 0-2 before running expensive Phase 3
- **Monitor BigQuery costs**: Phase 3 and 5 process most data (~5-10 GB total pipeline)

---

## 📚 References

### Related Models

- **h12_v3_2**: Seasonal state classifier (9 states)
- **h12_v4_2**: Quantile regression overlay (NOT used in v5_1)
- **h12_v5**: POLICY_E1 (frozen stable core, 6-component weighted policy)

### Key Documents

- `RESUMEN_EJECUTIVO_H12_V4_QR_RESULTADOS.md`: h12_v4_2 results
- `SITUACION_PROYECTO.md`: Overall project status
- `sql/bqml/h12_v5_oos_state_layer_strict/README.md`: h12_v5 documentation

---

## 📝 Notes

- **v5_1 is ADDITIVE**: Does not modify v3_2, v4_2, or v5
- **Frozen v5 (POLICY_E1)**: Remains unchanged and untouched
- **No overlap**: Difficult state candidates explicitly exclude stable core alerts
- **One-time LOCKED_TEST**: Used only for final evaluation, never for optimization
- **Production deployment**: Requires PROMOTE_ADDITIVE or EXPERIMENTAL_ADDITIVE verdict from Phase 7

---

## 🤝 Contributing

For questions or issues:
1. Review Phase 99 anti-leakage audit results
2. Check Phase 7 decision verdict and reasoning
3. Consult LOCKED_TEST metrics (Phase 6)
4. Verify all 16 anti-leakage checks pass

**Critical**: Never re-run Phase 4 (policy selection) after viewing LOCKED_TEST results. This violates anti-leakage guarantees.

---

**Version**: h12_v5_1_state_specific_oos_policy_strict  
**Last Updated**: 2024  
**License**: Internal Cruzber Models  
**Contact**: Hugo de Val Roig
