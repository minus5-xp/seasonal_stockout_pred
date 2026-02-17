-- =====================================================
-- ANTI-LEAKAGE TEST T1a: FUTURE FEATURE PROBE - HARD SUBSET (FIXED)
-- =====================================================
-- Purpose: Test model's ability to detect deliberate temporal leakage
--          on DIFFICULT cases only (where baseline struggles)
--
-- Uses ONLY available columns in weekly_features_h4:
--   lag_1, lag_2, lag_4, roll4_mean, roll13_mean, roll13_std,
--   iso_week, is_high_season, month, n_days_nonzero, etc.
--
-- Expected: Baseline AUC ~60-80% (weak on hard cases)
--           Leaky AUC ~80-95% (strong improvement with future info)
--           Delta: +15-20pp (proves detection capacity)
-- =====================================================

-- Step 1: Define hard subset
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
  -- Hard case criteria (using available columns)
  AND f.lag_1 > p.lag1_p50  -- Recent non-zero activity
  AND f.roll4_mean > 0       -- Not cold start
  AND f.n_days_nonzero >= 3  -- Sufficient history
  -- Exclude trivial cases
  AND NOT (f.lag_1 = 0 AND f.roll4_mean = 0)  -- Not trivially OOS
  AND NOT (f.lag_1 > 10 AND f.roll4_mean > 10) -- Not trivially NOT_OOS
;

-- Step 2: Train BASELINE model on hard subset (clean features only)
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
  y_oos_h4,
  
  -- Temporal (available columns only)
  iso_week,
  is_high_season,
  month,
  
  -- Lag features (available only)
  lag_1,
  lag_2,
  lag_4,
  
  -- Rolling features (available only)
  roll4_mean,
  roll13_mean,
  roll13_std,
  cv_roll13,
  
  -- Activity patterns
  n_days_active,
  n_days_nonzero,
  
  -- Client diversity (available only)
  n_customers_roll13,
  hhi_base_roll13,
  top_customer_share,
  
  -- Volatility
  amplitude
  
FROM `{dataset_ref}.features_hard_subset_h4`
WHERE split = 'VAL'
;

-- Step 3: Train LEAKY model with future information
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
  y_oos_h4,
  
  -- Same features as baseline
  iso_week,
  is_high_season,
  month,
  lag_1,
  lag_2,
  lag_4,
  roll4_mean,
  roll13_mean,
  roll13_std,
  cv_roll13,
  n_days_active,
  n_days_nonzero,
  n_customers_roll13,
  hhi_base_roll13,
  top_customer_share,
  amplitude,
  
  -- LEAKY FEATURE: Future sales at h=4
  y_sales_h4 AS leak_next_week_sales  -- THIS IS THE FUTURE LEAK
  
FROM `{dataset_ref}.features_hard_subset_h4`
WHERE split = 'VAL'
;

-- Step 4: Evaluate both models
CREATE OR REPLACE TABLE `{dataset_ref}.eval_baseline_hard_h4` AS
SELECT * FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_baseline_hard_h4`,
  (SELECT * FROM `{dataset_ref}.features_hard_subset_h4` WHERE split = 'VAL')
);

CREATE OR REPLACE TABLE `{dataset_ref}.eval_leaky_hard_h4` AS  
SELECT * FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_leaky_hard_h4`,
  (SELECT * FROM `{dataset_ref}.features_hard_subset_h4` WHERE split = 'VAL')
);

-- Step 5: Compare results
CREATE OR REPLACE TABLE `{dataset_ref}.comparison_hard_subset_h4` AS
WITH metrics AS (
  SELECT 
    'baseline_hard' AS model_type,
    roc_auc AS auc,
    log_loss,
    precision,
    recall
  FROM `{dataset_ref}.eval_baseline_hard_h4`
  
  UNION ALL
  
  SELECT 
    'leaky_hard' AS model_type,
    roc_auc AS auc,
    log_loss,
    precision,
    recall
  FROM `{dataset_ref}.eval_leaky_hard_h4`
),
comparison AS (
  SELECT
    MAX(CASE WHEN model_type = 'baseline_hard' THEN auc END) AS baseline_auc,
    MAX(CASE WHEN model_type = 'leaky_hard' THEN auc END) AS leaky_auc,
    MAX(CASE WHEN model_type = 'leaky_hard' THEN auc END) - 
    MAX(CASE WHEN model_type = 'baseline_hard' THEN auc END) AS auc_improvement,
    
    MAX(CASE WHEN model_type = 'leaky_hard' THEN precision END) AS leaky_precision,
    MAX(CASE WHEN model_type = 'leaky_hard' THEN recall END) AS leaky_recall
  FROM metrics
)
SELECT
  *,
  CASE
    WHEN auc_improvement >= 0.15 THEN '✅ PASS: Detected leakage on hard cases (+15pp)'
    WHEN auc_improvement >= 0.10 THEN '⚠️ MARGINAL: Weak detection (+10-15pp)'
    ELSE '❌ FAIL: Not sensitive to future on hard cases (< +10pp)'
  END AS verdict
FROM comparison
;

-- Final output
SELECT * FROM `{dataset_ref}.comparison_hard_subset_h4`;
