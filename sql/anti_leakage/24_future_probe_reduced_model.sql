-- =====================================================
-- ANTI-LEAKAGE TEST T1: FUTURE FEATURE PROBE - REDUCED MODEL
-- =====================================================
-- Purpose: Test model's ability to detect deliberate temporal leakage
--          using WEAK BASELINE (few features) to leave room for improvement
--
-- Rationale: Full model saturated at 98.9% AUC (no room to improve)
--            Reduced baseline should be weak (~60-70% AUC)
--            Leaky features should dramatically improve performance
--
-- Expected: Reduced baseline AUC ~60-70% (weak features only)
--           Reduced leaky AUC ~90-95% (strong improvement with future info)
--           Delta: +20-30pp (proves detection capacity)
--
-- Reduced Baseline: Only iso_week + is_high_season (calendar info)
-- Leaky Features: Add leak_next_week_sales (should dominate)
--
-- =====================================================

-- Step 1: Train REDUCED BASELINE (weak features only)
-- =====================================================
CREATE OR REPLACE MODEL `{dataset_ref}.m_reduced_baseline_h4`
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
  
  -- Temporal features ONLY (weak predictors)
  iso_week,
  is_high_season,
  is_jan,
  is_feb
  
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'VAL'
;


-- =====================================================
-- Step 2: Create leaky features (VAL split only)
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.features_reduced_leaky_h4` AS
SELECT
  f.*,
  
  -- Deliberate leakage: future sales (1 week ahead)
  LEAD(y_sales, 1) OVER (
    PARTITION BY sku_id
    ORDER BY week_start_date
  ) AS leak_next_week_sales,
  
  -- Current week sales (should NOT be in features)
  y_sales AS leak_current_sales

FROM `{dataset_ref}.weekly_features_h4` f
WHERE f.split = 'VAL'
;


-- =====================================================
-- Step 3: Train REDUCED LEAKY model (weak features + leakage)
-- =====================================================
CREATE OR REPLACE MODEL `{dataset_ref}.m_reduced_leaky_h4`
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
  
  -- Temporal features (weak)
  iso_week,
  is_high_season,
  is_jan,
  is_feb,
  
  -- 🔴 LEAKY FEATURES (should dominate importance)
  leak_next_week_sales,
  leak_current_sales

FROM `{dataset_ref}.features_reduced_leaky_h4`
WHERE leak_next_week_sales IS NOT NULL  -- Exclude last week with no future
;


-- =====================================================
-- Step 4: Evaluate REDUCED BASELINE
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_reduced_baseline_h4` AS
SELECT
  *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_reduced_baseline_h4`,
  (SELECT * FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'VAL')
)
;


-- =====================================================
-- Step 5: Evaluate REDUCED LEAKY
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_reduced_leaky_h4` AS
SELECT
  *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_reduced_leaky_h4`,
  (SELECT * FROM `{dataset_ref}.features_reduced_leaky_h4`
   WHERE leak_next_week_sales IS NOT NULL)
)
;


-- =====================================================
-- Step 6: Feature importance for reduced leaky model
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.feature_importance_reduced_leaky_h4` AS
SELECT
  feature,
  importance,
  CASE
    WHEN feature LIKE 'leak_%' THEN '🔴 LEAKY'
    ELSE '✅ CLEAN'
  END AS feature_type
FROM ML.FEATURE_IMPORTANCE(MODEL `{dataset_ref}.m_reduced_leaky_h4`)
ORDER BY importance DESC
;


-- =====================================================
-- Step 7: Compare reduced baseline vs reduced leaky
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.comparison_reduced_models_h4` AS
SELECT
  'reduced_baseline' AS model_type,
  roc_auc,
  log_loss,
  precision,
  recall,
  f1_score
FROM `{dataset_ref}.eval_reduced_baseline_h4`

UNION ALL

SELECT
  'reduced_leaky' AS model_type,
  roc_auc,
  log_loss,
  precision,
  recall,
  f1_score
FROM `{dataset_ref}.eval_reduced_leaky_h4`
;


-- =====================================================
-- Step 8: Final comparison (wide format)
-- =====================================================
WITH baseline AS (
  SELECT
    roc_auc AS baseline_auc,
    precision AS baseline_precision,
    recall AS baseline_recall
  FROM `{dataset_ref}.eval_reduced_baseline_h4`
),
leaky AS (
  SELECT
    roc_auc AS leaky_auc,
    precision AS leaky_precision,
    recall AS leaky_recall
  FROM `{dataset_ref}.eval_reduced_leaky_h4`
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
    WHEN l.leaky_auc - b.baseline_auc >= 0.20 THEN '✅ PASS: Strong sensitivity (+20pp)'
    WHEN l.leaky_auc - b.baseline_auc >= 0.10 THEN '⚠️ MARGINAL: Moderate sensitivity (+10-20pp)'
    ELSE '❌ FAIL: Weak sensitivity (<10pp)'
  END AS verdict,
  
  -- Interpretation
  CONCAT(
    'Reduced baseline (calendar only): ', ROUND(b.baseline_auc * 100, 1), '% AUC\n',
    'Reduced leaky (calendar + future): ', ROUND(l.leaky_auc * 100, 1), '% AUC\n',
    'Improvement: +', ROUND((l.leaky_auc - b.baseline_auc) * 100, 1), 'pp\n',
    'Interpretation: Model CAN exploit future info when baseline is weak.'
  ) AS interpretation
  
FROM baseline b
CROSS JOIN leaky l
;


-- =====================================================
-- Step 9: Verify leaky feature dominance
-- =====================================================
WITH top_features AS (
  SELECT
    feature,
    importance,
    feature_type,
    ROW_NUMBER() OVER (ORDER BY importance DESC) AS rank
  FROM `{dataset_ref}.feature_importance_reduced_leaky_h4`
)
SELECT
  rank,
  feature,
  importance,
  feature_type,
  CASE
    WHEN rank <= 2 AND feature_type = '🔴 LEAKY' THEN '✅ Expected: Leaky features dominate'
    WHEN rank <= 2 THEN '⚠️ Unexpected: Clean features dominate'
    ELSE NULL
  END AS dominance_verdict
FROM top_features
WHERE rank <= 5
ORDER BY rank
;


-- =====================================================
-- Step 10: Summary verdict
-- =====================================================
SELECT
  'T1_REDUCED_MODEL' AS test_id,
  CURRENT_TIMESTAMP() AS execution_timestamp,
  baseline_auc,
  leaky_auc,
  auc_improvement,
  verdict,
  
  -- Key takeaway
  CASE
    WHEN leaky_auc - baseline_auc >= 0.20 THEN 
      'Model demonstrates strong capacity to detect and exploit temporal leakage when baseline is weak. This validates the detection mechanism in T1.'
    WHEN leaky_auc - baseline_auc >= 0.10 THEN
      'Model shows moderate sensitivity to future information. Detection capacity exists but may not be as strong as expected.'
    ELSE
      'CRITICAL: Model does not improve significantly with future info even when baseline is weak. This suggests either (1) leaky features are not predictive, or (2) model cannot learn from them.'
  END AS key_takeaway

FROM (
  SELECT
    baseline_auc,
    leaky_auc,
    auc_improvement,
    verdict
  FROM `{dataset_ref}.comparison_reduced_models_h4`
  WHERE model_type IN ('reduced_baseline', 'reduced_leaky')
  PIVOT (
    MAX(roc_auc) AS auc
    FOR model_type IN ('reduced_baseline', 'reduced_leaky')
  )
)
CROSS JOIN (
  SELECT
    leaky_auc - baseline_auc AS auc_improvement,
    verdict
  FROM (
    SELECT
      b.baseline_auc,
      l.leaky_auc,
      l.leaky_auc - b.baseline_auc AS auc_improvement,
      CASE
        WHEN l.leaky_auc - b.baseline_auc >= 0.20 THEN '✅ PASS'
        WHEN l.leaky_auc - b.baseline_auc >= 0.10 THEN '⚠️ MARGINAL'
        ELSE '❌ FAIL'
      END AS verdict
    FROM `{dataset_ref}.eval_reduced_baseline_h4` b
    CROSS JOIN `{dataset_ref}.eval_reduced_leaky_h4` l
  )
)
;
