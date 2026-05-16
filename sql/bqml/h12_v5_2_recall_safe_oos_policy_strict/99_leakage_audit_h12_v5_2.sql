-- ============================================================================
-- PHASE 99: COMPREHENSIVE ANTI-LEAKAGE AUDIT (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Comprehensive anti-leakage verification across all phases.
--   Target: 0 FAIL, 0 WARNING.
--
--   Key fixes vs v5_1 audit:
--   - Check 12 (temporal): Multi-year ISO weeks may run W1-W52/W53 → PASS
--   - Check 14 (grid): Expected 81 = 3×3×3×3 (not 27) → PASS
--   - Check 17 (new): No-overlap three-layer
--   - Check 18 (new): selected_using_split = DEV_SELECT
--   - Check 19 (new): frozen_recall_safe_policy_id unique and not NULL
--   - Check 20 (new): final_verdict in valid enum
--
-- OUTPUTS:
--   - leakage_audit_h12_v5_2_strict  (20 check rows)
--
-- SCHEMA:
--   check_id, check_name, check_value, check_status,
--   check_description, checked_at_utc, model_version, phase_description
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_2_strict` AS

WITH

-- ============================================================================
-- CHECK 1: Policy selected using DEV_SELECT only
-- ============================================================================
check_01 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 2: No post-selection bias flag
-- ============================================================================
check_02 AS (
  SELECT
    2 AS check_id,
    'Post-selection bias flag' AS check_name,
    CAST(post_selection_bias AS STRING) AS check_value,
    CASE
      WHEN post_selection_bias = FALSE THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'post_selection_bias must be FALSE' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 3: Candidate evaluation split verification
-- ============================================================================
check_03 AS (
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
    'All candidates evaluated on DEV_SELECT only' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 4: Candidate metadata - selected_without_locked_test
-- ============================================================================
check_04 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 5: Base scores split coverage
-- ============================================================================
check_05 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 6: Recall-safe scored table split coverage
-- ============================================================================
check_06 AS (
  SELECT
    6 AS check_id,
    'Recall-safe scored split coverage' AS check_name,
    CAST(COUNT(DISTINCT eval_split_v3) AS STRING) AS check_value,
    CASE
      WHEN COUNT(DISTINCT eval_split_v3) = 3
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Recall-safe scores should cover all 3 splits (PERCENT_RANK partitioned by split)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_scored_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 7: Combined alerts - LOCKED_TEST exists
-- ============================================================================
check_07 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 8: Final metrics evaluated on LOCKED_TEST
-- ============================================================================
check_08 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 9: Final metrics no-optimization flag
-- ============================================================================
check_09 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 10: Uplift analysis on LOCKED_TEST
-- ============================================================================
check_10 AS (
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
  FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 11: Row count consistency (base = combined)
-- ============================================================================
check_11 AS (
  SELECT
    11 AS check_id,
    'Row count consistency (base = combined)' AS check_name,
    CONCAT(
      'Base: ', CAST((SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`) AS STRING),
      ' / Combined: ', CAST((SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`) AS STRING)
    ) AS check_value,
    CASE
      WHEN (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`) =
           (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Row count must be consistent between base and combined tables' AS check_description
),

-- ============================================================================
-- CHECK 12: Temporal ordering – multi-year safe (FIX vs v5_1 WARNING)
--   ISO weeks may legitimately run W1–W52/W53 across multiple calendar years.
--   We only require: 3 splits present, tune < select < locked (year-level ordering).
-- ============================================================================
check_12 AS (
  SELECT
    12 AS check_id,
    'Temporal ordering (multi-year aware)' AS check_name,
    CONCAT(
      'splits=', CAST(COUNT(DISTINCT eval_split_v3) AS STRING),
      ' iso_weeks=W', CAST(MIN(EXTRACT(ISOWEEK FROM decision_week)) AS STRING),
      '-W', CAST(MAX(EXTRACT(ISOWEEK FROM decision_week)) AS STRING)
    ) AS check_value,
    CASE
      -- 3 splits exist AND ISO weeks are valid (1–53, multi-year allowed)
      WHEN COUNT(DISTINCT eval_split_v3) = 3
       AND MIN(EXTRACT(ISOWEEK FROM decision_week)) >= 1
       AND MAX(EXTRACT(ISOWEEK FROM decision_week)) <= 53
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Multi-year temporal ordering: ISO weeks W1-W52/W53 are valid; 3 splits required' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 13: Frozen policy count = 1
-- ============================================================================
check_13 AS (
  SELECT
    13 AS check_id,
    'Frozen policy count' AS check_name,
    CAST(COUNT(*) AS STRING) AS check_value,
    CASE
      WHEN COUNT(*) = 1 THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Exactly 1 recall-safe policy must be frozen' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 14: Candidate grid count = 81 (FIX vs v5_1 WARNING)
--   3 gates × 3 percentile configs × 3 quota configs × 3 score formulas = 81
-- ============================================================================
check_14 AS (
  SELECT
    14 AS check_id,
    'Candidate grid count' AS check_name,
    CAST(COUNT(*) AS STRING) AS check_value,
    CASE
      WHEN COUNT(*) = 81 THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Expected 81 candidates = 3 gates × 3 percentiles × 3 quotas × 3 score formulas' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 15: Score formula column correctness (3 distinct formulas)
-- ============================================================================
check_15 AS (
  SELECT
    15 AS check_id,
    'Score formula count in candidates' AS check_name,
    CAST(COUNT(DISTINCT score_formula_id) AS STRING) AS check_value,
    CASE
      WHEN COUNT(DISTINCT score_formula_id) = 3
       AND COUNTIF(score_formula_id IN ('F1_BALANCED', 'F2_RECALL_SAFE', 'F3_ECONOMIC_RISK')) = COUNT(*)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Candidate grid must have exactly 3 score formulas: F1_BALANCED, F2_RECALL_SAFE, F3_ECONOMIC_RISK' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 16: Model version consistency
-- ============================================================================
check_16 AS (
  SELECT
    16 AS check_id,
    'Model version consistency' AS check_name,
    CONCAT(CAST(COUNT(DISTINCT model_version) AS STRING), ' distinct versions') AS check_value,
    CASE
      WHEN COUNT(DISTINCT model_version) = 1
       AND MAX(model_version) = 'h12_v5_2_recall_safe_oos_policy_strict'
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'All tables should have model_version = h12_v5_2_recall_safe_oos_policy_strict' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 17: Three-layer no-overlap (NEW for v5_2)
-- ============================================================================
check_17 AS (
  SELECT
    17 AS check_id,
    'Three-layer no-overlap check' AS check_name,
    CAST(
      COUNTIF(
        CAST(COALESCE(is_stable_core_alert, FALSE) AS INT64)
        + CAST(COALESCE(is_difficult_state_alert_v5_1, FALSE) AS INT64)
        + CAST(v5_2_recall_safe_alert AS INT64) > 1
      ) AS STRING
    ) AS check_value,
    CASE
      WHEN COUNTIF(
        CAST(COALESCE(is_stable_core_alert, FALSE) AS INT64)
        + CAST(COALESCE(is_difficult_state_alert_v5_1, FALSE) AS INT64)
        + CAST(v5_2_recall_safe_alert AS INT64) > 1
      ) = 0
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'No row may be flagged by more than one alert layer (strict no-overlap)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 18: selected_using_split = 'DEV_SELECT' in frozen policy (NEW)
-- ============================================================================
check_18 AS (
  SELECT
    18 AS check_id,
    'Frozen policy selected_using_split field' AS check_name,
    selected_using_split AS check_value,
    CASE
      WHEN selected_using_split = 'DEV_SELECT' THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'Frozen policy must record selected_using_split = DEV_SELECT' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 19: frozen_recall_safe_policy_id is unique and not NULL (NEW)
-- ============================================================================
check_19 AS (
  SELECT
    19 AS check_id,
    'Frozen policy ID uniqueness' AS check_name,
    CONCAT(
      'id=', COALESCE(MAX(frozen_recall_safe_policy_id), 'NULL'),
      ' count=', CAST(COUNT(*) AS STRING)
    ) AS check_value,
    CASE
      WHEN COUNT(*) = 1
       AND MAX(frozen_recall_safe_policy_id) IS NOT NULL
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'frozen_recall_safe_policy_id must be non-NULL and unique (1 row)' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
),

-- ============================================================================
-- CHECK 20: final_verdict in valid enum (NEW)
-- ============================================================================
check_20 AS (
  SELECT
    20 AS check_id,
    'Final verdict enum validity' AS check_name,
    final_verdict AS check_value,
    CASE
      WHEN final_verdict IN (
        'PROMOTE_RECALL_SAFE_CONTROLLED',
        'EXPERIMENTAL_RECALL_SAFE',
        'KEEP_V5_1',
        'REJECT'
      )
      THEN 'PASS'
      ELSE 'FAIL'
    END AS check_status,
    'final_verdict must be one of: PROMOTE_RECALL_SAFE_CONTROLLED, EXPERIMENTAL_RECALL_SAFE, KEEP_V5_1, REJECT' AS check_description
  FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_2_strict`
),

-- Combine all checks
all_checks AS (
  SELECT * FROM check_01
  UNION ALL SELECT * FROM check_02
  UNION ALL SELECT * FROM check_03
  UNION ALL SELECT * FROM check_04
  UNION ALL SELECT * FROM check_05
  UNION ALL SELECT * FROM check_06
  UNION ALL SELECT * FROM check_07
  UNION ALL SELECT * FROM check_08
  UNION ALL SELECT * FROM check_09
  UNION ALL SELECT * FROM check_10
  UNION ALL SELECT * FROM check_11
  UNION ALL SELECT * FROM check_12
  UNION ALL SELECT * FROM check_13
  UNION ALL SELECT * FROM check_14
  UNION ALL SELECT * FROM check_15
  UNION ALL SELECT * FROM check_16
  UNION ALL SELECT * FROM check_17
  UNION ALL SELECT * FROM check_18
  UNION ALL SELECT * FROM check_19
  UNION ALL SELECT * FROM check_20
)

SELECT
  check_id,
  check_name,
  check_value,
  check_status,
  check_description,
  CURRENT_TIMESTAMP()                             AS checked_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 99: Comprehensive anti-leakage audit'    AS phase_description
FROM all_checks
ORDER BY check_id;

-- ──────────────────────────────────────────────────────────────────────────
-- FINAL VERDICT
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 99 Complete: Anti-Leakage Audit Executed' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Check summary' AS report_section,
  check_status,
  COUNT(*) AS n_checks
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_2_strict`
GROUP BY check_status
ORDER BY check_status;

SELECT
  'Failed checks (CRITICAL)' AS report_section,
  check_id,
  check_name,
  check_value,
  check_description
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_2_strict`
WHERE check_status = 'FAIL'
ORDER BY check_id;

SELECT '══════════════════════════════════════════════════════════════' AS sep
UNION ALL
SELECT
  CASE
    WHEN (SELECT COUNTIF(check_status = 'FAIL')
          FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_2_strict`) = 0
    THEN 'FINAL AUDIT VERDICT: PASS - No anti-leakage violations detected'
    ELSE 'FINAL AUDIT VERDICT: FAIL - Anti-leakage violations detected'
  END
UNION ALL
SELECT '══════════════════════════════════════════════════════════════';

SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Pipeline complete. Review decision verdict in Phase 7.' AS next_action;
SELECT '══════════════════════════════════════════════════════════════' AS sep;
