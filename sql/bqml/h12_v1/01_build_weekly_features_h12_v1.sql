-- ============================================================================
-- STEP 01: BUILD WEEKLY FEATURES  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   Reconstruct everything from {BASE_SALES_TABLE}:
--     1. Dense SKU × week spine
--     2. Customer/price/value metrics
--     3. Feature engineering (lags, rolling stats, intermittency, seasonality)
--     4. Per-week OOS proxy (stockout_event_week)
--     5. 12-WEEK FORWARD LABEL AGGREGATION (critical — sum t+1..t+12)
--     6. Train / Calib / Val split
--
-- LEAKAGE GUARANTEE:
--   All features use only data from weeks <= decision_week.
--   Labels use data from decision_week+1 through decision_week+12.
--   Rows where the full 12-week future is not observable are EXCLUDED.
--
-- TARGET DEFINITION:
--   y_true_12w        = SUM(y_sales, t+1..t+12)          -- not point forecast
--   stockout_event_12w = MAX(stockout_event_week, t+1..t+12)
--   n_stockout_weeks_12w = SUM(stockout_event_week, t+1..t+12)
--
-- TEMPORAL ALIGNMENT (mirrors R script 30_Dense_Panel_12W_Unified_Best.R):
--   TRAIN: 2021-01-04 -> 2023-06-30
--   CALIB: 2023-07-01 -> 2023-12-31
--   VAL  : 2024-01-01 -> 2024-12-29  (only rows with n_future_obs = 12)
--
-- INPUT:  {BASE_SALES_TABLE}   (v_fact_lineas_enriched columns used:
--                               fecha_albaran, codigo_articulo, codigo_cliente,
--                               unidades, base_imponible_stored, precio_unitario_neto)
-- OUTPUT TABLES (all in {PROJECT_ID}.{BQ_DATASET}):
--   sales_weekly_base_h12_v1
--   sales_weekly_sku_customer_h12_v1
--   vip_customers_h12_v1
--   sku_week_customer_metrics_h12_v1
--   sku_week_value_metrics_h12_v1
--   weekly_features_h12_v1
--   train_calib_split_h12_v1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1A. DENSE WEEKLY SPINE  (SKU x WEEK)
-- ---------------------------------------------------------------------------
-- Calendar extends to VAL_END + 20 weeks so the 12-week forward label join
-- can always find all 12 future rows for the last VAL decision_weeks.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_base_h12_v1` AS
WITH sku_universe AS (
  SELECT DISTINCT
    CAST(codigo_articulo AS STRING) AS sku_id
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN '2021-01-04' AND DATE_ADD('2024-12-29', INTERVAL 20 WEEK)
),
week_calendar AS (
  SELECT wk AS week_start_date
  FROM UNNEST(
    GENERATE_DATE_ARRAY(
      DATE_TRUNC(DATE '2021-01-04', ISOWEEK),
      DATE_TRUNC(DATE_ADD('2024-12-29', INTERVAL 20 WEEK), ISOWEEK),
      INTERVAL 7 DAY
    )
  ) AS wk
),
weekly_sales AS (
  SELECT
    CAST(codigo_articulo AS STRING) AS sku_id,
    DATE_TRUNC(fecha_albaran, ISOWEEK) AS week_start_date,
    SUM(CASE WHEN unidades > 0 THEN unidades ELSE 0 END) AS y_sales,
    COUNT(DISTINCT fecha_albaran)                          AS n_days_active,
    COUNT(DISTINCT CASE WHEN unidades > 0 THEN fecha_albaran END) AS n_days_nonzero
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN '2021-01-04' AND DATE_ADD('2024-12-29', INTERVAL 20 WEEK)
    AND COALESCE(unidades, 0) >= 0  -- exclude returns if needed
  GROUP BY sku_id, week_start_date
),
spine AS (
  SELECT s.sku_id, c.week_start_date
  FROM sku_universe s
  CROSS JOIN week_calendar c
)
SELECT
  sp.sku_id,
  sp.week_start_date,
  EXTRACT(ISOYEAR FROM sp.week_start_date)  AS iso_year,
  EXTRACT(ISOWEEK  FROM sp.week_start_date) AS iso_week,
  COALESCE(ws.y_sales,        0) AS y_sales,
  COALESCE(ws.n_days_active,  0) AS n_days_active,
  COALESCE(ws.n_days_nonzero, 0) AS n_days_nonzero
FROM spine sp
LEFT JOIN weekly_sales ws USING (sku_id, week_start_date)
ORDER BY sku_id, week_start_date;

-- Sanity: row count and zero-fill check
SELECT COUNT(*) AS n_rows, COUNTIF(y_sales = 0) AS n_zero_weeks,
  MIN(week_start_date) AS earliest_week, MAX(week_start_date) AS latest_week
FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_base_h12_v1`;

-- ---------------------------------------------------------------------------
-- 1B. SKU × WEEK × CUSTOMER (for concentration metrics)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_sku_customer_h12_v1` AS
SELECT
  CAST(codigo_articulo AS STRING) AS sku_id,
  DATE_TRUNC(fecha_albaran, ISOWEEK) AS week_start_date,
  codigo_cliente,
  SUM(GREATEST(unidades, 0))                AS units_week,
  SUM(base_imponible_stored)                AS base_week,
  -- v_fact_lineas_enriched: precio_unitario_neto = base_imponible_stored / unidades
  SAFE_DIVIDE(
    SUM(precio_unitario_neto * GREATEST(unidades, 0)),
    NULLIF(SUM(GREATEST(unidades, 0)), 0)
  )                                         AS avg_precio_weighted_week,
  COUNT(DISTINCT fecha_albaran)             AS n_days_active_week
FROM {BASE_SALES_TABLE}
WHERE fecha_albaran BETWEEN '2021-01-04' AND DATE_ADD('2024-12-29', INTERVAL 20 WEEK)
GROUP BY sku_id, week_start_date, codigo_cliente;

-- ---------------------------------------------------------------------------
-- 1C. VIP CUSTOMERS (defined on TRAIN+CALIB only to avoid leakage)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.vip_customers_h12_v1` AS
WITH customer_totals AS (
  SELECT
    codigo_cliente,
    SUM(base_imponible_stored) AS total_base_traincalib,
    SUM(GREATEST(unidades, 0)) AS total_units_traincalib
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN '2021-01-04' AND '2023-12-31'
  GROUP BY codigo_cliente
),
ranked AS (
  SELECT *, DENSE_RANK() OVER (ORDER BY total_base_traincalib DESC) AS rnk
  FROM customer_totals
  WHERE total_base_traincalib > 0
)
SELECT codigo_cliente, total_base_traincalib, total_units_traincalib, rnk
FROM ranked
WHERE rnk <= 50
ORDER BY rnk;

-- ---------------------------------------------------------------------------
-- 1D. SKU-WEEK CUSTOMER METRICS (concentration / whale features)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_week_customer_metrics_h12_v1` AS
WITH totals AS (
  SELECT sku_id, week_start_date,
    SUM(units_week) AS units_week_total,
    SUM(base_week)  AS base_week_total
  FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_sku_customer_h12_v1`
  GROUP BY sku_id, week_start_date
),
shares AS (
  SELECT
    s.sku_id, s.week_start_date, s.codigo_cliente,
    s.units_week, s.base_week,
    t.units_week_total, t.base_week_total,
    SAFE_DIVIDE(s.base_week,  NULLIF(t.base_week_total,  0)) AS share_base,
    SAFE_DIVIDE(s.units_week, NULLIF(t.units_week_total, 0)) AS share_units,
    CASE WHEN v.codigo_cliente IS NOT NULL THEN 1 ELSE 0 END  AS is_vip_customer
  FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_sku_customer_h12_v1` s
  JOIN totals t USING (sku_id, week_start_date)
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.vip_customers_h12_v1` v
    ON v.codigo_cliente = s.codigo_cliente
)
SELECT
  sku_id, week_start_date,
  COUNT(DISTINCT codigo_cliente)                        AS n_customers_week,
  SUM(CASE WHEN is_vip_customer = 1 THEN 1 ELSE 0 END) AS n_vip_customers_week,
  MAX(is_vip_customer)                                  AS has_vip_customer_week,
  MAX(share_base)                                       AS top_customer_share_base_week,
  MAX(share_units)                                      AS top_customer_share_units_week,
  SUM(POW(share_base,  2))                              AS hhi_base_week,
  SUM(POW(share_units, 2))                              AS hhi_units_week
FROM shares
GROUP BY sku_id, week_start_date;

-- ---------------------------------------------------------------------------
-- 1E. SKU-WEEK VALUE / PRICE METRICS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_week_value_metrics_h12_v1` AS
WITH sku_week AS (
  SELECT
    CAST(codigo_articulo AS STRING) AS sku_id,
    DATE_TRUNC(fecha_albaran, ISOWEEK) AS week_start_date,
    SUM(GREATEST(unidades, 0))           AS units_week_total,
    SUM(base_imponible_stored)           AS base_week_total,
    SAFE_DIVIDE(
      SUM(precio_unitario_neto * GREATEST(unidades, 0)),
      NULLIF(SUM(GREATEST(unidades, 0)), 0)
    )                                    AS avg_precio_weighted_week
  FROM {BASE_SALES_TABLE}
  WHERE fecha_albaran BETWEEN '2021-01-04' AND DATE_ADD('2024-12-29', INTERVAL 20 WEEK)
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
    WHEN avg_precio_weighted_week IS NULL OR avg_precio_weighted_week < 1e-6 THEN 0
    WHEN SAFE_DIVIDE(
           SAFE_DIVIDE(base_week_total, NULLIF(units_week_total, 0)),
           avg_precio_weighted_week
         ) > 5.0 THEN 1
    WHEN SAFE_DIVIDE(
           avg_precio_weighted_week,
           SAFE_DIVIDE(base_week_total, NULLIF(units_week_total, 0))
         ) > 5.0 THEN 1
    ELSE 0
  END AS flag_price_discrepancy_week
FROM sku_week;

-- ---------------------------------------------------------------------------
-- 2. FEATURE ENGINEERING — weekly_features_h12_v1
-- ---------------------------------------------------------------------------
-- Built in four sub-steps inside a single CREATE OR REPLACE TABLE:
--   a) base join (spine + price + customer)
--   b) lags, rolling stats, lifecycle
--   c) seasonality, OOS proxy per week, intermittency
--   d) 12-WEEK FORWARD LABEL AGGREGATION (self-join)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.weekly_features_h12_v1` AS

WITH

-- ============================================================
-- 2a. BASE JOIN
-- ============================================================
base AS (
  SELECT
    b.sku_id,
    b.week_start_date,
    b.iso_year,
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
  FROM `{PROJECT_ID}.{BQ_DATASET}.sales_weekly_base_h12_v1` b
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_week_value_metrics_h12_v1` v
    ON v.sku_id = b.sku_id AND v.week_start_date = b.week_start_date
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_week_customer_metrics_h12_v1` c
    ON c.sku_id = b.sku_id AND c.week_start_date = b.week_start_date
),

-- ============================================================
-- 2b. LAGS, ROLLING STATS, LIFECYCLE
-- ============================================================
feat AS (
  SELECT
    b.*,
    -- demand lags
    LAG(y_sales,  1)  OVER w AS lag_1,
    LAG(y_sales,  2)  OVER w AS lag_2,
    LAG(y_sales,  4)  OVER w AS lag_4,
    LAG(y_sales,  8)  OVER w AS lag_8,
    LAG(y_sales, 12)  OVER w AS lag_12,
    LAG(y_sales, 13)  OVER w AS lag_13,
    LAG(y_sales, 26)  OVER w AS lag_26,
    LAG(y_sales, 52)  OVER w AS lag_52,
    -- price lags
    LAG(base_week_total,     1)  OVER w AS base_lag_1,
    LAG(base_week_total,     4)  OVER w AS base_lag_4,
    LAG(base_week_total,    12)  OVER w AS base_lag_12,
    LAG(base_week_total,    13)  OVER w AS base_lag_13,
    LAG(unit_price_net_week, 1)  OVER w AS price_lag_1,
    LAG(unit_price_net_week, 4)  OVER w AS price_lag_4,
    LAG(unit_price_net_week,12)  OVER w AS price_lag_12,
    LAG(unit_price_net_week,13)  OVER w AS price_lag_13,
    -- customer lags
    LAG(n_customers_week,           1) OVER w AS cust_n_lag_1,
    LAG(n_customers_week,           4) OVER w AS cust_n_lag_4,
    LAG(top_customer_share_base_week, 1) OVER w AS top_share_lag_1,
    LAG(top_customer_share_base_week, 4) OVER w AS top_share_lag_4,
    LAG(hhi_base_week, 1) OVER w AS hhi_lag_1,
    LAG(hhi_base_week, 4) OVER w AS hhi_lag_4,
    LAG(has_vip_customer_week, 1) OVER w AS vip_lag_1,
    LAG(has_vip_customer_week, 4) OVER w AS vip_lag_4,
    -- rolling means / stds
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 4  PRECEDING AND 1 PRECEDING) AS roll4_mean,
    STDDEV(y_sales) OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 4  PRECEDING AND 1 PRECEDING) AS roll4_std,
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 8  PRECEDING AND 1 PRECEDING) AS roll8_mean,
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS roll12_mean,
    STDDEV(y_sales) OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS roll12_std,
    AVG(y_sales)    OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING) AS roll13_mean,
    STDDEV(y_sales) OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING) AS roll13_std,
    -- ever-sold flag (lookback only)
    MAX(CASE WHEN y_sales > 0 THEN 1 ELSE 0 END)
      OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
      AS ever_sold_before,
    -- lifecycle
    DATE_DIFF(week_start_date, DATE '2021-01-04', WEEK) AS weeks_since_start,
    -- sale frequency over last 12 weeks (intermittency)
    SAFE_DIVIDE(
      COUNTIF(y_sales > 0) OVER (
        PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
      ),
      12
    ) AS sale_freq_12w,
    -- zero share over last 13/26 weeks
    SAFE_DIVIDE(
      COUNTIF(y_sales = 0) OVER (
        PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING
      ),
      13
    ) AS zero_share_13w,
    SAFE_DIVIDE(
      COUNTIF(y_sales = 0) OVER (
        PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING
      ),
      26
    ) AS zero_share_26w
  FROM base b
  WINDOW w AS (PARTITION BY sku_id ORDER BY week_start_date)
),

-- ============================================================
-- 2c. SEASONALITY, OOS PROXY, DERIVED FEATURES
-- ============================================================
with_proxy AS (
  SELECT
    f.*,
    -- seasonality
    SIN(2 * ACOS(-1.0) * 1 * iso_week / 52.0) AS sin1,
    COS(2 * ACOS(-1.0) * 1 * iso_week / 52.0) AS cos1,
    SIN(2 * ACOS(-1.0) * 2 * iso_week / 52.0) AS sin2,
    COS(2 * ACOS(-1.0) * 2 * iso_week / 52.0) AS cos2,
    SIN(2 * ACOS(-1.0) * 3 * iso_week / 52.0) AS sin3,
    COS(2 * ACOS(-1.0) * 3 * iso_week / 52.0) AS cos3,
    CASE WHEN iso_week BETWEEN 20 AND 35 THEN 'HIGH_SEASON' ELSE 'REST' END AS season_group,
    -- derived demand stats
    COALESCE(roll4_std  / NULLIF(roll4_mean,  0), 0.0) AS cv_4w,
    COALESCE(roll12_std / NULLIF(roll12_mean, 0), 0.0) AS cv_12w,
    COALESCE(roll13_std / NULLIF(roll13_mean, 0), 0.0) AS cv_13w,
    COALESCE(roll13_mean, 0.0)                          AS amplitude,
    COALESCE(lag_1 / NULLIF(roll13_mean, 0), 1.0)       AS lag1_rel,
    SAFE_DIVIDE(unit_price_net_week, NULLIF(price_lag_1, 0)) - 1.0 AS price_change_1w,
    -- per-week OOS proxy (H12 improved rule with sale_freq signal)
    CASE
      WHEN y_sales = 0
       AND COALESCE(ever_sold_before, 0) = 1
       AND (
             COALESCE(sale_freq_12w, 0)  > 0.25
          OR COALESCE(roll4_mean,   0.0) > 5.0
          OR COALESCE(lag_1,        0.0) > 5.0
          OR COALESCE(roll13_mean,  0.0) > 5.0
           )
      THEN 1 ELSE 0
    END AS stockout_event_week,
    -- lifecycle ratio (progress through observable data range)
    SAFE_DIVIDE(
      DATE_DIFF(week_start_date, DATE '2021-01-04', WEEK),
      DATE_DIFF(DATE '2024-12-29', DATE '2021-01-04', WEEK)
    ) AS lifecycle_ratio
  FROM feat f
),

-- ============================================================
-- 2d. OOS LAGS (on per-week proxy, no future leakage)
-- ============================================================
with_oos_lags AS (
  SELECT
    p.*,
    LAG(stockout_event_week, 1) OVER (PARTITION BY sku_id ORDER BY week_start_date) AS oos_lag1,
    LAG(stockout_event_week, 2) OVER (PARTITION BY sku_id ORDER BY week_start_date) AS oos_lag2,
    LAG(stockout_event_week, 4) OVER (PARTITION BY sku_id ORDER BY week_start_date) AS oos_lag4,
    -- last_nonzero_lag: weeks since last nonzero sale (max 52 fallback)
    MIN(CASE WHEN y_sales > 0
             THEN DATE_DIFF(p.week_start_date, p.week_start_date, WEEK)
             ELSE NULL END)
      OVER (PARTITION BY sku_id ORDER BY week_start_date ROWS BETWEEN 52 PRECEDING AND 1 PRECEDING)
      AS last_nonzero_lag_placeholder  -- replaced in final SELECT
  FROM with_proxy p
),

-- ============================================================
-- 2e. 12-WEEK FORWARD LABEL AGGREGATION
-- -----------
-- Self-join over future rows t+1..t+12.
-- Each decision_week (d) joins to rows with:
--     week_start_date > d  AND  week_start_date <= DATE_ADD(d, 12 WEEK)
-- We count n_future_obs; rows with n_future_obs < 12 are EXCLUDED
-- in train_calib_split_h12_v1 below.
-- ============================================================
current_rows AS (
  SELECT
    sku_id,
    week_start_date    AS decision_week,
    -- all feature columns pass through (listed explicitly to control order)
    iso_week, iso_year, y_sales, n_days_active, n_days_nonzero,
    season_group,
    lag_1, lag_2, lag_4, lag_8, lag_12, lag_13, lag_26, lag_52,
    base_lag_1, base_lag_4, base_lag_12, base_lag_13,
    price_lag_1, price_lag_4, price_lag_12, price_lag_13,
    cust_n_lag_1, cust_n_lag_4, top_share_lag_1, top_share_lag_4,
    hhi_lag_1, hhi_lag_4, vip_lag_1, vip_lag_4,
    roll4_mean, roll4_std, roll8_mean, roll12_mean, roll12_std, roll13_mean, roll13_std,
    ever_sold_before, weeks_since_start, lifecycle_ratio,
    sale_freq_12w, zero_share_13w, zero_share_26w,
    sin1, cos1, sin2, cos2, sin3, cos3,
    cv_4w, cv_12w, cv_13w, amplitude, lag1_rel,
    price_change_1w, flag_price_discrepancy_week,
    base_week_total, unit_price_net_week, avg_precio_weighted_week,
    n_customers_week, n_vip_customers_week, has_vip_customer_week,
    top_customer_share_base_week, top_customer_share_units_week,
    hhi_base_week, hhi_units_week,
    stockout_event_week,
    oos_lag1, oos_lag2, oos_lag4
  FROM with_oos_lags
),

future_rows AS (
  SELECT
    sku_id,
    week_start_date AS future_week,
    y_sales         AS future_y_sales,
    stockout_event_week AS future_oos,
    -- expected weekly baseline for lost-units proxy (use best available lookback)
    COALESCE(roll12_mean, roll13_mean, roll4_mean, 0.0) AS expected_weekly_baseline
  FROM with_proxy
),

-- Aggregate 12 future weeks per (sku, decision_week)
label_agg AS (
  SELECT
    c.sku_id,
    c.decision_week,
    COUNT(*)                                       AS n_future_obs,
    SUM(f.future_y_sales)                          AS y_true_12w,
    MAX(f.future_oos)                              AS stockout_event_12w,
    SUM(f.future_oos)                              AS n_stockout_weeks_12w,
    -- lost_units proxy: shortfall during OOS weeks vs expected baseline
    SUM(
      CASE
        WHEN f.future_oos = 1
        THEN GREATEST(f.expected_weekly_baseline - f.future_y_sales, 0.0)
        ELSE 0.0
      END
    )                                              AS lost_units_proxy_12w
  FROM current_rows c
  JOIN future_rows f
    ON  f.sku_id = c.sku_id
    AND f.future_week >  c.decision_week
    AND f.future_week <= DATE_ADD(c.decision_week, INTERVAL 12 WEEK)
  GROUP BY c.sku_id, c.decision_week
)

-- Final join: features + 12W aggregated labels
SELECT
  cr.*,
  la.n_future_obs,
  la.y_true_12w,
  la.stockout_event_12w,
  la.n_stockout_weeks_12w,
  la.lost_units_proxy_12w,
  -- convenience: target window dates
  DATE_ADD(cr.decision_week, INTERVAL 1  WEEK) AS target_start_week,
  DATE_ADD(cr.decision_week, INTERVAL 12 WEEK) AS target_end_week
FROM current_rows cr
LEFT JOIN label_agg la
  ON la.sku_id = cr.sku_id AND la.decision_week = cr.decision_week
WHERE cr.decision_week >= '2021-01-04'
ORDER BY cr.sku_id, cr.decision_week;

-- Sanity: label completeness
SELECT
  CASE WHEN n_future_obs = 12 THEN 'complete'
       WHEN n_future_obs < 12 AND n_future_obs > 0 THEN 'partial'
       WHEN n_future_obs IS NULL THEN 'no_future_data'
       ELSE 'other' END AS label_status,
  COUNT(*)     AS n_rows,
  AVG(y_true_12w) AS avg_y_true_12w,
  AVG(stockout_event_12w) AS oos_prevalence
FROM `{PROJECT_ID}.{BQ_DATASET}.weekly_features_h12_v1`
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------------
-- 3. TRAIN / CALIB / VAL SPLIT  — train_calib_split_h12_v1
-- ---------------------------------------------------------------------------
-- KEY FILTER: n_future_obs = 12  (equivalent to drop_na in R)
-- decision_week determines the split (not the label week).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h12_v1` AS
SELECT
  *,
  CASE
    WHEN decision_week BETWEEN '2021-01-04' AND '2023-06-30' THEN 'TRAIN'
    WHEN decision_week BETWEEN '2023-07-01' AND '2023-12-31' THEN 'CALIB'
    WHEN decision_week BETWEEN '2024-01-01' AND '2024-12-29' THEN 'VAL'
    ELSE 'OUT_OF_RANGE'
  END AS split,
  CASE
    WHEN decision_week BETWEEN '2021-01-04' AND '2023-06-30' THEN TRUE
    ELSE FALSE
  END AS is_train,
  NTILE(10) OVER (PARTITION BY season_group ORDER BY amplitude) AS demand_decile
FROM `{PROJECT_ID}.{BQ_DATASET}.weekly_features_h12_v1`
WHERE
  n_future_obs = 12          -- only rows with complete 12-week label
  AND y_true_12w IS NOT NULL -- belt-and-suspenders null check
  AND decision_week BETWEEN '2021-01-04' AND '2024-12-29';

-- Diagnostics: split distribution and label stats
SELECT
  split,
  COUNT(*)                                     AS n_rows,
  COUNT(DISTINCT sku_id)                       AS n_skus,
  COUNT(DISTINCT decision_week)                AS n_weeks,
  ROUND(AVG(y_true_12w), 2)                   AS avg_demand_12w,
  ROUND(AVG(stockout_event_12w), 4)            AS oos_prevalence,
  ROUND(AVG(CAST(n_stockout_weeks_12w AS FLOAT64)), 3) AS avg_oos_weeks,
  COUNTIF(y_true_12w = 0)                     AS n_zero_demand_rows,
  MIN(decision_week)                           AS earliest_decision,
  MAX(decision_week)                           AS latest_decision
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h12_v1`
GROUP BY split
ORDER BY split;

-- Additional check: no VAL rows with partial labels
SELECT
  'VAL_label_completeness_check' AS check_name,
  COUNT(*) AS n_val_rows,
  COUNTIF(n_future_obs != 12) AS n_incomplete_label,
  COUNTIF(decision_week > '2024-12-29') AS n_out_of_range
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h12_v1`
WHERE split = 'VAL';
