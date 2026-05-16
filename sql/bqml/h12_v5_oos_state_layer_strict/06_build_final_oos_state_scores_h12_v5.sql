-- ============================================================================
-- PHASE 6: BUILD FINAL OOS STATE SCORES (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Apply the frozen OOS state policy to ALL data splits.
--   Generate final OOS detection scores and flags for each observation.
--
-- INPUTS:
--   - oos_state_feature_matrix_h12_v5_strict (all splits)
--   - oos_frozen_policy_h12_v5_strict (1 row with frozen parameters)
--   - oos_policy_candidates_h12_v5_strict (to retrieve frozen policy weights)
--
-- OUTPUTS:
--   - oos_final_scores_h12_v5_strict (119,857 rows)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict` AS
WITH

frozen_policy_params AS (
  SELECT
    fp.frozen_candidate_id,
    fp.frozen_policy_id,
    fp.frozen_policy_family,
    pc.w1, pc.w2, pc.w3, pc.w4, pc.w5, pc.w6,
    pc.p_suspected_oos_threshold,
    pc.top_n,
    pc.ranking_scope
  FROM `thequantitativeledger.cruzber_models_eu.oos_frozen_policy_h12_v5_strict` fp
  JOIN `thequantitativeledger.cruzber_models_eu.oos_policy_candidates_h12_v5_strict` pc
    ON fp.frozen_candidate_id = pc.candidate_id
),

all_data AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
),

scored AS (
  SELECT
    d.sku_id,
    d.decision_week,
    d.week_start_date,
    d.eval_split_v3,
    d.season_group,
    d.sku_season_state,
    d.y_sales,
    d.y_true_12w,
    d.stockout_event_12w,
    d.yhat_p50_v3_2_12w,
    d.p_oos_h12,
    d.zero_run_length,
    d.zero_run_length_capped,
    d.normalized_expected_demand_gap,
    d.historical_positive_rate_same_week,
    d.recent_mean_sales_12w,
    d.recent_mean_sales_4w,
    
    fp.frozen_policy_id,
    fp.frozen_policy_family,
    fp.w1, fp.w2, fp.w3, fp.w4, fp.w5, fp.w6,
    fp.p_suspected_oos_threshold,
    
    -- Component scores (all strictly bounded [0,1])
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
    
    -- p_suspected_oos_score_raw (weighted sum before zero adjustment)
    GREATEST(0.0,
      fp.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
      + fp.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
      + fp.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
      + fp.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
      + fp.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
      + fp.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
    ) AS p_suspected_oos_score_raw,
    
    -- p_true_zero_demand (clamped to [0,1])
    LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0) AS p_true_zero_demand,
    
    -- p_suspected_oos (adjusted by true zero probability, bounded to [0,1])
    GREATEST(0.0, LEAST(
      GREATEST(0.0,
        fp.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
        + fp.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
        + fp.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
        + fp.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
        + fp.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
        + fp.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
      )
      * GREATEST(0.0, (1.0 - LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0))),
      1.0
    )) AS p_suspected_oos,
    
    -- expected_lost_sales_if_oos
    GREATEST(0.0, LEAST(
      GREATEST(0.0,
        fp.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
        + fp.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
        + fp.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
        + fp.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
        + fp.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
        + fp.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
      )
      * GREATEST(0.0, (1.0 - LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0))),
      1.0
    )) * GREATEST(d.yhat_p50_v3_2_12w - d.recent_mean_sales_4w, 0.0)
    AS expected_lost_sales_if_oos,
    
    -- audit_priority_score (>= 0 always)
    GREATEST(
      GREATEST(0.0, LEAST(
        GREATEST(0.0,
          fp.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
          + fp.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
          + fp.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
          + fp.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
          + fp.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
          + fp.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
        )
        * GREATEST(0.0, (1.0 - LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0))),
        1.0
      )) * LN(1.0 + GREATEST(d.yhat_p50_v3_2_12w - d.recent_mean_sales_4w, 0.0))
        * CASE d.season_group WHEN 'HIGH_SEASON' THEN 1.2 ELSE 1.0 END,
      0.0
    ) AS audit_priority_score,
    
    -- oos_flag (threshold-based)
    CASE 
      WHEN GREATEST(0.0, LEAST(
        GREATEST(0.0,
          fp.w1 * LEAST(d.zero_run_length_capped / 12.0, 1.0)
          + fp.w2 * LEAST(GREATEST(COALESCE(d.normalized_expected_demand_gap, 0.0), 0.0), 1.0)
          + fp.w3 * LEAST(GREATEST(COALESCE(d.historical_positive_rate_same_week, 0.0), 0.0), 1.0)
          + fp.w4 * (CASE d.sku_season_state WHEN 'ALWAYS_ON' THEN 1.00 WHEN 'IN_SEASON' THEN 0.80 WHEN 'TRANSITION_UP' THEN 0.75 WHEN 'TRANSITION_DOWN' THEN 0.60 WHEN 'INTERMITTENT_RANDOM' THEN 0.50 WHEN 'REST_OFFPEAK' THEN 0.35 ELSE 0.20 END)
          + fp.w5 * LEAST(GREATEST(COALESCE(d.p_oos_h12, 0.0), 0.0), 1.0)
          + fp.w6 * LEAST(GREATEST(CASE WHEN d.recent_mean_sales_12w > 0 AND d.recent_mean_sales_4w = 0 THEN 1.0 WHEN d.recent_mean_sales_12w > 0 THEN SAFE_DIVIDE(d.recent_mean_sales_12w - d.recent_mean_sales_4w, d.recent_mean_sales_12w) ELSE 0.0 END, 0.0), 1.0)
        )
        * GREATEST(0.0, (1.0 - LEAST((COALESCE(d.historical_zero_rate_same_week, 0.5) + COALESCE(d.recent_zero_rate_12w, 0.5)) / 2.0, 1.0))),
        1.0
      ))
       >= fp.p_suspected_oos_threshold
      THEN 1
      ELSE 0
    END AS oos_flag,
    
    -- Metadata
    'h12_v5_oos_state_layer_strict' AS model_version,
    CURRENT_TIMESTAMP() AS scored_at_utc
    
  FROM all_data d
  CROSS JOIN frozen_policy_params fp
)

SELECT * FROM scored
ORDER BY sku_id, decision_week;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 6 Complete: Final OOS State Scores Generated' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Final scores summary' AS check_name,
  COUNT(*) AS total_obs,
  COUNT(DISTINCT sku_id) AS n_skus,
  COUNT(DISTINCT decision_week) AS n_weeks,
  ROUND(AVG(p_suspected_oos), 3) AS avg_p_suspected_oos,
  SUM(oos_flag) AS total_oos_flags,
  ROUND(100.0 * SUM(oos_flag) / COUNT(*), 2) AS pct_flagged_oos,
  ROUND(SUM(expected_lost_sales_if_oos), 2) AS total_expected_lost_sales
FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`;

SELECT
  'Flags by split' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  SUM(oos_flag) AS n_oos_flags,
  ROUND(100.0 * SUM(oos_flag) / COUNT(*), 2) AS pct_flagged
FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 7 will compute LOCKED_TEST metrics (one-time use)' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
