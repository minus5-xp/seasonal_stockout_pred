-- ============================================================================
-- PHASE 4: EVAL OOS STATE CANDIDATES ON DEV_SELECT (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Evaluate all policy candidates using DEV_SELECT holdout data.
--   Compute precision@k, recall@k, lift@k metrics.
--   Flag candidates exceeding top_n constraints.
--
-- INPUTS:
--   - oos_state_feature_matrix_h12_v5_strict (DEV_SELECT only)
--   - oos_policy_candidates_h12_v5_strict
--
-- OUTPUTS:
--   - oos_candidate_evaluation_dev_select_h12_v5_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_candidate_evaluation_dev_select_h12_v5_strict` AS
WITH

dev_select_data AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
  WHERE eval_split_v3 = 'DEV_SELECT'
),

candidates AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.oos_policy_candidates_h12_v5_strict`
),

scored AS (
  SELECT
    c.candidate_id,
    c.policy_id,
    c.family,
    c.w1, c.w2, c.w3, c.w4, c.w5, c.w6,
    c.p_suspected_oos_threshold,
    c.top_n,
    c.ranking_scope,
    
    d.sku_id,
    d.decision_week,
    d.season_group,
    d.sku_season_state,
    d.y_sales,
    d.y_true_12w,
    d.stockout_event_12w,
    d.yhat_p50_v3_2_12w,
    
    -- p_suspected_oos (same formula as Phase 3, bounded to [0,1])
    GREATEST(0.0, LEAST(
      GREATEST(0.0,
        c.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
        + c.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
        + c.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
        + c.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
        + c.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
        + c.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
      )
      * GREATEST(0.0, (1.0 - LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0))),
      1.0
    )) AS p_suspected_oos,
    
    -- expected_lost_sales_if_oos
    GREATEST(0.0, LEAST(
      GREATEST(0.0,
        c.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
        + c.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
        + c.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
        + c.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
        + c.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
        + c.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
      )
      * GREATEST(0.0, (1.0 - LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0))),
      1.0
    )) * GREATEST(d.yhat_p50_v3_2_12w - d.recent_mean_sales_4w, 0.0)
    AS expected_lost_sales_if_oos
    
  FROM dev_select_data d
  CROSS JOIN candidates c
),

flagged_oos AS (
  SELECT
    *,
    CASE WHEN p_suspected_oos >= p_suspected_oos_threshold THEN 1 ELSE 0 END AS oos_flag
  FROM scored
),

-- Global metrics
global_metrics AS (
  SELECT
    candidate_id,
    COUNT(*) AS n_obs,
    SUM(oos_flag) AS n_flagged_oos,
    SUM(stockout_event_12w) AS n_true_oos_events,
    
    -- Precision@k metrics
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) AS precision,
    
    -- Recall@k metrics  
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(stockout_event_12w), 0)) AS recall,
    
    -- F1 score
    SAFE_DIVIDE(
      2.0 * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(stockout_event_12w), 0)),
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) + SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(stockout_event_12w), 0))
    ) AS f1_score,
    
    -- Lift@k
    SAFE_DIVIDE(
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)),
      SAFE_DIVIDE(SUM(stockout_event_12w), COUNT(*))
    ) AS lift,
    
    -- Expected lost sales captured
    SUM(CASE WHEN oos_flag = 1 THEN expected_lost_sales_if_oos ELSE 0 END) AS total_expected_lost_sales_captured
    
  FROM flagged_oos
  GROUP BY candidate_id
),

-- Segment metrics (by season_group)
segment_metrics AS (
  SELECT
    candidate_id,
    season_group,
    COUNT(*) AS n_obs,
    SUM(oos_flag) AS n_flagged_oos,
    SUM(stockout_event_12w) AS n_true_oos_events,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) AS precision_segment,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(stockout_event_12w), 0)) AS recall_segment,
    SAFE_DIVIDE(
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)),
      SAFE_DIVIDE(SUM(stockout_event_12w), COUNT(*))
    ) AS lift_segment
  FROM flagged_oos
  GROUP BY candidate_id, season_group
),

-- Top-N constraint check
top_n_check AS (
  SELECT
    candidate_id,
    ranking_scope,
    top_n,
    CASE ranking_scope
      WHEN 'GLOBAL' THEN (SELECT SUM(oos_flag) FROM flagged_oos WHERE candidate_id = c.candidate_id)
      ELSE NULL  -- Segment-level check done separately
    END AS actual_flagged_global,
    CASE 
      WHEN ranking_scope = 'GLOBAL' THEN
        CASE WHEN (SELECT SUM(oos_flag) FROM flagged_oos WHERE candidate_id = c.candidate_id) > top_n THEN TRUE ELSE FALSE END
      ELSE FALSE
    END AS exceeds_top_n_constraint
  FROM candidates c
),

-- Selection loss (lower is better)
selection_loss AS (
  SELECT
    gm.candidate_id,
    c.policy_id,
    c.family,
    
    -- Components
    gm.precision,
    gm.recall,
    gm.f1_score,
    gm.lift,
    gm.n_flagged_oos,
    gm.n_true_oos_events,
    gm.total_expected_lost_sales_captured,
    tnc.exceeds_top_n_constraint,
    
    -- Selection loss: penalize low lift, excess flags, and constraint violations
    (2.0 - COALESCE(gm.lift, 0.0))  -- Lower lift = higher loss
    + 0.01 * (gm.n_flagged_oos - gm.n_true_oos_events)  -- Excess false positives
    + IF(tnc.exceeds_top_n_constraint, 10.0, 0.0)  -- Huge penalty for violating constraint
    AS selection_loss
    
  FROM global_metrics gm
  JOIN candidates c USING (candidate_id)
  JOIN top_n_check tnc USING (candidate_id)
)

SELECT
  sl.*,
  gm.n_obs AS total_observations,
  
  -- Segment metrics (pivot HIGH_SEASON, OFF_SEASON)
  MAX(CASE WHEN sm.season_group = 'HIGH_SEASON' THEN sm.precision_segment END) AS precision_high_season,
  MAX(CASE WHEN sm.season_group = 'HIGH_SEASON' THEN sm.recall_segment END) AS recall_high_season,
  MAX(CASE WHEN sm.season_group = 'HIGH_SEASON' THEN sm.lift_segment END) AS lift_high_season,
  MAX(CASE WHEN sm.season_group = 'OFF_SEASON' THEN sm.precision_segment END) AS precision_off_season,
  MAX(CASE WHEN sm.season_group = 'OFF_SEASON' THEN sm.recall_segment END) AS recall_off_season,
  MAX(CASE WHEN sm.season_group = 'OFF_SEASON' THEN sm.lift_segment END) AS lift_off_season
  
FROM selection_loss sl
JOIN global_metrics gm USING (candidate_id)
LEFT JOIN segment_metrics sm USING (candidate_id)
GROUP BY
  sl.candidate_id, sl.policy_id, sl.family, sl.precision, sl.recall, sl.f1_score, sl.lift,
  sl.n_flagged_oos, sl.n_true_oos_events, sl.total_expected_lost_sales_captured,
  sl.exceeds_top_n_constraint, sl.selection_loss, gm.n_obs
ORDER BY sl.selection_loss ASC;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 4 Complete: OOS Candidate Evaluation (DEV_SELECT)' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Evaluation summary' AS check_name,
  COUNT(*) AS n_candidates_evaluated,
  ROUND(AVG(precision), 3) AS avg_precision,
  ROUND(AVG(recall), 3) AS avg_recall,
  ROUND(AVG(lift), 2) AS avg_lift,
  MIN(selection_loss) AS best_selection_loss,
  SUM(CAST(exceeds_top_n_constraint AS INT64)) AS n_violating_constraints
FROM `thequantitativeledger.cruzber_models_eu.oos_candidate_evaluation_dev_select_h12_v5_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 5 will select frozen policy from best candidate' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
