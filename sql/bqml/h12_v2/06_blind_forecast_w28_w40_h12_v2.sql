-- ============================================================================
-- STEP 06: BLIND FORECAST W28-W40 2024  (h=12 v2)
-- ============================================================================
-- PURPOSE:
--   Generate blind forecast for iso_week 28-40 of 2024 ONLY if
--   gate_verdict_h12_v2.deployment_decision = 'DEPLOY'.
--
--   If HOLD: creates tables with 0 data rows and a status column.
--
-- ANTI-LEAKAGE GUARANTEES:
--   - y_true_12w = NULL (always masked)
--   - stockout_event_12w = NULL (always masked)
--   - n_stockout_weeks_12w = NULL (always masked)
--   - features are from decision_week or earlier only
--   - labels_included = FALSE
--
-- OUTPUT TABLES:
--   blind_forecast_national_w28_w40_h12_v2
--   blind_forecast_provincial_w28_w40_h12_v2
--   blind_alerts_top100_w28_w40_h12_v2
--   blind_leakage_check_h12_v2
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 6a. NATIONAL BLIND FORECAST
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2` AS
WITH deployment AS (
  SELECT deployment_decision, failed_gates, selected_policy
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` LIMIT 1
),
blind_rows AS (
  SELECT
    fn.*,
    d.deployment_decision,
    d.failed_gates,
    'BLIND_W28_W40_2024' AS forecast_type,
    FALSE AS labels_included
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2` fn
  CROSS JOIN deployment d
  WHERE fn.eval_split_v2 = 'BLIND'
    AND d.deployment_decision = 'DEPLOY'
)
SELECT
  decision_week,
  iso_year,
  iso_week,
  target_start_week,
  target_end_week,
  sku_id,
  sku_name,
  familia,
  abc_class,
  sb_class,
  season_group,
  eval_split_v2,
  p_oos_h12,
  alert_score,
  selected_policy,
  yhat_p50_12w,
  q80_12w,
  q90_12w,
  q95_12w,
  q99_12w,
  expected_buffer_q90,
  expected_buffer_q95,
  lost_units_proxy_12w,
  service_recommendation,
  -- LABELS MASKED — always NULL for blind
  CAST(NULL AS FLOAT64) AS y_true_12w,
  CAST(NULL AS INT64)   AS stockout_event_12w,
  CAST(NULL AS INT64)   AS n_stockout_weeks_12w,
  forecast_type,
  labels_included,
  version
FROM blind_rows

UNION ALL

-- If HOLD: produce a status row (no forecast data)
SELECT
  CAST(NULL AS DATE), CAST(NULL AS INT64), CAST(NULL AS INT64),
  CAST(NULL AS DATE), CAST(NULL AS DATE),
  CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS STRING), 'HOLD_NOT_GENERATED' AS eval_split_v2,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), d.selected_policy,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CONCAT('HOLD: ', d.failed_gates),
  CAST(NULL AS FLOAT64), CAST(NULL AS INT64), CAST(NULL AS INT64),
  CONCAT('HOLD_DEPLOYMENT_REQUIRED: ', d.failed_gates),
  FALSE,
  'h12_v2'
FROM (SELECT deployment_decision, failed_gates, selected_policy
      FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` LIMIT 1) d
WHERE d.deployment_decision != 'DEPLOY';

-- Blind row count
SELECT
  forecast_type,
  COUNT(*) AS n_rows,
  MIN(iso_week) AS min_iso_week,
  MAX(iso_week) AS max_iso_week,
  COUNTIF(y_true_12w IS NOT NULL) AS n_labels_exposed  -- MUST BE 0
FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2`
GROUP BY forecast_type;

-- ---------------------------------------------------------------------------
-- 6b. PROVINCIAL BLIND FORECAST
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_provincial_w28_w40_h12_v2` AS
WITH deployment AS (
  SELECT deployment_decision FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` LIMIT 1
)
SELECT
  fp.decision_week,
  fp.iso_year,
  fp.iso_week,
  fp.target_start_week,
  fp.target_end_week,
  fp.sku_id,
  fp.sku_name,
  fp.familia,
  fp.abc_class,
  fp.sb_class,
  fp.provincia,
  fp.region,
  fp.season_group,
  fp.eval_split_v2,
  fp.p_oos_12w,
  fp.alert_score_national,
  fp.yhat_p50_12w_national,
  fp.q90_12w_national,
  fp.q95_12w_national,
  fp.yhat_p50_12w_prov,
  fp.q80_12w_prov,
  fp.q90_12w_prov,
  fp.q95_12w_prov,
  fp.q99_12w_prov,
  fp.expected_buffer_q90_prov,
  fp.lost_units_proxy_12w_prov,
  -- LABELS MASKED
  CAST(NULL AS FLOAT64) AS y_true_12w,
  CAST(NULL AS INT64)   AS stockout_event_12w,
  fp.dirichlet_weight,
  fp.dirichlet_weight_raw,
  fp.prior_prov,
  fp.prior_level_used,
  fp.alpha0_used,
  fp.hist_units_sku_prov_52w,
  fp.hist_units_sku_total_52w,
  fp.hist_weeks_sku_prov_52w,
  'BLIND_W28_W40_2024' AS forecast_type,
  FALSE AS labels_included,
  fp.version
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2` fp
CROSS JOIN deployment d
WHERE fp.eval_split_v2 = 'BLIND'
  AND d.deployment_decision = 'DEPLOY'

UNION ALL

-- HOLD fallback: empty-schema row so table always exists
SELECT
  CAST(NULL AS DATE), CAST(NULL AS INT64), CAST(NULL AS INT64),
  CAST(NULL AS DATE), CAST(NULL AS DATE),
  CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS STRING), 'HOLD_NOT_GENERATED' AS eval_split_v2,
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS INT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS STRING), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS INT64),
  CONCAT('HOLD: ', d.failed_gates) AS forecast_type,
  FALSE AS labels_included,
  'h12_v2' AS version
FROM (SELECT deployment_decision, failed_gates FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` LIMIT 1) d
WHERE d.deployment_decision != 'DEPLOY';

-- ---------------------------------------------------------------------------
-- 6c. BLIND ALERTS TOP-100
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_alerts_top100_w28_w40_h12_v2` AS
WITH deployment AS (
  SELECT deployment_decision FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` LIMIT 1
)
SELECT
  a.decision_week,
  a.iso_year,
  a.iso_week,
  a.target_start_week,
  a.target_end_week,
  a.sku_id,
  m.sku_name,
  m.familia,
  m.abc_class,
  a.season_group,
  a.p_oos_h12,
  a.risk_score AS alert_score,
  a.applied_policy,
  a.alert_rank,
  a.yhat_p50_12w,
  a.q90_12w,
  a.q95_12w,
  GREATEST(a.q90_12w - a.yhat_p50_12w, 0.0) AS expected_buffer_q90,
  a.lost_units_proxy_12w,
  CASE WHEN a.p_oos_h12 >= 0.80 THEN 'CRITICAL'
       WHEN a.p_oos_h12 >= 0.60 THEN 'HIGH'
       WHEN a.p_oos_h12 >= 0.40 THEN 'MEDIUM'
       ELSE 'LOW' END AS service_recommendation,
  -- LABELS MASKED
  CAST(NULL AS INT64)   AS true_stockout_label,
  CAST(NULL AS INT64)   AS true_stockout_sales0,
  'BLIND_W28_W40_2024'  AS forecast_type,
  FALSE                 AS labels_included,
  a.version
FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v2` a
CROSS JOIN deployment d
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_metadata_h12_v2` m ON m.sku_id = a.sku_id
WHERE a.eval_split_v2 = 'BLIND'
  AND d.deployment_decision = 'DEPLOY';

-- ---------------------------------------------------------------------------
-- 6d. BLIND LEAKAGE CHECK
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2` AS
WITH
national_blind AS (
  SELECT
    COUNT(*) AS n_rows,
    COUNTIF(y_true_12w IS NOT NULL)        AS n_rows_with_y_true_not_null,
    COUNTIF(stockout_event_12w IS NOT NULL) AS n_rows_with_stockout_not_null,
    COUNTIF(labels_included = TRUE)        AS n_rows_labels_included,
    MIN(iso_week)                          AS min_iso_week,
    MAX(iso_week)                          AS max_iso_week,
    COUNTIF(iso_week < 28 OR iso_week > 40) AS n_out_of_blind_range
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2`
  WHERE forecast_type = 'BLIND_W28_W40_2024'
),
deployment AS (
  SELECT deployment_decision FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` LIMIT 1
)
SELECT
  nb.n_rows,
  nb.n_rows_with_y_true_not_null,
  nb.n_rows_with_stockout_not_null,
  nb.n_rows_labels_included,
  nb.min_iso_week,
  nb.max_iso_week,
  nb.n_out_of_blind_range,
  d.deployment_decision AS deployment_required_status,
  CASE
    WHEN nb.n_rows_with_y_true_not_null = 0
     AND nb.n_rows_with_stockout_not_null = 0
     AND nb.n_rows_labels_included = 0
     AND nb.n_out_of_blind_range = 0
     AND d.deployment_decision = 'DEPLOY'
    THEN 'PASS'
    ELSE 'FAIL'
  END AS blind_leakage_status
FROM national_blind nb
CROSS JOIN deployment d;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2`;
