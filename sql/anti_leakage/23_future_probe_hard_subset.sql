-- =====================================================
-- ANTI-LEAKAGE TEST T1: FUTURE FEATURE PROBE - HARD SUBSET
-- =====================================================
-- Purpose: Test model's ability to detect deliberate temporal leakage
--          on DIFFICULT cases only (where baseline struggles)
--
-- Rationale: Full dataset test inconclusive due to saturated performance
--            (baseline AUC 98.9%). Hard subset should show larger delta.
--
-- Expected: Baseline AUC ~60-80% (weak on hard cases)
--           Leaky AUC ~80-95% (strong improvement with future info)
--           Delta: +15-20pp (proves detection capacity)
--
-- Hard Subset Criteria:
--   1. lag_1 > percentile(50) (recent activity)
--   2. roll4_mean > 0 (not cold start)
--   3. n_days_nonzero >= 3 (sufficient history)
--   4. y_oos_h4 label is NOT trivially predictable
--
-- =====================================================

-- Step 1: Define hard subset
-- (Exclude easy cases where label is trivially 0 or 1)
CREATE OR REPLACE TABLE `{dataset_ref}.features_hard_subset_h4` AS
WITH percentiles AS (
  SELECT
    APPROX_QUANTILES(lag_1, 100)[OFFSET(50)] AS lag1_p50
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE split = 'VAL'
)
SELECT
  f.*
FROM `{dataset_ref}.weekly_features_h4` f
CROSS JOIN percentiles p
WHERE
  f.split = 'VAL'
  -- Hard case criteria
  AND f.lag_1 > p.lag1_p50  -- Recent non-zero activity
  AND f.roll4_mean > 0       -- Not cold start
  AND f.n_days_nonzero >= 3  -- Sufficient history
  -- Exclude trivial cases
  AND NOT (f.lag_1 = 0 AND f.roll4_mean = 0)  -- Not trivially OOS
  AND NOT (f.lag_1 > 10 AND f.roll4_mean > 10) -- Not trivially NOT_OOS
;

-- Check hard subset size
SELECT
  COUNT(*) AS n_hard_subset,
  SUM(CASE WHEN y_oos_h4 = 1 THEN 1 ELSE 0 END) AS n_oos,
  AVG(CASE WHEN y_oos_h4 = 1 THEN 1.0 ELSE 0.0 END) AS prevalence_hard
FROM `{dataset_ref}.features_hard_subset_h4`
;


-- =====================================================
-- Step 2: Train BASELINE model on hard subset (clean features)
-- =====================================================
CREATE OR REPLACE MODEL `{dataset_ref}.m_baseline_hard_h4`
OPTIONS (
  model_type = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols = ['y_oos_h4'],
  auto_class_weights = TRUE,
  max_iterations = 50,
  early_stop = TRUE,
  min_rel_progress = 0.01,
  data_split_method = 'NO_SPLIT'
) AS
SELECT
  -- Target
  y_oos_h4,
  
  -- Temporal
  iso_week,
  is_high_season,
  is_jan,
  is_feb,
  
  -- Lag features
  lag_1,
  lag_2,
  lag_3,
  lag_4,
  
  -- Rolling features
  roll4_mean,
  roll4_std,
  roll13_mean,
  roll13_std,
  
  -- Volatility
  cv_roll4,
  cv_roll13,
  
  -- Client diversity
  n_customers_roll4,
  n_customers_roll13,
  
  -- Demand patterns
  n_days_nonzero,
  pct_days_nonzero
  
FROM `{dataset_ref}.features_hard_subset_h4`
;


-- =====================================================
-- Step 3: Create LEAKY features for hard subset
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.features_leaky_hard_h4` AS
SELECT
  f.*,
  
  -- Deliberate leakage: future sales (1 week ahead)
  LEAD(y_sales, 1) OVER (
    PARTITION BY sku_id
    ORDER BY week_start_date
  ) AS leak_next_week_sales,
  
  -- Current week sales (should NOT be in features)
  y_sales AS leak_current_sales

FROM `{dataset_ref}.features_hard_subset_h4` f
;


-- =====================================================
-- Step 4: Train LEAKY model on hard subset
-- =====================================================
CREATE OR REPLACE MODEL `{dataset_ref}.m_leaky_hard_h4`
OPTIONS (
  model_type = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols = ['y_oos_h4'],
  auto_class_weights = TRUE,
  max_iterations = 50,
  early_stop = TRUE,
  min_rel_progress = 0.01,
  data_split_method = 'NO_SPLIT'
) AS
SELECT
  -- Target
  y_oos_h4,
  
  -- Temporal
  iso_week,
  is_high_season,
  is_jan,
  is_feb,
  
  -- Lag features
  lag_1,
  lag_2,
  lag_3,
  lag_4,
  
  -- Rolling features
  roll4_mean,
  roll4_std,
  roll13_mean,
  roll13_std,
  
  -- Volatility
  cv_roll4,
  cv_roll13,
  
  -- Client diversity
  n_customers_roll4,
  n_customers_roll13,
  
  -- Demand patterns
  n_days_nonzero,
  pct_days_nonzero,
  
  -- 🔴 LEAKY FEATURES (should NOT exist in real model)
  leak_next_week_sales,
  leak_current_sales

FROM `{dataset_ref}.features_leaky_hard_h4`
WHERE leak_next_week_sales IS NOT NULL  -- Exclude last week with no future
;


-- =====================================================
-- Step 5: Evaluate BASELINE on hard subset
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_baseline_hard_h4` AS
SELECT
  *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_baseline_hard_h4`,
  (SELECT * FROM `{dataset_ref}.features_hard_subset_h4`)
)
;


-- =====================================================
-- Step 6: Evaluate LEAKY on hard subset
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_leaky_hard_h4` AS
SELECT
  *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_leaky_hard_h4`,
  (SELECT * FROM `{dataset_ref}.features_leaky_hard_h4`
   WHERE leak_next_week_sales IS NOT NULL)
)
;


-- =====================================================
-- Step 7: Compare baseline vs leaky on hard subset
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.comparison_hard_subset_h4` AS
SELECT
  'baseline_hard' AS model_type,
  roc_auc,
  log_loss,
  precision,
  recall,
  f1_score
FROM `{dataset_ref}.eval_baseline_hard_h4`

UNION ALL

SELECT
  'leaky_hard' AS model_type,
  roc_auc,
  log_loss,
  precision,
  recall,
  f1_score
FROM `{dataset_ref}.eval_leaky_hard_h4`
;


-- =====================================================
-- Step 8: Feature importance for leaky model (hard subset)
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.feature_importance_leaky_hard_h4` AS
SELECT
  feature,
  importance,
  CASE
    WHEN feature LIKE 'leak_%' THEN '🔴 LEAKY'
    ELSE '✅ CLEAN'
  END AS feature_type
FROM ML.FEATURE_IMPORTANCE(MODEL `{dataset_ref}.m_leaky_hard_h4`)
ORDER BY importance DESC
;


-- =====================================================
-- Step 9: Final comparison (wide format)
-- =====================================================
WITH baseline AS (
  SELECT
    roc_auc AS baseline_auc,
    precision AS baseline_precision,
    recall AS baseline_recall
  FROM `{dataset_ref}.eval_baseline_hard_h4`
),
leaky AS (
  SELECT
    roc_auc AS leaky_auc,
    precision AS leaky_precision,
    recall AS leaky_recall
  FROM `{dataset_ref}.eval_leaky_hard_h4`
)
SELECT
  b.baseline_auc,
  l.leaky_auc,
  l.leaky_auc - b.baseline_auc AS auc_improvement,
  b.baseline_precision,
  l.leaky_precision,
  b.baseline_recall,
  l.leaky_recall,
  
  -- Verdict
  CASE
    WHEN l.leaky_auc - b.baseline_auc >= 0.10 THEN '✅ PASS: Model sensitive to future info (+10pp)'
    WHEN l.leaky_auc - b.baseline_auc >= 0.05 THEN '⚠️ MARGINAL: Some sensitivity (+5-10pp)'
    ELSE '❌ FAIL: Not sensitive to future info (<5pp)'
  END AS verdict
  
FROM baseline b
CROSS JOIN leaky l
;
