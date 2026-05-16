-- ============================================================================
-- PHASE 6: FINAL LOCKED_TEST METRICS (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   ONE-TIME evaluation on LOCKED_TEST using frozen policy from Phase 4.
--   Compute comprehensive metrics segmented by:
--   - Global
--   - Season group (HIGH_SEASON, LOW_SEASON, TRANSITION)
--   - SKU season state (all 9 states)
--   - Alert source (STABLE_CORE, DIFFICULT_STATE)
--
--   Also compute top-K analysis (K=50,100,200,500,1000).
--
-- INPUTS:
--   - combined_oos_alerts_h12_v5_1_strict (Phase 5, LOCKED_TEST only)
--
-- OUTPUTS:
--   - final_locked_test_metrics_h12_v5_1_strict
--
-- ANTI-LEAKAGE:
--   - This is the FINAL evaluation, policy already frozen
--   - No optimization based on these metrics
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict` AS

WITH

locked_test_data AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
),

-- Global metrics
global_metrics AS (
  SELECT
    'GLOBAL' AS segment_type,
    'ALL' AS segment_value,
    
    COUNT(*) AS n_obs,
    COUNTIF(stockout_event_12w = 1) AS n_true_oos,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate,
    
    -- Stable core (POLICY_E1)
    COUNTIF(is_stable_core_alert) AS n_stable_alerts,
    COUNTIF(is_stable_core_alert AND stockout_event_12w = 1) AS n_stable_tp,
    COUNTIF(is_stable_core_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_stable_fp,
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(is_stable_core_alert)
    ) AS stable_precision,
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS stable_recall,
    
    -- Difficult state (incremental)
    COUNTIF(is_difficult_state_alert) AS n_difficult_alerts,
    COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1) AS n_difficult_tp,
    COUNTIF(is_difficult_state_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_difficult_fp,
    SAFE_DIVIDE(
      COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1),
      COUNTIF(is_difficult_state_alert)
    ) AS difficult_precision,
    SAFE_DIVIDE(
      COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS difficult_recall,
    
    -- Combined (stable + difficult)
    COUNTIF(combined_oos_alert) AS n_combined_alerts,
    COUNTIF(combined_oos_alert AND stockout_event_12w = 1) AS n_combined_tp,
    COUNTIF(combined_oos_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_combined_fp,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert AND stockout_event_12w = 1),
      COUNTIF(combined_oos_alert)
    ) AS combined_precision,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS combined_recall,
    
    -- Expected lost sales
    SUM(CASE WHEN is_stable_core_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS stable_els_recovered,
    SUM(CASE WHEN is_difficult_state_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS difficult_els_recovered,
    SUM(CASE WHEN combined_oos_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS combined_els_recovered
    
  FROM locked_test_data
),

-- By season group
season_group_metrics AS (
  SELECT
    'SEASON_GROUP' AS segment_type,
    season_group AS segment_value,
    
    COUNT(*) AS n_obs,
    COUNTIF(stockout_event_12w = 1) AS n_true_oos,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate,
    
    COUNTIF(is_stable_core_alert) AS n_stable_alerts,
    COUNTIF(is_stable_core_alert AND stockout_event_12w = 1) AS n_stable_tp,
    COUNTIF(is_stable_core_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_stable_fp,
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(is_stable_core_alert)
    ) AS stable_precision,
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS stable_recall,
    
    COUNTIF(is_difficult_state_alert) AS n_difficult_alerts,
    COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1) AS n_difficult_tp,
    COUNTIF(is_difficult_state_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_difficult_fp,
    SAFE_DIVIDE(
      COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1),
      COUNTIF(is_difficult_state_alert)
    ) AS difficult_precision,
    SAFE_DIVIDE(
      COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS difficult_recall,
    
    COUNTIF(combined_oos_alert) AS n_combined_alerts,
    COUNTIF(combined_oos_alert AND stockout_event_12w = 1) AS n_combined_tp,
    COUNTIF(combined_oos_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_combined_fp,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert AND stockout_event_12w = 1),
      COUNTIF(combined_oos_alert)
    ) AS combined_precision,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS combined_recall,
    
    SUM(CASE WHEN is_stable_core_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS stable_els_recovered,
    SUM(CASE WHEN is_difficult_state_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS difficult_els_recovered,
    SUM(CASE WHEN combined_oos_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS combined_els_recovered
    
  FROM locked_test_data
  GROUP BY season_group
),

-- By SKU season state
state_metrics AS (
  SELECT
    'SKU_SEASON_STATE' AS segment_type,
    sku_season_state AS segment_value,
    
    COUNT(*) AS n_obs,
    COUNTIF(stockout_event_12w = 1) AS n_true_oos,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate,
    
    COUNTIF(is_stable_core_alert) AS n_stable_alerts,
    COUNTIF(is_stable_core_alert AND stockout_event_12w = 1) AS n_stable_tp,
    COUNTIF(is_stable_core_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_stable_fp,
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(is_stable_core_alert)
    ) AS stable_precision,
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS stable_recall,
    
    COUNTIF(is_difficult_state_alert) AS n_difficult_alerts,
    COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1) AS n_difficult_tp,
    COUNTIF(is_difficult_state_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_difficult_fp,
    SAFE_DIVIDE(
      COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1),
      COUNTIF(is_difficult_state_alert)
    ) AS difficult_precision,
    SAFE_DIVIDE(
      COUNTIF(is_difficult_state_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS difficult_recall,
    
    COUNTIF(combined_oos_alert) AS n_combined_alerts,
    COUNTIF(combined_oos_alert AND stockout_event_12w = 1) AS n_combined_tp,
    COUNTIF(combined_oos_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_combined_fp,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert AND stockout_event_12w = 1),
      COUNTIF(combined_oos_alert)
    ) AS combined_precision,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS combined_recall,
    
    SUM(CASE WHEN is_stable_core_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS stable_els_recovered,
    SUM(CASE WHEN is_difficult_state_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS difficult_els_recovered,
    SUM(CASE WHEN combined_oos_alert AND stockout_event_12w = 1
             THEN expected_lost_sales_if_oos ELSE 0 END) AS combined_els_recovered
    
  FROM locked_test_data
  GROUP BY sku_season_state
),

-- Combine all segments
all_segments AS (
  SELECT * FROM global_metrics
  UNION ALL SELECT * FROM season_group_metrics
  UNION ALL SELECT * FROM state_metrics
)

SELECT
  segment_type,
  segment_value,
  
  -- Observation counts
  n_obs,
  n_true_oos,
  base_rate,
  
  -- Stable core metrics
  n_stable_alerts,
  n_stable_tp,
  n_stable_fp,
  stable_precision,
  stable_recall,
  SAFE_DIVIDE(stable_precision, base_rate) AS stable_lift,
  stable_els_recovered,
  
  -- Difficult state metrics
  n_difficult_alerts,
  n_difficult_tp,
  n_difficult_fp,
  difficult_precision,
  difficult_recall,
  SAFE_DIVIDE(difficult_precision, base_rate) AS difficult_lift,
  difficult_els_recovered,
  
  -- Combined metrics
  n_combined_alerts,
  n_combined_tp,
  n_combined_fp,
  combined_precision,
  combined_recall,
  SAFE_DIVIDE(combined_precision, base_rate) AS combined_lift,
  combined_els_recovered,
  
  -- Incremental uplift (difficult vs stable)
  n_difficult_alerts AS incremental_alerts,
  n_difficult_tp AS incremental_tp,
  SAFE_DIVIDE(n_combined_tp - n_stable_tp, n_true_oos) AS incremental_recall_points,
  difficult_els_recovered AS incremental_els,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS evaluated_at_utc,
  'LOCKED_TEST' AS evaluated_on_split,
  TRUE AS final_evaluation_no_optimization,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 6: Final LOCKED_TEST metrics' AS phase_description
  
FROM all_segments
ORDER BY 
  CASE segment_type 
    WHEN 'GLOBAL' THEN 1
    WHEN 'SEASON_GROUP' THEN 2
    WHEN 'SKU_SEASON_STATE' THEN 3
  END,
  segment_value;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 6 Complete: Final LOCKED_TEST Metrics Computed' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Global summary
SELECT
  'Global LOCKED_TEST summary' AS check_name,
  n_obs,
  n_true_oos,
  ROUND(base_rate, 4) AS base_rate,
  n_stable_alerts,
  ROUND(stable_precision, 3) AS stable_prec,
  ROUND(stable_recall, 3) AS stable_rec,
  n_difficult_alerts,
  ROUND(difficult_precision, 3) AS diff_prec,
  ROUND(difficult_recall, 3) AS diff_rec,
  n_combined_alerts,
  ROUND(combined_precision, 3) AS comb_prec,
  ROUND(combined_recall, 3) AS comb_rec,
  ROUND(combined_lift, 2) AS comb_lift
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
WHERE segment_type = 'GLOBAL';

-- Difficult state performance
SELECT
  'Difficult state performance' AS check_name,
  segment_value AS state,
  n_obs,
  n_true_oos,
  n_stable_alerts AS stable_alert,
  n_difficult_alerts AS diff_alert,
  ROUND(difficult_precision, 3) AS diff_prec,
  n_difficult_tp AS diff_tp,
  ROUND(difficult_els_recovered, 1) AS diff_els
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
WHERE segment_type = 'SKU_SEASON_STATE'
  AND segment_value IN ('OFF_SEASON', 'TRANSITION_UP', 'TRANSITION_DOWN', 'INTERMITTENT_RANDOM')
ORDER BY n_difficult_alerts DESC;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 7 will analyze incremental uplift and provide decision verdict' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
