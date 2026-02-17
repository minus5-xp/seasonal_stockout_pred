-- ============================================================================
-- HITO 4 ABLATION A3: SEASON-ONLY MODEL
-- ============================================================================
-- Purpose: Train model using ONLY seasonal/time features
--
-- Included features (2):
--   - iso_week (week of year 1-52)
--   - is_high_season (binary flag for tourism peak)
--
-- Excluded features (12): All demand and whale features
--
-- Hypothesis: AUC ≈ 0.70-0.75
--   Seasonality alone provides decent signal (tourism→stockouts) but insufficient
--   Cannot capture SKU-specific demand dynamics or supply chain vulnerabilities
--   
-- Business interpretation:
--   If A3 achieves AUC 0.70-0.75, validates that:
--   1. Tourism seasonality is a real driver (not just correlation)
--   2. But it's not sufficient alone (need demand features for 0.98+ AUC)
-- ============================================================================

DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-06-30';

-- Train Ablation Model A3 (season-only)
CREATE OR REPLACE MODEL `{dataset_ref}.m_ablation_a3_season_only`
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
  -- ONLY seasonal features (2)
  iso_week,
  is_high_season
  -- EXCLUDED: All demand features (lag_*, roll*, amplitude, cv, etc.)
  -- EXCLUDED: All whale features (hhi, top_customer_share, n_customers)
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'TRAIN'
  AND ever_sold_flag = 1
  AND y_oos_h4 IS NOT NULL;

-- Sanity check
SELECT
  'A3: Season-Only - Training Complete' AS status,
  (SELECT COUNT(*) FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'TRAIN') AS n_train_rows,
  2 AS n_features_used,
  12 AS n_features_excluded,
  'Expect AUC ~0.70-0.75' AS expected_performance
FROM (SELECT 1);
