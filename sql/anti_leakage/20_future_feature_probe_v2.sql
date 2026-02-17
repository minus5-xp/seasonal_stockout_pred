-- ============================================================================
-- ANTI-LEAKAGE TEST T1: FUTURE FEATURE PROBE (VERSIÓN REAL)
-- ============================================================================
-- Purpose: Inject deliberate temporal leakage to verify model CAN detect it
--   - Uses REAL tables: weekly_features_h4, m_oos_h4
--   - Adds leaky features: y_sales (current week), LEAD(y_sales, 1)
--   - Expected: AUC spike +15pp → proves detection capacity
--
-- Success criteria:
--   AUC_leaky - AUC_baseline > 0.15 (15pp improvement)
--   Leaky features dominate importance (top-2 ranked)
-- ============================================================================

DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-06-30';
DECLARE VAL_START_DATE DATE DEFAULT '2024-01-01';
DECLARE VAL_END_DATE DATE DEFAULT '2024-12-29';

-- ====================
-- Step 1: Create Features WITH Leakage
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.features_leaky_probe_h4` AS
SELECT
  *,
  -- LEAKY FEATURES (should NOT be available at forecast time)
  y_sales AS leak_current_sales,  -- Sales at current week (should use lag_1)
  LEAD(y_sales, 1) OVER (PARTITION BY sku_id ORDER BY week_start_date) AS leak_next_week_sales
FROM `{dataset_ref}.weekly_features_h4`
WHERE split IN ('TRAIN', 'VAL')
  AND y_oos_h4 IS NOT NULL
  AND ever_sold_flag = 1;

-- Diagnostic
SELECT
  'Leaky Features Created' AS status,
  COUNT(*) AS total_rows,
  AVG(leak_current_sales) AS avg_leak_current,
  AVG(leak_next_week_sales) AS avg_leak_next,
  CORR(leak_current_sales, CAST(y_oos_h4 AS FLOAT64)) AS corr_current_label
FROM `{dataset_ref}.features_leaky_probe_h4`;

-- ====================
-- Step 2: Train LEAKY Model
-- ====================
CREATE OR REPLACE MODEL `{dataset_ref}.m_leaky_probe_h4`
OPTIONS(
  model_type='BOOSTED_TREE_CLASSIFIER',
  input_label_cols=['y_oos_h4'],
  auto_class_weights=TRUE,
  max_iterations=50,
  early_stop=TRUE,
  data_split_method='NO_SPLIT'
) AS
SELECT
  y_oos_h4,
  -- Legitimate features (same as baseline)
  lag_1, lag_2, lag_4,
  roll4_mean, roll13_mean, roll13_std,
  iso_week, is_high_season,
  hhi_base_roll13, n_customers_roll13, top_customer_share,
  amplitude, cv_roll13, n_days_nonzero,
  -- LEAKY FEATURES
  leak_current_sales,
  leak_next_week_sales
FROM `{dataset_ref}.features_leaky_probe_h4`
WHERE split = 'TRAIN';

SELECT 'Leaky Model Trained' AS status;

-- ====================
-- Step 3: Evaluate LEAKY Model (VAL)
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_leaky_probe_h4` AS
SELECT *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_leaky_probe_h4`,
  (
    SELECT
      y_oos_h4,
      lag_1, lag_2, lag_4,
      roll4_mean, roll13_mean, roll13_std,
      iso_week, is_high_season,
      hhi_base_roll13, n_customers_roll13, top_customer_share,
      amplitude, cv_roll13, n_days_nonzero,
      leak_current_sales,
      leak_next_week_sales
    FROM `{dataset_ref}.features_leaky_probe_h4`
    WHERE split = 'VAL'
  )
);

SELECT * FROM `{dataset_ref}.eval_leaky_probe_h4`;

-- ====================
-- Step 4: Get BASELINE AUC
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_baseline_auc_h4` AS
SELECT
  roc_auc AS baseline_auc
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_oos_h4`,
  (
    SELECT
      y_oos_h4,
      lag_1, lag_2, lag_4,
      roll4_mean, roll13_mean, roll13_std,
      iso_week, is_high_season,
      hhi_base_roll13, n_customers_roll13, top_customer_share,
      amplitude, cv_roll13, n_days_nonzero
    FROM `{dataset_ref}.weekly_features_h4`
    WHERE split = 'VAL'
      AND y_oos_h4 IS NOT NULL
      AND ever_sold_flag = 1
  )
);

SELECT * FROM `{dataset_ref}.eval_baseline_auc_h4`;

-- ====================
-- Step 5: Compare LEAKY vs BASELINE
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.comparison_leaky_vs_baseline_h4` AS
WITH metrics AS (
  SELECT
    (SELECT baseline_auc FROM `{dataset_ref}.eval_baseline_auc_h4` LIMIT 1) AS baseline_auc,
    (SELECT roc_auc FROM `{dataset_ref}.eval_leaky_probe_h4` LIMIT 1) AS leaky_auc,
    (SELECT precision FROM `{dataset_ref}.eval_leaky_probe_h4` LIMIT 1) AS leaky_precision,
    (SELECT recall FROM `{dataset_ref}.eval_leaky_probe_h4` LIMIT 1) AS leaky_recall
)
SELECT
  baseline_auc,
  leaky_auc,
  leaky_auc - baseline_auc AS auc_improvement,
  leaky_precision,
  leaky_recall,
  CASE
    WHEN leaky_auc - baseline_auc > 0.15
    THEN '✅ PASS: Model can exploit leakage (+15pp)'
    WHEN leaky_auc - baseline_auc > 0.05
    THEN '⚠️ MARGINAL: Moderate sensitivity (+5-15pp)'
    ELSE '❌ FAIL: NOT sensitive to future (< +5pp, suspicious)'
  END AS verdict
FROM metrics;

SELECT * FROM `{dataset_ref}.comparison_leaky_vs_baseline_h4`;

-- ====================
-- Step 6: Feature Importance
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.feature_importance_leaky_h4` AS
SELECT
  *,
  CASE 
    WHEN feature IN ('leak_current_sales', 'leak_next_week_sales') 
    THEN '🔴 LEAKY'
    ELSE 'Legitimate'
  END AS feature_type
FROM ML.FEATURE_IMPORTANCE(MODEL `{dataset_ref}.m_leaky_probe_h4`)
ORDER BY importance_weight DESC
LIMIT 20;

SELECT * FROM `{dataset_ref}.feature_importance_leaky_h4`;

-- ====================
-- SUMMARY
-- ====================
SELECT
  'T1: FUTURE FEATURE PROBE' AS test_name,
  baseline_auc,
  leaky_auc,
  auc_improvement,
  verdict,
  CASE
    WHEN auc_improvement > 0.15 
    THEN 'Model CAN detect leakage → Baseline features are CLEAN'
    WHEN auc_improvement BETWEEN 0.05 AND 0.15
    THEN 'Moderate capacity → Review feature importance'
    ELSE 'NOT sensitive → Pipeline issue OR baseline already leaky'
  END AS interpretation
FROM `{dataset_ref}.comparison_leaky_vs_baseline_h4`;
