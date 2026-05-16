-- ============================================================================
-- PHASE 7: INCREMENTAL UPLIFT ANALYSIS & DECISION VERDICT (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Deep-dive analysis of difficult_state_policy incremental contribution.
--   Generate DECISION_VERDICT for production deployment:
--   - PROMOTE_ADDITIVE: Strong incremental value, recommend production
--   - EXPERIMENTAL_ADDITIVE: Moderate value, test in shadow mode
--   - REJECT_ADDITIVE: No value or harmful, do not deploy
--   - KEEP_STABLE_ONLY: Stable core sufficient
--
-- INPUTS:
--   - final_locked_test_metrics_h12_v5_1_strict (Phase 6)
--   - combined_oos_alerts_h12_v5_1_strict (Phase 5, LOCKED_TEST)
--
-- OUTPUTS:
--   - incremental_uplift_analysis_h12_v5_1_strict (1 row with verdict)
--
-- ANTI-LEAKAGE:
--   - Analysis on LOCKED_TEST, policy already frozen
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict` AS

WITH

-- Global metrics from Phase 6
global_metrics AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
  WHERE segment_type = 'GLOBAL'
  LIMIT 1
),

-- Difficult state metrics
difficult_state_metrics AS (
  SELECT
    segment_value AS state,
    n_obs,
    n_true_oos,
    base_rate,
    n_stable_alerts,
    n_difficult_alerts,
    difficult_precision,
    difficult_recall,
    difficult_lift,
    difficult_els_recovered
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
  WHERE segment_type = 'SKU_SEASON_STATE'
    AND segment_value IN ('OFF_SEASON', 'TRANSITION_UP', 'TRANSITION_DOWN', 'INTERMITTENT_RANDOM')
),

-- Weekly stability analysis
weekly_counts_cte AS (
  SELECT
    decision_week,
    COUNTIF(is_difficult_state_alert) AS alerts_this_week
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
  GROUP BY decision_week
),

weekly_stability AS (
  SELECT
    STDDEV(alerts_this_week) AS weekly_difficult_alerts_std,
    AVG(alerts_this_week) AS weekly_difficult_alerts_mean
  FROM weekly_counts_cte
),

-- Decision logic
decision_analysis AS (
  SELECT
    g.*,
    
    -- Incremental value metrics
    SAFE_DIVIDE(incremental_tp, n_difficult_alerts) AS incremental_precision_check,
    SAFE_DIVIDE(incremental_tp, n_true_oos) AS incremental_recall_check,
    SAFE_DIVIDE(difficult_precision, base_rate) AS incremental_lift_check,
    
    -- State coverage (target states)
    (SELECT SUM(n_difficult_alerts) FROM difficult_state_metrics 
     WHERE state IN ('OFF_SEASON', 'TRANSITION_UP', 'TRANSITION_DOWN', 'INTERMITTENT_RANDOM')) AS total_difficult_alerts_target_states,
    
    (SELECT SUM(n_difficult_tp) FROM difficult_state_metrics 
     WHERE state IN ('OFF_SEASON', 'TRANSITION_UP', 'TRANSITION_DOWN', 'INTERMITTENT_RANDOM')) AS total_difficult_tp_target_states,
    
    -- Stability
    ws.weekly_difficult_alerts_std,
    ws.weekly_difficult_alerts_mean,
    SAFE_DIVIDE(ws.weekly_difficult_alerts_std, ws.weekly_difficult_alerts_mean) AS coefficient_of_variation,
    
    -- Value thresholds
    CASE 
      -- Strong promotion criteria
      WHEN SAFE_DIVIDE(incremental_tp, n_difficult_alerts) >= 1.5 * base_rate
       AND SAFE_DIVIDE(incremental_tp, n_true_oos) >= 0.05
       AND incremental_els >= 100.0
       AND SAFE_DIVIDE(ws.weekly_difficult_alerts_std, ws.weekly_difficult_alerts_mean) < 0.5
      THEN 'PROMOTE_ADDITIVE'
      
      -- Experimental criteria (moderate value)
      WHEN SAFE_DIVIDE(incremental_tp, n_difficult_alerts) >= base_rate
       AND SAFE_DIVIDE(incremental_tp, n_true_oos) >= 0.02
       AND incremental_els >= 50.0
      THEN 'EXPERIMENTAL_ADDITIVE'
      
      -- Reject criteria (harmful or no value)
      WHEN SAFE_DIVIDE(incremental_tp, n_difficult_alerts) < base_rate
        OR incremental_tp < 5
        OR incremental_els < 20.0
      THEN 'REJECT_ADDITIVE'
      
      -- Default: keep stable only
      ELSE 'KEEP_STABLE_ONLY'
    END AS decision_verdict,
    
    -- Verdict reasoning
    CASE 
      WHEN SAFE_DIVIDE(incremental_tp, n_difficult_alerts) >= 1.5 * base_rate
       AND SAFE_DIVIDE(incremental_tp, n_true_oos) >= 0.05
       AND incremental_els >= 100.0
       AND SAFE_DIVIDE(ws.weekly_difficult_alerts_std, ws.weekly_difficult_alerts_mean) < 0.5
      THEN 'Incremental precision ≥1.5× base, recall ≥5%, ELS ≥100, stable weekly variation'
      
      WHEN SAFE_DIVIDE(incremental_tp, n_difficult_alerts) >= base_rate
       AND SAFE_DIVIDE(incremental_tp, n_true_oos) >= 0.02
       AND incremental_els >= 50.0
      THEN 'Incremental precision ≥ base, recall ≥2%, ELS ≥50 (moderate value, test in shadow mode)'
      
      WHEN SAFE_DIVIDE(incremental_tp, n_difficult_alerts) < base_rate
      THEN 'Incremental precision below base rate (noise)'
      
      WHEN incremental_tp < 5
      THEN 'Too few incremental TPs (<5), insufficient evidence'
      
      WHEN incremental_els < 20.0
      THEN 'Incremental expected lost sales too low (<20 units)'
      
      ELSE 'Does not meet promotion or experimental criteria'
    END AS verdict_reasoning
    
  FROM global_metrics g
  CROSS JOIN weekly_stability ws
)

SELECT
  -- Global context
  n_obs,
  n_true_oos,
  base_rate,
  
  -- Stable baseline
  n_stable_alerts,
  n_stable_tp,
  stable_precision,
  stable_recall,
  stable_lift,
  
  -- Incremental contribution
  n_difficult_alerts AS incremental_alerts,
  incremental_tp,
  incremental_recall_points,
  difficult_precision AS incremental_precision,
  difficult_recall AS incremental_recall,
  difficult_lift AS incremental_lift,
  difficult_els_recovered AS incremental_els,
  
  -- Combined
  combined_precision,
  combined_recall,
  combined_lift,
  
  -- Stability
  weekly_difficult_alerts_std,
  weekly_difficult_alerts_mean,
  coefficient_of_variation,
  
  -- Target state coverage
  total_difficult_alerts_target_states,
  total_difficult_tp_target_states,
  
  -- DECISION VERDICT
  decision_verdict,
  verdict_reasoning,
  
  -- Recommendations
  CASE decision_verdict
    WHEN 'PROMOTE_ADDITIVE' THEN 'Deploy h12_v5_1 to production. Strong incremental value in difficult states.'
    WHEN 'EXPERIMENTAL_ADDITIVE' THEN 'Test h12_v5_1 in shadow mode. Monitor precision and alert volume.'
    WHEN 'REJECT_ADDITIVE' THEN 'Do not deploy h12_v5_1. No incremental value or harmful.'
    WHEN 'KEEP_STABLE_ONLY' THEN 'Keep h12_v5 (POLICY_E1) only. Difficult state layer not beneficial.'
  END AS recommendation,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS analyzed_at_utc,
  'LOCKED_TEST' AS analyzed_on_split,
  TRUE AS final_decision_no_optimization,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 7: Incremental uplift analysis and decision verdict' AS phase_description
  
FROM decision_analysis;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION & DECISION REPORT
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 7 Complete: Incremental Uplift Analysis & Decision Verdict' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Decision verdict summary
SELECT
  '┌─ DECISION VERDICT ─────────────────────────────────────────────┐' AS header
UNION ALL
SELECT CONCAT('│ ', decision_verdict, REPEAT(' ', 60 - LENGTH(decision_verdict)), '│')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT '├────────────────────────────────────────────────────────────────┤'
UNION ALL
SELECT CONCAT('│ Incremental Precision: ', CAST(ROUND(incremental_precision, 3) AS STRING), 
              ' (Lift: ', CAST(ROUND(incremental_lift, 2) AS STRING), '×)',
              REPEAT(' ', 60 - LENGTH(CONCAT('Incremental Precision: ', CAST(ROUND(incremental_precision, 3) AS STRING), 
              ' (Lift: ', CAST(ROUND(incremental_lift, 2) AS STRING), '×)'))), '│')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT CONCAT('│ Incremental Recall: ', CAST(ROUND(incremental_recall, 3) AS STRING),
              ' (+', CAST(ROUND(incremental_recall_points * 100, 1) AS STRING), ' pp)',
              REPEAT(' ', 60 - LENGTH(CONCAT('Incremental Recall: ', CAST(ROUND(incremental_recall, 3) AS STRING),
              ' (+', CAST(ROUND(incremental_recall_points * 100, 1) AS STRING), ' pp)'))), '│')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT CONCAT('│ Incremental TPs: ', CAST(incremental_tp AS STRING), 
              ' / Alerts: ', CAST(incremental_alerts AS STRING),
              REPEAT(' ', 60 - LENGTH(CONCAT('Incremental TPs: ', CAST(incremental_tp AS STRING), 
              ' / Alerts: ', CAST(incremental_alerts AS STRING)))), '│')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT CONCAT('│ Incremental ELS: ', CAST(ROUND(incremental_els, 1) AS STRING), ' units',
              REPEAT(' ', 60 - LENGTH(CONCAT('Incremental ELS: ', CAST(ROUND(incremental_els, 1) AS STRING), ' units'))), '│')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT '├────────────────────────────────────────────────────────────────┤'
UNION ALL
SELECT CONCAT('│ Reasoning: ', SUBSTR(verdict_reasoning, 1, 49), '... │')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT '├────────────────────────────────────────────────────────────────┤'
UNION ALL
SELECT CONCAT('│ ', SUBSTR(recommendation, 1, 58), ' │')
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
UNION ALL
SELECT '└────────────────────────────────────────────────────────────────┘';

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 8 will extract top actionable alerts' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
