-- =====================================================
-- CONSOLIDATED BASELINE COMPARISON
-- =====================================================
-- Purpose: Execute all baselines and consolidate results
--          for fair comparison with BOOSTED_TREE baseline
--
-- Baselines:
--   H0: Heuristic (rule-based)
--   H1: Logistic Regression
--   H2: Temporal (Markov/lag-based)
--   H3: Unconstraining (optional)
--   MAIN: BOOSTED_TREE (m_oos_h4)
--
-- Output: Single comparison table for paper
-- =====================================================

-- Step 1: Collect all baseline AUC scores
CREATE OR REPLACE TABLE `{dataset_ref}.baselines_comparison` AS
WITH all_models AS (
  -- H0: Heuristic
  SELECT
    'H0_Heuristic' AS model_name,
    'Rule-based thresholds' AS description,
    roc_auc AS auc,
    precision,
    recall,
    f1_score,
    NULL AS log_loss,
    1 AS sort_order
  FROM `{dataset_ref}.auc_h0_heuristic`
  
  UNION ALL
  
  -- H1: Logistic Regression
  SELECT
    'H1_Logistic' AS model_name,
    'Logistic Regression (BQML)' AS description,
    roc_auc AS auc,
    precision,
    recall,
    f1_score,
    log_loss,
    2 AS sort_order
  FROM `{dataset_ref}.eval_h1_logistic`
  
  UNION ALL
  
  -- H2: Temporal
  SELECT
    'H2_Temporal' AS model_name,
    'Naive temporal persistence' AS description,
    roc_auc AS auc,
    precision,
    recall,
    f1_score,
    NULL AS log_loss,
    3 AS sort_order
  FROM `{dataset_ref}.auc_h2_temporal`
  
  UNION ALL
  
  -- MAIN: BOOSTED_TREE (reference)
  SELECT
    'MAIN_BoostedTree' AS model_name,
    'BOOSTED_TREE_CLASSIFIER (h=4)' AS description,
    roc_auc AS auc,
    precision,
    recall,
    f1_score,
    log_loss,
    0 AS sort_order  -- Show first as reference
  FROM `{dataset_ref}.eval_oos_h4`
  WHERE TRUE
  LIMIT 1
)
SELECT
  model_name,
  description,
  ROUND(auc, 4) AS auc,
  ROUND(precision, 4) AS precision,
  ROUND(recall, 4) AS recall,
  ROUND(f1_score, 4) AS f1_score,
  ROUND(log_loss, 4) AS log_loss,
  
  -- Delta vs main model
  ROUND(auc - (SELECT auc FROM all_models WHERE model_name = 'MAIN_BoostedTree'), 4) AS delta_auc_vs_main,
  
  -- Performance tier
  CASE
    WHEN model_name = 'MAIN_BoostedTree' THEN '🥇 Reference Model'
    WHEN auc >= 0.85 THEN '🥈 Strong Baseline'
    WHEN auc >= 0.70 THEN '🥉 Reasonable Baseline'
    WHEN auc >= 0.60 THEN '⚠️ Weak Baseline'
    ELSE '❌ Poor Baseline'
  END AS verdict
  
FROM all_models
ORDER BY sort_order;

-- Step 2: Precision@K comparison across all models
CREATE OR REPLACE TABLE `{dataset_ref}.precision_at_k_comparison` AS
WITH all_precision_k AS (
  SELECT model_name, k, precision_at_k, lift_at_k
  FROM `{dataset_ref}.precision_at_k_h0`
  
  UNION ALL
  
  SELECT model_name, k, precision_at_k, lift_at_k
  FROM `{dataset_ref}.precision_at_k_h1`
  
  UNION ALL
  
  SELECT model_name, k, precision_at_k, lift_at_k
  FROM `{dataset_ref}.precision_at_k_h2`
  
  UNION ALL
  
  -- Main model (needs to be calculated if not exists)
  SELECT 
    'MAIN_BoostedTree' AS model_name,
    k,
    SAFE_DIVIDE(COUNTIF(y_true = 1), k) AS precision_at_k,
    SAFE_DIVIDE(
      SAFE_DIVIDE(COUNTIF(y_true = 1), k),
      (SELECT AVG(CAST(y_oos_h4 AS FLOAT64)) FROM `{dataset_ref}.score_oos_h4_calibrated` WHERE split = 'VAL')
    ) AS lift_at_k
  FROM (
    SELECT k FROM UNNEST([100, 500, 1000, 5000]) AS k
  ) k_vals
  CROSS JOIN (
    SELECT
      y_oos_h4 AS y_true,
      ROW_NUMBER() OVER (ORDER BY prob_oos_platt DESC) AS rank
    FROM `{dataset_ref}.score_oos_h4_calibrated`
    WHERE split = 'VAL'
  ) ranked
  WHERE ranked.rank <= k_vals.k
  GROUP BY k
)
SELECT
  k,
  MAX(CASE WHEN model_name = 'MAIN_BoostedTree' THEN ROUND(precision_at_k, 4) END) AS main_prec_k,
  MAX(CASE WHEN model_name = 'H0_Heuristic' THEN ROUND(precision_at_k, 4) END) AS h0_prec_k,
  MAX(CASE WHEN model_name = 'H1_Logistic' THEN ROUND(precision_at_k, 4) END) AS h1_prec_k,
  MAX(CASE WHEN model_name = 'H2_Temporal' THEN ROUND(precision_at_k, 4) END) AS h2_prec_k,
  
  MAX(CASE WHEN model_name = 'MAIN_BoostedTree' THEN ROUND(lift_at_k, 2) END) AS main_lift_k,
  MAX(CASE WHEN model_name = 'H0_Heuristic' THEN ROUND(lift_at_k, 2) END) AS h0_lift_k,
  MAX(CASE WHEN model_name = 'H1_Logistic' THEN ROUND(lift_at_k, 2) END) AS h1_lift_k,
  MAX(CASE WHEN model_name = 'H2_Temporal' THEN ROUND(lift_at_k, 2) END) AS h2_lift_k
FROM all_precision_k
GROUP BY k
ORDER BY k;

-- Step 3: Feature importance comparison (Logistic vs BOOSTED_TREE)
CREATE OR REPLACE TABLE `{dataset_ref}.feature_importance_comparison` AS
WITH boosted_tree_importance AS (
  SELECT
    'MAIN_BoostedTree' AS model_name,
    feature_name AS feature,
    importance_gain AS importance_score,
    ROW_NUMBER() OVER (ORDER BY importance_gain DESC) AS rank
  FROM `{dataset_ref}.feature_importance_oos_h4`
  LIMIT 15
),
logistic_importance AS (
  SELECT
    'H1_Logistic' AS model_name,
    feature,
    abs_coefficient AS importance_score,
    ROW_NUMBER() OVER (ORDER BY abs_coefficient DESC) AS rank
  FROM `{dataset_ref}.feature_importance_h1`
  LIMIT 15
)
SELECT
  COALESCE(bt.feature, lr.feature) AS feature,
  bt.importance_score AS boosted_tree_importance,
  bt.rank AS boosted_tree_rank,
  lr.importance_score AS logistic_importance,
  lr.rank AS logistic_rank,
  
  CASE
    WHEN bt.rank IS NOT NULL AND lr.rank IS NOT NULL THEN '✅ Consistent'
    WHEN bt.rank IS NOT NULL THEN '🌳 Tree-only'
    ELSE '📊 Linear-only'
  END AS importance_pattern
  
FROM boosted_tree_importance bt
FULL OUTER JOIN logistic_importance lr
  ON bt.feature = lr.feature
ORDER BY COALESCE(bt.rank, 999), COALESCE(lr.rank, 999);

-- Final output: Summary for paper
SELECT
  '==============================================' AS separator,
  'BASELINE COMPARISON SUMMARY' AS title,
  '==============================================' AS separator2,
  '' AS blank1,
  'AUC Rankings:' AS metric1,
  CONCAT(model_name, ': ', CAST(auc AS STRING), ' (', verdict, ')') AS model_performance
FROM `{dataset_ref}.baselines_comparison`
ORDER BY auc DESC;

-- Output main comparison table
SELECT * FROM `{dataset_ref}.baselines_comparison` ORDER BY auc DESC;
