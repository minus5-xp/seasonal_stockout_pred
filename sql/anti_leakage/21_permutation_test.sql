-- ============================================================================
-- ANTI-LEAKAGE TEST T2: PERMUTATION TEST
-- ============================================================================
-- Purpose: Permute labels (shuffle y_oos within time windows) to verify performance collapse
--
-- Design:
--   1. Take VAL split features
--   2. PERMUTE labels randomly (break feature→label relationship)
--   3. Evaluate baseline model on permuted data
--   4. Expected: AUC_permuted ≈ 0.50 (random guessing)
--   5. If AUC_permuted >> 0.50, features contain "hidden label proxies" (leak)
--
-- Hypothesis:
--   Performance should collapse to ~0.50 when labels are random
--   (proves model relies on feature→label relationship, not memorization)
--
-- Success criteria:
--   0.45 < AUC_permuted < 0.55 (random performance)
--   AUC_baseline / AUC_permuted > 1.5 (baseline is 50%+ better than random)
-- ============================================================================

-- Step 1: Create permuted labels dataset
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.features_permuted_labels_h4` AS
WITH val_data AS (
  -- Get VAL split only
  SELECT 
    *,
    ROW_NUMBER() OVER (ORDER BY RAND()) as row_num_shuffle
  FROM `{project_id}.{dataset_id}.features_oos_h4`
  WHERE target_date BETWEEN '2024-01-01' AND '2024-03-31'  -- VAL period
),

labels_only AS (
  -- Extract labels and shuffle them
  SELECT 
    row_num_shuffle,
    y_oos_4w as y_oos_4w_original,
    LEAD(y_oos_4w) OVER (ORDER BY RAND()) as y_oos_4w_permuted
  FROM val_data
)

SELECT 
  v.*,
  l.y_oos_4w_permuted,
  -- Keep original for comparison
  v.y_oos_4w as y_oos_4w_original
FROM val_data v
INNER JOIN labels_only l ON v.row_num_shuffle = l.row_num_shuffle
;

-- Verify permutation worked (should see different distributions in temporal windows)
SELECT 
  DATE_TRUNC(target_date, WEEK) as week,
  AVG(CAST(y_oos_4w_original AS FLOAT64)) as prevalence_original,
  AVG(CAST(y_oos_4w_permuted AS FLOAT64)) as prevalence_permuted,
  ABS(AVG(CAST(y_oos_4w_original AS FLOAT64)) - AVG(CAST(y_oos_4w_permuted AS FLOAT64))) as delta_prevalence
FROM `{project_id}.{dataset_id}.features_permuted_labels_h4`
GROUP BY week
ORDER BY week
LIMIT 10;

-- Step 2: Evaluate baseline model on PERMUTED labels
-- (Use ML.PREDICT but substitute permuted labels in evaluation)
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.eval_permuted_test_h4` AS
WITH predictions AS (
  -- Predict using BASELINE model (trained on real labels)
  SELECT
    p.*,
    f.y_oos_4w_permuted  -- Use permuted labels for evaluation
  FROM ML.PREDICT(
    MODEL `{project_id}.{dataset_id}.stockout_seasonal_oos_h4`,
    (
      SELECT 
        sku_key,
        target_date,
        lag_sales_4w,
        lag_sales_8w,
        lag_sales_12w,
        sku_sales_volatility,
        hhi_concentration,
        top_product_share,
        is_high_season,
        month,
        week_of_year
      FROM `{project_id}.{dataset_id}.features_permuted_labels_h4`
    )
  ) p
  INNER JOIN `{project_id}.{dataset_id}.features_permuted_labels_h4` f
    ON p.sku_key = f.sku_key 
    AND p.target_date = f.target_date
)

SELECT
  'PERMUTED_LABELS' as test_type,
  COUNT(*) as n_samples,
  SUM(CAST(y_oos_4w_permuted AS INT64)) as n_positives,
  AVG(CAST(y_oos_4w_permuted AS FLOAT64)) as prevalence,
  
  -- Confusion matrix (against permuted labels)
  COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w_permuted = 1) as tp,
  COUNTIF(predicted_y_oos_4w = 0 AND y_oos_4w_permuted = 1) as fn,
  COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w_permuted = 0) as fp,
  COUNTIF(predicted_y_oos_4w = 0 AND y_oos_4w_permuted = 0) as tn,
  
  -- Metrics (should be ~random)
  SAFE_DIVIDE(
    COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w_permuted = 1),
    COUNTIF(predicted_y_oos_4w = 1)
  ) as precision_permuted,
  SAFE_DIVIDE(
    COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w_permuted = 1),
    COUNTIF(y_oos_4w_permuted = 1)
  ) as recall_permuted
FROM predictions
;

-- Step 3: Calculate AUC on permuted labels manually (BigQuery ML.EVALUATE needs actual model)
-- Alternative: Use sklearn-like ROC calculation
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.roc_curve_permuted_h4` AS
WITH predictions_scored AS (
  SELECT
    f.y_oos_4w_permuted as y_true,
    p.predicted_y_oos_4w_probs[OFFSET(1)].prob as y_score  -- Prob of class 1
  FROM ML.PREDICT(
    MODEL `{project_id}.{dataset_id}.stockout_seasonal_oos_h4`,
    (
      SELECT 
        sku_key,
        target_date,
        lag_sales_4w,
        lag_sales_8w,
        lag_sales_12w,
        sku_sales_volatility,
        hhi_concentration,
        top_product_share,
        is_high_season,
        month,
        week_of_year
      FROM `{project_id}.{dataset_id}.features_permuted_labels_h4`
    )
  ) p
  INNER JOIN `{project_id}.{dataset_id}.features_permuted_labels_h4` f
    ON p.sku_key = f.sku_key 
    AND p.target_date = f.target_date
),

thresholds AS (
  -- Generate 100 thresholds
  SELECT threshold / 100.0 as threshold
  FROM UNNEST(GENERATE_ARRAY(0, 100)) as threshold
),

roc_points AS (
  SELECT
    t.threshold,
    -- TPR = TP / (TP + FN)
    SAFE_DIVIDE(
      COUNTIF(ps.y_score >= t.threshold AND ps.y_true = 1),
      COUNTIF(ps.y_true = 1)
    ) as tpr,
    -- FPR = FP / (FP + TN)
    SAFE_DIVIDE(
      COUNTIF(ps.y_score >= t.threshold AND ps.y_true = 0),
      COUNTIF(ps.y_true = 0)
    ) as fpr
  FROM predictions_scored ps
  CROSS JOIN thresholds t
  GROUP BY t.threshold
)

SELECT 
  *,
  -- AUC approximation using trapezoidal rule
  AVG(tpr) OVER (ORDER BY fpr ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) as auc_cumulative
FROM roc_points
ORDER BY threshold DESC
;

-- Calculate final AUC (trapezoidal integration)
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.auc_permuted_h4` AS
WITH roc_sorted AS (
  SELECT 
    fpr,
    tpr,
    LAG(fpr) OVER (ORDER BY fpr) as fpr_prev,
    LAG(tpr) OVER (ORDER BY fpr) as tpr_prev
  FROM `{project_id}.{dataset_id}.roc_curve_permuted_h4`
),

trapezoids AS (
  SELECT
    (fpr - COALESCE(fpr_prev, 0)) * (tpr + COALESCE(tpr_prev, 0)) / 2.0 as area_segment
  FROM roc_sorted
  WHERE fpr_prev IS NOT NULL
)

SELECT
  'PERMUTED_TEST' as test_type,
  SUM(area_segment) as auc_permuted
FROM trapezoids
;

-- Step 4: Comparison with BASELINE
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.comparison_baseline_vs_permuted_h4` AS
WITH baseline_metrics AS (
  SELECT
    'BASELINE' as test_type,
    roc_auc as auc,
    precision,
    recall
  FROM `{project_id}.{dataset_id}.results_model_evaluate`
  WHERE model_name = 'stockout_seasonal_oos_h4'
  LIMIT 1
),

permuted_metrics AS (
  SELECT
    test_type,
    auc_permuted as auc,
    NULL as precision,  -- Not directly comparable
    NULL as recall
  FROM `{project_id}.{dataset_id}.auc_permuted_h4`
)

SELECT
  b.test_type as baseline_test,
  b.auc as baseline_auc,
  b.precision as baseline_precision,
  b.recall as baseline_recall,
  
  p.test_type as permuted_test,
  p.auc as permuted_auc,
  
  -- Performance ratio
  SAFE_DIVIDE(b.auc, p.auc) as auc_ratio,
  
  -- Verdict
  CASE
    WHEN p.auc BETWEEN 0.45 AND 0.55 THEN '✅ PASS: Permuted AUC ≈ 0.50 (random)'
    WHEN p.auc > 0.60 THEN '❌ FAIL: Permuted AUC > 0.60 (label leakage suspected)'
    ELSE '⚠️ WARNING: Permuted AUC < 0.45 (unexpected)'
  END as verdict_permuted,
  
  CASE
    WHEN SAFE_DIVIDE(b.auc, p.auc) > 1.5 THEN '✅ PASS: Baseline 50%+ better than random'
    WHEN SAFE_DIVIDE(b.auc, p.auc) > 1.2 THEN '⚠️ MARGINAL: Baseline only 20%+ better'
    ELSE '❌ FAIL: Baseline not significantly better than permuted'
  END as verdict_ratio

FROM baseline_metrics b
CROSS JOIN permuted_metrics p
;

-- Step 5: Temporal stability check (permuted performance should NOT vary by season)
CREATE OR REPLACE TABLE `{project_id}.{dataset_id}.permuted_by_season_h4` AS
WITH predictions AS (
  SELECT
    p.*,
    f.y_oos_4w_permuted,
    f.is_high_season
  FROM ML.PREDICT(
    MODEL `{project_id}.{dataset_id}.stockout_seasonal_oos_h4`,
    (
      SELECT 
        sku_key,
        target_date,
        lag_sales_4w,
        lag_sales_8w,
        lag_sales_12w,
        sku_sales_volatility,
        hhi_concentration,
        top_product_share,
        is_high_season,
        month,
        week_of_year
      FROM `{project_id}.{dataset_id}.features_permuted_labels_h4`
    )
  ) p
  INNER JOIN `{project_id}.{dataset_id}.features_permuted_labels_h4` f
    ON p.sku_key = f.sku_key 
    AND p.target_date = f.target_date
)

SELECT
  CASE 
    WHEN is_high_season THEN 'HIGH_SEASON'
    ELSE 'REST'
  END as season_type,
  COUNT(*) as n_samples,
  
  -- Precision on permuted labels (should be ~prevalence)
  SAFE_DIVIDE(
    COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w_permuted = 1),
    COUNTIF(predicted_y_oos_4w = 1)
  ) as precision_permuted,
  
  -- Expected precision if random = prevalence
  AVG(CAST(y_oos_4w_permuted AS FLOAT64)) as expected_precision_random,
  
  -- Delta (should be ~0)
  ABS(
    SAFE_DIVIDE(
      COUNTIF(predicted_y_oos_4w = 1 AND y_oos_4w_permuted = 1),
      COUNTIF(predicted_y_oos_4w = 1)
    ) - AVG(CAST(y_oos_4w_permuted AS FLOAT64))
  ) as delta_from_random

FROM predictions
GROUP BY season_type
ORDER BY season_type
;

-- ============================================================================
-- SUMMARY QUERY: Show results
-- ============================================================================
SELECT 
  '=== ANTI-LEAKAGE TEST T2: PERMUTATION TEST ===' as test_name,
  '' as blank,
  'Expected: AUC_permuted ≈ 0.50 (random guessing)' as expectation,
  'Expected: AUC_baseline / AUC_permuted > 1.5' as expectation2
  
UNION ALL

SELECT
  'Results:',
  CONCAT('Permuted AUC = ', CAST(ROUND(permuted_auc, 3) AS STRING)),
  CONCAT('Baseline AUC = ', CAST(ROUND(baseline_auc, 3) AS STRING)),
  CONCAT('Ratio = ', CAST(ROUND(auc_ratio, 2) AS STRING), 'x')
FROM `{project_id}.{dataset_id}.comparison_baseline_vs_permuted_h4`
;

-- Query final results
SELECT * FROM `{project_id}.{dataset_id}.comparison_baseline_vs_permuted_h4`;
SELECT * FROM `{project_id}.{dataset_id}.permuted_by_season_h4`;

