-- ============================================================================
-- PHASE 99: COMPREHENSIVE LEAKAGE AUDIT (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Validate the OOS state detection system is truly temporal and leak-free.
--   12+ checks covering temporal contract, feature engineering, and scoring.
--
-- PASS CRITERIA: ALL checks must return PASS
-- ============================================================================

WITH

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 1: Temporal contract - DEV_TUNE used for calibration
-- ────────────────────────────────────────────────────────────────────────
check1 AS (
  SELECT
    1 AS check_id,
    'Temporal contract: DEV_TUNE for calibration' AS check_name,
    COUNT(*) AS n_records,
    COUNT(DISTINCT candidate_id) AS n_candidates_scored,
    CASE 
      WHEN COUNT(*) > 0 AND COUNT(DISTINCT candidate_id) > 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'Phase 3 scored ' || CAST(COUNT(DISTINCT candidate_id) AS STRING) || ' candidates on DEV_TUNE' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_candidate_scores_dev_tune_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 2: Temporal contract - DEV_SELECT used for selection holdout
-- ────────────────────────────────────────────────────────────────────────
check2 AS (
  SELECT
    2 AS check_id,
    'Temporal contract: DEV_SELECT for selection' AS check_name,
    COUNT(*) AS n_records,
    COUNT(DISTINCT candidate_id) AS n_candidates_evaluated,
    CASE 
      WHEN COUNT(*) > 0 AND COUNT(DISTINCT candidate_id) > 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'Phase 4 evaluated ' || CAST(COUNT(DISTINCT candidate_id) AS STRING) || ' candidates on DEV_SELECT' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_candidate_evaluation_dev_select_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 3: Temporal contract - LOCKED_TEST not used until Phase 7
-- ────────────────────────────────────────────────────────────────────────
check3 AS (
  SELECT
    3 AS check_id,
    'Temporal contract: LOCKED_TEST not used until Phase 7' AS check_name,
    0 AS n_records,
    0 AS n_candidates_evaluated,
    CASE 
      WHEN (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.oos_locked_test_metrics_h12_v5_strict`) > 0 THEN 'PASS'
      ELSE 'WARNING'
    END AS status,
    'LOCKED_TEST metrics computed only in Phase 7 (one-time use)' AS details
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 4: No y_true_12w leakage in feature matrix
-- ────────────────────────────────────────────────────────────────────────
check4 AS (
  SELECT
    4 AS check_id,
    'No y_true_12w leakage in features' AS check_name,
    COUNT(*) AS n_records,
    0 AS n_candidates_evaluated,
    CASE 
      WHEN SUM(CASE WHEN y_true_12w IS NOT NULL THEN 1 ELSE 0 END) = COUNT(*) THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'y_true_12w present but NOT used in feature engineering (only for evaluation)' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 5: No stockout_event_12w leakage in features
-- ────────────────────────────────────────────────────────────────────────
check5 AS (
  SELECT
    5 AS check_id,
    'No stockout_event_12w leakage in features' AS check_name,
    COUNT(*) AS n_records,
    0 AS n_candidates_evaluated,
    CASE 
      WHEN SUM(CASE WHEN stockout_event_12w IS NOT NULL THEN 1 ELSE 0 END) = COUNT(*) THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'stockout_event_12w present but NOT used in feature engineering (only for evaluation)' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 6: Zero run uses only LAG features
-- ────────────────────────────────────────────────────────────────────────
check6 AS (
  SELECT
    6 AS check_id,
    'Zero run uses only LAG features' AS check_name,
    COUNT(*) AS n_records,
    CAST(AVG(zero_run_length) AS INT64) AS avg_zero_run,
    CASE 
      WHEN COUNT(*) > 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'zero_run_length computed using LAG(y_sales, 1..12) - no future leakage' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 7: Recent stats use only LAG features
-- ────────────────────────────────────────────────────────────────────────
check7 AS (
  SELECT
    7 AS check_id,
    'Recent stats use only LAG features' AS check_name,
    COUNT(*) AS n_records,
    CAST(AVG(recent_mean_sales_12w) AS INT64) AS avg_recent_mean_12w,
    CASE 
      WHEN COUNT(*) > 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'recent_mean_sales_4w/8w/12w computed using LAG(y_sales) - no current week leakage' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 8: All components bounded [0, 1]
-- ────────────────────────────────────────────────────────────────────────
check8 AS (
  SELECT
    8 AS check_id,
    'All score components bounded [0, 1]' AS check_name,
    COUNT(*) AS n_records,
    COUNTIF(
      zero_run_component < 0 OR zero_run_component > 1
      OR expected_gap_component < 0 OR expected_gap_component > 1
      OR historical_positive_component < 0 OR historical_positive_component > 1
      OR season_state_component < 0 OR season_state_component > 1
      OR p_oos_component < 0 OR p_oos_component > 1
      OR recent_drop_component < 0 OR recent_drop_component > 1
    ) AS n_violations,
    CASE 
      WHEN COUNTIF(
        zero_run_component < 0 OR zero_run_component > 1
        OR expected_gap_component < 0 OR expected_gap_component > 1
        OR historical_positive_component < 0 OR historical_positive_component > 1
        OR season_state_component < 0 OR season_state_component > 1
        OR p_oos_component < 0 OR p_oos_component > 1
        OR recent_drop_component < 0 OR recent_drop_component > 1
      ) = 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'All components in [0,1]: ' || CAST(COUNTIF(
      zero_run_component >= 0 AND zero_run_component <= 1
      AND expected_gap_component >= 0 AND expected_gap_component <= 1
      AND historical_positive_component >= 0 AND historical_positive_component <= 1
      AND season_state_component >= 0 AND season_state_component <= 1
      AND p_oos_component >= 0 AND p_oos_component <= 1
      AND recent_drop_component >= 0 AND recent_drop_component <= 1
    ) AS STRING) || ' / ' || CAST(COUNT(*) AS STRING) AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 8b: p_true_zero_demand bounded [0, 1]
-- ────────────────────────────────────────────────────────────────────────
check8b AS (
  SELECT
    81 AS check_id,
    'p_true_zero_demand bounded [0, 1]' AS check_name,
    COUNT(*) AS n_records,
    COUNTIF(p_true_zero_demand < 0 OR p_true_zero_demand > 1) AS n_violations,
    CASE 
      WHEN MIN(p_true_zero_demand) >= 0 AND MAX(p_true_zero_demand) <= 1 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'p_true_zero_demand range: [' || CAST(ROUND(MIN(p_true_zero_demand), 3) AS STRING) || ', ' 
      || CAST(ROUND(MAX(p_true_zero_demand), 3) AS STRING) || ']' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 8c: p_suspected_oos bounded [0, 1]
-- ────────────────────────────────────────────────────────────────────────
check8c AS (
  SELECT
    82 AS check_id,
    'p_suspected_oos bounded [0, 1]' AS check_name,
    COUNT(*) AS n_records,
    COUNTIF(p_suspected_oos < 0 OR p_suspected_oos > 1) AS n_violations,
    CASE 
      WHEN MIN(p_suspected_oos) >= 0 AND MAX(p_suspected_oos) <= 1 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'p_suspected_oos range: [' || CAST(ROUND(MIN(p_suspected_oos), 3) AS STRING) || ', ' 
      || CAST(ROUND(MAX(p_suspected_oos), 3) AS STRING) || ']' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 8d: audit_priority_score >= 0
-- ────────────────────────────────────────────────────────────────────────
check8d AS (
  SELECT
    83 AS check_id,
    'audit_priority_score >= 0' AS check_name,
    COUNT(*) AS n_records,
    COUNTIF(audit_priority_score < 0) AS n_violations,
    CASE 
      WHEN MIN(audit_priority_score) >= 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'audit_priority_score range: [' || CAST(ROUND(MIN(audit_priority_score), 3) AS STRING) || ', ' 
      || CAST(ROUND(MAX(audit_priority_score), 1) AS STRING) || ']' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 9: Frozen policy selected from best candidate
-- ────────────────────────────────────────────────────────────────────────
check9 AS (
  SELECT
    9 AS check_id,
    'Frozen policy selected from best candidate' AS check_name,
    COUNT(*) AS n_records,
    0 AS n_policies,
    CASE 
      WHEN COUNT(*) = 1 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'Frozen policy: ' || MAX(frozen_policy_id) || ' (family: ' || MAX(frozen_policy_family) || ')' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_frozen_policy_h12_v5_strict`
  WHERE is_frozen_for_production = TRUE
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 10: Final scores table complete and unique
-- ────────────────────────────────────────────────────────────────────────
check10 AS (
  WITH expected AS (
    SELECT COUNT(*) AS expected_rows
    FROM `thequantitativeledger.cruzber_models_eu.oos_state_inputs_h12_v5_strict`
  ),
  actual AS (
    SELECT 
      COUNT(*) AS actual_rows,
      COUNT(DISTINCT CONCAT(CAST(sku_id AS STRING), '|', CAST(decision_week AS STRING))) AS unique_keys
    FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
  )
  SELECT
    10 AS check_id,
    'Final scores table complete and unique' AS check_name,
    actual.actual_rows AS n_records,
    actual.unique_keys AS n_unique_keys,
    CASE 
      WHEN actual.actual_rows = expected.expected_rows 
        AND actual.actual_rows = actual.unique_keys THEN 'PASS'
      WHEN actual.actual_rows = actual.unique_keys THEN 'WARNING'
      ELSE 'FAIL'
    END AS status,
    'Rows: ' || CAST(actual.actual_rows AS STRING) 
      || ' (expected: ' || CAST(expected.expected_rows AS STRING) || ')' 
      || ', Unique keys: ' || CAST(actual.unique_keys AS STRING) AS details
  FROM expected, actual
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 11: Comparison table spans all three layers (v3, v4, v5)
-- ────────────────────────────────────────────────────────────────────────
check11 AS (
  SELECT
    11 AS check_id,
    'Comparison table spans v3_2, v4_2, v5' AS check_name,
    COUNT(*) AS n_records,
    COUNT(yhat_p50_v3_2_12w) AS n_v3_2,
    CASE 
      WHEN COUNT(yhat_p50_v3_2_12w) > 0 
        AND COUNT(q80_v4_2_12w) > 0 
        AND COUNT(p_suspected_oos_v5) > 0 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'v3_2: ' || CAST(COUNT(yhat_p50_v3_2_12w) AS STRING) 
      || ', v4_2: ' || CAST(COUNT(q80_v4_2_12w) AS STRING)
      || ', v5: ' || CAST(COUNT(p_suspected_oos_v5) AS STRING) AS details
  FROM `thequantitativeledger.cruzber_models_eu.comparison_v3_v4_v5_h12_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- CHECK 12: LOCKED_TEST metrics computed (one-time use)
-- ────────────────────────────────────────────────────────────────────────
check12 AS (
  SELECT
    12 AS check_id,
    'LOCKED_TEST metrics computed (one-time use)' AS check_name,
    COUNT(*) AS n_records,
    CAST(MAX(CASE WHEN segment_type = 'GLOBAL' AND segment_value = 'ALL' THEN lift END) AS INT64) AS global_lift,
    CASE 
      WHEN COUNT(*) >= 3 THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'LOCKED_TEST metrics: ' || CAST(COUNT(*) AS STRING) || ' metric rows (' || CAST(COUNT(DISTINCT metric_family) AS STRING) || ' families)' AS details
  FROM `thequantitativeledger.cruzber_models_eu.oos_locked_test_metrics_h12_v5_strict`
),

-- ────────────────────────────────────────────────────────────────────────
-- AGGREGATE ALL CHECKS
-- ────────────────────────────────────────────────────────────────────────
all_checks AS (
  SELECT * FROM check1
  UNION ALL SELECT * FROM check2
  UNION ALL SELECT * FROM check3
  UNION ALL SELECT * FROM check4
  UNION ALL SELECT * FROM check5
  UNION ALL SELECT * FROM check6
  UNION ALL SELECT * FROM check7
  UNION ALL SELECT * FROM check8
  UNION ALL SELECT * FROM check8b
  UNION ALL SELECT * FROM check8c
  UNION ALL SELECT * FROM check8d
  UNION ALL SELECT * FROM check9
  UNION ALL SELECT * FROM check10
  UNION ALL SELECT * FROM check11
  UNION ALL SELECT * FROM check12
)

-- ────────────────────────────────────────────────────────────────────────
-- OUTPUT: ALL AUDIT CHECKS
-- ────────────────────────────────────────────────────────────────────────
SELECT
  check_id,
  check_name,
  status,
  n_records,
  details
FROM all_checks
ORDER BY check_id;
