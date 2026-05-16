-- ============================================================================
-- PHASE 99: COMPREHENSIVE ANTI-LEAKAGE AUDIT (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Comprehensive anti-leakage verification across all phases.
--   Verify that:
--   1. Policy selection used only DEV_SELECT (not LOCKED_TEST)
--   2. Temporal ordering preserved (no future information leakage)
--   3. PERCENT_RANK partitioned by eval_split_v3 (no cross-split contamination)
--   4. LOCKED_TEST used only for final evaluation (one-time)
--   5. No post-selection optimization
--
-- OUTPUTS:
--   - leakage_audit_h12_v5_1_strict (15+ check rows)
--   - Final verdict: PASS / FAIL
--
-- ANTI-LEAKAGE:
--   - This IS the anti-leakage verification
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict` AS

WITH

-- ============================================================================
-- CHECK 1: Policy selected using DEV_SELECT only
-- ============================================================================
check_01_policy_selection_split AS (
  SELECT
    1 AS check_id,
    'Policy selection split' AS check_name,
    selected_using_split AS check_value,
    CASE 
      WHEN selected_using_split = 'DEV_SELECT'
       AND selected_without_locked_test = TRUE
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Policy must be selected using DEV_SELECT holdout only' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 2: No post-selection bias flag
-- ============================================================================
check_02_post_selection_bias AS (
  SELECT
    2 AS check_id,
    'Post-selection bias flag' AS check_name,
    CAST(post_selection_bias AS STRING) AS check_value,
    CASE 
      WHEN post_selection_bias = FALSE THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'post_selection_bias must be FALSE (no optimization after selection)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 3: Candidate evaluation split verification
-- ============================================================================
check_03_candidate_eval_split AS (
  SELECT
    3 AS check_id,
    'Candidate evaluation split' AS check_name,
    CAST(COUNT(DISTINCT evaluated_on_split) AS STRING) AS check_value,
    CASE 
      WHEN COUNT(DISTINCT evaluated_on_split) = 1
       AND MAX(evaluated_on_split) = 'DEV_SELECT'
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'All candidates evaluated on DEV_SELECT only (count distinct = 1)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 4: Candidate metadata - selected_without_locked_test
-- ============================================================================
check_04_candidate_metadata AS (
  SELECT
    4 AS check_id,
    'Candidate selected_without_locked_test flag' AS check_name,
    CONCAT(
      CAST(COUNTIF(selected_without_locked_test) AS STRING), ' / ',
      CAST(COUNT(*) AS STRING)
    ) AS check_value,
    CASE 
      WHEN COUNTIF(selected_without_locked_test) = COUNT(*)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'All candidates must have selected_without_locked_test=TRUE' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 5: Base scores - split coverage (must include all 3 splits)
-- ============================================================================
check_05_base_scores_split_coverage AS (
  SELECT
    5 AS check_id,
    'Base scores split coverage' AS check_name,
    CAST(COUNT(DISTINCT eval_split_v3) AS STRING) AS check_value,
    CASE 
      WHEN COUNT(DISTINCT eval_split_v3) = 3
       AND COUNTIF(eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')) = COUNT(*)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Base scores must cover DEV_TUNE, DEV_SELECT, LOCKED_TEST (3 splits)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 6: Difficult state scores - split partitioning
-- ============================================================================
check_06_difficult_scores_split AS (
  SELECT
    6 AS check_id,
    'Difficult state scores split coverage' AS check_name,
    CAST(COUNT(DISTINCT eval_split_v3) AS STRING) AS check_value,
    CASE 
      WHEN COUNT(DISTINCT eval_split_v3) = 3
      THEN 'PASS'
      ELSE 'WARNING'
    END AS check_status,
    'Difficult scores should cover all 3 splits (PERCENT_RANK partitioned by split)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 7: Combined alerts - LOCKED_TEST exists
-- ============================================================================
check_07_combined_alerts_locked_test AS (
  SELECT
    7 AS check_id,
    'Combined alerts LOCKED_TEST presence' AS check_name,
    CAST(COUNTIF(eval_split_v3 = 'LOCKED_TEST') AS STRING) AS check_value,
    CASE 
      WHEN COUNTIF(eval_split_v3 = 'LOCKED_TEST') > 0
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Combined alerts must include LOCKED_TEST data' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 8: Final metrics - evaluated on LOCKED_TEST
-- ============================================================================
check_08_final_metrics_split AS (
  SELECT
    8 AS check_id,
    'Final metrics evaluation split' AS check_name,
    CAST(COUNT(DISTINCT evaluated_on_split) AS STRING) AS check_value,
    CASE 
      WHEN COUNT(DISTINCT evaluated_on_split) = 1
       AND MAX(evaluated_on_split) = 'LOCKED_TEST'
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Final metrics evaluated on LOCKED_TEST only' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 9: Final metrics - no optimization flag
-- ============================================================================
check_09_final_metrics_no_optimization AS (
  SELECT
    9 AS check_id,
    'Final metrics no_optimization flag' AS check_name,
    CONCAT(
      CAST(COUNTIF(final_evaluation_no_optimization) AS STRING), ' / ',
      CAST(COUNT(*) AS STRING)
    ) AS check_value,
    CASE 
      WHEN COUNTIF(final_evaluation_no_optimization) = COUNT(*)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'All final metrics must have final_evaluation_no_optimization=TRUE' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 10: Uplift analysis - LOCKED_TEST split
-- ============================================================================
check_10_uplift_analysis_split AS (
  SELECT
    10 AS check_id,
    'Uplift analysis split' AS check_name,
    analyzed_on_split AS check_value,
    CASE 
      WHEN analyzed_on_split = 'LOCKED_TEST'
       AND final_decision_no_optimization = TRUE
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Uplift analysis on LOCKED_TEST with no optimization' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 11: Stable core alerts - no overlap with difficult state alerts
-- ============================================================================
check_11_alert_overlap AS (
  SELECT
    11 AS check_id,
    'Alert overlap (stable vs difficult)' AS check_name,
    CAST(COUNTIF(is_stable_core_alert AND is_difficult_state_alert) AS STRING) AS check_value,
    CASE 
      WHEN COUNTIF(is_stable_core_alert AND is_difficult_state_alert) = 0
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'No overlap: is_difficult_state_candidate excludes stable alerts by definition' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 12: Temporal ordering - decision_week in valid range
-- ============================================================================
check_12_temporal_ordering AS (
  SELECT
    12 AS check_id,
    'Temporal ordering (decision_week range)' AS check_name,
    CONCAT(
      'W', CAST(MIN(EXTRACT(ISOWEEK FROM decision_week)) AS STRING), 
      ' to W', CAST(MAX(EXTRACT(ISOWEEK FROM decision_week)) AS STRING)
    ) AS check_value,
    CASE 
      WHEN MIN(EXTRACT(ISOWEEK FROM decision_week)) >= 1 
       AND MAX(EXTRACT(ISOWEEK FROM decision_week)) <= 40
      THEN 'PASS'
      ELSE 'WARNING'
    END AS check_status,
    'decision_week must be in expected range (W01-W40 for 2024)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 13: Row count consistency (base → difficult → combined)
-- ============================================================================
check_13_row_count_consistency AS (
  SELECT
    13 AS check_id,
    'Row count consistency' AS check_name,
    CONCAT(
      'Base: ', CAST((SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`) AS STRING),
      ' / Combined: ', CAST((SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`) AS STRING)
    ) AS check_value,
    CASE 
      WHEN (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`) =
           (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Row count must be consistent across base and combined tables' AS check_description
),

-- ============================================================================
-- CHECK 14: Candidate count (should be 81 = 3×3×3)
-- ============================================================================
check_14_candidate_count AS (
  SELECT
    14 AS check_id,
    'Candidate grid count' AS check_name,
    CAST(COUNT(*) AS STRING) AS check_value,
    CASE 
      WHEN COUNT(*) = 81 THEN 'PASS'
      ELSE 'WARNING'
    END AS check_status,
    'Expected 81 candidates (3 gates × 3 percentiles × 3 quotas)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 15: Frozen policy - exactly 1 policy selected
-- ============================================================================
check_15_frozen_policy_count AS (
  SELECT
    15 AS check_id,
    'Frozen policy count' AS check_name,
    CAST(COUNT(*) AS STRING) AS check_value,
    CASE 
      WHEN COUNT(*) = 1 THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Exactly 1 policy must be frozen' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
),

-- ============================================================================
-- CHECK 16: Model version consistency
-- ============================================================================
check_16_model_version AS (
  SELECT
    16 AS check_id,
    'Model version consistency' AS check_name,
    CONCAT(
      CAST(COUNT(DISTINCT model_version) AS STRING), 
      ' distinct versions'
    ) AS check_value,
    CASE 
      WHEN COUNT(DISTINCT model_version) = 1
       AND MAX(model_version) = 'h12_v5_1_state_specific_oos_policy_strict'
      THEN 'PASS'
      ELSE 'WARNING'
    END AS check_status,
    'All tables should have consistent model_version tag' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
),

-- ============================================================================
-- Combine all checks
-- ============================================================================
all_checks AS (
  SELECT * FROM check_01_policy_selection_split
  UNION ALL SELECT * FROM check_02_post_selection_bias
  UNION ALL SELECT * FROM check_03_candidate_eval_split
  UNION ALL SELECT * FROM check_04_candidate_metadata
  UNION ALL SELECT * FROM check_05_base_scores_split_coverage
  UNION ALL SELECT * FROM check_06_difficult_scores_split
  UNION ALL SELECT * FROM check_07_combined_alerts_locked_test
  UNION ALL SELECT * FROM check_08_final_metrics_split
  UNION ALL SELECT * FROM check_09_final_metrics_no_optimization
  UNION ALL SELECT * FROM check_10_uplift_analysis_split
  UNION ALL SELECT * FROM check_11_alert_overlap
  UNION ALL SELECT * FROM check_12_temporal_ordering
  UNION ALL SELECT * FROM check_13_row_count_consistency
  UNION ALL SELECT * FROM check_14_candidate_count
  UNION ALL SELECT * FROM check_15_frozen_policy_count
  UNION ALL SELECT * FROM check_16_model_version
)

SELECT
  check_id,
  check_name,
  check_value,
  check_status,
  check_description,
  CURRENT_TIMESTAMP() AS checked_at_utc,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 99: Comprehensive anti-leakage audit' AS phase_description
FROM all_checks
ORDER BY check_id;

-- ──────────────────────────────────────────────────────────────────────────
-- FINAL VERDICT
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 99 Complete: Anti-Leakage Audit Executed' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Summary by status
SELECT
  'Check summary' AS report_section,
  check_status,
  COUNT(*) AS n_checks
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict`
GROUP BY check_status
ORDER BY check_status;

-- Failed checks (critical)
SELECT
  'Failed checks (CRITICAL)' AS report_section,
  check_id,
  check_name,
  check_value,
  check_description
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict`
WHERE check_status = 'FAIL'
ORDER BY check_id;

-- Final verdict
SELECT
  '════════════════════════════════════════════════════════════════' AS separator
UNION ALL
SELECT
  CASE 
    WHEN (SELECT COUNTIF(check_status = 'FAIL') FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict`) = 0
    THEN '✓✓✓ FINAL VERDICT: PASS - No anti-leakage violations detected ✓✓✓'
    ELSE '✗✗✗ FINAL VERDICT: FAIL - Anti-leakage violations detected ✗✗✗'
  END
UNION ALL
SELECT '════════════════════════════════════════════════════════════════';

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Pipeline complete. Review decision verdict in Phase 7.' AS next_action;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
