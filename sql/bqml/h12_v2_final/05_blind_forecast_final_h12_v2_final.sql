-- ============================================================================
-- STEP 05: BLIND FORECAST FINAL W28-W40  (h12_v2_final)
-- ============================================================================
-- PURPOSE:
--   Produce final blind forecast tables using corrected probabilities + Dirichlet.
--   Only creates DEPLOY tables if deployment_decision_final = 'DEPLOY_FULL'.
--   Otherwise creates HOLD placeholder tables (always exists for run_summary).
--
-- ANTI-LEAKAGE:
--   y_true_12w = NULL, stockout_event_12w = NULL, labels_included = FALSE.
--   Weeks 28-40 of 2024 only. No future data in features.
--
-- OUTPUTS:
--   blind_forecast_national_w28_w40_h12_v2_final
--   blind_forecast_provincial_w28_w40_h12_v2_final
--   blind_alerts_top100_w28_w40_h12_v2_final
--   blind_leakage_check_h12_v2_final
--   blind_dirichlet_reconciliation_check_h12_v2_final
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5a. NATIONAL BLIND FORECAST FINAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2_final` AS
WITH
verdict AS (
  SELECT deployment_decision_final, failed_gates_final, selected_policy
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2_final` LIMIT 1
),
blind_rows AS (
  SELECT
    f.decision_week,
    f.iso_year,
    f.iso_week,
    f.target_start_week,
    f.target_end_week,
    f.sku_id,
    f.sku_name,
    f.familia,
    f.abc_class,
    f.sb_class,
    f.season_group,
    f.p_oos_12w_rank,
    f.p_oos_12w_report,
    f.p_oos_12w_deploy,
    f.probability_reporting_choice,
    f.alert_score_final,
    f.selected_policy,
    ROW_NUMBER() OVER (PARTITION BY f.decision_week ORDER BY f.alert_score_final DESC) AS rank_alert,
    f.yhat_p50_12w,
    f.q80_12w,
    f.q90_12w,
    f.q95_12w,
    f.q99_12w,
    f.expected_buffer_q90,
    f.expected_buffer_q95,
    f.service_recommendation,
    'BLIND_W28_W40_2024_FINAL' AS forecast_type,
    FALSE AS labels_included,
    'h12_v2_final' AS version
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2_final` f
  CROSS JOIN verdict v
  WHERE f.eval_split_v2 = 'BLIND'
    AND v.deployment_decision_final = 'DEPLOY_FULL'
)
-- DEPLOY_FULL rows
SELECT
  decision_week, iso_year, iso_week, target_start_week, target_end_week,
  sku_id, sku_name, familia, abc_class, sb_class, season_group,
  p_oos_12w_rank, p_oos_12w_report, p_oos_12w_deploy, probability_reporting_choice,
  alert_score_final, selected_policy, rank_alert,
  yhat_p50_12w, q80_12w, q90_12w, q95_12w, q99_12w,
  expected_buffer_q90, expected_buffer_q95,
  service_recommendation,
  CAST(NULL AS FLOAT64) AS y_true_12w,
  CAST(NULL AS INT64)   AS stockout_event_12w,
  CAST(NULL AS INT64)   AS n_stockout_weeks_12w,
  forecast_type, labels_included, version
FROM blind_rows

UNION ALL

-- HOLD fallback (always creates table with status row)
SELECT
  CAST(NULL AS DATE), CAST(NULL AS INT64), CAST(NULL AS INT64),
  CAST(NULL AS DATE), CAST(NULL AS DATE),
  CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS STRING), CAST(NULL AS STRING), CAST(NULL AS STRING),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS STRING), CAST(NULL AS FLOAT64), v.selected_policy,
  CAST(NULL AS INT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CAST(NULL AS FLOAT64), CAST(NULL AS FLOAT64),
  CONCAT('HOLD: ', v.failed_gates_final),
  CAST(NULL AS FLOAT64), CAST(NULL AS INT64), CAST(NULL AS INT64),
  CONCAT('HOLD_DEPLOYMENT_REQUIRED: ', v.failed_gates_final),
  FALSE, 'h12_v2_final'
FROM verdict v
WHERE v.deployment_decision_final != 'DEPLOY_FULL';

-- Sanity
SELECT forecast_type, COUNT(*) n_rows,
  MIN(iso_week) min_week, MAX(iso_week) max_week,
  COUNTIF(y_true_12w IS NOT NULL) n_labels_exposed
FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2_final`
GROUP BY forecast_type;

-- ---------------------------------------------------------------------------
-- 5b. PROVINCIAL BLIND FORECAST FINAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_provincial_w28_w40_h12_v2_final` AS
WITH verdict AS (
  SELECT deployment_decision_final, failed_gates_final
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2_final` LIMIT 1
),
blind_recon AS (
  SELECT
    decision_week, sku_id, row_status AS reconciliation_status
  FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2_final`
)
SELECT
  p.decision_week,
  p.iso_year,
  p.iso_week,
  p.target_start_week,
  p.target_end_week,
  p.sku_id,
  p.sku_name,
  p.familia,
  p.abc_class,
  p.sb_class,
  p.provincia,
  p.region,
  p.season_group,
  p.p_oos_12w_rank,
  p.p_oos_12w_report,
  p.p_oos_12w_deploy,
  p.probability_reporting_choice,
  p.alert_score_national,
  p.yhat_p50_12w_national,
  p.q90_12w_national,
  p.q95_12w_national,
  p.yhat_p50_12w_prov_final,
  p.q80_12w_prov_final,
  p.q90_12w_prov_final,
  p.q95_12w_prov_final,
  p.q99_12w_prov_final,
  p.expected_buffer_q90_prov_final,
  p.lost_units_proxy_12w_prov_final,
  p.dirichlet_weight_final,
  p.prior_level_used_final,
  p.dirichlet_fix_reason,
  COALESCE(r.reconciliation_status, 'UNKNOWN') AS reconciliation_status,
  -- LABELS MASKED
  CAST(NULL AS FLOAT64) AS y_true_12w,
  CAST(NULL AS INT64)   AS stockout_event_12w,
  'BLIND_W28_W40_2024_FINAL' AS forecast_type,
  FALSE AS labels_included,
  p.version
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2_final` p
LEFT JOIN blind_recon r ON r.sku_id = p.sku_id AND r.decision_week = p.decision_week
CROSS JOIN verdict v
WHERE p.eval_split_v2 = 'BLIND'
  AND v.deployment_decision_final = 'DEPLOY_FULL'
  AND p.provincia != 'NACIONAL';   -- Spain 52 provinces only

-- ---------------------------------------------------------------------------
-- 5c. BLIND ALERTS TOP-100 FINAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_alerts_top100_w28_w40_h12_v2_final` AS
SELECT *
FROM (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY alert_score_final DESC) AS alert_rank_final
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2_final`
  WHERE forecast_type = 'BLIND_W28_W40_2024_FINAL'
)
WHERE alert_rank_final <= 100
ORDER BY decision_week, alert_rank_final;

-- ---------------------------------------------------------------------------
-- 5d. BLIND LEAKAGE CHECK FINAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2_final` AS
WITH
national AS (
  SELECT
    COUNT(*) AS n_rows,
    COUNTIF(y_true_12w IS NOT NULL) AS n_y_true_not_null,
    COUNTIF(stockout_event_12w IS NOT NULL) AS n_stockout_not_null,
    COUNTIF(CAST(labels_included AS INT64) = 1) AS n_labels_included,
    MIN(iso_week) AS min_iso_week,
    MAX(iso_week) AS max_iso_week,
    COUNTIF(iso_week < 28 OR iso_week > 40) AS n_out_of_range
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2_final`
  WHERE forecast_type = 'BLIND_W28_W40_2024_FINAL'
),
verdict AS (
  SELECT deployment_decision_final
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2_final` LIMIT 1
)
SELECT
  n.n_rows,
  n.n_y_true_not_null  AS n_rows_with_y_true_not_null,
  n.n_stockout_not_null AS n_rows_with_stockout_label_not_null,
  n.n_labels_included,
  n.min_iso_week,
  n.max_iso_week,
  n.n_out_of_range,
  v.deployment_decision_final AS deployment_required_status,
  CASE
    WHEN n.n_y_true_not_null = 0
     AND n.n_stockout_not_null = 0
     AND n.n_labels_included = 0
     AND n.n_out_of_range = 0
     AND v.deployment_decision_final = 'DEPLOY_FULL'
    THEN 'PASS'
    WHEN v.deployment_decision_final != 'DEPLOY_FULL'
    THEN 'HOLD_NOT_GENERATED'
    ELSE 'FAIL'
  END AS blind_leakage_status
FROM national n, verdict v;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2_final`;

-- ---------------------------------------------------------------------------
-- 5e. BLIND DIRICHLET RECONCILIATION CHECK FINAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_dirichlet_reconciliation_check_h12_v2_final` AS
WITH
prov_sum AS (
  SELECT
    decision_week,
    sku_id,
    SUM(dirichlet_weight_final) AS sum_weight_final,
    SUM(yhat_p50_12w_prov_final) AS sum_p50,
    SUM(q90_12w_prov_final) AS sum_q90,
    SUM(q95_12w_prov_final) AS sum_q95,
    COUNT(DISTINCT provincia) AS n_prov
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_provincial_w28_w40_h12_v2_final`
  GROUP BY decision_week, sku_id
),
nat AS (
  SELECT decision_week, sku_id, yhat_p50_12w AS p50_nat, q90_12w AS q90_nat, q95_12w AS q95_nat
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_national_w28_w40_h12_v2_final`
  WHERE forecast_type = 'BLIND_W28_W40_2024_FINAL'
)
SELECT
  p.decision_week, p.sku_id, p.n_prov,
  ROUND(ABS(p.sum_weight_final - 1.0), 12) AS err_weight,
  ROUND(ABS(p.sum_p50 - n.p50_nat), 6) AS err_p50,
  ROUND(ABS(p.sum_q90 - n.q90_nat), 6) AS err_q90,
  ROUND(ABS(p.sum_q95 - n.q95_nat), 6) AS err_q95,
  CASE
    WHEN ABS(p.sum_weight_final - 1.0) <= 1e-9
     AND ABS(p.sum_p50 - n.p50_nat) <= 0.001
     AND ABS(p.sum_q90 - n.q90_nat) <= 0.001
    THEN 'PASS' ELSE 'FAIL'
  END AS row_status
FROM prov_sum p
JOIN nat n USING (decision_week, sku_id);
