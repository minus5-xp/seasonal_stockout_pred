-- ============================================================================
-- HITO 4 ABLATION A1: WITHOUT WHALE FEATURES
-- ============================================================================
-- Purpose: Train model identical to A0 but excluding customer concentration features
--
-- Excluded features (3):
--   - hhi_base_roll13 (HHI index)
--   - top_customer_share (top client %)
--   - n_customers_roll13 (# unique clients)
--
-- Remaining features (11):
--   - Core demand: lag_1, lag_2, lag_4, roll4_mean, roll13_mean, roll13_std,
--                  amplitude, cv_roll13, n_days_nonzero (9 features)
--   - Seasonal: iso_week, is_high_season (2 features)
--
-- Hypothesis: Δ_AUC (A0 - A1) < 0.02
--   Whale features capture supply chain vulnerability but demand patterns dominate
-- ============================================================================

DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-06-30';

-- Train Ablation Model A1 (no whales)
CREATE OR REPLACE MODEL `{dataset_ref}.m_ablation_a1_no_whales`
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
  -- Seasonal features (2)
  iso_week,
  is_high_season
  -- EXCLUDED: hhi_base_roll13, n_customers_roll13, top_customer_share
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'TRAIN'
  AND ever_sold_flag = 1
  AND y_oos_h4 IS NOT NULL;

-- Sanity check
SELECT
  'A1: Without Whales - Training Complete' AS status,
  (SELECT COUNT(*) FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'TRAIN') AS n_train_rows,
  11 AS n_features_used,
  3 AS n_features_excluded
FROM (SELECT 1);
