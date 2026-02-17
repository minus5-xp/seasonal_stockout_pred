-- =====================================================
-- BASELINE H0: HEURISTIC RULE-BASED PREDICTOR
-- =====================================================
-- Purpose: Simple rule-based baseline for OOS prediction
--          Uses intuitive business logic without ML
--
-- Heuristic Logic:
--   1. Recent inactivity (lag_1 very low or zero)
--   2. Rolling average indicates decline (roll4_mean low)
--   3. Few active days in recent period (n_days_nonzero < threshold)
--
-- Score: Weighted combination of rules (0-1 scale)
-- =====================================================

-- Step 1: Generate heuristic scores for validation set
CREATE OR REPLACE TABLE `{dataset_ref}.score_h0_heuristic_val` AS
WITH heuristic_scores AS (
  SELECT
    sku_id,
    week_start_date,
    y_oos_h4 AS y_true,
    split,
    
    -- Individual rule scores (0-1 each)
    CASE 
      WHEN lag_1 = 0 THEN 1.0
      WHEN lag_1 <= 1 THEN 0.8
      WHEN lag_1 <= 3 THEN 0.5
      ELSE 0.0
    END AS score_lag_rule,
    
    CASE
      WHEN roll4_mean = 0 THEN 1.0
      WHEN roll4_mean <= 1 THEN 0.7
      WHEN roll4_mean <= 3 THEN 0.4
      ELSE 0.0
    END AS score_roll4_rule,
    
    CASE
      WHEN n_days_nonzero = 0 THEN 1.0
      WHEN n_days_nonzero <= 2 THEN 0.6
      WHEN n_days_nonzero <= 4 THEN 0.3
      ELSE 0.0
    END AS score_activity_rule,
    
    -- Combine rules with weights (simple average for transparency)
    (
      CASE 
        WHEN lag_1 = 0 THEN 1.0
        WHEN lag_1 <= 1 THEN 0.8
        WHEN lag_1 <= 3 THEN 0.5
        ELSE 0.0
      END +
      CASE
        WHEN roll4_mean = 0 THEN 1.0
        WHEN roll4_mean <= 1 THEN 0.7
        WHEN roll4_mean <= 3 THEN 0.4
        ELSE 0.0
      END +
      CASE
        WHEN n_days_nonzero = 0 THEN 1.0
        WHEN n_days_nonzero <= 2 THEN 0.6
        WHEN n_days_nonzero <= 4 THEN 0.3
        ELSE 0.0
      END
    ) / 3.0 AS score_h0_heuristic,
    
    -- Features for analysis
    lag_1,
    roll4_mean,
    n_days_nonzero
    
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE split = 'VAL'
)
SELECT * FROM heuristic_scores;

-- Step 2: Evaluate heuristic baseline (AUC + confusion matrix)
CREATE OR REPLACE TABLE `{dataset_ref}.eval_h0_heuristic` AS
WITH predictions AS (
  SELECT
    y_true,
    score_h0_heuristic AS predicted_score,
    CASE WHEN score_h0_heuristic >= 0.5 THEN 1 ELSE 0 END AS predicted_label
  FROM `{dataset_ref}.score_h0_heuristic_val`
),
confusion AS (
  SELECT
    COUNT(*) AS total_samples,
    SUM(CASE WHEN y_true = 1 THEN 1 ELSE 0 END) AS actual_positives,
    SUM(CASE WHEN y_true = 0 THEN 1 ELSE 0 END) AS actual_negatives,
    SUM(CASE WHEN predicted_label = 1 AND y_true = 1 THEN 1 ELSE 0 END) AS true_positives,
    SUM(CASE WHEN predicted_label = 1 AND y_true = 0 THEN 1 ELSE 0 END) AS false_positives,
    SUM(CASE WHEN predicted_label = 0 AND y_true = 0 THEN 1 ELSE 0 END) AS true_negatives,
    SUM(CASE WHEN predicted_label = 0 AND y_true = 1 THEN 1 ELSE 0 END) AS false_negatives
  FROM predictions
),
metrics AS (
  SELECT
    total_samples,
    actual_positives,
    actual_negatives,
    true_positives,
    false_positives,
    true_negatives,
    false_negatives,
    
    -- Standard metrics
    SAFE_DIVIDE(true_positives, true_positives + false_positives) AS precision,
    SAFE_DIVIDE(true_positives, actual_positives) AS recall,
    SAFE_DIVIDE(true_positives + true_negatives, total_samples) AS accuracy,
    
    -- F1 score
    SAFE_DIVIDE(
      2 * true_positives,
      2 * true_positives + false_positives + false_negatives
    ) AS f1_score
  FROM confusion
)
SELECT * FROM metrics;

-- Step 3: Calculate AUC using ROC curve approximation
CREATE OR REPLACE TABLE `{dataset_ref}.auc_h0_heuristic` AS
WITH ranked_predictions AS (
  SELECT
    y_true,
    score_h0_heuristic,
    ROW_NUMBER() OVER (ORDER BY score_h0_heuristic DESC, y_true DESC) AS rank_order
  FROM `{dataset_ref}.score_h0_heuristic_val`
),
cumulative_stats AS (
  SELECT
    rank_order,
    y_true,
    score_h0_heuristic,
    SUM(y_true) OVER (ORDER BY rank_order) AS cum_tp,
    SUM(1 - y_true) OVER (ORDER BY rank_order) AS cum_fp
  FROM ranked_predictions
),
distinct_thresholds AS (
  SELECT DISTINCT
    score_h0_heuristic AS threshold,
    MAX(cum_tp) AS tp_at_threshold,
    MAX(cum_fp) AS fp_at_threshold
  FROM cumulative_stats
  GROUP BY score_h0_heuristic
),
roc_points AS (
  SELECT
    threshold,
    tp_at_threshold,
    fp_at_threshold,
    MAX(tp_at_threshold) OVER () AS total_positives,
    MAX(fp_at_threshold) OVER () AS total_negatives,
    SAFE_DIVIDE(tp_at_threshold, MAX(tp_at_threshold) OVER ()) AS tpr,
    SAFE_DIVIDE(fp_at_threshold, MAX(fp_at_threshold) OVER ()) AS fpr
  FROM distinct_thresholds
),
auc_calculation AS (
  SELECT
    threshold,
    tpr,
    fpr,
    LAG(tpr, 1, 0) OVER (ORDER BY fpr) AS prev_tpr,
    tpr - LAG(tpr, 1, 0) OVER (ORDER BY fpr) AS delta_tpr,
    fpr - LAG(fpr, 1, 0) OVER (ORDER BY fpr) AS delta_fpr
  FROM roc_points
),
auc_final AS (
  SELECT
    SUM(
      (prev_tpr + tpr) / 2 * delta_fpr
    ) AS roc_auc
  FROM auc_calculation
  WHERE delta_fpr > 0
)
SELECT 
  'H0_Heuristic' AS model_name,
  roc_auc,
  (SELECT precision FROM `{dataset_ref}.eval_h0_heuristic`) AS precision,
  (SELECT recall FROM `{dataset_ref}.eval_h0_heuristic`) AS recall,
  (SELECT f1_score FROM `{dataset_ref}.eval_h0_heuristic`) AS f1_score,
  (SELECT accuracy FROM `{dataset_ref}.eval_h0_heuristic`) AS accuracy
FROM auc_final;

-- Step 4: Precision@K and Lift@K (top 100, 500, 1000)
CREATE OR REPLACE TABLE `{dataset_ref}.precision_at_k_h0` AS
WITH ranked_preds AS (
  SELECT
    y_true,
    score_h0_heuristic,
    ROW_NUMBER() OVER (ORDER BY score_h0_heuristic DESC) AS rank
  FROM `{dataset_ref}.score_h0_heuristic_val`
),
k_values AS (
  SELECT k FROM UNNEST([100, 500, 1000, 5000]) AS k
),
precision_at_k AS (
  SELECT
    k,
    COUNTIF(rp.y_true = 1) AS true_positives_at_k,
    k AS predictions_at_k,
    SAFE_DIVIDE(COUNTIF(rp.y_true = 1), k) AS precision_at_k,
    
    -- Baseline precision (if we picked K random)
    (SELECT AVG(y_true) FROM `{dataset_ref}.score_h0_heuristic_val`) AS baseline_precision,
    
    -- Lift
    SAFE_DIVIDE(
      SAFE_DIVIDE(COUNTIF(rp.y_true = 1), k),
      (SELECT AVG(y_true) FROM `{dataset_ref}.score_h0_heuristic_val`)
    ) AS lift_at_k
  FROM k_values kv
  JOIN ranked_preds rp ON rp.rank <= kv.k
  GROUP BY k
)
SELECT
  'H0_Heuristic' AS model_name,
  k,
  precision_at_k,
  lift_at_k,
  baseline_precision
FROM precision_at_k
ORDER BY k;

-- Final summary output
SELECT 
  'H0_Heuristic' AS baseline_name,
  'Rule-based: lag_1 + roll4_mean + n_days_nonzero thresholds' AS description,
  roc_auc,
  precision,
  recall,
  f1_score,
  CASE
    WHEN roc_auc >= 0.70 THEN '✅ Reasonable baseline'
    WHEN roc_auc >= 0.60 THEN '⚠️ Weak baseline'
    ELSE '❌ Poor baseline'
  END AS verdict
FROM `{dataset_ref}.auc_h0_heuristic`;
