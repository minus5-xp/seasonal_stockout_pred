-- ============================================================================
-- PHASE 3: SCORE OOS STATE CANDIDATES ON DEV_TUNE (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Apply all policy candidates to DEV_TUNE data.
--   Compute component scores and final OOS probability scores.
--
-- INPUTS:
--   - oos_state_feature_matrix_h12_v5_strict (DEV_TUNE only)
--   - oos_policy_candidates_h12_v5_strict
--
-- OUTPUTS:
--   - oos_candidate_scores_dev_tune_h12_v5_strict
-- ============================================================================

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
    c.policy_id,
    c.family,
    c.w1, c.w2, c.w3, c.w4, c.w5, c.w6,
    c.p_suspected_oos_threshold,
    c.top_n,
    c.ranking_scope,
    
    d.sku_id,
    d.decision_week,
    d.eval_split_v3,
    d.season_group,
    d.sku_season_state,
    d.y_sales,
    d.y_true_12w,
    d.stockout_event_12w,
    d.yhat_p50_v3_2_12w,
    d.p_oos_h12,
    
    -- Component scores (0-1 range)
    LEAST(d.zero_run_length_capped / 12.0, 1.0) AS zero_run_component,
    LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0) AS expected_gap_component,
    LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0) AS historical_positive_component,
    CASE d.sku_season_state
      WHEN 'ALWAYS_ON' THEN 1.00
      WHEN 'IN_SEASON' THEN 0.80
      WHEN 'TRANSITION_UP' THEN 0.75
      WHEN 'TRANSITION_DOWN' THEN 0.60
      WHEN 'INTERMITTENT_RANDOM' THEN 0.50
      WHEN 'REST_OFFPEAK' THEN 0.35
      ELSE 0.20
    END AS season_state_component,
    LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0) AS p_oos_component,
    LEAST(GREATEST(
      CASE
        WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0
        WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w)
        ELSE 0.0
      END, 0.0), 1.0) AS recent_drop_component,
    
    -- Compute p_suspected_oos_score_raw (weighted sum before zero adjustment)
    GREATEST(0.0,
      c.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
      + c.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
      + c.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
      + c.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
      + c.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
      + c.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
    ) AS p_suspected_oos_score_raw,
    
    -- p_true_zero_demand (heuristic: average of historical and recent zero rates, clamped to [0,1])
    LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0) AS p_true_zero_demand,
    
    -- p_suspected_oos (adjusted by probability of true zero, bounded to [0,1])
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
    AS expected_lost_sales_if_oos,
    
    -- audit_priority_score (>= 0 always)
    GREATEST(
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
      )) * LN(1.0 + GREATEST(d.yhat_p50_v3_2_12w - d.recent_mean_sales_4w, 0.0))
        * CASE d.season_group WHEN 'HIGH_SEASON' THEN 1.2 ELSE 1.0 END,
      0.0
    ) AS audit_priority_score
    
  FROM dev_tune_data d
  CROSS JOIN candidates c
)

SELECT * FROM scored;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 3 Complete: OOS Candidate Scores Computed (DEV_TUNE)' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Scoring summary' AS check_name,
  COUNT(DISTINCT candidate_id) AS n_candidates,
  COUNT(*) AS n_scored_obs,
  ROUND(AVG(p_suspected_oos_score_raw), 3) AS avg_score_raw,
  ROUND(AVG(p_suspected_oos), 3) AS avg_p_suspected_oos,
  ROUND(AVG(expected_lost_sales_if_oos), 2) AS avg_expected_lost_sales
FROM `thequantitativeledger.cruzber_models_eu.oos_candidate_scores_dev_tune_h12_v5_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 4 will evaluate candidates on DEV_SELECT' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
