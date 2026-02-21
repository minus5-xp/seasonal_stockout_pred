-- ============================================================================
-- STEP 09: RUN SUMMARY  (h=4 v4)
-- ============================================================================
-- Creates a single audit row summarising all gate outcomes for this run.
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.run_summary_h4_v4` AS
WITH
b3 AS (
  SELECT overall_verdict AS b3_verdict,
    COUNTIF(season_verdict = 'PASS') AS b3_seasons_pass,
    COUNTIF(season_verdict = 'FAIL') AS b3_seasons_fail
  FROM `thequantitativeledger.cruzber_models_eu.gate_b3_verdict_h4_v4`
  GROUP BY overall_verdict
),
b3p AS (
  SELECT overall_verdict AS b3_paper_verdict
  FROM `thequantitativeledger.cruzber_models_eu.gate_b3_paper_verdict_h4_v4`
  GROUP BY overall_verdict
),
b4 AS (
  SELECT gate_b4_overall_verdict AS b4_verdict, avg_lift_v4, min_lift_v4, avg_delta_lift_pct_vs_v3
  FROM `thequantitativeledger.cruzber_models_eu.gate_b4_verdict_h4_v4`
),
lk AS (
  SELECT status AS leakage_status, n_rows_checked, n_wrong_horizon
  FROM `thequantitativeledger.cruzber_models_eu.leakage_check_h4_v4`
),
san AS (
  SELECT
    ROUND(MAX(pct_q90_negative_before), 4) AS max_pct_neg_before,
    ROUND(MAX(pct_q90_negative_after), 4)  AS max_pct_neg_after,
    ROUND(MAX(pct_q90_capped), 4)          AS max_pct_capped
  FROM `thequantitativeledger.cruzber_models_eu.diag_quantile_sanity_h4_v4`
  WHERE split = 'VAL'
)
SELECT
  'v4'                      AS version,
  b3.b3_verdict,
  b3.b3_seasons_pass,
  b3.b3_seasons_fail,
  b3p.b3_paper_verdict,
  b4.b4_verdict,
  b4.avg_lift_v4,
  b4.min_lift_v4,
  b4.avg_delta_lift_pct_vs_v3,
  lk.leakage_status,
  lk.n_rows_checked,
  lk.n_wrong_horizon,
  san.max_pct_neg_before     AS sanity_max_pct_neg_before,
  san.max_pct_neg_after      AS sanity_max_pct_neg_after,
  san.max_pct_capped         AS sanity_max_pct_capped,
  CASE
    WHEN b3.b3_verdict = 'PASS'
     AND b4.b4_verdict IN ('PASS', 'CONDITIONAL_PASS')
     AND lk.leakage_status = 'PASS'
    THEN 'DEPLOY'
    ELSE 'HOLD'
  END AS deployment_decision,
  CURRENT_TIMESTAMP()        AS run_at,
  CONCAT(
    'B3=', b3.b3_verdict,
    ' | B4=', b4.b4_verdict,
    ' | lift=', CAST(ROUND(b4.min_lift_v4, 2) AS STRING),
    ' | leakage=', lk.leakage_status,
    ' | neg_after=', CAST(san.max_pct_neg_after AS STRING)
  )                          AS summary_line
FROM b3, b3p, b4, lk, san;

SELECT * FROM `thequantitativeledger.cruzber_models_eu.run_summary_h4_v4`;
