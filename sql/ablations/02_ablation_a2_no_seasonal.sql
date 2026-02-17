-- ============================================================================
-- HITO 4 ABLATION A2: WITHOUT SEASONAL FEATURES
-- ============================================================================
-- Purpose: Train model identical to A0 but excluding seasonality/time features
--
-- Excluded features (2):
--   - iso_week (week of year 1-52)
--   - is_high_season (binary flag for tourism peak)
--
-- Remaining features (12):
--   - Core demand: lag_1, lag_2, lag_4, roll4_mean, roll13_mean, roll13_std,
--                  amplitude, cv_roll13, n_days_nonzero (9 features)
--   - Whale features: hhi_base_roll13, n_customers_roll13, top_customer_share (3)
--
-- Hypothesis: Δ_AUC (A0 - A2) ≈ 0.01
--   Seasonal patterns are captured indirectly by rolling statistics
--   Explicit season flags provide marginal lift
-- ============================================================================

DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-06-30';

-- Train Ablation Model A2 (no seasonal)
CREATE OR REPLACE MODEL `{dataset_ref}.m_ablation_a2_no_seasonal`
OPTIONS(
  model_type='BOOSTED_TREE_CLASSIFIER',
  input_label_cols=['y_oos_h4'],
  auto_class_weights=TRUE,
  max_iterations=50,
  early_stop=TRUE,
  min_rel_progress=0.01,
  data_split_method='NO_SPLIT',
  enable_global_explain=TRUE
) AS
SELECT
  -- Target
  y_oos_h4,
  -- Core demand features (9)
  lag_1,
  lag_2,
  lag_4,
  roll4_mean,
  roll13_mean,
  roll13_std,
  amplitude,
  cv_roll13,
  n_days_nonzero,
  -- Whale features (3)
  hhi_base_roll13,
  n_customers_roll13,
  top_customer_share
  -- EXCLUDED: iso_week, is_high_season
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'TRAIN'
  AND ever_sold_flag = 1
  AND y_oos_h4 IS NOT NULL;

-- Sanity check
SELECT
  'A2: Without Seasonal - Training Complete' AS status,
  (SELECT COUNT(*) FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'TRAIN') AS n_train_rows,
  12 AS n_features_used,
  2 AS n_features_excluded
FROM (SELECT 1);
