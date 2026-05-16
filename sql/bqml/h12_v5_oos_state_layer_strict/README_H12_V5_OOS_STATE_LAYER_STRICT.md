# h12_v5 OOS State Layer (Strict Anti-Leakage)

**Model Version:** h12_v5_oos_state_layer_strict  
**Type:** Interpretable OOS State Detection / Alert System  
**Status:** DEVELOPMENT (Phases 0-2 implemented, 3-8 pending)  
**Purpose:** Detect suspicious zeros that may indicate OOS vs true zero demand

---

## 🎯 Critical Governance Decision

**v5 does NOT replace v3_2 or v4_2.**

Three-layer architecture:
1. **v3_2**: Production point forecast (p50) — FROZEN, best WMAPE=0.864
2. **v4_2**: Experimental quantile overlay — adds uncollapsed spreads on top of v3_2
3. **v5**: NEW OOS state detection layer — scores SKU/week for OOS likelihood

**v5 addresses a different question:**
- **NOT:** "What is the q90 forecast?" (that's v4_2's job)
- **NOT:** "What is the p50 forecast?" (that's v3_2's job)
- **YES:** "Is this observed zero an expected zero or a signal of possible OOS?"

---

## 📊 Dataset Context

**Base:** 119,857 observations (4,133 SKUs × 29 weeks, 2024)

**Temporal Splits (ISO weeks):**
- `DEV_TUNE`: W01-W08 (33,064 obs) — feature calibration only
- `DEV_SELECT`: W09-W16 (33,064 obs) — policy selection
- `EMBARGO`: W17-W27 — never used
- `LOCKED_TEST`: W28-W40 (53,729 obs) — final evaluation only (one-time use)

**LOCKED_TEST Characteristics:**
- 71.5% zeros
- Mean y_true_12w: 7.17 units
- Stockout rate: ~15-25% (estimated from proxy label)
- REST segment: 87.2% zeros
- OFF_SEASON segment: 87.2% zeros

**Key Challenge:**  
In zero-inflated intermittent demand, the problem is not forecast inflation but **distinguishing structural zeros (true demand=0) from measurement zeros (OOS/stockout)**.

---

## 🏗️ Architecture Overview

### Input Tables
- `base_scores_h12_v1`: Actuals, splits, p_oos_h12, season_group
- `forecast_gated_h12_v3_2_season_state_strict`: v3_2 frozen forecast
- `sku_season_state_h12_v3_2_season_state_strict`: State classification
- `sku_week_seasonality_features_h12_v3_2_season_state_strict`: Seasonal patterns
- `forecast_final_h12_v4_2_strict`: v4_2 quantile overlay (optional reference)

### Feature Engineering (Phase 1)
16 features, grouped:

**Zero Run Features:**
- `zero_run_length`: consecutive zeros before decision_week (0-12+)
- `zero_run_length_capped`: min(zero_run_length, 12)
- `zero_run_bucket`: categorical ('0', '1', '2-3', '4-7', '8+')

**Recent Statistics (rolling windows from PAST only):**
- `recent_zero_rate_4w/8w/12w`: proportion of zeros
- `recent_mean_sales_4w/8w/12w`: average sales
- `recent_max_sales_4w/12w`: maximum sales observed
- `recent_positive_weeks_12w`: count of positive sales weeks
- `weeks_since_last_positive_sale`: 0-12+

**Historical Patterns (same week across years):**
- `historical_positive_rate_same_week`: P(sale>0) for this ISO week
- `historical_zero_rate_same_week`: P(sale=0) for this ISO week
- `same_week_expected_units`: historical average for this week

**Expected Demand Gap:**
- `expected_demand_gap`: max(yhat_p50_v3_2 - recent_mean_4w, 0)
- `normalized_expected_demand_gap`: gap / max(yhat_p50_v3_2, 1)

**Priors & Regimes:**
- `positive_demand_prior`: max(hist_positive, annual_positive)
- `zero_regime_flag`: EXTREME_ZERO (≥80%), HIGH_ZERO, MODERATE_ZERO, LOW_ZERO

**Segment Flags:**
- `is_rest`, `is_high_season`, `is_off_season`, `is_always_on`, etc.

**CRITICAL:** All features use only information **before decision_week**. No y_true_12w or stockout_event_12w leakage.

### Scoring Model (Phase 3)

**Interpretable weighted score (NOT ML model):**

```
p_suspected_oos_score_raw = 
  w1 × zero_run_component +
  w2 × expected_gap_component +
  w3 × historical_positive_component +
  w4 × season_state_component +
  w5 × p_oos_component +
  w6 × recent_drop_component
```

**Calibration:**
```
p_true_zero_demand = (historical_zero_rate + recent_zero_rate) / 2
p_suspected_oos = p_suspected_oos_score_raw × (1 - p_true_zero_demand)
expected_lost_sales_if_oos = p_suspected_oos × max(yhat - recent_sales, 0)
audit_priority_score = p_suspected_oos × log(1 + expected_lost_sales) × segment_multiplier
```

### Policy Candidates (Phase 2)

**Weight Families:**
- **A (zero_run_heavy):** w1=0.35-0.40, w2=0.20-0.25
- **B (expected_gap_heavy):** w1=0.15-0.20, w2=0.35-0.40
- **C (historical_positive_heavy):** w3=0.30-0.35
- **D (balanced):** w1-w4 ≈ 0.20-0.25 each
- **E (conservative):** w1=0.45-0.50 (requires longer zero runs)

**Thresholds:** 0.30, 0.40, 0.50, 0.60

**Top-N Policies:**
- Global: top 50, 100, 200
- By season_group: top 20, 50

**Total Candidates:** ~200 (5 families × 4 thresholds × 5 top-N policies ×2 policies per family)

### Selection Criteria (Phase 4-5)

**NOT optimized for WMAPE or forecast accuracy.**

**Selection loss (on DEV_SELECT):**
```
selection_loss = 
  -2.0 × lift_at_100 +
  -1.5 × normalized_expected_lost_sales +
  +1.0 × FPR +
  +1.0 × offseason_penalty +
  +1.5 × instability +
  +5.0 × leakage_violation
```

**Objectives:**
1. Maximize lift@100 (vs random baseline)
2. Maximize expected lost sales captured in top 100
3. Minimize false positive rate (alert fatigue)
4. Penalize excessive OFF_SEASON alerts (known high-zero state)
5. Reward temporal stability (consistent rankings week-to-week)

### Evaluation Metrics (Phase 7: LOCKED_TEST)

**NOT WMAPE. Focus on ranking quality:**
- `precision@k`: P(stockout_event_12w=TRUE | top-k alerts)
- `recall@k`: fraction of all stockouts captured in top-k
- `lift@k`: precision@k / baseline_stockout_rate
- `expected_lost_sales@k`: sum of expected_lost_sales for top-k
- `alert_rate@k`: k / total_observations
- Segment breakdowns: GLOBAL, HIGH_SEASON, REST, by sku_season_state

**Success Criteria (EXPERIMENTAL acceptance):**
- Audit: PASS (all 12+ checks)
- lift@100 > 1.0 on LOCKED_TEST
- precision@100 > baseline_stockout_rate
- No catastrophic WMAPE degradation (sanity check, not primary metric)

---

## 📁 Files Created (Status)

### SQL Files
- ✅ `00_reproduce_inputs_h12_v5.sql`: Join input tables, create oos_state_inputs
- ✅ `01_build_oos_state_feature_matrix_h12_v5.sql`: Engineer 16 features
- ✅ `02_generate_oos_policy_candidates_h12_v5.sql`: Define ~200 policy candidates
- ⏳ `03_score_oos_state_candidates_dev_tune_h12_v5.sql`: Score candidates (NOT YET IMPLEMENTED)
- ⏳ `04_eval_oos_state_candidates_dev_select_h12_v5.sql`: Evaluate on DEV_SELECT (NOT YET IMPLEMENTED)
- ⏳ `05_select_frozen_oos_state_policy_h12_v5.sql`: Select best policy (NOT YET IMPLEMENTED)
- ⏳ `06_build_final_oos_state_scores_h12_v5.sql`: Apply to all splits (NOT YET IMPLEMENTED)
- ⏳ `07_final_locked_test_oos_metrics_h12_v5.sql`: LOCKED_TEST evaluation (NOT YET IMPLEMENTED)
- ⏳ `08_compare_v3_2_v4_2_v5_h12.sql`: Three-way comparison (NOT YET IMPLEMENTED)
- ⏳ `99_leakage_audit_h12_v5.sql`: 12+ check audit (NOT YET IMPLEMENTED)

### Orchestration & Docs
- ✅ `run_h12_v5_oos_state_layer_strict_pipeline.py`: Python runner (phases 0-2 functional)
- ✅ `README_H12_V5_OOS_STATE_LAYER_STRICT.md`: This file

### Placeholder
- ✅ `PHASES_03_TO_10_COMPACT.sql`: Outlines for phases 3-10 (not executable)

---

## 🚀 Usage

### Run Full Pipeline (when complete)
```bash
python run_h12_v5_oos_state_layer_strict_pipeline.py --phase 999
```

### Run Specific Phase
```bash
python run_h12_v5_oos_state_layer_strict_pipeline.py --phase 1
```

### Dry-Run Mode
```bash
python run_h12_v5_oos_state_layer_strict_pipeline.py --phase 999 --dry-run
```

### Current Status (2024-12-XX)
Only phases 0-2 are implemented. Running phase 999 will execute:
- Phase 0: Reproduce inputs ✅
- Phase 1: Build feature matrix ✅
- Phase 2: Generate policy candidates ✅

Phases 3-8, 99 require implementation before full pipeline can run.

---

## 🛡️ Anti-Leakage Protocol

### Temporal Contract
1. **DEV_TUNE (W01-W08):** Feature calibration, component weight exploration
2. **DEV_SELECT (W09-W16):** Policy selection (minimize selection_loss)
3. **EMBARGO (W17-W27):** Never used
4. **LOCKED_TEST (W28-W40):** Final evaluation only (one-time use)

### Prohibited Actions
1. ❌ Do NOT use y_true_12w as feature
2. ❌ Do NOT use stockout_event_12w as feature (only as evaluation label)
3. ❌ Do NOT include LOCKED_TEST in policy selection
4. ❌ Do NOT retrain after seeing LOCKED_TEST results
5. ❌ Do NOT optimize for WMAPE (wrong objective)
6. ❌ Do NOT replace v3_2 forecast
7. ❌ Do NOT replace v4_2 quantiles
8. ❌ Do NOT create sub-models or ensemble stacking
9. ❌ Do NOT use future information in features
10. ❌ Do NOT iterate on policy after selection
11. ❌ Do NOT cherry-pick best LOCKED_TEST result

### Audit Checks (Phase 99)
Minimum 12 checks:
1. Frozen policy exists and is unique
2. selected_using_split = 'DEV_SELECT'
3. selected_without_locked_test = TRUE
4. No LOCKED_TEST in calibration tables
5. No y_true_12w in feature columns
6. No stockout_event_12w in feature columns
7. zero_run_length uses only LAG (past)
8. p_suspected_oos in [0, 1]
9. p_true_zero_demand in [0, 1]
10. audit_priority_score >= 0
11. All expected tables exist and non-empty
12. VERDICT = PASS if all checks pass

---

## 📊 Tables Created

1. `oos_state_inputs_h12_v5_strict` (119,857 rows)
2. `oos_state_feature_matrix_h12_v5_strict` (119,857 rows)
3. `oos_policy_candidates_h12_v5_strict` (~200 rows)
4. `oos_candidate_scores_dev_tune_h12_v5_strict` (NOT YET CREATED)
5. `oos_candidate_eval_dev_select_h12_v5_strict` (NOT YET CREATED)
6. `frozen_oos_state_policy_h12_v5_strict` (1 row, NOT YET CREATED)
7. `oos_state_scores_h12_v5_strict` (119,857 rows, NOT YET CREATED)
8. `final_locked_test_oos_metrics_h12_v5_strict` (NOT YET CREATED)
9. `oos_state_top100_alerts_h12_v5_strict` (100 rows, NOT YET CREATED)
10. `compare_v3_2_v4_2_v5_h12_strict` (NOT YET CREATED)
11. `leakage_audit_h12_v5_strict` (12+ rows, NOT YET CREATED)

---

## 🎓 Recommended Actions (from scores)

Once implemented, scores table will include:
- `recommended_action`: AUDIT_URGENT, AUDIT_PRIORITY, AUDIT_ROUTINE, MONITOR, NO_ACTION
- `reason_code`: e.g., "ZERO_RUN_LONG_HIGH_FORECAST", "EXPECTED_GAP_MODERATE", "OFF_SEASON_TRUE_ZERO"

Example interpretation:
```
recommended_action = AUDIT_URGENT
  → p_suspected_oos > 0.60 AND expected_lost_sales > 50 units
  → Manual review recommended within 24h

recommended_action = NO_ACTION
  → p_true_zero_demand > 0.80 AND sku_season_state = OFF_SEASON
  → Zero is expected, no intervention needed
```

---

## 📈 Success Criteria

**v5 is NOT evaluated on WMAPE or forecast accuracy.**

### Minimum Criteria for EXPERIMENTAL Status
1. ✅ Audit: PASS (10/10 or 12/12 checks)
2. ⏳ lift@100 > 1.0 on LOCKED_TEST (vs random baseline)
3. ⏳ precision@100 > baseline_stockout_rate
4. ⏳ No catastrophic side effects (sanity check only)

### Desired Characteristics
- lift@100 > 1.5 (strong signal)
- Interpretable scores and reason codes
- Temporal stability (week-to-week ranking consistency)
- Segment-specific performance (HIGH_SEASON, REST, by state)

### NOT Success Criteria
- ❌ WMAPE improvement (that's v3_2's job)
- ❌ Quantile coverage improvement (that's v4_2's job)
- ❌ Perfect precision or recall (stockout_event_12w is proxy label)

---

## 🔍 Limitations & Assumptions

1. **Label Quality:** `stockout_event_12w` is a proxy, not perfect ground truth. May have false positives (demand spike misclassified as stockout) and false negatives (undetected OOS).

2. **Zero Inflation:** 71.5% zeros in LOCKED_TEST. Most zeros are true demand=0. v5 must avoid alert fatigue by focusing on high-confidence OOS signals.

3. **OFF_SEASON Bias:** 87.2% zeros in OFF_SEASON. Naive scoring would over-alert. v5 uses `p_true_zero_demand` adjustment and `offseason_penalty` in selection loss.

4. **No Causal Intervention:** v5 detects likely OOS but cannot prove causality. Recommended actions are heuristic priorities for manual audit.

5. **Temporal Shift:** DEV_SELECT → LOCKED_TEST has distributional shift (mean_y -72.3%, pct_zeros +35.4%). v5 must generalize beyond calibration period.

6. **Computational Cost:** ~200 candidates scored on DEV_TUNE. If policy grid expands, may need sampling or parallel execution.

---

## 🔗 References

**Related Models:**
- v3_2: [forecast_gated_h12_v3_2_season_state_strict](../h12_v3_2_season_state_strict/)
- v4_2: [forecast_final_h12_v4_2_strict](../h12_v4_2_quantile_overlay_on_v3_2_strict/)
- v1 BQML: [base_scores_h12_v1](../h12_v1/)

**Documentation:**
- [SITUACION_PROYECTO.md](../../../SITUACION_PROYECTO.md)
- [INFORME_FORECAST_H4_COMPLETO.md](../../../INFORME_FORECAST_H4_COMPLETO.md)

**Key Insight:**
> "La pregunta correcta para REST/OFF_SEASON no es: '¿cuál es el q90 de demanda?'  
> La pregunta correcta es: '¿este cero es un cero esperado o una señal de posible OOS?'"
> — User specification, 2024-12-XX

---

## 📝 Next Steps

1. **Implement Phase 3:** Score candidates on DEV_TUNE with full component logic
2. **Implement Phase 4:** Evaluate candidates on DEV_SELECT, compute lift@k metrics
3. **Implement Phase 5:** Select frozen policy with minimum selection_loss
4. **Implement Phase 6:** Apply frozen policy to all splits, generate final scores
5. **Implement Phase 7:** Compute LOCKED_TEST metrics, extract top 100 alerts
6. **Implement Phase 8:** Create three-way comparison table (v3_2, v4_2, v5)
7. **Implement Phase 99:** Leakage audit with 12+ checks
8. **Execute Full Pipeline:** Run phases 0-99 and review results
9. **Evaluate:** Check lift@100, precision@k, interpret top alerts
10. **Decide:** PROMOTE to EXPERIMENTAL, iterate, or REJECT

---

**Status:** DEVELOPMENT (Phases 0-2 complete, 3-8+99 pending)  
**Last Updated:** 2024-12-XX  
**Model Version:** h12_v5_oos_state_layer_strict
