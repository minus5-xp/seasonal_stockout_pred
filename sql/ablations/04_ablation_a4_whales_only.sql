-- ============================================================================
-- HITO 4 ABLATION A4: WHALES-ONLY MODEL
-- ============================================================================
-- Purpose: Train model using ONLY customer concentration/whale features
--
-- Included features (3):
--   - hhi_base_roll13 (Herfindahl-Hirschman Index 0-1, higher = more concentrated)
--   - top_customer_share (% of volume from top customer)
--   - n_customers_roll13 (# unique customers in 13-week window)
--
-- Excluded features (11): All demand and seasonal features
--
-- Hypothesis: AUC ≈ 0.65-0.70
--   Concentration captures structural vulnerability:
--     - High HHI → few customers → single-point-of-failure risk
--     - Top customer dominance → if they stop buying, instant stockout
--   But cannot capture:
--     - Recent demand trends (lag features)
--     - Demand volatility (CV, std)
--     - Seasonal timing (when stockouts occur)
--   
-- Business interpretation:
--   If A4 achieves AUC 0.65-0.70, validates that:
--   1. Customer concentration IS a real risk factor (not noise)
--   2. But it's a slow-moving indicator (structural, not immediate)
--   3. Need demand dynamics for actionable predictions
-- ============================================================================

DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-06-30';

-- Train Ablation Model A4 (whales-only)
CREATE OR REPLACE MODEL `{dataset_ref}.m_ablation_a4_whales_only`
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
  -- ONLY whale/concentration features (3)
  hhi_base_roll13,
  n_customers_roll13,
  top_customer_share
  -- EXCLUDED: All demand features (lag_*, roll*, amplitude, cv, etc.)
  -- EXCLUDED: All seasonal features (iso_week, is_high_season)
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'TRAIN'
  AND ever_sold_flag = 1
  AND y_oos_h4 IS NOT NULL;

-- Sanity check
SELECT
  'A4: Whales-Only - Training Complete' AS status,
  (SELECT COUNT(*) FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'TRAIN') AS n_train_rows,
  3 AS n_features_used,
  11 AS n_features_excluded,
  'Expect AUC ~0.65-0.70' AS expected_performance
FROM (SELECT 1);
