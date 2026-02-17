-- =====================================================
-- BASELINE H1: LOGISTIC REGRESSION (BQML)
-- =====================================================
-- Purpose: Linear baseline using same feature set as BOOSTED_TREE
--          but with logistic regression (no tree interactions)
--
-- Fair comparison:
--   - Same train/val split
--   - Same core features (no future info)
--   - Same evaluation metrics (AUC, precision@K, lift@K)
--
-- Expected: AUC ~70-85% (decent linear baseline, below tree 98.9%)
-- =====================================================

-- Step 1: Train logistic regression model
CREATE OR REPLACE MODEL `{dataset_ref}.m_baseline_h1_logistic`
OPTIONS (
  model_type = 'LOGISTIC_REG',
  input_label_cols = ['y_oos_h4'],
  auto_class_weights = TRUE,
  max_iterations = 50,
  l2_reg = 0.01,  -- Light regularization
  data_split_method = 'NO_SPLIT',  -- We control split manually
  enable_global_explain = TRUE
) AS
SELECT
  -- Target
  y_oos_h4,
  
  -- Temporal features
  iso_week,
  is_high_season,
  month,
  
  -- Lag features (recent history)
  lag_1,
  lag_2,
  lag_4,
  
  -- Rolling statistics (trend)
  roll4_mean,
  roll13_mean,
  roll13_std,
  
  -- Volatility
  cv_roll13,
  amplitude,
  
  -- Activity patterns
  n_days_active,
  n_days_nonzero,
  
  -- Customer diversity (concentration risk)
  n_customers_roll13,
  hhi_base_roll13,
  top_customer_share
  
FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'TRAIN'  -- Train on same data as BOOSTED_TREE
;

-- Step 2: Generate predictions on validation set
CREATE OR REPLACE TABLE `{dataset_ref}.score_h1_logistic_val` AS
SELECT
  sku_id,
  week_start_date,
  y_oos_h4 AS y_true,
  predicted_y_oos_h4 AS predicted_label,
  predicted_y_oos_h4_probs[OFFSET(1)].prob AS score_h1_logistic,
  split
FROM ML.PREDICT(
  MODEL `{dataset_ref}.m_baseline_h1_logistic`,
  (SELECT * FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'VAL')
);

-- Step 3: Evaluate model (standard BQML metrics)
CREATE OR REPLACE TABLE `{dataset_ref}.eval_h1_logistic` AS
SELECT 
  'H1_Logistic' AS model_name,
  *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_baseline_h1_logistic`,
  (SELECT * FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'VAL')
);

-- Step 4: Precision@K and Lift@K
CREATE OR REPLACE TABLE `{dataset_ref}.precision_at_k_h1` AS
WITH ranked_preds AS (
  SELECT
    y_true,
    score_h1_logistic,
    ROW_NUMBER() OVER (ORDER BY score_h1_logistic DESC) AS rank
  FROM `{dataset_ref}.score_h1_logistic_val`
),
k_values AS (
  SELECT k FROM UNNEST([100, 500, 1000, 5000]) AS k
),
precision_at_k AS (
  SELECT
    k,
    COUNTIF(rp.y_true = 1) AS true_positives_at_k,
    SAFE_DIVIDE(COUNTIF(rp.y_true = 1), k) AS precision_at_k,
    (SELECT AVG(y_true) FROM `{dataset_ref}.score_h1_logistic_val`) AS baseline_precision,
    SAFE_DIVIDE(
      SAFE_DIVIDE(COUNTIF(rp.y_true = 1), k),
      (SELECT AVG(y_true) FROM `{dataset_ref}.score_h1_logistic_val`)
    ) AS lift_at_k
  FROM k_values kv
  JOIN ranked_preds rp ON rp.rank <= kv.k
  GROUP BY k
)
SELECT
  'H1_Logistic' AS model_name,
  k,
  precision_at_k,
  lift_at_k,
  baseline_precision
FROM precision_at_k
ORDER BY k;

-- Step 5: Feature importance (global explanation)
CREATE OR REPLACE TABLE `{dataset_ref}.feature_importance_h1` AS
SELECT
  'H1_Logistic' AS model_name,
  feature,
  category AS feature_category,
  weight AS coefficient,
  ABS(weight) AS abs_coefficient
FROM ML.WEIGHTS(MODEL `{dataset_ref}.m_baseline_h1_logistic`)
ORDER BY abs_coefficient DESC
LIMIT 20;

-- Final summary output
SELECT
  'H1_Logistic' AS baseline_name,
  'Logistic Regression (same features as BOOSTED_TREE)' AS description,
  roc_auc,
  precision,
  recall,
  f1_score,
  log_loss,
  CASE
    WHEN roc_auc >= 0.85 THEN '✅ Strong linear baseline'
    WHEN roc_auc >= 0.70 THEN '✅ Reasonable linear baseline'
    WHEN roc_auc >= 0.60 THEN '⚠️ Weak linear baseline'
    ELSE '❌ Poor baseline'
  END AS verdict
FROM `{dataset_ref}.eval_h1_logistic`;
