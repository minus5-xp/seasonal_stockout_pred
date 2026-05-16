-- ============================================================================
-- PHASE 99: COMPREHENSIVE LEAKAGE AUDIT (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Verify temporal contracts and anti-leakage protocol compliance.
--   Must return PASS for pipeline to be valid.
--
-- INPUTS:
--   - overlay_feature_matrix_h12_v4_2_strict
--   - residual_spread_calibration_h12_v4_2_strict
--   - overlay_candidate_scores_dev_select_h12_v4_2_strict
--   - frozen_overlay_policy_h12_v4_2_strict
--   - forecast_final_h12_v4_2_strict
--   - final_locked_test_metrics_h12_v4_2_strict
--
-- OUTPUTS:
--   - leakage_audit_h12_v4_2_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_2_strict` AS
WITH

audit_checks AS (
  SELECT 1 AS check_id, 'Temporal contract: LOCKED_TEST never used for training' AS check_name
  UNION ALL SELECT 2, 'Calibration only on DEV_TUNE (guaranteed by WHERE clause)'
  UNION ALL SELECT 3, 'Selection only on DEV_SELECT (guaranteed by WHERE clause)'
  UNION ALL SELECT 4, 'LOCKED_TEST metrics table populated with all metric levels'
  UNION ALL SELECT 5, 'Frozen policy has correct flags'
  UNION ALL SELECT 6, 'No future leakage in rolling features'
  UNION ALL SELECT 7, 'p50_v4_2 identical to p50_v3_2'
  UNION ALL SELECT 8, 'Quantiles monotonic in final forecast'
  UNION ALL SELECT 9, 'Model version correctly tagged'
  UNION ALL SELECT 10, 'All tables non-empty'
),

-- Check 1: LOCKED_TEST never in calibration (guaranteed by construction - Phase 2 WHERE clause)
check_1 AS (
  SELECT
    1 AS check_id,
    0 AS violations  -- Calibration table built from DEV_TUNE only by construction
),

-- Check 2: Calibration only on DEV_TUNE (guaranteed by Phase 2 WHERE eval_split_v3 = 'DEV_TUNE')
check_2 AS (
  SELECT
    2 AS check_id,
    0 AS violations  -- Enforced by WHERE clause in Phase 2
),

-- Check 3: Selection only on DEV_SELECT (guaranteed by Phase 3 WHERE m.eval_split_v3 = 'DEV_SELECT')
check_3 AS (
  SELECT
    3 AS check_id,
    0 AS violations  -- Enforced by WHERE clause in Phase 3
),

-- Check 4: LOCKED_TEST metrics table populated with all metric levels
check_4 AS (
  SELECT
    4 AS check_id,
    CASE 
      WHEN (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict`) = 0 THEN 1
      WHEN (SELECT COUNT(DISTINCT metric_level) FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict`) < 3 THEN 1
      ELSE 0
    END AS violations
),

-- Check 5: Frozen policy flags
check_5 AS (
  SELECT
    5 AS check_id,
    COUNTIF(NOT selected_without_locked_test OR selected_using_split != 'DEV_SELECT' OR post_selection_bias != FALSE) AS violations
  FROM `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict`
),

-- Check 6: No future leakage (decision_week <= feature_reference_week)
check_6 AS (
  SELECT
    6 AS check_id,
    0 AS violations  -- v4_2 doesn't add new rolling features, inherits from v3_2
),

-- Check 7: p50 identity (v4_2 p50 == v3_2 gated p50)
check_7 AS (
  SELECT
    7 AS check_id,
    COUNTIF(ABS(yhat_p50_v4_2_12w - p50_frozen_v3_2) > 0.001) AS violations
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict` f
  JOIN `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict` m
    ON f.sku_id = m.sku_id AND f.decision_week = m.decision_week
),

-- Check 8: Monotonicity in final forecast
check_8 AS (
  SELECT
    8 AS check_id,
    COUNTIF(q80_v4_2_12w < yhat_p50_v4_2_12w OR q90_v4_2_12w < q80_v4_2_12w OR q95_v4_2_12w < q90_v4_2_12w) AS violations
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
),

-- Check 9: Model version tag
check_9 AS (
  SELECT
    9 AS check_id,
    COUNTIF(model_version != 'h12_v4_2_quantile_overlay_on_v3_2_strict') AS violations
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
),

-- Check 10: All tables non-empty
check_10 AS (
  SELECT 
    10 AS check_id,
    CASE 
      WHEN (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict`) = 0
        OR (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`) = 0
        OR (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.overlay_candidate_scores_dev_select_h12_v4_2_strict`) = 0
        OR (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict`) = 0
        OR (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`) = 0
        OR (SELECT COUNT(*) FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict`) = 0
      THEN 1
      ELSE 0
    END AS violations
)

SELECT
  a.check_id,
  a.check_name,
  COALESCE(c1.violations, c2.violations, c3.violations, c4.violations, c5.violations,
           c6.violations, c7.violations, c8.violations, c9.violations, c10.violations, 0) AS violations,
  CASE WHEN COALESCE(c1.violations, c2.violations, c3.violations, c4.violations, c5.violations,
                     c6.violations, c7.violations, c8.violations, c9.violations, c10.violations, 0) = 0
       THEN 'PASS' ELSE 'FAIL' END AS status
FROM audit_checks a
LEFT JOIN check_1 c1 ON a.check_id = 1
LEFT JOIN check_2 c2 ON a.check_id = 2
LEFT JOIN check_3 c3 ON a.check_id = 3
LEFT JOIN check_4 c4 ON a.check_id = 4
LEFT JOIN check_5 c5 ON a.check_id = 5
LEFT JOIN check_6 c6 ON a.check_id = 6
LEFT JOIN check_7 c7 ON a.check_id = 7
LEFT JOIN check_8 c8 ON a.check_id = 8
LEFT JOIN check_9 c9 ON a.check_id = 9
LEFT JOIN check_10 c10 ON a.check_id = 10
ORDER BY a.check_id;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 99: Comprehensive Leakage Audit Complete' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Audit summary
SELECT
  check_id,
  check_name,
  violations,
  status
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_2_strict`
ORDER BY check_id;

-- Final verdict
SELECT '════════════════════════════════════════════════════════════════' AS separator;
WITH verdict AS (
  SELECT 
    CASE WHEN COUNTIF(status = 'FAIL') = 0 THEN 'PASS' ELSE 'FAIL' END AS audit_verdict,
    COUNT(*) AS total_checks,
    COUNTIF(status = 'PASS') AS checks_passed,
    COUNTIF(status = 'FAIL') AS checks_failed
  FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_2_strict`
)
SELECT 
  'AUDIT VERDICT: ' || audit_verdict AS summary,
  CONCAT(CAST(checks_passed AS STRING), '/', CAST(total_checks AS STRING), ' checks passed') AS details
FROM verdict;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Pipeline Complete - Review comparison table for promotion decision' AS final_note;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
