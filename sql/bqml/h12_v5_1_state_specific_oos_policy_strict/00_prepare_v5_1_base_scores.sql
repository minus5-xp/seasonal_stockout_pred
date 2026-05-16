-- ============================================================================
-- PHASE 0: PREPARE v5_1 BASE SCORES (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Reproduce v5 final scores and add flags for v5_1 additive policy:
--   - is_stable_core_alert: flags from frozen POLICY_E1 (v5)
--   - is_difficult_state_candidate: rows in difficult states NOT already flagged
--
-- INPUTS:
--   - oos_final_scores_h12_v5_strict (v5 frozen scores, 119,857 rows)
--
-- OUTPUTS:
--   - base_scores_h12_v5_1_strict (119,857 rows with added flags)
--
-- ANTI-LEAKAGE:
--   - Uses frozen v5 scores (POLICY_E1 already selected on DEV_SELECT)
--   - No new temporal violations introduced
--   - Difficult states defined by coverage gap analysis, not LOCKED_TEST
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` AS

WITH

v5_scores AS (
  SELECT
    -- Base identifiers
    sku_id,
    decision_week,
    week_start_date,
    eval_split_v3,
    season_group,
    sku_season_state,
    
    -- Actuals (for evaluation only, NOT used in scoring)
    y_sales,
    y_true_12w,
    stockout_event_12w,
    
    -- v3_2 forecast
    yhat_p50_v3_2_12w,
    
    -- v5 component scores (all [0,1])
    zero_run_component,
    expected_gap_component,
    historical_positive_component,
    season_state_component,
    p_oos_component,
    recent_drop_component,
    
    -- v5 intermediate scores
    p_suspected_oos_score_raw,
    p_true_zero_demand,
    
    -- v5 FINAL SCORES (frozen POLICY_E1)
    p_suspected_oos,
    p_oos_h12,
    expected_lost_sales_if_oos,
    audit_priority_score,
    
    -- v5 binary flag (frozen POLICY_E1)
    oos_flag AS oos_flag_v5
    
  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

-- Define difficult states where POLICY_E1 has zero coverage
difficult_states_definition AS (
  SELECT
    sku_id,
    decision_week,
    
    -- Stable core alert: frozen POLICY_E1 flags (convert INT64 to BOOL)
    oos_flag_v5 = 1 AS is_stable_core_alert,
    
    -- Difficult zero-demand candidate: has OOS signal evidence BUT not flagged by POLICY_E1.
    -- Feature-based definition (works across all splits, no sku_season_state dependency).
    CASE 
      WHEN zero_run_component >= 0.15        -- Some zero-run OOS signal present
       AND p_true_zero_demand < 0.75         -- Not clearly a structural true zero
       AND COALESCE(oos_flag_v5, 0) = 0      -- Not already flagged by POLICY_E1
      THEN TRUE
      ELSE FALSE
    END AS is_difficult_state_candidate
    
  FROM v5_scores
)

SELECT
  v5.*,
  dsd.is_stable_core_alert,
  dsd.is_difficult_state_candidate,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at_utc,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 0: Reproduce v5 base scores with v5_1 flags' AS phase_description
  
FROM v5_scores v5
INNER JOIN difficult_states_definition dsd
  ON v5.sku_id = dsd.sku_id
 AND v5.decision_week = dsd.decision_week;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 0 Complete: v5_1 Base Scores Prepared' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Row count check
SELECT
  'Row count validation' AS check_name,
  COUNT(*) AS n_rows,
  COUNT(DISTINCT CONCAT(sku_id, '_', decision_week)) AS n_unique_keys,
  CASE 
    WHEN COUNT(*) = 119857 AND COUNT(DISTINCT CONCAT(sku_id, '_', decision_week)) = 119857
    THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS validation_status
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`;

-- Split distribution
SELECT
  'Split distribution' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

-- Stable core alert summary
SELECT
  'Stable core alerts (POLICY_E1)' AS check_name,
  eval_split_v3,
  COUNTIF(is_stable_core_alert) AS n_stable_alerts,
  ROUND(100.0 * COUNTIF(is_stable_core_alert) / COUNT(*), 2) AS pct_flagged
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

-- Difficult zero-demand candidate summary by season_group and eval_split
SELECT
  'Difficult zero-demand candidates' AS check_name,
  eval_split_v3,
  season_group,
  COUNT(*) AS n_obs,
  COUNTIF(is_difficult_state_candidate) AS n_candidates,
  ROUND(100.0 * COUNTIF(is_difficult_state_candidate) / COUNT(*), 1) AS pct_candidates,
  COUNTIF(is_stable_core_alert) AS n_stable_alerts
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
GROUP BY eval_split_v3, season_group
ORDER BY eval_split_v3, season_group;

-- Overlap check (should be zero: candidates exclude stable alerts)
SELECT
  'Overlap check (stable AND difficult)' AS check_name,
  COUNTIF(is_stable_core_alert AND is_difficult_state_candidate) AS n_overlap,
  CASE 
    WHEN COUNTIF(is_stable_core_alert AND is_difficult_state_candidate) = 0
    THEN '✓ PASS: No overlap (correct)'
    ELSE '✗ FAIL: Overlap detected'
  END AS validation_status
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 1 will compute difficult_state_score for candidates' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
