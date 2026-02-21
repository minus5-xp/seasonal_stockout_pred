-- ============================================================================
-- STEP 02: TRAIN BQML MODELS v4  (OOS classifier + demand regressor)
-- ============================================================================
-- PURPOSE:
--   1. Materialise enriched_base_h4_v4: the canonical training spine
--      by joining the three source tables:
--        train_with_poos_h4    -> split, demand_decile, p_oos_h4, all raw features
--        optionb_spine_h4      -> is_high_season, hhi_base_roll13, y_oos_h4
--        weekly_features_h4_v4 -> new intermittent features (step 01 output)
--   2. Re-train OOS classifier  m_oos_h4_v4
--   3. Re-train demand regressor m_demand_h4_v4
--   4. Materialize predictions  base_scores_h4_v4
--
-- LEAKAGE SAFETY:
--   Training only on split = 'TRAIN'.
--   New features use lookback windows [t-13w, t-1w] only.
--
-- SOURCE TABLES:
--   train_with_poos_h4     : split, demand_decile, p_oos_h4, y_true_h4, features
--   optionb_spine_h4       : is_high_season, hhi_base_roll13, y_oos_h4
--   weekly_features_h4_v4  : zero_share_13w, last_nonzero_lag, mean_interarrival_13w
-- OUTPUT:
--   enriched_base_h4_v4, m_oos_h4_v4, m_demand_h4_v4, base_scores_h4_v4
-- ============================================================================

-- ============================================================================
-- 2-PRE. BUILD ENRICHED TRAINING SPINE
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4` AS
SELECT
  -- Keys & split assignment
  t.sku_id,
  t.week_start_date,
  t.split,
  t.is_train,
  t.demand_decile,

  -- Calendar / season
  t.iso_week,
  t.season_group,
  COALESCE(s.is_high_season, CAST(t.iso_week BETWEEN 14 AND 39 AS INT64)) AS is_high_season,

  -- Labels
  t.y_true_h4,
  t.y_sales,
  t.stockout_event_h4,
  COALESCE(s.y_oos_h4, 0)           AS y_oos_h4,

  -- Core features (from train_with_poos_h4)
  t.amplitude,
  t.roll13_mean,
  t.roll13_std,
  t.cv_13w,
  t.cv_4w,
  t.lag_1,
  t.lag_2,
  t.lag_4,
  t.lag_8,
  t.lag_13,
  t.lag_26,
  t.lag_52,
  t.roll4_mean,
  t.roll8_mean,
  t.oos_lag1,
  t.oos_lag2,
  t.oos_lag4,
  t.sin1, t.cos1, t.sin2, t.cos2, t.sin3, t.cos3,
  t.weeks_since_start,
  t.lag1_rel,
  t.base_week_total,
  t.unit_price_net_week,
  t.avg_precio_weighted_week,
  t.flag_price_discrepancy_week,
  t.base_lag_1, t.base_lag_4, t.base_lag_13,
  t.price_lag_1, t.price_lag_4, t.price_lag_13,
  t.price_change_1w,
  t.n_customers_week,
  t.has_vip_customer_week,
  t.top_customer_share_base_week,
  t.hhi_base_week,
  t.cust_n_lag_1, t.cust_n_lag_4,
  t.top_share_lag_1, t.top_share_lag_4,
  t.hhi_lag_1, t.hhi_lag_4,
  t.vip_lag_1, t.vip_lag_4,

  -- From optionb_spine_h4
  COALESCE(s.hhi_base_roll13, t.hhi_base_week) AS hhi_base_roll13,

  -- Calibrated OOS probability from train_with_poos_h4
  t.p_oos_h4,

  -- NEW: intermittent-demand features from step 01
  COALESCE(v.zero_share_13w,        0.0)  AS zero_share_13w,
  COALESCE(v.last_nonzero_lag,     14.0)  AS last_nonzero_lag,
  COALESCE(v.mean_interarrival_13w, 13.0) AS mean_interarrival_13w

FROM `thequantitativeledger.cruzber_models_eu.train_with_poos_h4` t
LEFT JOIN `thequantitativeledger.cruzber_models_eu.optionb_spine_h4` s
  ON t.sku_id = s.sku_id AND t.week_start_date = s.week_start_date
LEFT JOIN `thequantitativeledger.cruzber_models_eu.weekly_features_h4_v4` v
  ON t.sku_id = v.sku_id AND t.week_start_date = v.week_start_date
WHERE t.split IN ('TRAIN', 'CALIB', 'VAL');

-- Quick sanity
SELECT split, COUNT(*) AS n_rows,
  ROUND(AVG(zero_share_13w), 4)   AS avg_zero_share,
  ROUND(AVG(is_high_season), 4)   AS pct_high_season,
  COUNTIF(hhi_base_roll13 IS NULL) AS n_null_hhi
FROM `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4`
GROUP BY split ORDER BY split;

-- ============================================================================
-- 2a. OOS CLASSIFIER  m_oos_h4_v4
-- ============================================================================
-- Matches the existing m_oos_h4 structure; adds 3 new features.
CREATE OR REPLACE MODEL `thequantitativeledger.cruzber_models_eu.m_oos_h4_v4`
OPTIONS (
  model_type               = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols         = ['y_oos_h4'],
  num_parallel_tree        = 6,
  max_tree_depth           = 6,
  subsample                = 0.8,
  l1_reg                   = 0.1,
  l2_reg                   = 1.0,
  learn_rate               = 0.05,
  max_iterations           = 300,
  early_stop               = TRUE,
  min_rel_progress         = 0.001,
  enable_global_explain    = FALSE
)
AS
SELECT
  -- Label
  CAST(y_oos_h4 AS INT64)           AS y_oos_h4,

  -- Existing features (kept identical to m_oos_h4 for comparability)
  amplitude,
  roll13_mean,
  roll13_std,
  cv_13w,
  hhi_base_roll13,
  is_high_season,

  -- NEW: intermittent-demand features
  zero_share_13w,
  last_nonzero_lag,
  mean_interarrival_13w

FROM `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4`
WHERE split = 'TRAIN'
  AND y_oos_h4 IS NOT NULL;


-- ============================================================================
-- 2b. DEMAND REGRESSOR  m_demand_h4_v4
-- ============================================================================
CREATE OR REPLACE MODEL `thequantitativeledger.cruzber_models_eu.m_demand_h4_v4`
OPTIONS (
  model_type               = 'BOOSTED_TREE_REGRESSOR',
  input_label_cols         = ['y_true_h4'],
  num_parallel_tree        = 6,
  max_tree_depth           = 6,
  subsample                = 0.8,
  l1_reg                   = 0.1,
  l2_reg                   = 1.0,
  learn_rate               = 0.05,
  max_iterations           = 300,
  early_stop               = TRUE,
  min_rel_progress         = 0.001,
  enable_global_explain    = FALSE
)
AS
SELECT
  -- Label (non-negative; OOS rows have y_true_h4=0 which is valid for demand regression)
  GREATEST(0.0, y_true_h4)          AS y_true_h4,

  -- Existing features
  amplitude,
  roll13_mean,
  roll13_std,
  cv_13w,
  hhi_base_roll13,
  is_high_season,
  p_oos_h4,          -- previous-period OOS probability as exog signal

  -- NEW: intermittent-demand features
  zero_share_13w,
  last_nonzero_lag,
  mean_interarrival_13w

FROM `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4`
WHERE split = 'TRAIN'
  AND y_true_h4 IS NOT NULL;

-- NOTE: Scoring (base_scores_h4_v4) is in 02b_score_models_h4_v4.sql
-- (separated so --skip-training can skip model creation without losing scoring)
