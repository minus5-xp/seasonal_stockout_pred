-- ============================================================================
-- ANTI-LEAKAGE TEST T1: FUTURE FEATURE PROBE
-- ============================================================================
-- Purpose: Deliberately inject a "future feature" to detect pipeline leakage
-- 
-- Design:
--   1. Create LEAKY feature: lag_sales_future = sales at t (should NOT be available at t-h)
--   2. Train model WITH leaky feature
--   3. Compare AUC_leaky vs AUC_baseline
--   4. Expected: AUC_leaky >> AUC_baseline (proves model CAN use future if available)
--   5. Sanity check: if AUC_baseline ≈ AUC_leaky, something is wrong
--
-- Hypothesis:
--   If we add a feature that "knows the future", AUC should increase dramatically
--   (proving the model has capacity to exploit temporal leakage IF present)
--
-- Success criteria:
--   AUC_leaky - AUC_baseline > 0.15 (15pp improvement)
--   This proves: (a) model can detect leakage, (b) baseline features are NOT leaky
-- ============================================================================

-- Step 1: Create feature table WITH intentional leakage
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.features_leaky_probe_h4` AS
WITH base_features AS (
  -- Assume we have a features table like: features_oos_h4
  SELECT 
    sku_key,
    target_date,
    -- Copy all legitimate features
    lag_sales_4w,
    lag_sales_8w,
    lag_sales_12w,
    sku_sales_volatility,
    hhi_concentration,
    top_product_share,
    is_high_season,
    month,
    week_of_year,
    -- Original label
    y_oos_4w
  FROM `{project_id}.{dataset_id}.features_oos_h4`
  WHERE target_date >= '2023-01-01'  -- Ensure sufficient history
),

sales_lookup AS (
  -- Get actual sales AT target_date (this is the LEAK)
  SELECT 
    sku_key,
    sales_date,
    SUM(sales_qty) as sales_at_target
  FROM `{project_id}.{dataset_id}.fact_sales`
  GROUP BY sku_key, sales_date
)

SELECT 
  bf.*,
  -- LEAKY FEATURE: sales at target_date (should be UNKNOWN at forecast time)
  COALESCE(sl.sales_at_target, 0) as lag_sales_FUTURE,
  -- Another leak: next week's sales
  COALESCE(sl_next.sales_at_target, 0) as lag_sales_FUTURE_plus1w
FROM base_features bf
LEFT JOIN sales_lookup sl 
  ON bf.sku_key = sl.sku_key 
  AND bf.target_date = sl.sales_date
LEFT JOIN sales_lookup sl_next
  ON bf.sku_key = sl_next.sku_key
  AND bf.target_date = DATE_ADD(sl_next.sales_date, INTERVAL -7 DAY)
;

-- Step 2: Train LEAKY model
CREATE OR REPLACE MODEL `{project_id}.{dataset_id}.model_leaky_probe_h4`
OPTIONS(
  model_type='BOOSTED_TREE_CLASSIFIER',
  input_label_cols=['y_oos_4w'],
  max_iterations=50,
  learn_rate=0.1,
  min_tree_weight=1,
  tree_method='HIST',
  data_split_method='CUSTOM',
  data_split_col='split'
) AS
SELECT 
  -- Add split column for temporal validation
  CASE 
    WHEN target_date < '2024-01-01' THEN 'TRAIN'
    WHEN target_date BETWEEN '2024-01-01' AND '2024-03-31' THEN 'EVAL'
    ELSE 'TEST'
  END as split,
  
  -- Features (INCLUDING leaky ones)
  lag_sales_4w,
  lag_sales_8w,
  lag_sales_12w,
  sku_sales_volatility,
  hhi_concentration,
  top_product_share,
  is_high_season,
  month,
  week_of_year,
  lag_sales_FUTURE,  -- LEAK
  lag_sales_FUTURE_plus1w,  -- LEAK
  
  -- Label
  y_oos_4w
FROM `{project_id}.{dataset_id}.features_leaky_probe_h4`
WHERE target_date >= '2023-01-01'
;

-- Step 3: Evaluate LEAKY model
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.eval_leaky_probe_h4` AS
WITH predictions AS (
  SELECT
    *,
    CASE 
      WHEN target_date < '2024-01-01' THEN 'TRAIN'
      WHEN target_date BETWEEN '2024-01-01' AND '2024-03-31' THEN 'VAL'
      ELSE 'TEST'
    END as split
  FROM ML.PREDICT(
    MODEL `{project_id}.{dataset_id}.model_leaky_probe_h4`,
    (SELECT * FROM `{project_id}.{dataset_id}.features_leaky_probe_h4`)
  )
)

SELECT
  split,
  COUNT(*) as n_samples,
  SUM(CAST(y_oos_4w AS INT64)) as n_positives,
  AVG(CAST(y_oos_4w AS FLOAT64)) as prevalence,
  
  -- Confusion matrix metrics
  COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w = 1) as tp,
  COUNTIF(predicted_y_oos_4w = 0 AND y_oos_4w = 1) as fn,
  COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w = 0) as fp,
  COUNTIF(predicted_y_oos_4w = 0 AND y_oos_4w = 0) as tn,
  
  -- Precision, Recall
  SAFE_DIVIDE(
    COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w = 1),
    COUNTIF(predicted_y_oos_4w = 1)
  ) as precision,
  SAFE_DIVIDE(
    COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w = 1),
    COUNTIF(y_oos_4w = 1)
  ) as recall
  
FROM predictions
GROUP BY split
ORDER BY 
  CASE split 
    WHEN 'TRAIN' THEN 1 
    WHEN 'VAL' THEN 2 
    ELSE 3 
  END
;

-- Step 4: Get AUC from ML.EVALUATE
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.eval_leaky_auc_h4` AS
SELECT 
  'LEAKY_MODEL' as model_type,
  *
FROM ML.EVALUATE(
  MODEL `{project_id}.{dataset_id}.model_leaky_probe_h4`,
  (
    SELECT * FROM `{project_id}.{dataset_id}.features_leaky_probe_h4`
    WHERE target_date BETWEEN '2024-01-01' AND '2024-03-31'  -- VAL split
  )
);

-- Step 5: Compare with BASELINE (assume baseline model exists)
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.comparison_leaky_vs_baseline_h4` AS
WITH baseline_auc AS (
  SELECT 
    'BASELINE_MODEL' as model_type,
    roc_auc,
    precision,
    recall,
    f1_score
  FROM `{project_id}.{dataset_id}.results_model_evaluate`
  WHERE model_name = 'stockout_seasonal_oos_h4'
  LIMIT 1
),

leaky_auc AS (
  SELECT
    'LEAKY_MODEL' as model_type,
    roc_auc,
    precision,
    recall,
    f1_score
  FROM `{project_id}.{dataset_id}.eval_leaky_auc_h4`
  LIMIT 1
)

SELECT 
  b.model_type as baseline_model,
  b.roc_auc as baseline_auc,
  b.precision as baseline_precision,
  b.recall as baseline_recall,
  
  l.model_type as leaky_model,
  l.roc_auc as leaky_auc,
  l.precision as leaky_precision,
  l.recall as leaky_recall,
  
  -- Deltas
  l.roc_auc - b.roc_auc as auc_improvement,
  l.precision - b.precision as precision_improvement,
  l.recall - b.recall as recall_improvement,
  
  -- Verdict
  CASE 
    WHEN l.roc_auc - b.roc_auc > 0.15 THEN '✅ PASS: Model can exploit leakage (proof of capacity)'
    WHEN l.roc_auc - b.roc_auc > 0.05 THEN '⚠️ MARGINAL: Some leakage exploitation detected'
    ELSE '❌ FAIL: Model NOT sensitive to future features (suspicious)'
  END as verdict
  
FROM baseline_auc b
CROSS JOIN leaky_auc l
;

-- Step 6: Feature importance comparison
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.feature_importance_leaky_h4` AS
SELECT
  feature,
  importance,
  CASE 
    WHEN feature IN ('lag_sales_FUTURE', 'lag_sales_FUTURE_plus1w') THEN '🔴 LEAKY FEATURE'
    ELSE 'Legitimate feature'
  END as feature_type
FROM ML.FEATURE_IMPORTANCE(
  MODEL `{project_id}.{dataset_id}.model_leaky_probe_h4`
)
ORDER BY importance DESC
LIMIT 20;

-- ============================================================================
-- SUMMARY QUERY: Show results
-- ============================================================================
SELECT 
  '=== ANTI-LEAKAGE TEST T1: FUTURE FEATURE PROBE ===' as test_name,
  '' as blank,
  'Expected: AUC_leaky >> AUC_baseline (>15pp improvement)' as expectation,
  'This proves the model CAN detect leakage IF present' as interpretation
  
UNION ALL

SELECT 
  'Results:', 
  CAST(auc_improvement AS STRING),
  verdict,
  CASE 
    WHEN auc_improvement > 0.15 THEN 'Baseline features are CLEAN (no leakage detected)'
    ELSE 'WARNING: Investigate baseline features'
  END
FROM `{project_id}.{dataset_id}.comparison_leaky_vs_baseline_h4`
;

-- Query final comparison
SELECT * FROM `{project_id}.{dataset_id}.comparison_leaky_vs_baseline_h4`;
SELECT * FROM `{project_id}.{dataset_id}.feature_importance_leaky_h4`;

