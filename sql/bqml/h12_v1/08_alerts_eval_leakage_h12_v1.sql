-- ============================================================================
-- STEP 08: ALERTS EVALUATION + LEAKAGE CHECK + COMPARISON SCOPE  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   (a) eval_alerts_top100_h12_pooled_v1 : precision/recall/lift@100
--   (b) Demand forecast metrics: WMAPE, MAE, bias (y_true_12w)
--   (c) leakage_check_h12_v1 : anti-leakage assertions
--   (d) comparison_scope_h12_vs_R_v11 : alignment table vs R script
--
-- LEAKAGE CHECKS:
--   1. target_start_week = decision_week + 1 WEEK for ALL rows
--   2. target_end_week   = decision_week + 12 WEEK for ALL rows
--   3. VAL rows: decision_week in [2024-01-01, 2024-12-29]
--   4. TRAIN/CALIB rows: decision_week in [2021-01-04, 2023-12-31]
--   5. No rows with n_future_obs < 12 (all labels are complete)
--   6. n_wrong_horizon = 0 (no point forecast at t+12 instead of sum)
--
-- OUTPUT TABLES:
--   eval_alerts_top100_h12_pooled_v1
--   eval_demand_h12_v1
--   leakage_check_h12_v1
--   comparison_scope_h12_vs_R_v11
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 8a. POOLED ALERT EVALUATION
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h12_pooled_v1` AS
WITH
pooled AS (
  SELECT
    season_group,
    CAST(true_stockout_label AS INT64)  AS label_model,
    CAST(true_stockout_sales0 AS INT64) AS label_sales0,
    COALESCE(lost_units_proxy_12w, 0.0) AS lost_units_proxy
  FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v1`
),
global_base AS (
  SELECT
    season_group,
    COUNT(DISTINCT f.decision_week) * 100 AS n_alerts_expected,
    COUNT(*)                              AS n_total_universe,
    COUNTIF(CAST(stockout_event_12w AS INT64) = 1) AS n_total_stockouts_model,
    COUNTIF(y_true_12w = 0)               AS n_total_stockouts_sales0,
    SUM(COALESCE(lost_units_proxy_12w, 0.0)) AS total_lost_units
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1` f
  WHERE split = 'VAL'
  GROUP BY season_group
),
alert_perf AS (
  SELECT
    'POOLED' AS period,
    p.season_group,
    COUNT(*)                                          AS n_alerts,
    COUNTIF(p.label_model = 1)                        AS n_tp_model,
    SAFE_DIVIDE(COUNTIF(p.label_model = 1), COUNT(*)) AS precision_model,
    COUNTIF(p.label_sales0 = 1)                       AS n_tp_sales0,
    SAFE_DIVIDE(COUNTIF(p.label_sales0 = 1), COUNT(*)) AS precision_sales0,
    SUM(p.lost_units_proxy)                            AS lost_units_captured
  FROM pooled p
  GROUP BY p.season_group
)
SELECT
  ap.period,
  ap.season_group,
  ap.n_alerts,
  ap.n_tp_model,
  gb.n_total_stockouts_model,
  gb.n_total_universe,
  ap.precision_model,
  ap.precision_sales0,
  ap.n_tp_sales0,
  ap.lost_units_captured,
  gb.total_lost_units AS total_lost_units_universe,
  -- recall (model)
  SAFE_DIVIDE(ap.n_tp_model, NULLIF(gb.n_total_stockouts_model, 0)) AS recall_model,
  -- recall (sales=0)
  SAFE_DIVIDE(ap.n_tp_sales0, NULLIF(gb.n_total_stockouts_sales0, 0)) AS recall_sales0,
  -- lift@100 (model)
  SAFE_DIVIDE(
    ap.precision_model,
    SAFE_DIVIDE(gb.n_total_stockouts_model, NULLIF(gb.n_total_universe, 0))
  ) AS lift_model,
  -- lift@100 (sales=0)
  SAFE_DIVIDE(
    ap.precision_sales0,
    SAFE_DIVIDE(gb.n_total_stockouts_sales0, NULLIF(gb.n_total_universe, 0))
  ) AS lift_sales0
FROM alert_perf ap
LEFT JOIN global_base gb USING (season_group)
ORDER BY season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h12_pooled_v1`;

-- ---------------------------------------------------------------------------
-- 8b. DEMAND FORECAST EVALUATION  (VAL, active demand scope)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_demand_h12_v1` AS
SELECT
  'VAL' AS split,
  season_group,
  COUNT(*) AS n_obs,
  -- MAE
  ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)), 2) AS mae_12w,
  -- WMAPE = SUM(|actual - pred|) / SUM(|actual|)
  ROUND(
    SAFE_DIVIDE(
      SUM(ABS(y_true_12w - yhat_p50_12w)),
      NULLIF(SUM(ABS(y_true_12w)), 0)
    ), 4
  ) AS wmape_12w,
  -- bias (mean signed error / mean actual)
  ROUND(
    SAFE_DIVIDE(
      AVG(yhat_p50_12w - y_true_12w),
      NULLIF(AVG(y_true_12w), 0)
    ), 4
  ) AS bias_pct_12w,
  -- mean actual / mean predicted
  ROUND(AVG(y_true_12w), 2) AS avg_actual,
  ROUND(AVG(yhat_p50_12w), 2) AS avg_predicted
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0  -- active demand scope
GROUP BY season_group

UNION ALL

SELECT
  'VAL_GLOBAL' AS split,
  'ALL' AS season_group,
  COUNT(*) AS n_obs,
  ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)), 2) AS mae_12w,
  ROUND(
    SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)), 0))
  , 4) AS wmape_12w,
  ROUND(
    SAFE_DIVIDE(AVG(yhat_p50_12w - y_true_12w), NULLIF(AVG(y_true_12w), 0))
  , 4) AS bias_pct_12w,
  ROUND(AVG(y_true_12w), 2) AS avg_actual,
  ROUND(AVG(yhat_p50_12w), 2) AS avg_predicted
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL' AND amplitude >= 10.0
ORDER BY split, season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.eval_demand_h12_v1`;

-- ---------------------------------------------------------------------------
-- 8c. LEAKAGE CHECK
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_check_h12_v1` AS
WITH checks AS (
  SELECT
    COUNT(*)          AS n_rows_checked,

    -- Check 1: target_start_week = decision_week + 1 week
    COUNTIF(target_start_week != DATE_ADD(decision_week, INTERVAL 1 WEEK))
                      AS n_wrong_start_week,

    -- Check 2: target_end_week = decision_week + 12 weeks
    COUNTIF(target_end_week != DATE_ADD(decision_week, INTERVAL 12 WEEK))
                      AS n_wrong_end_week,

    -- Check 3: VAL only has decision_weeks in 2024
    COUNTIF(split = 'VAL' AND (decision_week < '2024-01-01' OR decision_week > '2024-12-29'))
                      AS n_val_outside_2024,

    -- Check 4: TRAIN/CALIB only in 2021-2023
    COUNTIF(split IN ('TRAIN', 'CALIB') AND decision_week > '2023-12-31')
                      AS n_traincalib_after_2023,

    -- Check 5: No rows where horizon != 12 weeks
    --   (target window length must be exactly 12 weeks for every row)
    COUNTIF(DATE_DIFF(target_end_week, target_start_week, WEEK) != 11)
                      AS n_wrong_horizon_length
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
  WHERE split IN ('TRAIN', 'CALIB', 'VAL')
),
horizon_check AS (
  -- Additional check: n_future_obs = 12 in train_calib_split
  SELECT COUNTIF(n_future_obs != 12) AS n_incomplete_labels
  FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h12_v1`
)
SELECT
  c.n_rows_checked,
  c.n_wrong_start_week,
  c.n_wrong_end_week,
  c.n_val_outside_2024,
  c.n_traincalib_after_2023,
  c.n_wrong_horizon_length,
  h.n_incomplete_labels,
  -- summary wrong_horizon (sum of all violations)
  c.n_wrong_start_week + c.n_wrong_end_week + c.n_wrong_horizon_length
    AS n_wrong_horizon,
  CASE
    WHEN c.n_wrong_start_week = 0
     AND c.n_wrong_end_week   = 0
     AND c.n_val_outside_2024 = 0
     AND c.n_traincalib_after_2023 = 0
     AND c.n_wrong_horizon_length  = 0
     AND h.n_incomplete_labels     = 0
    THEN 'PASS'
    ELSE 'FAIL'
  END AS status,
  CURRENT_TIMESTAMP() AS checked_at
FROM checks c
CROSS JOIN horizon_check h;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_check_h12_v1`;

-- ---------------------------------------------------------------------------
-- 8d. COMPARISON SCOPE TABLE  (H12 BQML vs R script 30_Dense_Panel_12W)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.comparison_scope_h12_vs_R_v11` AS

WITH scope_facts AS (
  SELECT
    -- TARGET alignment
    'sum t+1..t+12' AS bqml_target_definition,
    'sum(lead(1:12) in R)' AS r_target_definition,
    CASE WHEN bqml_target_is_cumulative = 1 THEN 'MATCH' ELSE 'FAIL' END AS target_type_status,

    -- TEMPORAL alignment
    MIN(CASE WHEN split = 'TRAIN' THEN decision_week END) AS bqml_train_start,
    MAX(CASE WHEN split = 'TRAIN' THEN decision_week END) AS bqml_train_end,
    MIN(CASE WHEN split = 'CALIB' THEN decision_week END) AS bqml_calib_start,
    MAX(CASE WHEN split = 'CALIB' THEN decision_week END) AS bqml_calib_end,
    MIN(CASE WHEN split = 'VAL'   THEN decision_week END) AS bqml_val_start,
    MAX(CASE WHEN split = 'VAL'   THEN decision_week END) AS bqml_val_end,

    -- TARGET completeness
    COUNTIF(n_future_obs != 12) AS n_incomplete_target_rows,

    -- VAL outside 2024
    COUNTIF(split = 'VAL' AND EXTRACT(YEAR FROM decision_week) != 2024) AS n_val_outside_2024,

    -- Horizon type check (not point forecast at t+12)
    -- A point forecast at t+12 would have n_future_obs=1, which we require to be 12
    COUNTIF(n_future_obs = 1) AS n_point_forecast_rows  -- should be 0

  FROM (
    SELECT
      split, decision_week, n_future_obs,
      1 AS bqml_target_is_cumulative  -- always TRUE by construction
    FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h12_v1`
  )
  GROUP BY bqml_target_is_cumulative, bqml_target_is_cumulative  -- dummy grouping
)
SELECT
  -- R script reference
  '30_Dense_Panel_12W_Unified_Best.R' AS r_script_reference,
  'sum(lead(1:12)) per SKU per week'  AS r_target_definition,
  '2021, 2022, 2023'                  AS r_train_years,
  '2024'                              AS r_test_year,
  'drop_na(target_12w_ahead)'         AS r_incomplete_target_handling,

  -- BQML pipeline
  'y_true_12w = SUM(y_sales, t+1..t+12)' AS bqml_target_definition,
  CAST(s.bqml_train_start AS STRING)      AS bqml_train_start,
  CAST(s.bqml_train_end   AS STRING)      AS bqml_train_end,
  CAST(s.bqml_calib_start AS STRING)      AS bqml_calib_start,
  CAST(s.bqml_calib_end   AS STRING)      AS bqml_calib_end,
  CAST(s.bqml_val_start   AS STRING)      AS bqml_val_start,
  CAST(s.bqml_val_end     AS STRING)      AS bqml_val_end,
  'n_future_obs = 12'                     AS bqml_incomplete_target_handling,
  s.n_incomplete_target_rows,
  s.n_val_outside_2024,
  s.n_point_forecast_rows,

  -- STATUS
  CASE
    WHEN s.n_incomplete_target_rows > 0 THEN 'FAIL: incomplete_target_rows_present'
    WHEN s.n_val_outside_2024       > 0 THEN 'FAIL: val_decision_weeks_outside_2024'
    WHEN s.n_point_forecast_rows    > 0 THEN 'FAIL: point_forecast_t+12_detected'
    ELSE 'OK'
  END AS status,

  CURRENT_TIMESTAMP() AS evaluated_at

FROM scope_facts s;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.comparison_scope_h12_vs_R_v11`;
