-- =====================================================
-- BASELINE H2: TEMPORAL MARKOV/LAG-BASED
-- =====================================================
-- Purpose: Naive temporal baseline using previous OOS state
--          Mimics simple Markov assumption: P(OOS_t | OOS_t-1)
--
-- Logic:
--   - If SKU was OOS in previous period â†’ likely OOS now
--   - Score based on lag_1 sales (lower sales = higher OOS prob)
--   - Enhanced with simple moving average trend
--
-- This is a "temporal persistence" baseline
-- Expected AUC: ~60-75% (weak temporal correlation)
-- =====================================================

-- Step 1: Create temporal features (lag OOS status if available)
-- Note: We don't have y_oos_h4 for t-1 directly, so we use lag_1 as proxy
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.features_temporal_h2` AS
WITH lag_features AS (
  SELECT
    sku_id,
    week_start_date,
    y_oos_h4,
    split,
    
    -- Proxy for previous OOS state (lag_1 = 0 suggests previous OOS)
    CASE WHEN lag_1 = 0 THEN 1 ELSE 0 END AS prev_oos_proxy,
    
    -- Temporal score based on recent sales trajectory
    CASE
      -- Strong OOS signal: no sales recently
      WHEN lag_1 = 0 AND roll4_mean = 0 THEN 0.95
      WHEN lag_1 = 0 AND roll4_mean <= 1 THEN 0.85
      
      -- Moderate OOS signal: declining sales
      WHEN lag_1 <= 1 AND roll4_mean <= 2 THEN 0.70
      WHEN lag_1 <= 2 AND roll4_mean <= 3 THEN 0.55
      
      -- Weak OOS signal: some activity but low
      WHEN lag_1 <= 3 THEN 0.40
      WHEN roll4_mean <= 3 THEN 0.30
      
      -- No OOS signal: healthy sales
      ELSE 0.10
    END AS score_h2_temporal,
    
    -- Features
    lag_1,
    lag_2,
    lag_4,
    roll4_mean,
    roll13_mean,
    n_days_nonzero
    
  FROM `thequantitativeledger.cruzber_models_eu.weekly_features_h4`
  WHERE split IN ('TRAIN', 'VAL')
)
SELECT * FROM lag_features;

-- Step 2: Evaluate temporal baseline on validation set
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.score_h2_temporal_val` AS
SELECT
  sku_id,
  week_start_date,
  y_oos_h4 AS y_true,
  score_h2_temporal,
  CASE WHEN score_h2_temporal >= 0.5 THEN 1 ELSE 0 END AS predicted_label,
  prev_oos_proxy,
  split
FROM `thequantitativeledger.cruzber_models_eu.features_temporal_h2`
WHERE split = 'VAL';

-- Step 3: Calculate metrics
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.eval_h2_temporal` AS
WITH predictions AS (
  SELECT
    y_true,
    score_h2_temporal AS predicted_score,
    predicted_label
  FROM `thequantitativeledger.cruzber_models_eu.score_h2_temporal_val`
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
)
SELECT
  total_samples,
  actual_positives,
  actual_negatives,
  true_positives,
  false_positives,
  true_negatives,
  false_negatives,
  SAFE_DIVIDE(true_positives, true_positives + false_positives) AS precision,
  SAFE_DIVIDE(true_positives, actual_positives) AS recall,
  SAFE_DIVIDE(true_positives + true_negatives, total_samples) AS accuracy,
  SAFE_DIVIDE(
    2 * true_positives,
    2 * true_positives + false_positives + false_negatives
  ) AS f1_score
FROM confusion;

-- Step 4: Calculate AUC
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.auc_h2_temporal` AS
WITH ranked_predictions AS (
  SELECT
    y_true,
    score_h2_temporal,
    ROW_NUMBER() OVER (ORDER BY score_h2_temporal DESC, y_true DESC) AS rank_order
  FROM `thequantitativeledger.cruzber_models_eu.score_h2_temporal_val`
),
cumulative_stats AS (
  SELECT
    rank_order,
    y_true,
    score_h2_temporal,
    SUM(y_true) OVER (ORDER BY rank_order) AS cum_tp,
    SUM(1 - y_true) OVER (ORDER BY rank_order) AS cum_fp
  FROM ranked_predictions
),
distinct_thresholds AS (
  SELECT DISTINCT
    score_h2_temporal AS threshold,
    MAX(cum_tp) AS tp_at_threshold,
    MAX(cum_fp) AS fp_at_threshold
  FROM cumulative_stats
  GROUP BY score_h2_temporal
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
  'H2_Temporal' AS model_name,
  roc_auc,
  (SELECT precision FROM `thequantitativeledger.cruzber_models_eu.eval_h2_temporal`) AS precision,
  (SELECT recall FROM `thequantitativeledger.cruzber_models_eu.eval_h2_temporal`) AS recall,
  (SELECT f1_score FROM `thequantitativeledger.cruzber_models_eu.eval_h2_temporal`) AS f1_score,
  (SELECT accuracy FROM `thequantitativeledger.cruzber_models_eu.eval_h2_temporal`) AS accuracy
FROM auc_final;

-- Step 5: Precision@K and Lift@K
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.precision_at_k_h2` AS
WITH ranked_preds AS (
  SELECT
    y_true,
    score_h2_temporal,
    ROW_NUMBER() OVER (ORDER BY score_h2_temporal DESC) AS rank
  FROM `thequantitativeledger.cruzber_models_eu.score_h2_temporal_val`
),
k_values AS (
  SELECT k FROM UNNEST([100, 500, 1000, 5000]) AS k
),
precision_at_k AS (
  SELECT
    k,
    COUNTIF(rp.y_true = 1) AS true_positives_at_k,
    SAFE_DIVIDE(COUNTIF(rp.y_true = 1), k) AS precision_at_k,
    (SELECT AVG(y_true) FROM `thequantitativeledger.cruzber_models_eu.score_h2_temporal_val`) AS baseline_precision,
    SAFE_DIVIDE(
      SAFE_DIVIDE(COUNTIF(rp.y_true = 1), k),
      (SELECT AVG(y_true) FROM `thequantitativeledger.cruzber_models_eu.score_h2_temporal_val`)
    ) AS lift_at_k
  FROM k_values kv
  JOIN ranked_preds rp ON rp.rank <= kv.k
  GROUP BY k
)
SELECT
  'H2_Temporal' AS model_name,
  k,
  precision_at_k,
  lift_at_k,
  baseline_precision
FROM precision_at_k
ORDER BY k;

-- Final summary output
SELECT 
  'H2_Temporal' AS baseline_name,
  'Naive temporal: lag-based OOS persistence' AS description,
  roc_auc,
  precision,
  recall,
  f1_score,
  CASE
    WHEN roc_auc >= 0.75 THEN 'âœ… Strong temporal baseline'
    WHEN roc_auc >= 0.65 THEN 'âœ… Reasonable temporal baseline'
    WHEN roc_auc >= 0.55 THEN 'âš ï¸ Weak temporal baseline'
    ELSE 'âŒ Poor baseline'
  END AS verdict
FROM `thequantitativeledger.cruzber_models_eu.auc_h2_temporal`;

