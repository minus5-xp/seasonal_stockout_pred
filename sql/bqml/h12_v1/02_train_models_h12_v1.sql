-- ============================================================================
-- STEP 02: TRAIN BQML MODELS  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   1. Materialise enriched_base_h12_v1  (canonical training spine)
--   2. Train OOS classifier  m_oos_h12_v1          (label: stockout_event_12w)
--   3. Score classifier on ALL splits -> score_oos_h12_all_v1
--   4. Detect positive-class mapping  -> oos_prob_mapping_h12_v1
--   5. Platt calibration on CALIB     -> m_platt_oos_h12_v1 / score_oos_h12_calibrated_v1
--   6. Train demand regressor m_demand_h12_v1        (label: y_true_12w)
--      using p_oos_h12 as exogenous feature
--
-- LEAKAGE SAFETY:
--   OOS classifier trained on split IN ('TRAIN','CALIB').
--   DATA_SPLIT_METHOD='CUSTOM', DATA_SPLIT_COL='is_train':
--     is_train=TRUE  -> internal BQ training fold
--     is_train=FALSE (CALIB) -> internal BQ eval fold
--   Demand regressor trained the same way.
--
-- NOTE on --skip-training:
--   The runner skips this script if --skip-training is passed.
--   Step 02b (scoring) always runs regardless of that flag.
--
-- INPUT:  train_calib_split_h12_v1  (from step 01)
-- OUTPUT: enriched_base_h12_v1, m_oos_h12_v1, score_oos_h12_all_v1,
--         oos_prob_mapping_h12_v1, m_platt_oos_h12_v1,
--         score_oos_h12_calibrated_v1, m_demand_h12_v1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 2-PRE. BUILD ENRICHED SPINE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1` AS
SELECT
  -- keys
  sku_id,
  decision_week                              AS week_start_date,
  split,
  is_train,
  demand_decile,
  -- calendar / season
  iso_week,
  iso_year,
  season_group,
  -- labels
  y_true_12w,
  y_sales,
  stockout_event_12w,
  n_stockout_weeks_12w,
  lost_units_proxy_12w,
  n_future_obs,
  target_start_week,
  target_end_week,
  -- core demand features
  amplitude,
  roll13_mean,
  roll13_std,
  roll12_mean,
  roll12_std,
  cv_13w,
  cv_12w,
  cv_4w,
  lag_1,
  lag_2,
  lag_4,
  lag_8,
  lag_12,
  lag_13,
  lag_26,
  lag_52,
  roll4_mean,
  roll4_std,
  roll8_mean,
  lag1_rel,
  oos_lag1,
  oos_lag2,
  oos_lag4,
  -- seasonality
  sin1, cos1, sin2, cos2, sin3, cos3,
  -- lifecycle
  weeks_since_start,
  lifecycle_ratio,
  -- intermittency
  sale_freq_12w,
  zero_share_13w,
  zero_share_26w,
  -- price / value
  base_week_total,
  unit_price_net_week,
  avg_precio_weighted_week,
  flag_price_discrepancy_week,
  base_lag_1,  base_lag_4,  base_lag_12,  base_lag_13,
  price_lag_1, price_lag_4, price_lag_12, price_lag_13,
  price_change_1w,
  -- customer / whale
  n_customers_week,
  n_vip_customers_week,
  has_vip_customer_week,
  top_customer_share_base_week,
  hhi_base_week,
  cust_n_lag_1, cust_n_lag_4,
  top_share_lag_1, top_share_lag_4,
  hhi_lag_1, hhi_lag_4,
  vip_lag_1, vip_lag_4
FROM `{PROJECT_ID}.{BQ_DATASET}.train_calib_split_h12_v1`
WHERE split IN ('TRAIN', 'CALIB', 'VAL');

SELECT split, COUNT(*) AS n_rows, ROUND(AVG(stockout_event_12w), 4) AS oos_rate,
  ROUND(AVG(y_true_12w), 2) AS avg_demand_12w
FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
GROUP BY split ORDER BY split;

-- ---------------------------------------------------------------------------
-- 2a. OOS CLASSIFIER  m_oos_h12_v1
-- Label: stockout_event_12w (binary, aggregated from t+1..t+12)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h12_v1`
OPTIONS (
  model_type               = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols         = ['stockout_event_12w'],
  num_parallel_tree        = 6,
  max_iterations           = 50,
  learn_rate               = 0.1,
  l1_reg                   = 0.01,
  l2_reg                   = 0.01,
  max_tree_depth           = 6,
  subsample                = 0.8,
  min_tree_child_weight    = 10,
  auto_class_weights       = TRUE,
  data_split_method        = 'CUSTOM',
  data_split_col           = 'is_train'
) AS
SELECT
  -- label
  CAST(stockout_event_12w AS INT64) AS stockout_event_12w,
  is_train,
  -- demand core
  lag_1, lag_2, lag_4, lag_8, lag_12, lag_13,
  roll4_mean, roll4_std, roll8_mean, roll12_mean, roll13_mean, roll13_std,
  oos_lag1, oos_lag2, oos_lag4,
  -- seasonality
  sin1, cos1, sin2, cos2, sin3, cos3,
  -- cv / amplitude
  cv_4w, cv_12w, cv_13w, lag1_rel, amplitude,
  -- intermittency
  sale_freq_12w, zero_share_13w, zero_share_26w,
  -- lifecycle
  weeks_since_start, lifecycle_ratio,
  -- price / value
  base_lag_1, base_lag_4, base_lag_13,
  price_lag_1, price_lag_4, price_lag_13,
  price_change_1w, flag_price_discrepancy_week,
  -- customer / whale
  n_customers_week, has_vip_customer_week,
  top_customer_share_base_week, hhi_base_week
FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
WHERE split IN ('TRAIN', 'CALIB');

-- Quick eval on VAL
SELECT 'OOS_Classifier_h12_v1' AS model_name, *
FROM ML.EVALUATE(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h12_v1`,
  (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1` WHERE split = 'VAL')
);

-- ---------------------------------------------------------------------------
-- 2b. SCORE CLASSIFIER ON ALL SPLITS  -> score_oos_h12_all_v1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_all_v1` AS
SELECT
  p.sku_id,
  p.week_start_date,
  p.split,
  p.stockout_event_12w                   AS true_label,
  -- extract raw class probabilities (label=0 and label=1)
  (SELECT prob FROM UNNEST(p.predicted_stockout_event_12w_probs)
   WHERE SAFE_CAST(label AS INT64) = 0)  AS p0_raw,
  (SELECT prob FROM UNNEST(p.predicted_stockout_event_12w_probs)
   WHERE SAFE_CAST(label AS INT64) = 1)  AS p1_raw
FROM ML.PREDICT(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h12_v1`,
  (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
   WHERE split IN ('TRAIN', 'CALIB', 'VAL'))
) p;

-- ---------------------------------------------------------------------------
-- 2c. DETECT POSITIVE-CLASS MAPPING  -> oos_prob_mapping_h12_v1
-- ---------------------------------------------------------------------------
-- BQML may swap label 0/1. Compute correlation of p1_raw with true_label
-- on CALIB; if correlation is negative, the positive class is mapped as 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h12_v1` AS
WITH corr AS (
  SELECT
    CORR(p1_raw, CAST(true_label AS FLOAT64)) AS corr_p1_vs_label
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_all_v1`
  WHERE split = 'CALIB'
)
SELECT
  corr_p1_vs_label,
  CASE
    WHEN corr_p1_vs_label >= 0 THEN 'USE_P1'   -- p1_raw is P(OOS=1)
    ELSE                             'USE_P0'   -- p0_raw is P(OOS=1)
  END AS mapping,
  CURRENT_TIMESTAMP() AS created_at
FROM corr;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h12_v1`;

-- ---------------------------------------------------------------------------
-- 2d. SCORE TABLE WITH CORRECT POSITIVE-CLASS PROBABILITY
-- (Inline mapping: always use the p column with positive correlation to label)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_all_v1` AS
WITH raw AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    p.split,
    p.stockout_event_12w AS true_label,
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_12w_probs)
     WHERE SAFE_CAST(label AS INT64) = 0) AS p0_raw,
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_12w_probs)
     WHERE SAFE_CAST(label AS INT64) = 1) AS p1_raw
  FROM ML.PREDICT(
    MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h12_v1`,
    (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
     WHERE split IN ('TRAIN', 'CALIB', 'VAL'))
  ) p
),
mapping AS (
  SELECT mapping FROM `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h12_v1` LIMIT 1
)
SELECT
  r.*,
  CASE WHEN m.mapping = 'USE_P1' THEN r.p1_raw ELSE r.p0_raw END AS p_oos_raw
FROM raw r
CROSS JOIN mapping m;

-- Brier raw
SELECT
  split,
  ROUND(AVG(POW(p_oos_raw - CAST(true_label AS FLOAT64), 2)), 5) AS brier_raw,
  ROUND(AVG(p_oos_raw), 4) AS mean_p_oos_raw,
  ROUND(AVG(CAST(true_label AS FLOAT64)), 4) AS prevalence
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_all_v1`
GROUP BY split ORDER BY split;

-- ---------------------------------------------------------------------------
-- 2e. PLATT CALIBRATION  m_platt_oos_h12_v1
-- Trained on CALIB split only. Maps p_oos_raw -> p_oos_h12 (calibrated).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MODEL `{PROJECT_ID}.{BQ_DATASET}.m_platt_oos_h12_v1`
OPTIONS (
  model_type        = 'LOGISTIC_REG',
  input_label_cols  = ['true_label'],
  data_split_method = 'NO_SPLIT',
  max_iterations    = 50,
  l2_reg            = 1.0
) AS
SELECT
  CAST(true_label AS INT64) AS true_label,
  p_oos_raw
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_all_v1`
WHERE split = 'CALIB';

-- ---------------------------------------------------------------------------
-- 2f. CALIBRATED SCORES  -> score_oos_h12_calibrated_v1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` AS
SELECT
  p.sku_id,
  p.week_start_date,
  p.split,
  p.true_label,
  p.p_oos_raw,
  -- calibrated probability (Platt)
  (SELECT prob FROM UNNEST(p.predicted_true_label_probs)
   WHERE SAFE_CAST(label AS INT64) = 1) AS p_oos_h12
FROM ML.PREDICT(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_platt_oos_h12_v1`,
  (SELECT sku_id, week_start_date, split, true_label, p_oos_raw
   FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_all_v1`)
) p;

-- Brier comparison: raw vs calibrated
SELECT
  split,
  ROUND(AVG(POW(p_oos_raw  - CAST(true_label AS FLOAT64), 2)), 5) AS brier_raw,
  ROUND(AVG(POW(p_oos_h12  - CAST(true_label AS FLOAT64), 2)), 5) AS brier_cal,
  ROUND(AVG(p_oos_raw),  4) AS mean_p_raw,
  ROUND(AVG(p_oos_h12),  4) AS mean_p_cal,
  ROUND(AVG(CAST(true_label AS FLOAT64)), 4) AS prevalence
FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1`
GROUP BY split ORDER BY split;

-- Calibration deciles on VAL
SELECT
  decile,
  ROUND(AVG(p_oos_h12), 4)                   AS avg_predicted,
  ROUND(AVG(CAST(true_label AS FLOAT64)), 4) AS avg_actual,
  COUNT(*)                                    AS n
FROM (
  SELECT
    true_label,
    p_oos_h12,
    NTILE(10) OVER (ORDER BY p_oos_h12) AS decile
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1`
  WHERE split = 'VAL'
)
GROUP BY decile ORDER BY decile;

-- ---------------------------------------------------------------------------
-- 2g. ENRICH TRAINING SPINE WITH p_oos_h12 (for demand regressor)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1` AS
SELECT
  e.*,
  COALESCE(cal.p_oos_h12, 0.0) AS p_oos_h12
FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1` e
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` cal
  ON cal.sku_id = e.sku_id AND cal.week_start_date = e.week_start_date;

-- ---------------------------------------------------------------------------
-- 2h. DEMAND REGRESSOR  m_demand_h12_v1
-- Label: y_true_12w (sum of 12 future weeks)
-- Uses p_oos_h12 as exogenous feature (same pattern as H4 using p_oos_h4)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h12_v1`
OPTIONS (
  model_type            = 'BOOSTED_TREE_REGRESSOR',
  input_label_cols      = ['y_true_12w'],
  num_parallel_tree     = 6,
  max_iterations        = 50,
  learn_rate            = 0.1,
  l1_reg                = 0.01,
  l2_reg                = 0.01,
  max_tree_depth        = 6,
  subsample             = 0.8,
  min_tree_child_weight = 10,
  data_split_method     = 'CUSTOM',
  data_split_col        = 'is_train'
) AS
SELECT
  y_true_12w,
  is_train,
  -- calibrated OOS probability (exogenous)
  p_oos_h12,
  -- demand core
  lag_1, lag_2, lag_4, lag_8, lag_12, lag_13,
  roll4_mean, roll4_std, roll8_mean, roll12_mean, roll13_mean, roll13_std,
  oos_lag1, oos_lag2, oos_lag4,
  -- seasonality
  sin1, cos1, sin2, cos2, sin3, cos3,
  -- cv / amplitude
  cv_4w, cv_12w, cv_13w, lag1_rel, amplitude,
  -- intermittency
  sale_freq_12w, zero_share_13w, zero_share_26w,
  -- lifecycle
  weeks_since_start, lifecycle_ratio,
  -- price / value
  base_lag_1, base_lag_4, base_lag_13,
  price_lag_1, price_lag_4, price_lag_13,
  price_change_1w, flag_price_discrepancy_week,
  -- customer / whale
  n_customers_week, has_vip_customer_week,
  top_customer_share_base_week, hhi_base_week
FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
WHERE split IN ('TRAIN', 'CALIB');

-- Quick eval on VAL
SELECT 'Demand_Regressor_h12_v1' AS model_name, *
FROM ML.EVALUATE(
  MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h12_v1`,
  (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1` WHERE split = 'VAL')
);
