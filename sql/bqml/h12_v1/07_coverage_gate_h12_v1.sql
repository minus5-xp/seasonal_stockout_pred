-- ============================================================================
-- STEP 07: COVERAGE EVALUATION + GATE B3  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   Evaluate quantile violation rates on VAL (active demand scope).
--   Gate B3 passes when viol_rate_p90 in [0.08, 0.12] per season_group.
--
-- ACTIVE DEMAND SCOPE: amplitude >= 10.0
--
-- OUTPUT TABLES:
--   eval_coverage_h12_v1_conditional         : row-level coverage flags (VAL)
--   eval_coverage_summary_h12_v1_conditional : summary by season (VAL + VAL_TEST)
--   gate_b3_verdict_h12_v1                   : PASS/FAIL per season + overall
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 7a. ROW-LEVEL COVERAGE FLAGS  (VAL, active-demand scope)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h12_v1_conditional` AS
SELECT
  decision_week,
  sku_id,
  season_group,
  segment_id_child,
  split,
  amplitude,
  y_true_12w,
  yhat_p50_12w,
  q80_12w,
  q90_12w,
  q95_12w,
  q99_12w,
  correction_factor,
  CASE WHEN y_true_12w > q80_12w THEN 1 ELSE 0 END AS viol_p80,
  CASE WHEN y_true_12w > q90_12w THEN 1 ELSE 0 END AS viol_p90,
  CASE WHEN y_true_12w > q95_12w THEN 1 ELSE 0 END AS viol_p95,
  CASE WHEN y_true_12w > q99_12w THEN 1 ELSE 0 END AS viol_p99
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0;  -- active demand scope

-- ---------------------------------------------------------------------------
-- 7b. SUMMARY BY SEASON  (VAL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h12_v1_conditional` AS
SELECT
  'FULL_VAL' AS eval_scope,
  season_group,
  COUNT(*)                              AS n_obs,
  ROUND(AVG(viol_p80), 4)              AS viol_rate_p80,
  ROUND(AVG(viol_p90), 4)              AS viol_rate_p90,
  ROUND(AVG(viol_p95), 4)              AS viol_rate_p95,
  ROUND(AVG(viol_p99), 4)              AS viol_rate_p99,
  ROUND(AVG(viol_p90) - 0.10, 4)      AS deviation_p90,
  ROUND(ABS(AVG(viol_p90) - 0.10), 4) AS distance_p90,
  ROUND(AVG(correction_factor), 4)     AS avg_correction_factor
FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h12_v1_conditional`
GROUP BY season_group

UNION ALL

-- VAL_TEST only (paper-clean evaluation)
SELECT
  'VAL_TEST' AS eval_scope,
  c.season_group,
  COUNT(*)                              AS n_obs,
  ROUND(AVG(c.viol_p80), 4)            AS viol_rate_p80,
  ROUND(AVG(c.viol_p90), 4)            AS viol_rate_p90,
  ROUND(AVG(c.viol_p95), 4)            AS viol_rate_p95,
  ROUND(AVG(c.viol_p99), 4)            AS viol_rate_p99,
  ROUND(AVG(c.viol_p90) - 0.10, 4)    AS deviation_p90,
  ROUND(ABS(AVG(c.viol_p90) - 0.10), 4) AS distance_p90,
  ROUND(AVG(c.correction_factor), 4)   AS avg_correction_factor
FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h12_v1_conditional` c
INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_test_split_h12_v1` sp
  ON c.decision_week = sp.decision_week AND sp.paper_split = 'VAL_TEST'
GROUP BY c.season_group

ORDER BY eval_scope, season_group;

-- ---------------------------------------------------------------------------
-- 7c. GATE B3 VERDICT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.gate_b3_verdict_h12_v1` AS
WITH season_verdicts AS (
  SELECT
    eval_scope,
    season_group,
    viol_rate_p90,
    n_obs,
    CASE
      WHEN n_obs < 50 THEN 'INSUFFICIENT_DATA'
      WHEN viol_rate_p90 BETWEEN 0.08 AND 0.12 THEN 'PASS'
      ELSE 'FAIL'
    END AS season_verdict
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h12_v1_conditional`
  WHERE eval_scope = 'FULL_VAL'
)
SELECT
  eval_scope,
  season_group,
  viol_rate_p90,
  n_obs,
  season_verdict,
  -- overall verdict = PASS only if all seasons PASS (INSUFFICIENT_DATA = CONDITIONAL_PASS)
  CASE
    WHEN COUNTIF(season_verdict = 'FAIL') OVER () > 0 THEN 'FAIL'
    WHEN COUNTIF(season_verdict = 'INSUFFICIENT_DATA') OVER () > 0 THEN 'CONDITIONAL_PASS'
    ELSE 'PASS'
  END AS overall_verdict
FROM season_verdicts;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.gate_b3_verdict_h12_v1`;
