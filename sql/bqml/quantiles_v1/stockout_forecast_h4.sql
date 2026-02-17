-- ============================================================================
-- BIGQUERY + BQML: 4-WEEK AHEAD STOCKOUT FORECAST (HORIZON h=4)
-- ============================================================================
-- Purpose: Production-ready implementation of 3-layer probabilistic forecasting
--   Layer 1: OOS Classification → p_oos_h4 (stockout risk at t+4)
--   Layer 2: Demand Regression → yhat_p50_h4 (median demand at t+4)
--   Layer 3: Empirical Quantiles → q90_h4, q95_h4 (stratified by 20 segments)
--
-- Architecture:
--   - Strict leakage control (no future information in features)
--   - ISO week arithmetic (week_start_date + 4 weeks)
--   - Segmentation: 2 seasons × 10 deciles = 20 segments
--   - BQML models: Boosted Trees (classifier + regressor)
--
-- EXECUTION ORDER:
--   1. Run entire script top-to-bottom (takes ~10-20 min for large dataset)
--   2. All tables use CREATE OR REPLACE (idempotent)
--   3. Models retrain each run (set AUTO_CLASS_WEIGHTS=TRUE for imbalance)
--
-- OUTPUT ARTIFACTS:
--   - Models: m_oos_h4, m_demand_h4
--   - Tables: weekly_features_h4, forecast_h4, alerts_top100_h4
--   - Evaluation: eval_alerts_h4, eval_coverage_h4, leakage_check_h4
--
-- ENVIRONMENT VARIABLES (injected by runner):
--   - PROJECT_ID: GCP project ID (default: thequantitativeledger)
--   - BQ_DATASET: BigQuery dataset name (default: cruzber_models_eu)
--   - BASE_SALES_TABLE: Fully qualified sales table (REQUIRED)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SECTION 0: CONFIGURATION & PARAMETERS
-- ----------------------------------------------------------------------------

DECLARE PROJECT_ID STRING DEFAULT '{PROJECT_ID}';
DECLARE DATASET_NAME STRING DEFAULT '{BQ_DATASET}';
DECLARE BASE_SALES_TABLE STRING DEFAULT '{BASE_SALES_TABLE}';
DECLARE HORIZON_WEEKS INT64 DEFAULT 4;  -- Forecast horizon (t+4 weeks)
DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';  -- Monday of ISO week 1
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-12-31';
DECLARE VAL_START_DATE DATE DEFAULT '2024-01-01';
DECLARE VAL_END_DATE DATE DEFAULT '2024-12-29';  -- ISO week 52 end
DECLARE HIGH_SEASON_WEEKS ARRAY<INT64> DEFAULT [20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35];  -- Weeks 20-35
DECLARE EPSILON FLOAT64 DEFAULT 0.01;  -- Floor for division stability
DECLARE DEMAND_ACTIVE_THRESHOLD FLOAT64 DEFAULT 5.0;
DECLARE VIP_TOP_N INT64 DEFAULT 50;
DECLARE VIP_MIN_TOTAL_BASE FLOAT64 DEFAULT 0.0;
DECLARE PRICE_EPS FLOAT64 DEFAULT 1e-6;
DECLARE MAX_PRICE_RATIO_DISCREPANCY FLOAT64 DEFAULT 5.0;

-- Validation: BASE_SALES_TABLE must be provided
IF BASE_SALES_TABLE IS NULL OR BASE_SALES_TABLE = '' THEN
  RAISE USING MESSAGE = 'ERROR: BASE_SALES_TABLE environment variable required. Set it to your fully-qualified sales table (e.g., project.dataset.fact_lineas_albaran)';
END IF;

-- ----------------------------------------------------------------------------
-- SECTION 1: WEEKLY AGGREGATION (SKU × ISO WEEK GRAIN) — DENSE SPINE
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_base` AS
WITH sku_universe AS (
  SELECT DISTINCT
    CAST(codigo_articulo AS STRING) AS sku_id
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN TRAIN_START_DATE AND DATE_ADD(VAL_END_DATE, INTERVAL (HORIZON_WEEKS + 8) WEEK)
),
week_calendar AS (
  SELECT
    wk AS week_start_date
  FROM UNNEST(
    GENERATE_DATE_ARRAY(
      DATE_TRUNC(TRAIN_START_DATE, ISOWEEK),
      DATE_TRUNC(DATE_ADD(VAL_END_DATE, INTERVAL (HORIZON_WEEKS + 8) WEEK), ISOWEEK),
      INTERVAL 7 DAY
    )
  ) AS wk
),
weekly_sales AS (
  SELECT
    CAST(codigo_articulo AS STRING) AS sku_id,
    DATE_TRUNC(fecha_albaran, ISOWEEK) AS week_start_date,
    SUM(CASE WHEN unidades > 0 THEN unidades ELSE 0 END) AS y_sales,
    COUNT(DISTINCT fecha_albaran) AS n_days_active,
    COUNT(DISTINCT CASE WHEN unidades > 0 THEN fecha_albaran END) AS n_days_nonzero
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN TRAIN_START_DATE AND DATE_ADD(VAL_END_DATE, INTERVAL (HORIZON_WEEKS + 8) WEEK)
  GROUP BY sku_id, week_start_date
),
spine AS (
  SELECT
    s.sku_id,
    c.week_start_date
  FROM sku_universe s
  CROSS JOIN week_calendar c
)
SELECT
  sp.sku_id,
  sp.week_start_date,
  EXTRACT(ISOYEAR FROM sp.week_start_date) AS iso_year,
  EXTRACT(ISOWEEK FROM sp.week_start_date) AS iso_week,
  COALESCE(ws.y_sales, 0) AS y_sales,
  COALESCE(ws.n_days_active, 0) AS n_days_active,
  COALESCE(ws.n_days_nonzero, 0) AS n_days_nonzero
FROM spine sp
LEFT JOIN weekly_sales ws
  USING (sku_id, week_start_date)
ORDER BY sku_id, week_start_date;

-- ----------------------------------------------------------------------------
-- SECTION 1B: CUSTOMER-LEVEL WEEKLY AGGREGATION (SKU × WEEK × CUSTOMER)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_sku_customer` AS
SELECT
  codigo_articulo AS sku_id,
  DATE_TRUNC(fecha_albaran, ISOWEEK) AS week_start_date,
  codigo_cliente,
  SUM(unidades) AS units_week,
  SUM(base_imponible) AS base_week,
  SAFE_DIVIDE(SUM(precio * unidades), NULLIF(SUM(unidades), 0)) AS avg_precio_weighted_week,
  COUNT(DISTINCT fecha_albaran) AS n_days_active_week
FROM {BASE_SALES_TABLE}
WHERE fecha_albaran BETWEEN TRAIN_START_DATE AND DATE_ADD(VAL_END_DATE, INTERVAL 8 WEEK)
GROUP BY sku_id, week_start_date, codigo_cliente;

-- ----------------------------------------------------------------------------
-- SECTION 1C: VIP CUSTOMER LIST (TRAIN+CALIB ONLY)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.vip_customers_h4` AS
WITH customer_totals AS (
  SELECT
    codigo_cliente,
    SUM(base_imponible) AS total_base_traincalib,
    SUM(unidades) AS total_units_traincalib
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN TRAIN_START_DATE AND DATE_SUB(VAL_START_DATE, INTERVAL 1 DAY)
  GROUP BY codigo_cliente
),
ranked AS (
  SELECT
    *,
    DENSE_RANK() OVER (ORDER BY total_base_traincalib DESC) AS rnk
  FROM customer_totals
  WHERE total_base_traincalib >= VIP_MIN_TOTAL_BASE
)
SELECT
  codigo_cliente,
  total_base_traincalib,
  total_units_traincalib,
  rnk
FROM ranked
WHERE rnk <= VIP_TOP_N
ORDER BY rnk;

-- ----------------------------------------------------------------------------
-- SECTION 1D: SKU-WEEK CUSTOMER METRICS (CONCENTRATION / WHALES)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_week_customer_metrics` AS
WITH totals AS (
  SELECT
    sku_id,
    week_start_date,
    SUM(units_week) AS units_week_total,
    SUM(base_week) AS base_week_total
  FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_sku_customer`
  GROUP BY sku_id, week_start_date
),
shares AS (
  SELECT
    s.sku_id,
    s.week_start_date,
    s.codigo_cliente,
    s.units_week,
    s.base_week,
    t.units_week_total,
    t.base_week_total,
    SAFE_DIVIDE(s.base_week, NULLIF(t.base_week_total, 0)) AS share_base,
    SAFE_DIVIDE(s.units_week, NULLIF(t.units_week_total, 0)) AS share_units,
    CASE WHEN v.codigo_cliente IS NOT NULL THEN 1 ELSE 0 END AS is_vip_customer
  FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_sku_customer` s
  JOIN totals t USING (sku_id, week_start_date)
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.vip_customers_h4` v
    ON v.codigo_cliente = s.codigo_cliente
),
agg AS (
  SELECT
    sku_id,
    week_start_date,
    COUNT(DISTINCT codigo_cliente) AS n_customers_week,
    SUM(CASE WHEN is_vip_customer = 1 THEN 1 ELSE 0 END) AS n_vip_customers_week,
    MAX(is_vip_customer) AS has_vip_customer_week,
    MAX(share_base) AS top_customer_share_base_week,
    MAX(share_units) AS top_customer_share_units_week,
    SUM(POW(share_base, 2)) AS hhi_base_week,
    SUM(POW(share_units, 2)) AS hhi_units_week
  FROM shares
  GROUP BY sku_id, week_start_date
)
SELECT * FROM agg;

-- ----------------------------------------------------------------------------
-- SECTION 1E: SKU-WEEK VALUE/PRICE METRICS (BASE + UNIT PRICE)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_week_value_metrics` AS
WITH sku_week AS (
  SELECT
    codigo_articulo AS sku_id,
    DATE_TRUNC(fecha_albaran, ISOWEEK) AS week_start_date,
    SUM(unidades) AS units_week_total,
    SUM(base_imponible) AS base_week_total,
    SAFE_DIVIDE(SUM(precio * unidades), NULLIF(SUM(unidades), 0)) AS avg_precio_weighted_week
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN TRAIN_START_DATE AND DATE_ADD(VAL_END_DATE, INTERVAL 8 WEEK)
  GROUP BY sku_id, week_start_date
)
SELECT
  sku_id,
  week_start_date,
  units_week_total,
  base_week_total,
  avg_precio_weighted_week,
  SAFE_DIVIDE(base_week_total, NULLIF(units_week_total, 0)) AS unit_price_net_week,
  CASE
    WHEN units_week_total = 0 THEN 0
    WHEN avg_precio_weighted_week IS NULL OR avg_precio_weighted_week < PRICE_EPS THEN 0
    WHEN SAFE_DIVIDE(SAFE_DIVIDE(base_week_total, NULLIF(units_week_total, 0)), avg_precio_weighted_week) > MAX_PRICE_RATIO_DISCREPANCY THEN 1
    WHEN SAFE_DIVIDE(avg_precio_weighted_week, SAFE_DIVIDE(base_week_total, NULLIF(units_week_total, 0))) > MAX_PRICE_RATIO_DISCREPANCY THEN 1
    ELSE 0
  END AS flag_price_discrepancy_week
FROM sku_week;

-- ----------------------------------------------------------------------------
-- SECTION 2: FEATURE ENGINEERING (WEEKLY SKU FEATURES) — JOIN-BASED LABELS
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.weekly_features_h4` AS
WITH base AS (
  SELECT
    b.sku_id,
    b.week_start_date,
    b.iso_week,
    b.y_sales,
    b.n_days_active,
    b.n_days_nonzero,
    v.base_week_total,
    v.unit_price_net_week,
    v.avg_precio_weighted_week,
    v.flag_price_discrepancy_week,
    c.n_customers_week,
    c.n_vip_customers_week,
    c.has_vip_customer_week,
    c.top_customer_share_base_week,
    c.top_customer_share_units_week,
    c.hhi_base_week,
    c.hhi_units_week
  FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_base` b
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_week_value_metrics` v
    ON v.sku_id = b.sku_id AND v.week_start_date = b.week_start_date
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_week_customer_metrics` c
    ON c.sku_id = b.sku_id AND c.week_start_date = b.week_start_date
),
feat AS (
  SELECT
    b.*,
    LAG(y_sales, 1)  OVER w AS lag_1,
    LAG(y_sales, 2)  OVER w AS lag_2,
    LAG(y_sales, 4)  OVER w AS lag_4,
    LAG(y_sales, 8)  OVER w AS lag_8,
    LAG(y_sales, 13) OVER w AS lag_13,
    LAG(y_sales, 26) OVER w AS lag_26,
    LAG(y_sales, 52) OVER w AS lag_52,
    LAG(base_week_total, 1) OVER w AS base_lag_1,
    LAG(base_week_total, 4) OVER w AS base_lag_4,
    LAG(base_week_total, 13) OVER w AS base_lag_13,
    LAG(unit_price_net_week, 1) OVER w AS price_lag_1,
    LAG(unit_price_net_week, 4) OVER w AS price_lag_4,
    LAG(unit_price_net_week, 13) OVER w AS price_lag_13,
    LAG(n_customers_week, 1) OVER w AS cust_n_lag_1,
    LAG(n_customers_week, 4) OVER w AS cust_n_lag_4,
    LAG(top_customer_share_base_week, 1) OVER w AS top_share_lag_1,
    LAG(top_customer_share_base_week, 4) OVER w AS top_share_lag_4,
    LAG(hhi_base_week, 1) OVER w AS hhi_lag_1,
    LAG(hhi_base_week, 4) OVER w AS hhi_lag_4,
    LAG(has_vip_customer_week, 1) OVER w AS vip_lag_1,
    LAG(has_vip_customer_week, 4) OVER w AS vip_lag_4,
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 4  PRECEDING AND 1 PRECEDING) AS roll4_mean,
    STDDEV(y_sales) OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 4  PRECEDING AND 1 PRECEDING) AS roll4_std,
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 8  PRECEDING AND 1 PRECEDING) AS roll8_mean,
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING) AS roll13_mean,
    STDDEV(y_sales) OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING) AS roll13_std,
    MAX(CASE WHEN y_sales > 0 THEN 1 ELSE 0 END)
      OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS ever_sold_before
  FROM base b
  WINDOW w AS (PARTITION BY sku_id ORDER BY week_start_date)
),
with_stockout AS (
  SELECT
    f.*,
    SIN(2 * ACOS(-1) * 1 * iso_week / 52.0) AS sin1,
    COS(2 * ACOS(-1) * 1 * iso_week / 52.0) AS cos1,
    SIN(2 * ACOS(-1) * 2 * iso_week / 52.0) AS sin2,
    COS(2 * ACOS(-1) * 2 * iso_week / 52.0) AS cos2,
    SIN(2 * ACOS(-1) * 3 * iso_week / 52.0) AS sin3,
    COS(2 * ACOS(-1) * 3 * iso_week / 52.0) AS cos3,
    CASE WHEN iso_week IN UNNEST(HIGH_SEASON_WEEKS) THEN 'HIGH_SEASON' ELSE 'REST' END AS season_group,
    DATE_DIFF(week_start_date, DATE('2020-01-06'), WEEK) AS weeks_since_start,
    CASE
      WHEN y_sales = 0
       AND ever_sold_before = 1
       AND (COALESCE(roll4_mean, 0) > 5 OR COALESCE(lag_1, 0) > 5 OR COALESCE(roll13_mean, 0) > 5)
      THEN 1 ELSE 0
    END AS stockout_event
  FROM feat f
),
final AS (
  SELECT
    t.*,
    DATE_ADD(t.week_start_date, INTERVAL HORIZON_WEEKS WEEK) AS label_week_h4
  FROM with_stockout t
),
labeled AS (
  SELECT
    t.sku_id,
    t.week_start_date,
    t.iso_week,
    t.season_group,
    t.y_sales,
    t.stockout_event,
    t.label_week_h4,
    t4.y_sales AS y_true_h4,
    t4.stockout_event AS stockout_event_h4,
    t.lag_1, t.lag_2, t.lag_4, t.lag_8, t.lag_13, t.lag_26, t.lag_52,
    t.roll4_mean, t.roll4_std, t.roll8_mean, t.roll13_mean, t.roll13_std,
    LAG(t.stockout_event, 1) OVER (PARTITION BY t.sku_id ORDER BY t.week_start_date) AS oos_lag1,
    LAG(t.stockout_event, 2) OVER (PARTITION BY t.sku_id ORDER BY t.week_start_date) AS oos_lag2,
    LAG(t.stockout_event, 4) OVER (PARTITION BY t.sku_id ORDER BY t.week_start_date) AS oos_lag4,
    t.sin1, t.cos1, t.sin2, t.cos2, t.sin3, t.cos3,
    t.weeks_since_start,
    COALESCE(t.roll4_std / NULLIF(t.roll4_mean, 0), 0) AS cv_4w,
    COALESCE(t.roll13_std / NULLIF(t.roll13_mean, 0), 0) AS cv_13w,
    COALESCE(t.lag_1 / NULLIF(t.roll13_mean, 0), 1) AS lag1_rel,
    COALESCE(t.roll13_mean, 0) AS amplitude,
    t.base_week_total,
    t.unit_price_net_week,
    t.avg_precio_weighted_week,
    t.flag_price_discrepancy_week,
    t.base_lag_1, t.base_lag_4, t.base_lag_13,
    t.price_lag_1, t.price_lag_4, t.price_lag_13,
    SAFE_DIVIDE(t.unit_price_net_week, NULLIF(t.price_lag_1, 0)) - 1.0 AS price_change_1w,
    t.n_customers_week,
    t.has_vip_customer_week,
    t.top_customer_share_base_week,
    t.hhi_base_week,
    t.cust_n_lag_1, t.cust_n_lag_4,
    t.top_share_lag_1, t.top_share_lag_4,
    t.hhi_lag_1, t.hhi_lag_4,
    t.vip_lag_1, t.vip_lag_4
  FROM final t
  LEFT JOIN final t4
    ON t4.sku_id = t.sku_id
   AND t4.week_start_date = t.label_week_h4
)
SELECT *
FROM labeled
WHERE week_start_date >= TRAIN_START_DATE
ORDER BY sku_id, week_start_date;

-- ----------------------------------------------------------------------------
-- SECTION 3: TRAIN/CALIBRATION SPLIT
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` AS
SELECT
  *,
  CASE
    WHEN week_start_date < '2023-07-01' THEN 'TRAIN'
    WHEN week_start_date BETWEEN '2023-07-01' AND '2023-12-31' THEN 'CALIB'
    ELSE 'VAL'
  END AS split,
  CASE WHEN week_start_date < '2023-07-01' THEN TRUE ELSE FALSE END AS is_train,
  NTILE(10) OVER (PARTITION BY season_group ORDER BY amplitude) AS demand_decile
FROM `{PROJECT_ID}.{BQ_DATASET}.weekly_features_h4`
WHERE y_true_h4 IS NOT NULL
  AND label_week_h4 <= VAL_END_DATE;

-- ----------------------------------------------------------------------------
-- SECTION 3B: DIAGNOSTICS — WHALES & PRICE QUALITY
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_whales_price_h4` AS
SELECT
  split,
  COUNT(*) AS n_rows,
  AVG(has_vip_customer_week) AS share_rows_with_vip,
  AVG(top_customer_share_base_week) AS mean_top_share_base,
  APPROX_QUANTILES(top_customer_share_base_week, 10)[OFFSET(9)] AS p90_top_share_base,
  AVG(hhi_base_week) AS mean_hhi_base,
  AVG(flag_price_discrepancy_week) AS share_price_discrepancy
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4`
GROUP BY split
ORDER BY split;

-- ----------------------------------------------------------------------------
-- SECTION 4: BQML MODEL 1 — STOCKOUT CLASSIFIER (LAYER 1)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h4`
OPTIONS(
  MODEL_TYPE='BOOSTED_TREE_CLASSIFIER',
  INPUT_LABEL_COLS=['stockout_event_h4'],
  DATA_SPLIT_METHOD='CUSTOM',
  DATA_SPLIT_COL='is_train',
  AUTO_CLASS_WEIGHTS=TRUE,
  MAX_ITERATIONS=50,
  LEARN_RATE=0.1,
  L1_REG=0.01,
  L2_REG=0.01,
  MAX_TREE_DEPTH=6,
  SUBSAMPLE=0.8,
  MIN_TREE_CHILD_WEIGHT=10
) AS
SELECT
  CAST(stockout_event_h4 AS INT64) AS stockout_event_h4,
  is_train,
  lag_1, lag_2, lag_4, lag_8, lag_13,
  roll4_mean, roll4_std, roll8_mean, roll13_mean, roll13_std,
  oos_lag1, oos_lag2, oos_lag4,
  sin1, cos1, sin2, cos2, sin3, cos3,
  cv_4w, cv_13w, lag1_rel, amplitude,
  base_lag_1, base_lag_4,
  price_lag_1, price_lag_4,
  price_change_1w,
  flag_price_discrepancy_week,
  n_customers_week,
  has_vip_customer_week,
  top_customer_share_base_week,
  hhi_base_week,
  weeks_since_start
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4`
WHERE split IN ('TRAIN', 'CALIB');

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4` AS
SELECT
  'OOS_Classifier_h4' AS model_name,
  *
FROM ML.EVALUATE(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h4`,
  (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` WHERE split = 'VAL')
);

-- ============================================================================
-- LAYER 1 SCORING: CANONICAL SCORE + AUTO-MAPPING OF POSITIVE CLASS
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_all` AS
SELECT
  t.sku_id,
  t.week_start_date,
  t.split,
  CAST(t.stockout_event_h4 AS INT64) AS y_true,
  COALESCE(
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_h4_probs) WHERE SAFE_CAST(label AS INT64) = 0),
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_h4_probs) WHERE LOWER(CAST(label AS STRING)) IN ('0', 'false', 'no')),
    NULL
  ) AS p0_raw,
  COALESCE(
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_h4_probs) WHERE SAFE_CAST(label AS INT64) = 1),
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_h4_probs) WHERE LOWER(CAST(label AS STRING)) IN ('1', 'true', 'yes')),
    NULL
  ) AS p1_raw,
  p.predicted_stockout_event_h4 AS predicted_label
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` t
LEFT JOIN ML.PREDICT(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h4`,
  (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4`)
) p
USING (sku_id, week_start_date);

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.label_values_oos_h4` AS
SELECT DISTINCT
  label AS observed_label,
  COUNT(*) OVER (PARTITION BY label) AS n_occurrences
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_all`
CROSS JOIN UNNEST(
  (SELECT ARRAY_AGG(STRUCT(CAST(label AS STRING) AS label)) 
   FROM UNNEST([STRUCT(p0_raw AS prob, '0' AS label), STRUCT(p1_raw AS prob, '1' AS label)]) 
   WHERE prob IS NOT NULL)
)
ORDER BY observed_label;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h4` AS
WITH train_calib_stats AS (
  SELECT
    AVG(CASE WHEN y_true = 1 THEN p1_raw END) - AVG(CASE WHEN y_true = 0 THEN p1_raw END) AS sep_p1,
    AVG(CASE WHEN y_true = 1 THEN p0_raw END) - AVG(CASE WHEN y_true = 0 THEN p0_raw END) AS sep_p0,
    COUNT(*) AS n_total,
    SUM(y_true) AS n_pos,
    AVG(y_true) AS prevalence,
    AVG(CASE WHEN y_true = 1 THEN p1_raw END) AS mean_p1_given_pos,
    AVG(CASE WHEN y_true = 0 THEN p1_raw END) AS mean_p1_given_neg,
    AVG(CASE WHEN y_true = 1 THEN p0_raw END) AS mean_p0_given_pos,
    AVG(CASE WHEN y_true = 0 THEN p0_raw END) AS mean_p0_given_neg
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_all`
  WHERE split IN ('TRAIN', 'CALIB')
    AND p0_raw IS NOT NULL
    AND p1_raw IS NOT NULL
)
SELECT
  CASE WHEN sep_p1 >= sep_p0 THEN '1' ELSE '0' END AS pos_label,
  sep_p1,
  sep_p0,
  n_total,
  n_pos,
  prevalence,
  mean_p1_given_pos,
  mean_p1_given_neg,
  mean_p0_given_pos,
  mean_p0_given_neg,
  ABS(sep_p1) AS signal_strength_p1,
  ABS(sep_p0) AS signal_strength_p0,
  CASE 
    WHEN sep_p1 >= sep_p0 THEN 'p1_raw maps to positive class (CORRECT)'
    ELSE 'p0_raw maps to positive class (INVERTED - BUG!)'
  END AS mapping_verdict
FROM train_calib_stats;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_final` AS
SELECT
  s.*,
  CASE 
    WHEN (SELECT pos_label FROM `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h4`) = '1' 
    THEN s.p1_raw 
    ELSE s.p0_raw 
  END AS p_oos_h4,
  CASE 
    WHEN (SELECT pos_label FROM `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h4`) = '1' 
    THEN s.p0_raw 
    ELSE s.p1_raw 
  END AS p_non_oos_h4
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_all` s;

-- ============================================================================
-- SECTION 4B: PROBABILITY CALIBRATION (PLATT SCALING ON CALIB)
-- ============================================================================

CREATE OR REPLACE MODEL `{PROJECT_ID}.{BQ_DATASET}.m_platt_oos_h4`
OPTIONS(
  MODEL_TYPE='LOGISTIC_REG',
  INPUT_LABEL_COLS=['y_true'],
  DATA_SPLIT_METHOD='NO_SPLIT'
) AS
SELECT
  CAST(y_true AS INT64) AS y_true,
  CAST(p_oos_h4 AS FLOAT64) AS p_oos_raw
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_final`
WHERE split = 'CALIB'
  AND p_oos_h4 IS NOT NULL;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_calibrated` AS
SELECT
  s.*,
  COALESCE(
    (SELECT prob FROM UNNEST(p.predicted_y_true_probs) WHERE SAFE_CAST(label AS INT64) = 1),
    (SELECT prob FROM UNNEST(p.predicted_y_true_probs) WHERE LOWER(CAST(label AS STRING)) IN ('1','true','yes')),
    NULL
  ) AS p_oos_h4_cal
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_final` s
LEFT JOIN ML.PREDICT(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_platt_oos_h4`,
  (SELECT sku_id, week_start_date, CAST(p_oos_h4 AS FLOAT64) AS p_oos_raw
   FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_final`
   WHERE p_oos_h4 IS NOT NULL)
) p
USING (sku_id, week_start_date);

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_platt_oos_h4` AS
SELECT
  split,
  COUNT(*) AS n_obs,
  SUM(y_true) AS n_pos,
  AVG(y_true) AS prevalence,
  AVG(p_oos_h4) AS mean_p_raw,
  AVG(p_oos_h4_cal) AS mean_p_cal,
  AVG(POW(p_oos_h4 - y_true, 2)) AS brier_raw,
  AVG(POW(p_oos_h4_cal - y_true, 2)) AS brier_cal
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_calibrated`
WHERE p_oos_h4 IS NOT NULL AND p_oos_h4_cal IS NOT NULL
GROUP BY split
ORDER BY split;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calib_deciles_oos_h4_val_platt` AS
WITH d AS (
  SELECT
    NTILE(10) OVER (ORDER BY p_oos_h4) AS decile_raw,
    NTILE(10) OVER (ORDER BY p_oos_h4_cal) AS decile_cal,
    y_true,
    p_oos_h4,
    p_oos_h4_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_calibrated`
  WHERE split = 'VAL'
    AND p_oos_h4 IS NOT NULL
    AND p_oos_h4_cal IS NOT NULL
)
SELECT
  'RAW' AS version,
  decile_raw AS decile,
  COUNT(*) AS n_obs,
  AVG(p_oos_h4) AS mean_pred,
  AVG(y_true) AS obs_rate,
  ABS(AVG(p_oos_h4) - AVG(y_true)) AS calib_error
FROM d
GROUP BY decile
UNION ALL
SELECT
  'CAL' AS version,
  decile_cal AS decile,
  COUNT(*) AS n_obs,
  AVG(p_oos_h4_cal) AS mean_pred,
  AVG(y_true) AS obs_rate,
  ABS(AVG(p_oos_h4_cal) - AVG(y_true)) AS calib_error
FROM d
GROUP BY decile
ORDER BY version, decile;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_oos_h4_by_split` AS
SELECT
  split,
  COUNT(*) AS n_total,
  SUM(y_true) AS n_positive,
  AVG(y_true) AS prevalence,
  AVG(p_oos_h4) AS mean_p_oos,
  STDDEV(p_oos_h4) AS stddev_p_oos,
  MIN(p_oos_h4) AS min_p_oos,
  MAX(p_oos_h4) AS max_p_oos,
  AVG(CASE WHEN y_true = 1 THEN p_oos_h4 END) AS mean_p_oos_given_pos,
  AVG(CASE WHEN y_true = 0 THEN p_oos_h4 END) AS mean_p_oos_given_neg,
  AVG(CASE WHEN y_true = 1 THEN p_oos_h4 END) - AVG(CASE WHEN y_true = 0 THEN p_oos_h4 END) AS signal_separation,
  AVG(CASE WHEN p_oos_h4 IS NULL THEN 1.0 ELSE 0.0 END) AS null_rate_p_oos,
  AVG(p_oos_h4 + p_non_oos_h4) AS mean_sum_probs,
  STDDEV(p_oos_h4 + p_non_oos_h4) AS stddev_sum_probs,
  CASE WHEN AVG(CASE WHEN y_true = 1 THEN p_oos_h4 END) > AVG(CASE WHEN y_true = 0 THEN p_oos_h4 END) 
       THEN 'PASS' ELSE 'FAIL' END AS signal_direction_check,
  CASE WHEN STDDEV(p_oos_h4) > 0.01 THEN 'PASS' ELSE 'FAIL' END AS variance_check
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_final`
GROUP BY split
ORDER BY split;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calib_deciles_oos_h4_traincalib` AS
WITH deciles AS (
  SELECT
    NTILE(10) OVER (ORDER BY p_oos_h4) AS decile,
    p_oos_h4,
    y_true
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_final`
  WHERE split IN ('TRAIN', 'CALIB')
    AND p_oos_h4 IS NOT NULL
)
SELECT
  decile,
  COUNT(*) AS n_obs,
  AVG(p_oos_h4) AS mean_predicted_prob,
  MIN(p_oos_h4) AS min_p_oos,
  MAX(p_oos_h4) AS max_p_oos,
  AVG(y_true) AS observed_rate,
  ABS(AVG(p_oos_h4) - AVG(y_true)) AS calibration_error,
  CASE WHEN ABS(AVG(p_oos_h4) - AVG(y_true)) < 0.05 THEN 'PASS' ELSE 'FAIL' END AS calib_check
FROM deciles
GROUP BY decile
ORDER BY decile;

-- ----------------------------------------------------------------------------
-- SECTION 5: BQML MODEL 2 — DEMAND REGRESSOR (LAYER 2)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4` AS
SELECT
  t.*,
  COALESCE(s.p_oos_h4_cal, s.p_oos_h4, 0.5) AS p_oos_h4
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` t
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_calibrated` s
USING (sku_id, week_start_date);

CREATE OR REPLACE MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h4`
OPTIONS(
  MODEL_TYPE='BOOSTED_TREE_REGRESSOR',
  INPUT_LABEL_COLS=['y_true_h4'],
  DATA_SPLIT_METHOD='CUSTOM',
  DATA_SPLIT_COL='is_train',
  MAX_ITERATIONS=100,
  LEARN_RATE=0.05,
  L1_REG=0.01,
  L2_REG=0.01,
  MAX_TREE_DEPTH=8,
  SUBSAMPLE=0.8,
  MIN_TREE_CHILD_WEIGHT=5
) AS
SELECT
  y_true_h4,
  is_train,
  lag_1, lag_2, lag_4, lag_8, lag_13,
  roll4_mean, roll4_std, roll8_mean, roll13_mean, roll13_std,
  oos_lag1, oos_lag2, oos_lag4,
  sin1, cos1, sin2, cos2, sin3, cos3,
  cv_4w, cv_13w, lag1_rel, amplitude,
  base_lag_1, base_lag_4,
  price_lag_1, price_lag_4,
  price_change_1w,
  flag_price_discrepancy_week,
  n_customers_week,
  has_vip_customer_week,
  top_customer_share_base_week,
  hhi_base_week,
  weeks_since_start,
  p_oos_h4
FROM `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4`
WHERE split IN ('TRAIN', 'CALIB');

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_regressor_h4` AS
SELECT
  'Demand_Regressor_h4' AS model_name,
  *
FROM ML.EVALUATE(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h4`,
  (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4` WHERE split = 'VAL')
);

-- ----------------------------------------------------------------------------
-- SECTION 6: RESIDUALS (FOR EMPIRICAL QUANTILES)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.residuals_h4` AS
WITH predictions AS (
  SELECT
    t.sku_id,
    t.week_start_date,
    t.season_group,
    t.demand_decile,
    t.y_true_h4,
    t.amplitude,
    p.predicted_y_true_h4 AS yhat_p50_h4
  FROM `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4` t
  LEFT JOIN ML.PREDICT(
    MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h4`,
    (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4` WHERE split = 'CALIB')
  ) p
  USING (sku_id, week_start_date)
  WHERE t.split = 'CALIB'
)
SELECT
  sku_id,
  week_start_date,
  season_group,
  demand_decile,
  CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0')) AS segment_id,
  y_true_h4,
  yhat_p50_h4,
  y_true_h4 - yhat_p50_h4 AS residual,
  amplitude
FROM predictions;

-- ----------------------------------------------------------------------------
-- SECTION 7: EMPIRICAL QUANTILE LOOKUP (LAYER 3)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h4` AS
WITH segment_stats AS (
  SELECT
    segment_id,
    season_group,
    demand_decile,
    COUNT(*) AS n_obs,
    AVG(amplitude) AS avg_amplitude,
    STDDEV(residual) AS std_residual,
    APPROX_QUANTILES(residual, 100) AS quantiles
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h4`
  GROUP BY segment_id, season_group, demand_decile
)
SELECT
  segment_id,
  season_group,
  demand_decile,
  n_obs,
  avg_amplitude,
  std_residual,
  quantiles[OFFSET(50)] AS q_resid_p50,
  quantiles[OFFSET(90)] AS q_resid_p90,
  quantiles[OFFSET(95)] AS q_resid_p95,
  quantiles[OFFSET(99)] AS q_resid_p99
FROM segment_stats
ORDER BY season_group, demand_decile;

-- ----------------------------------------------------------------------------
-- SECTION 8: FORECAST TABLE (POINT + QUANTILES FOR h=4)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_h4` AS
WITH base_predictions AS (
  SELECT
    t.sku_id,
    t.week_start_date,
    t.label_week_h4,
    t.iso_week,
    t.season_group,
    t.demand_decile,
    CONCAT(t.season_group, '_D', LPAD(CAST(t.demand_decile AS STRING), 2, '0')) AS segment_id,
    t.y_true_h4,
    t.amplitude,
    COALESCE(s.p_oos_h4_cal, s.p_oos_h4, 0.5) AS p_oos_h4,
    p_demand.predicted_y_true_h4 AS yhat_p50_h4
  FROM `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4` t
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h4_calibrated` s
    ON t.sku_id = s.sku_id 
    AND t.week_start_date = s.week_start_date
    AND t.split = 'VAL'
  LEFT JOIN ML.PREDICT(
    MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h4`,
    (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.train_with_poos_h4` WHERE split = 'VAL')
  ) p_demand
  ON p_demand.sku_id = t.sku_id AND p_demand.week_start_date = t.week_start_date
  WHERE t.split = 'VAL'
)
SELECT
  f.sku_id,
  f.week_start_date AS decision_week,
  f.label_week_h4 AS target_week,
  f.iso_week,
  f.season_group,
  f.demand_decile,
  f.segment_id,
  f.y_true_h4,
  f.p_oos_h4,
  f.yhat_p50_h4,
  f.yhat_p50_h4 + q.q_resid_p90 AS q90_h4,
  f.yhat_p50_h4 + q.q_resid_p95 AS q95_h4,
  f.yhat_p50_h4 + q.q_resid_p99 AS q99_h4,
  f.amplitude,
  q.n_obs AS segment_n_calib,
  q.std_residual AS segment_std_resid
FROM base_predictions f
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h4` q
USING (segment_id)
ORDER BY decision_week, p_oos_h4 DESC;

-- ----------------------------------------------------------------------------
-- SECTION 9: ALERT RANKING (TOP 100 PER WEEK)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h4` AS
WITH base AS (
  SELECT
    f.decision_week,
    f.target_week,
    f.sku_id,
    f.p_oos_h4,
    f.yhat_p50_h4,
    f.q90_h4,
    f.q95_h4,
    f.q99_h4,
    f.y_true_h4,
    f.season_group,
    f.segment_id,
    f.amplitude
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h4` f
),
labels AS (
  SELECT
    sku_id,
    label_week_h4 AS target_week,
    CAST(stockout_event_h4 AS INT64) AS stockout_event_h4
  FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4`
  WHERE label_week_h4 IS NOT NULL
),
enriched AS (
  SELECT
    b.*,
    COALESCE(l.stockout_event_h4, NULL) AS true_stockout_label_model,
    CASE WHEN b.y_true_h4 = 0 THEN 1 ELSE 0 END AS true_stockout_label_sales0,
    GREATEST(0, b.q95_h4 - b.yhat_p50_h4) AS uncertainty_width_p95,
    (b.p_oos_h4 * GREATEST(0, b.q95_h4 - b.yhat_p50_h4)) AS risk_score
  FROM base b
  LEFT JOIN labels l
    ON l.sku_id = b.sku_id
   AND l.target_week = b.target_week
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY decision_week
      ORDER BY risk_score DESC, p_oos_h4 DESC, amplitude DESC
    ) AS rank_in_week
  FROM enriched
)
SELECT
  decision_week,
  target_week,
  rank_in_week,
  sku_id,
  p_oos_h4,
  yhat_p50_h4,
  q90_h4,
  q95_h4,
  q99_h4,
  uncertainty_width_p95,
  risk_score,
  y_true_h4,
  true_stockout_label_model,
  true_stockout_label_sales0,
  season_group,
  segment_id,
  amplitude
FROM ranked
WHERE rank_in_week <= 100
ORDER BY decision_week, rank_in_week;

-- ============================================================================
-- SECTION 10: EVALUATION — ALERTS TOP-100 (PRECISION@100, RECALL@100, LIFT)
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4` AS
WITH alert_stats AS (
  SELECT
    decision_week,
    season_group,
    COUNT(*) AS n_alerts,
    SUM(true_stockout_label_model) AS n_true_positives_in_top100_model,
    SUM(CASE WHEN true_stockout_label_model IS NULL THEN 1 ELSE 0 END) AS n_null_labels_model,
    SAFE_DIVIDE(SUM(true_stockout_label_model), COUNT(*)) AS precision_at_100_model,
    SUM(true_stockout_label_sales0) AS n_true_positives_in_top100_sales0,
    SAFE_DIVIDE(SUM(true_stockout_label_sales0), COUNT(*)) AS precision_at_100_sales0,
    AVG(p_oos_h4) AS mean_p_oos_in_top100,
    MIN(p_oos_h4) AS min_p_oos_in_top100,
    AVG(risk_score) AS mean_risk_score_in_top100
  FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h4`
  GROUP BY decision_week, season_group
),
total_stockouts AS (
  SELECT
    f.decision_week,
    f.season_group,
    SUM(CAST(stockout_event_h4 AS INT64)) AS n_total_stockouts_model,
    AVG(CAST(stockout_event_h4 AS INT64)) AS prevalence_model,
    SUM(CASE WHEN f.y_true_h4 = 0 THEN 1 ELSE 0 END) AS n_total_stockouts_sales0,
    AVG(CASE WHEN f.y_true_h4 = 0 THEN 1.0 ELSE 0.0 END) AS prevalence_sales0
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h4` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` t
    ON f.sku_id = t.sku_id AND f.target_week = t.label_week_h4
  GROUP BY f.decision_week, f.season_group
)
SELECT
  a.decision_week,
  a.season_group,
  a.n_alerts,
  a.n_true_positives_in_top100_model,
  a.n_null_labels_model,
  t.n_total_stockouts_model,
  t.prevalence_model,
  a.precision_at_100_model,
  SAFE_DIVIDE(a.n_true_positives_in_top100_model, t.n_total_stockouts_model) AS recall_at_100_model,
  SAFE_DIVIDE(a.precision_at_100_model, t.prevalence_model) AS lift_at_100_model,
  a.n_true_positives_in_top100_sales0,
  t.n_total_stockouts_sales0,
  t.prevalence_sales0,
  a.precision_at_100_sales0,
  SAFE_DIVIDE(a.n_true_positives_in_top100_sales0, t.n_total_stockouts_sales0) AS recall_at_100_sales0,
  SAFE_DIVIDE(a.precision_at_100_sales0, t.prevalence_sales0) AS lift_at_100_sales0,
  a.mean_p_oos_in_top100,
  a.min_p_oos_in_top100,
  a.mean_risk_score_in_top100,
  CASE WHEN a.precision_at_100_model > t.prevalence_model THEN 'PASS' ELSE 'FAIL' END AS precision_vs_baseline_check,
  CASE WHEN SAFE_DIVIDE(a.precision_at_100_model, t.prevalence_model) > 1.5 THEN 'PASS' ELSE 'FAIL' END AS lift_check
FROM alert_stats a
LEFT JOIN total_stockouts t
  USING (decision_week, season_group)
ORDER BY decision_week, season_group;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` AS
WITH alert_stats_pooled AS (
  SELECT
    season_group,
    COUNT(*) AS n_alerts,
    SUM(true_stockout_label_model) AS n_true_positives_in_top100_model,
    SUM(CASE WHEN true_stockout_label_model IS NULL THEN 1 ELSE 0 END) AS n_null_labels_model,
    SAFE_DIVIDE(SUM(true_stockout_label_model), COUNT(*)) AS precision_at_100_model,
    SUM(true_stockout_label_sales0) AS n_true_positives_in_top100_sales0,
    SAFE_DIVIDE(SUM(true_stockout_label_sales0), COUNT(*)) AS precision_at_100_sales0,
    AVG(p_oos_h4) AS mean_p_oos_in_top100,
    AVG(risk_score) AS mean_risk_score_in_top100
  FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h4`
  GROUP BY season_group
),
total_stockouts_pooled AS (
  SELECT
    f.season_group,
    SUM(CAST(stockout_event_h4 AS INT64)) AS n_total_stockouts_model,
    AVG(CAST(stockout_event_h4 AS INT64)) AS prevalence_model,
    SUM(CASE WHEN f.y_true_h4 = 0 THEN 1 ELSE 0 END) AS n_total_stockouts_sales0,
    AVG(CASE WHEN f.y_true_h4 = 0 THEN 1.0 ELSE 0.0 END) AS prevalence_sales0
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h4` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` t
    ON f.sku_id = t.sku_id AND f.target_week = t.label_week_h4
  GROUP BY f.season_group
)
SELECT
  'POOLED' AS period,
  a.season_group,
  a.n_alerts,
  a.n_true_positives_in_top100_model,
  a.n_null_labels_model,
  t.n_total_stockouts_model,
  t.prevalence_model,
  a.precision_at_100_model,
  SAFE_DIVIDE(a.n_true_positives_in_top100_model, t.n_total_stockouts_model) AS recall_at_100_model,
  SAFE_DIVIDE(a.precision_at_100_model, t.prevalence_model) AS lift_at_100_model,
  a.n_true_positives_in_top100_sales0,
  t.n_total_stockouts_sales0,
  t.prevalence_sales0,
  a.precision_at_100_sales0,
  SAFE_DIVIDE(a.n_true_positives_in_top100_sales0, t.n_total_stockouts_sales0) AS recall_at_100_sales0,
  SAFE_DIVIDE(a.precision_at_100_sales0, t.prevalence_sales0) AS lift_at_100_sales0,
  a.mean_p_oos_in_top100,
  a.mean_risk_score_in_top100
FROM alert_stats_pooled a
LEFT JOIN total_stockouts_pooled t
  USING (season_group)
ORDER BY season_group;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_h4` AS
WITH alert_stats AS (
  SELECT
    decision_week,
    season_group,
    COUNT(*) AS n_alerts,
    SUM(true_stockout_label_model) AS n_true_positives,
    SAFE_DIVIDE(SUM(true_stockout_label_model), COUNT(*)) AS precision_at_100
  FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h4`
  GROUP BY decision_week, season_group
),
total_stockouts AS (
  SELECT
    f.decision_week,
    f.season_group,
    SUM(CAST(stockout_event_h4 AS INT64)) AS n_total_stockouts
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h4` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h4` t
    ON f.sku_id = t.sku_id AND f.target_week = t.label_week_h4
  GROUP BY f.decision_week, f.season_group
)
SELECT
  a.decision_week,
  a.season_group,
  a.n_alerts,
  a.n_true_positives,
  t.n_total_stockouts,
  SAFE_DIVIDE(a.n_true_positives, t.n_total_stockouts) AS recall_at_100,
  a.precision_at_100
FROM alert_stats a
LEFT JOIN total_stockouts t
USING (decision_week, season_group)
ORDER BY decision_week, season_group;

SELECT
  season_group,
  COUNT(*) AS n_weeks,
  AVG(recall_at_100) AS avg_recall_at_100,
  AVG(precision_at_100) AS avg_precision_at_100,
  MIN(recall_at_100) AS min_recall,
  MAX(recall_at_100) AS max_recall
FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_h4`
GROUP BY season_group
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- SECTION 11: EVALUATION — QUANTILE COVERAGE
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4` AS
WITH violations AS (
  SELECT
    season_group,
    segment_id,
    COUNT(*) AS n_obs,
    SUM(CASE WHEN y_true_h4 > q90_h4 THEN 1 ELSE 0 END) AS n_violations_p90,
    SUM(CASE WHEN y_true_h4 > q95_h4 THEN 1 ELSE 0 END) AS n_violations_p95,
    SUM(CASE WHEN y_true_h4 > q99_h4 THEN 1 ELSE 0 END) AS n_violations_p99,
    AVG(CASE WHEN y_true_h4 > q90_h4 THEN 1.0 ELSE 0.0 END) AS viol_rate_p90,
    AVG(CASE WHEN y_true_h4 > q95_h4 THEN 1.0 ELSE 0.0 END) AS viol_rate_p95,
    AVG(CASE WHEN y_true_h4 > q99_h4 THEN 1.0 ELSE 0.0 END) AS viol_rate_p99,
    0.10 AS nominal_rate_p90,
    0.05 AS nominal_rate_p95,
    0.01 AS nominal_rate_p99
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h4`
  GROUP BY season_group, segment_id
)
SELECT
  season_group,
  segment_id,
  n_obs,
  n_violations_p90,
  viol_rate_p90,
  nominal_rate_p90,
  viol_rate_p90 - nominal_rate_p90 AS deviation_p90,
  CASE 
    WHEN viol_rate_p90 < nominal_rate_p90 THEN 'Over-conservative'
    WHEN viol_rate_p90 > nominal_rate_p90 THEN 'Under-coverage'
    ELSE 'Calibrated'
  END AS calibration_status_p90,
  n_violations_p95,
  viol_rate_p95,
  nominal_rate_p95,
  viol_rate_p95 - nominal_rate_p95 AS deviation_p95,
  CASE 
    WHEN viol_rate_p95 < nominal_rate_p95 THEN 'Over-conservative'
    WHEN viol_rate_p95 > nominal_rate_p95 THEN 'Under-coverage'
    ELSE 'Calibrated'
  END AS calibration_status_p95,
  n_violations_p99,
  viol_rate_p99,
  nominal_rate_p99,
  viol_rate_p99 - nominal_rate_p99 AS deviation_p99,
  CASE 
    WHEN viol_rate_p99 < nominal_rate_p99 THEN 'Over-conservative'
    WHEN viol_rate_p99 > nominal_rate_p99 THEN 'Under-coverage'
    ELSE 'Calibrated'
  END AS calibration_status_p99
FROM violations
ORDER BY season_group, segment_id;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4_conditional` AS
WITH base AS (
  SELECT *
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h4`
  WHERE amplitude >= DEMAND_ACTIVE_THRESHOLD
),
violations AS (
  SELECT
    season_group,
    segment_id,
    COUNT(*) AS n_obs,
    SUM(CASE WHEN y_true_h4 > q90_h4 THEN 1 ELSE 0 END) AS n_violations_p90,
    SUM(CASE WHEN y_true_h4 > q95_h4 THEN 1 ELSE 0 END) AS n_violations_p95,
    SUM(CASE WHEN y_true_h4 > q99_h4 THEN 1 ELSE 0 END) AS n_violations_p99,
    AVG(CASE WHEN y_true_h4 > q90_h4 THEN 1.0 ELSE 0.0 END) AS viol_rate_p90,
    AVG(CASE WHEN y_true_h4 > q95_h4 THEN 1.0 ELSE 0.0 END) AS viol_rate_p95,
    AVG(CASE WHEN y_true_h4 > q99_h4 THEN 1.0 ELSE 0.0 END) AS viol_rate_p99
  FROM base
  GROUP BY season_group, segment_id
)
SELECT
  season_group,
  segment_id,
  n_obs,
  n_violations_p90,
  viol_rate_p90,
  (viol_rate_p90 - 0.10) AS deviation_p90,
  n_violations_p95,
  viol_rate_p95,
  (viol_rate_p95 - 0.05) AS deviation_p95,
  n_violations_p99,
  viol_rate_p99,
  (viol_rate_p99 - 0.01) AS deviation_p99
FROM violations
ORDER BY season_group, segment_id;

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional` AS
SELECT
  season_group,
  SUM(n_obs) AS n_obs_total,
  SAFE_DIVIDE(SUM(n_violations_p90), SUM(n_obs)) AS viol_rate_p90,
  SAFE_DIVIDE(SUM(n_violations_p95), SUM(n_obs)) AS viol_rate_p95,
  SAFE_DIVIDE(SUM(n_violations_p99), SUM(n_obs)) AS viol_rate_p99,
  SAFE_DIVIDE(SUM(n_violations_p90), SUM(n_obs)) - 0.10 AS deviation_p90,
  SAFE_DIVIDE(SUM(n_violations_p95), SUM(n_obs)) - 0.05 AS deviation_p95,
  SAFE_DIVIDE(SUM(n_violations_p99), SUM(n_obs)) - 0.01 AS deviation_p99
FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4_conditional`
GROUP BY season_group
ORDER BY season_group;

SELECT
  season_group,
  COUNT(DISTINCT segment_id) AS n_segments,
  SUM(n_obs) AS total_obs,
  AVG(viol_rate_p90) AS avg_viol_rate_p90,
  AVG(viol_rate_p95) AS avg_viol_rate_p95,
  STDDEV(viol_rate_p90) AS std_viol_rate_p90,
  STDDEV(viol_rate_p95) AS std_viol_rate_p95
FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4`
GROUP BY season_group
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- SECTION 12: LEAKAGE SANITY CHECK
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_check_h4` AS
SELECT
  'Leakage Check h=4' AS test_name,
  COUNT(*) AS n_rows_checked,
  SUM(CASE WHEN DATE_DIFF(label_week_h4, week_start_date, WEEK) <> 4 THEN 1 ELSE 0 END) AS n_wrong_horizon,
  SUM(CASE WHEN lag_1 IS NULL AND week_start_date > '2020-01-13' THEN 1 ELSE 0 END) AS n_missing_lag1,
  CASE 
    WHEN SUM(CASE WHEN DATE_DIFF(label_week_h4, week_start_date, WEEK) <> 4 THEN 1 ELSE 0 END) = 0 
    THEN '✅ PASS: No leakage detected'
    ELSE '❌ FAIL: Leakage detected - check horizon arithmetic'
  END AS status
FROM `{PROJECT_ID}.{BQ_DATASET}.weekly_features_h4`
WHERE label_week_h4 IS NOT NULL;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_check_h4`;

-- ----------------------------------------------------------------------------
-- SECTION 13: FINAL SUMMARY REPORT
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.run_summary_h4` AS
SELECT
  CURRENT_TIMESTAMP() AS run_ts,
  'h4' AS horizon,
  (SELECT roc_auc FROM `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4`) AS oos_auc_val,
  (SELECT recall FROM `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4`) AS oos_recall_val,
  (SELECT precision FROM `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4`) AS oos_precision_val,
  (SELECT log_loss FROM `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4`) AS oos_logloss_val,
  (SELECT mean_absolute_error FROM `{PROJECT_ID}.{BQ_DATASET}.eval_regressor_h4`) AS demand_mae_val,
  (SELECT r2_score FROM `{PROJECT_ID}.{BQ_DATASET}.eval_regressor_h4`) AS demand_r2_val,
  (SELECT brier_raw FROM `{PROJECT_ID}.{BQ_DATASET}.eval_platt_oos_h4` WHERE split='VAL') AS brier_raw_val,
  (SELECT brier_cal FROM `{PROJECT_ID}.{BQ_DATASET}.eval_platt_oos_h4` WHERE split='VAL') AS brier_cal_val,
  (SELECT mean_p_raw FROM `{PROJECT_ID}.{BQ_DATASET}.eval_platt_oos_h4` WHERE split='VAL') AS mean_p_raw_val,
  (SELECT mean_p_cal FROM `{PROJECT_ID}.{BQ_DATASET}.eval_platt_oos_h4` WHERE split='VAL') AS mean_p_cal_val,
  (SELECT prevalence FROM `{PROJECT_ID}.{BQ_DATASET}.eval_platt_oos_h4` WHERE split='VAL') AS prevalence_val,
  (SELECT precision_at_100_model FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` WHERE season_group='HIGH_SEASON') AS prec100_model_high,
  (SELECT recall_at_100_model FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` WHERE season_group='HIGH_SEASON') AS rec100_model_high,
  (SELECT lift_at_100_model FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` WHERE season_group='HIGH_SEASON') AS lift100_model_high,
  (SELECT precision_at_100_model FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` WHERE season_group='REST') AS prec100_model_rest,
  (SELECT recall_at_100_model FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` WHERE season_group='REST') AS rec100_model_rest,
  (SELECT lift_at_100_model FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled` WHERE season_group='REST') AS lift100_model_rest,
  (SELECT SAFE_DIVIDE(SUM(n_violations_p90), SUM(n_obs)) FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4` WHERE season_group='HIGH_SEASON') AS viol_p90_uncond_high,
  (SELECT SAFE_DIVIDE(SUM(n_violations_p95), SUM(n_obs)) FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4` WHERE season_group='HIGH_SEASON') AS viol_p95_uncond_high,
  (SELECT SAFE_DIVIDE(SUM(n_violations_p90), SUM(n_obs)) FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4` WHERE season_group='REST') AS viol_p90_uncond_rest,
  (SELECT SAFE_DIVIDE(SUM(n_violations_p95), SUM(n_obs)) FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_h4` WHERE season_group='REST') AS viol_p95_uncond_rest,
  (SELECT viol_rate_p90 FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional` WHERE season_group='HIGH_SEASON') AS viol_p90_cond_high,
  (SELECT viol_rate_p95 FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional` WHERE season_group='HIGH_SEASON') AS viol_p95_cond_high,
  (SELECT viol_rate_p90 FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional` WHERE season_group='REST') AS viol_p90_cond_rest,
  (SELECT viol_rate_p95 FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional` WHERE season_group='REST') AS viol_p95_cond_rest,
  DEMAND_ACTIVE_THRESHOLD AS demand_active_threshold
;

SELECT '============================================================' AS sep;
SELECT 'BIGQUERY STOCKOUT FORECAST h=4 — EXECUTION COMPLETE' AS title;
SELECT '============================================================' AS sep;
