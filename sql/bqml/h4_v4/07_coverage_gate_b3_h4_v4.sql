-- ============================================================================
-- STEP 07: COVERAGE EVALUATION + GATE B3  (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   Evaluate P90 conditional violation rate on:
--     (a) Full VAL (production gate)
--     (b) VAL_TEST only (paper-clean gate — NO snoop into VAL_TUNE)
--   Both use the SAME factors from quantile_factors_h4_v4.
--   No 999 placeholders. Empty split rows => explicit INSUFFICIENT_DATA verdict.
--
-- ACTIVE DEMAND SCOPE: amplitude >= 5.0
-- GATE B3 PASS:         viol_rate_p90 in [0.08, 0.12] per season_group
--
-- OUTPUT TABLES:
--   eval_coverage_h4_v4_conditional        : row-level coverage flags (VAL)
--   eval_coverage_summary_h4_v4_conditional: summary by season (VAL)
--   gate_b3_verdict_h4_v4                  : PASS/FAIL per season + overall
--   gate_b3_paper_verdict_h4_v4            : same evaluation on VAL_TEST only
-- ============================================================================

-- ============================================================================
-- 7a. ROW-LEVEL COVERAGE FLAGS  (VAL, active-demand scope)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.eval_coverage_h4_v4_conditional` AS
SELECT
  decision_week,
  sku_id,
  season_group,
  segment_id_child,
  split,
  amplitude,
  y_true_h4,
  yhat_p50_h4,
  q90_h4,
  q95_h4,
  q99_h4,
  correction_factor,
  CASE WHEN y_true_h4 > q90_h4 THEN 1 ELSE 0 END AS viol_p90,
  CASE WHEN y_true_h4 > q95_h4 THEN 1 ELSE 0 END AS viol_p95,
  CASE WHEN y_true_h4 > q99_h4 THEN 1 ELSE 0 END AS viol_p99
FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4`
WHERE split = 'VAL'
  AND amplitude >= 5.0;   -- active demand scope


-- ============================================================================
-- 7b. SUMMARY BY SEASON  (VAL)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.eval_coverage_summary_h4_v4_conditional` AS
SELECT
  season_group,
  COUNT(*)                              AS n_obs,
  ROUND(AVG(viol_p90), 4)              AS viol_rate_p90,
  ROUND(AVG(viol_p95), 4)              AS viol_rate_p95,
  ROUND(AVG(viol_p99), 4)              AS viol_rate_p99,
  ROUND(AVG(viol_p90) - 0.10, 4)      AS deviation_p90,
  ROUND(AVG(viol_p95) - 0.05, 4)      AS deviation_p95,
  ROUND(ABS(AVG(viol_p90) - 0.10), 4) AS distance_p90,
  ROUND(AVG(correction_factor), 4)     AS avg_correction_factor
FROM `thequantitativeledger.cruzber_models_eu.eval_coverage_h4_v4_conditional`
GROUP BY season_group;


-- ============================================================================
-- 7c. GATE B3 VERDICT  (VAL, production)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.gate_b3_verdict_h4_v4` AS
WITH per_season AS (
  SELECT
    'VAL' AS eval_set,
    season_group,
    n_obs,
    viol_rate_p90,
    viol_rate_p95,
    deviation_p90,
    distance_p90,
    avg_correction_factor,
    CASE
      WHEN n_obs = 0
        THEN 'INSUFFICIENT_DATA'
      WHEN viol_rate_p90 BETWEEN 0.08 AND 0.12
        THEN 'PASS'
      ELSE 'FAIL'
    END AS season_verdict
  FROM `thequantitativeledger.cruzber_models_eu.eval_coverage_summary_h4_v4_conditional`
),
overall AS (
  SELECT
    CASE
      WHEN COUNTIF(season_verdict = 'FAIL') > 0              THEN 'FAIL'
      WHEN COUNTIF(season_verdict = 'INSUFFICIENT_DATA') > 0 THEN 'INSUFFICIENT_DATA'
      ELSE 'PASS'
    END AS overall_verdict
  FROM per_season
)
SELECT
  ps.*,
  o.overall_verdict
FROM per_season ps
CROSS JOIN overall o
ORDER BY season_group;


-- ============================================================================
-- 7d.  PAPER EVALUATION: VAL_TEST only (no snoop on VAL_TUNE)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.gate_b3_paper_verdict_h4_v4` AS

WITH val_test_coverage AS (
  SELECT
    f.season_group,
    COUNT(*) AS n_obs,
    COUNTIF(f.y_true_h4 > f.q90_h4) AS n_viol,
    ROUND(SAFE_DIVIDE(COUNTIF(f.y_true_h4 > f.q90_h4), COUNT(*)), 4) AS viol_rate_p90,
    ROUND(AVG(f.correction_factor), 4) AS avg_correction_factor
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4` f
  INNER JOIN `thequantitativeledger.cruzber_models_eu.val_tune_test_split_h4_v4` sp
    ON f.decision_week = sp.decision_week
  WHERE f.split = 'VAL'
    AND sp.paper_split = 'VAL_TEST'
    AND f.amplitude >= 5.0
  GROUP BY f.season_group
),
per_season AS (
  SELECT
    'VAL_TEST' AS eval_set,
    season_group,
    n_obs,
    viol_rate_p90,
    avg_correction_factor,
    ROUND(ABS(viol_rate_p90 - 0.10), 4) AS distance_p90,
    CASE
      WHEN n_obs = 0 THEN 'INSUFFICIENT_DATA'
      WHEN viol_rate_p90 BETWEEN 0.08 AND 0.12 THEN 'PASS'
      ELSE 'FAIL'
    END AS season_verdict
  FROM val_test_coverage
),
overall AS (
  SELECT
    CASE
      WHEN COUNTIF(season_verdict = 'FAIL') > 0              THEN 'FAIL'
      WHEN COUNTIF(season_verdict = 'INSUFFICIENT_DATA') > 0 THEN 'INSUFFICIENT_DATA'
      ELSE 'PASS'
    END AS overall_verdict
  FROM per_season
)
SELECT ps.*, o.overall_verdict
FROM per_season ps CROSS JOIN overall o
ORDER BY season_group;


-- ============================================================================
-- Display results
-- ============================================================================
SELECT 'PRODUCTION GATE B3 (full VAL)' AS check_type;
SELECT eval_set, season_group, n_obs, viol_rate_p90, deviation_p90, season_verdict, overall_verdict
FROM `thequantitativeledger.cruzber_models_eu.gate_b3_verdict_h4_v4`;

SELECT 'PAPER GATE B3 (VAL_TEST only)' AS check_type;
SELECT eval_set, season_group, n_obs, viol_rate_p90, distance_p90, season_verdict, overall_verdict
FROM `thequantitativeledger.cruzber_models_eu.gate_b3_paper_verdict_h4_v4`;
