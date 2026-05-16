-- ============================================================================
-- STEP 09: RUN SUMMARY  (h=12 v1)
-- ============================================================================
-- Creates a single audit row summarising all gate outcomes.
-- deployment_decision = DEPLOY if all required gates pass, else HOLD.
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.run_summary_h12_v1` AS
WITH

-- Gate B3 verdict
b3 AS (
  SELECT
    ANY_VALUE(overall_verdict) AS b3_verdict,
    COUNTIF(season_verdict = 'PASS') AS b3_seasons_pass,
    COUNTIF(season_verdict = 'FAIL') AS b3_seasons_fail,
    COUNTIF(season_verdict = 'INSUFFICIENT_DATA') AS b3_seasons_insufficient
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_b3_verdict_h12_v1`
),

-- Coverage metrics on VAL (active demand)
cov AS (
  SELECT
    season_group,
    viol_rate_p90,
    viol_rate_p95
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h12_v1_conditional`
  WHERE eval_scope = 'FULL_VAL'
),

cov_agg AS (
  SELECT
    ROUND(AVG(viol_rate_p90), 4) AS avg_viol_rate_p90,
    ROUND(AVG(viol_rate_p95), 4) AS avg_viol_rate_p95
  FROM cov
),

-- Alerts evaluation (POOLED, all seasons)
alerts AS (
  SELECT
    ROUND(AVG(precision_model), 4) AS avg_precision_model,
    ROUND(AVG(recall_model),    4) AS avg_recall_model,
    ROUND(AVG(lift_model),      4) AS avg_lift_model,
    MIN(lift_model)                AS min_lift_model
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h12_pooled_v1`
),

-- Gate B4: lift > 1.5
b4 AS (
  SELECT
    CASE
      WHEN (SELECT MIN(lift_model) FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h12_pooled_v1`) >= 1.5
        THEN 'PASS'
      WHEN (SELECT MIN(lift_model) FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h12_pooled_v1`) >= 1.0
        THEN 'CONDITIONAL_PASS'
      ELSE 'FAIL'
    END AS b4_verdict
),

-- Demand metrics (global, active demand)
demand AS (
  SELECT
    ROUND(ANY_VALUE(CASE WHEN season_group = 'ALL' THEN mae_12w   END), 2) AS mae_12w,
    ROUND(ANY_VALUE(CASE WHEN season_group = 'ALL' THEN wmape_12w END), 4) AS wmape_12w,
    ROUND(ANY_VALUE(CASE WHEN season_group = 'ALL' THEN bias_pct_12w END), 4) AS bias_pct_12w
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_demand_h12_v1`
  WHERE split = 'VAL_GLOBAL'
),

-- OOS Brier scores (from calibrated scores)
brier AS (
  SELECT
    ROUND(AVG(POW(p_oos_raw - CAST(true_label AS FLOAT64), 2)), 5) AS brier_raw,
    ROUND(AVG(POW(p_oos_h12 - CAST(true_label AS FLOAT64), 2)), 5) AS brier_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1`
  WHERE split = 'VAL'
),

-- Leakage
lk AS (
  SELECT status AS leakage_status, n_rows_checked, n_wrong_horizon
  FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_check_h12_v1`
),

-- Quantile sanity (VAL)
san AS (
  SELECT
    ROUND(SUM(n_viol_q90_lt_q85), 0) AS total_mono_violations,
    ROUND(SUM(n_negative_q90), 0)    AS total_negative_q90,
    ROUND(MAX(pct_q90_capped), 4)    AS max_pct_q90_capped
  FROM `{PROJECT_ID}.{BQ_DATASET}.diag_quantile_sanity_h12_v1`
  WHERE split = 'VAL'
),

-- Comparison scope
comp AS (
  SELECT status AS comparison_scope_status
  FROM `{PROJECT_ID}.{BQ_DATASET}.comparison_scope_h12_vs_R_v11`
)

SELECT
  'h12_v1'                              AS version,
  -- B3 gate
  b3.b3_verdict,
  b3.b3_seasons_pass,
  b3.b3_seasons_fail,
  -- B4 gate
  b4.b4_verdict,
  alerts.avg_lift_model,
  alerts.min_lift_model,
  -- alerts evaluation
  alerts.avg_precision_model            AS precision_at_100,
  alerts.avg_recall_model               AS recall_at_100,
  -- demand metrics
  demand.mae_12w,
  demand.wmape_12w,
  demand.bias_pct_12w,
  -- OOS calibration
  brier.brier_raw,
  brier.brier_cal,
  -- coverage
  cov_agg.avg_viol_rate_p90,
  cov_agg.avg_viol_rate_p95,
  -- leakage
  lk.leakage_status,
  lk.n_rows_checked,
  lk.n_wrong_horizon,
  -- sanity
  san.total_mono_violations             AS sanity_mono_violations,
  san.total_negative_q90                AS sanity_negative_q90,
  san.max_pct_q90_capped               AS sanity_max_pct_q90_capped,
  -- comparison scope
  comp.comparison_scope_status,
  -- deployment decision
  CASE
    WHEN b3.b3_verdict IN ('PASS', 'CONDITIONAL_PASS')
     AND b4.b4_verdict IN ('PASS', 'CONDITIONAL_PASS')
     AND lk.leakage_status  = 'PASS'
     AND comp.comparison_scope_status = 'OK'
    THEN 'DEPLOY'
    ELSE 'HOLD'
  END                                   AS deployment_decision,
  CURRENT_TIMESTAMP()                   AS run_at,
  CONCAT(
    'B3=', b3.b3_verdict,
    ' | B4=', b4.b4_verdict,
    ' | lift=', CAST(ROUND(alerts.avg_lift_model, 2) AS STRING),
    ' | wmape=', CAST(demand.wmape_12w AS STRING),
    ' | viol_p90=', CAST(cov_agg.avg_viol_rate_p90 AS STRING),
    ' | leakage=', lk.leakage_status,
    ' | scope=', comp.comparison_scope_status
  )                                     AS summary_line
FROM b3, b4, alerts, demand, brier, cov_agg, lk, san, comp;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.run_summary_h12_v1`;
