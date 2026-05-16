# h12_v5_2 Recall-Safe OOS Policy (Strict Anti-Leakage)

## Overview

`h12_v5_2_recall_safe_oos_policy_strict` is the **third additive layer** in the OOS detection stack.

| Layer | Version | Policy ID | Scope |
|-------|---------|-----------|-------|
| 1 | v5 | POLICY_E1 | Stable core: reliable demand signal |
| 2 | v5_1 | GATE_C_P3_Q3 | Difficult states: off-season, transition, intermittent |
| 3 | **v5_2** | **TBD (frozen on DEV_SELECT)** | Recall-safe: borderline cases not yet covered |

**v5_2 does not replace or modify v5 or v5_1.** POLICY_E1 and GATE_C_P3_Q3 remain frozen.

---

## Additive Design Principle

```
combined_oos_alert_v5_2 =
    is_stable_core_alert          (v5 POLICY_E1)
    OR is_difficult_state_alert_v5_1  (v5_1 GATE_C_P3_Q3)
    OR v5_2_recall_safe_alert     (v5_2 NEW)
```

**Strict no-overlap**: `v5_2_recall_safe_alert` is only set to TRUE when
`is_stable_core_alert = FALSE AND is_difficult_state_alert_v5_1 = FALSE`.

---

## Candidate Types (Phase 0)

Five categories of recall-safe candidates (first-match wins, priority order):

| Type | Condition | Rationale |
|------|-----------|-----------|
| `CORE_DIFFICULT_V5_1_LIKE` | zero_run ≥ 0.15, p_true_zero < 0.75 | Mirrors v5_1 definition for near-misses |
| `LONG_ZERO_RUN_WITH_OOS_PRIOR` | zero_run ≥ 0.30, p_true_zero < 0.85, p_oos ≥ 0.05 | Long runs with external OOS evidence |
| `EXPECTED_GAP_WITH_OOS_PRIOR` | exp_gap ≥ 0.50, p_true_zero < 0.85, p_oos ≥ 0.05 | Forecast gap with OOS prior |
| `ECONOMIC_RISK_NOT_STRUCTURAL_ZERO` | els ≥ 1.0, p_susp ≥ 0.03, p_true_zero < 0.90 | High economic cost, not structural zero |
| `HIGH_OOS_PRIOR_WITH_DEMAND` | p_oos ≥ 0.10, p_true_zero < 0.90, yhat ≥ 1.0 | Strong OOS prior, demand signal present |

All types require `oos_flag_v5 = 0 AND NOT is_difficult_state_alert_v5_1`.

---

## Scoring (Phase 1)

**Adaptive segmentation**: If a `(eval_split × season_group × candidate_type)` cell has ≥ 500 rows, use the fine segment `season_group::candidate_type`. Otherwise fall back to `season_group`.

**Three score formulas** (all [0,1] weighted percentile rank composites):

| Formula | Weights | Focus |
|---------|---------|-------|
| F1_BALANCED | 0.30 p_susp + 0.25 audit + 0.20 els + 0.15 p_oos + 0.10 yhat | Balanced |
| F2_RECALL_SAFE | 0.20 p_susp + 0.15 audit + 0.15 els + 0.30 p_oos + 0.20 gap | Recall / OOS prior |
| F3_ECONOMIC_RISK | 0.20 p_susp + 0.20 audit + 0.35 els + 0.15 yhat + 0.10 p_oos | Economic cost |

`quantile_spread_p90_component` (v4_2 diagnostic) is computed but **never used** in F1/F2/F3.

---

## Policy Grid (Phase 2) — 81 candidates

```
3 gates  ×  3 percentile configs  ×  3 quota configs  ×  3 formulas  =  81
```

| Gate | min_yhat | min_els | min_p_susp | min_p_oos | max_true_zero |
|------|----------|---------|------------|-----------|---------------|
| GATE_C_BASE | 1.0 | 0.25 | 0.01 | 0.01 | — |
| GATE_D_RECALL_SAFE | 0.5 | 0.10 | 0.005 | 0.005 | 0.90 |
| GATE_E_ECONOMIC | 1.0 | 1.0 | — | — | 0.90 |

| Percentile Config | pct_high_season | pct_rest |
|-------------------|-----------------|----------|
| P3_CURRENT | 0.870 | 0.850 |
| P4_RECALL | 0.830 | 0.800 |
| P5_EXPANDED | 0.800 | 0.750 |

| Quota Config | quota_high_season | quota_rest |
|--------------|-------------------|------------|
| Q3_CURRENT | 30 | 20 |
| Q4_RECALL | 60 | 40 |
| Q5_EXPANDED | 90 | 60 |

---

## Selection Protocol (Phases 3–4)

1. Evaluate all 81 candidates on **DEV_SELECT only** (never LOCKED_TEST)
2. Compute incremental metrics vs frozen v5_1 baseline
3. Apply validity filters (precision floor, FPR cap, stability, CV)
4. Select candidate with minimum `selection_loss`
5. Freeze the selected policy

**Selection loss formula:**
```
loss = -4.0 × incr_recall
     - 2.0 × incr_lift
     - 1.0 × incr_els / 1000
     + 2.0 × incr_fpr
     + 1.5 × instability_penalty
     + 2.0 × precision_floor_penalty
     + 1.0 × alert_volume_penalty
```

---

## LOCKED_TEST Access (Phases 6–9)

LOCKED_TEST is accessed **only after the policy is frozen** (Phase 4):

| Phase | Purpose | LOCKED_TEST role |
|-------|---------|-----------------|
| 5 | Apply frozen policy | Labels rows (no feedback) |
| 6 | Final metrics | Evaluation only |
| 7 | Verdict | Diagnostic output |
| 8 | Top alerts | Actionable list |
| 9 | Diagnostics | FN analysis only |

---

## Decision Verdicts (Phase 7)

| Verdict | Criteria |
|---------|----------|
| `PROMOTE_RECALL_SAFE_CONTROLLED` | incr_prec ≥ floor, comb_prec ≥ floor, lift ≥ 2.0, Δrecall ≥ 0.3pp, FPR ≤ 0.01 |
| `EXPERIMENTAL_RECALL_SAFE` | incr_prec ≥ 0.50, comb_prec ≥ floor, lift ≥ 1.5, Δrecall ≥ 0.1pp, FPR ≤ 0.02 |
| `KEEP_V5_1` | No valid candidates found, or 0 incremental alerts |
| `REJECT` | Any other outcome (fails quality bar) |

---

## Methodological Warning

> **v5_2 was designed after observing v5_1 LOCKED_TEST results.**
> This introduces potential look-ahead bias at the architecture level.
> The LOCKED_TEST verdict here is **directional evidence only**.
> Production deployment requires a **fresh holdout split or prospective evaluation**.

This caveat is embedded in the `methodological_caveat` column of
`incremental_uplift_analysis_h12_v5_2_strict` and in the frozen policy table.

---

## Anti-Leakage Audit (Phase 99)

20 checks targeting 0 FAIL, 0 WARNING:

| # | Check | Fix vs v5_1 |
|---|-------|-------------|
| 12 | Temporal ordering | Multi-year ISO W1-W53 allowed → PASS |
| 14 | Grid count | 81 = 3×3×3×3 expected → PASS |
| 17 | Three-layer no-overlap | New for v5_2 |
| 18 | selected_using_split field | New for v5_2 |
| 19 | Policy ID uniqueness | New for v5_2 |
| 20 | final_verdict enum | New for v5_2 |

---

## Running the Pipeline

```powershell
# Set encoding for emoji output
$env:PYTHONIOENCODING="utf-8"

# Dry-run (check files exist, no BQ execution)
python sql/bqml/h12_v5_2_recall_safe_oos_policy_strict/run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --dry-run

# Run all phases
python sql/bqml/h12_v5_2_recall_safe_oos_policy_strict/run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase all

# Run specific phase (bypass dependency prompt)
echo y | python sql/bqml/h12_v5_2_recall_safe_oos_policy_strict/run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase 3
```

---

## BigQuery Tables Created

| Table | Phase | Description |
|-------|-------|-------------|
| `base_scores_h12_v5_2_strict` | 0 | Base with v5, v5_1 flags and candidate types |
| `recall_safe_scored_h12_v5_2_strict` | 1 | Scores + gate flags for recall-safe candidates |
| `recall_safe_policy_candidates_h12_v5_2_strict` | 2 | 81-row parameter grid |
| `recall_safe_candidate_eval_dev_select_h12_v5_2_strict` | 3 | Metrics per candidate on DEV_SELECT |
| `frozen_recall_safe_policy_h12_v5_2_strict` | 4 | Frozen policy (1 row) |
| `combined_oos_alerts_h12_v5_2_strict` | 5 | Three-layer alerts, all splits |
| `final_locked_test_metrics_h12_v5_2_strict` | 6 | LOCKED_TEST metrics by segment |
| `incremental_uplift_analysis_h12_v5_2_strict` | 7 | Verdict table |
| `top_alerts_combined_h12_v5_2_strict` | 8 | Actionable alert lists |
| `diagnostics_recall_frontier_h12_v5_2_strict` | 9 | FN analysis |
| `leakage_audit_h12_v5_2_strict` | 99 | 20-check audit |
