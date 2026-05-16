-- ============================================================================
-- PHASES 3-10: h12_v5 OOS State Layer Pipeline (COMPACT VERSION)
-- ============================================================================
-- This file contains all remaining phases in compact form
-- For production, each phase should be in separate file
-- ============================================================================

-- ============================================================================
-- PHASE 3: SCORE OOS STATE CANDIDATES ON DEV_TUNE
-- ============================================================================
/*
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_candidate_scores_dev_tune_h12_v5_strict` AS
WITH

dev_tune_data AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
  WHERE eval_split_v3 = 'DEV_TUNE'
),

candidates AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.oos_policy_candidates_h12_v5_strict`
),

scored AS (
  SELECT
    c.candidate_id,
    d.*,
    -- Component scores (0-1)
    LEAST(d.zero_run_length_capped / 12.0, 1.0) AS zero_run_component,
    LEAST(COALESCE(d.normalized_expected_demand_gap, 0.0), 1.0) AS expected_gap_component,
    COALESCE(d.historical_positive_rate_same_week, 0.0) AS historical_positive_component,
    CASE d.sku_season_state
      WHEN 'ALWAYS_ON' THEN 1.00
      WHEN 'IN_SEASON' THEN 0.80
      WHEN 'TRANSITION_UP' THEN 0.75
      WHEN 'TRANSITION_DOWN' THEN 0.60
      WHEN 'INTERMITTENT_RANDOM' THEN 0.50
      WHEN 'REST_OFFPEAK' THEN 0.35
      ELSE 0.20
    END AS season_state_component,
    LEAST(COALESCE(d.p_oos_h12, 0.0), 1.0) AS p_oos_component,
    CASE
      WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0
      ELSE LEAST(SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w), 1.0)
    END AS recent_drop_component,
    -- Compute p_suspected_oos_score_raw
    c.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
    + c.w2 * LEAST(COALESCE(d.normalized_expected_demand_gap, 0.0), 1.0)
    + c.w3 * COALESCE(d.historical_positive_rate_same_week, 0.0)
    + c.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 ELSE 0.20 END)
    + c.w5 * LEAST(COALESCE(d.p_oos_h12, 0.0), 1.0)
    + c.w6 * 0.5 AS p_suspected_oos_score_raw,
    -- p_true_zero_demand (heuristic)
    (d.historical_zero_rate_same_week + d.recent_zero_rate_12w) / 2.0 AS p_true_zero_demand,
    -- p_suspected_oos
    ((c.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
      + c.w2 * LEAST(COALESCE(d.normalized_expected_demand_gap, 0.0), 1.0)
      + c.w3 * COALESCE(d.historical_positive_rate_same_week, 0.0)
      + c.w4 * 0.5 + c.w5 * LEAST(COALESCE(d.p_oos_h12, 0.0), 1.0) + c.w6 * 0.5)
     * (1.0 - (d.historical_zero_rate_same_week + d.recent_zero_rate_12w) / 2.0)) AS p_suspected_oos,
    -- expected_lost_sales_if_oos
    ((c.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0) + c.w2 * LEAST(COALESCE(d.normalized_expected_demand_gap, 0.0), 1.0) + c.w3 * 0.5 + c.w4 * 0.5 + c.w5 * 0.5 + c.w6 * 0.5) * (1.0 - (d.historical_zero_rate_same_week + d.recent_zero_rate_12w) / 2.0))
    * GREATEST(d.yhat_p50_v3_2_12w - d.recent_mean_sales_4w, 0.0) AS expected_lost_sales_if_oos
  FROM dev_tune_data d
  CROSS JOIN candidates c
)

SELECT * FROM scored;
*/

-- SEE: 03_score_oos_state_candidates_dev_tune_h12_v5.sql (separate file)

-- ============================================================================
-- PHASE 4: EVAL OOS STATE CANDIDATES ON DEV_SELECT
-- ============================================================================
/*
Evaluate each candidate on DEV_SELECT:
- Compute rankings (global and by segment)
- Apply thresholds and top-N policies
- Compute precision@N, recall@N, lift@N
- Compute selection loss
- Save to: oos_candidate_eval_dev_select_h12_v5_strict
*/

-- SEE: 04_eval_oos_state_candidates_dev_select_h12_v5.sql

-- ============================================================================
-- PHASE 5: SELECT FROZEN OOS STATE POLICY
-- ============================================================================
/*
SELECT candidate with minimum selection_loss WHERE all validation checks pass.
Store in: frozen_oos_state_policy_h12_v5_strict
With flags:
- selected_using_split = 'DEV_SELECT'
- selected_without_locked_test = TRUE
- post_selection_bias = FALSE
*/

-- SEE: 05_select_frozen_oos_state_policy_h12_v5.sql

-- ============================================================================
-- PHASE 6: BUILD FINAL OOS STATE SCORES
-- ============================================================================
/*
Apply frozen policy to ALL data (DEV_TUNE, DEV_SELECT, LOCKED_TEST).
Generate final scores, rankings, recommended_action, reason_code.
Output: oos_state_scores_h12_v5_strict
*/

-- SEE: 06_build_final_oos_state_scores_h12_v5.sql

-- ============================================================================
-- PHASE 7: FINAL LOCKED_TEST OOS METRICS
-- ============================================================================
/*
Compute metrics on LOCKED_TEST only:
- precision@50/100/200
- recall@50/100/200
- lift@50/100/200
- alert_rate
- expected_lost_sales by top-N
- segment breakdowns
Output: final_locked_test_oos_metrics_h12_v5_strict
*/

-- SEE: 07_final_locked_test_oos_metrics_h12_v5.sql

-- ============================================================================
-- PHASE 8: COMPARE v3_2, v4_2, v5
-- ============================================================================
/*
Conceptual comparison table showing:
- v3_2 role: point forecast
- v4_2 role: quantile overlay
- v5 role: OOS state/alert layer
Output: compare_v3_2_v4_2_v5_h12_strict
*/

-- SEE: 08_compare_v3_2_v4_2_v5_h12.sql

-- ============================================================================
-- PHASE 99: LEAKAGE AUDIT
-- ============================================================================
/*
Audit checks (12+ checks):
1. Frozen policy exists
2. selected_using_split = 'DEV_SELECT'
3. selected_without_locked_test = TRUE
4. No LOCKED_TEST in calibration
5. No y_true_12w as feature
6. No stockout_event_12w as feature
7. zero_run uses only past
8. p_suspected_oos in [0,1]
9. p_true_zero_demand in [0,1]
10. audit_priority_score >= 0
11. All tables non-empty
12. VERDICT = PASS if all pass
Output: leakage_audit_h12_v5_strict
*/

-- SEE: 99_leakage_audit_h12_v5.sql

SELECT 'All phases defined. See individual phase files for complete SQL.' AS status;
