-- =====================================================
-- ANTI-LEAKAGE: LABEL DETERMINISM AUDIT
-- =====================================================
-- Purpose: Quantify how much of y_oos_h4 (silver label) is explained
--          by simple heuristic vs. complex ML model
--
-- Rationale: Silver labels are constructed via deterministic rule:
--            y_oos_h4 = 1 IF (y_sales = 0 AND (lag_1 > 5 OR roll4_mean > 5))
--            This makes labels highly predictable from features (98.9% AUC)
--
-- Audit Questions:
--   1. What AUC does the heuristic rule achieve?
--   2. What incremental value does ML model add over heuristic?
--   3. What % of labels are trivially predictable?
--
-- Expected:
--   - Heuristic AUC: ~85-95% (very strong)
--   - ML model AUC: ~98-99% (nearly perfect)
--   - Incremental value: +3-10pp (ML improves heuristic)
--   - Trivially predictable: ~70-90% of cases
--
-- =====================================================

-- Step 1: Reconstruct silver label heuristic
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.silver_label_heuristic_h4` AS
SELECT
  week_start_date,
  sku_id,
  sku_name,
  split,
  
  -- Ground truth silver label
  y_oos_h4 AS y_true,
  
  -- Reconstructed heuristic prediction
  CASE
    WHEN y_sales_h4 = 0 AND (lag_1 > 5.0 OR roll4_mean > 5.0) THEN 1
    ELSE 0
  END AS y_pred_heuristic,
  
  -- Feature values used in heuristic
  y_sales_h4,
  lag_1,
  roll4_mean,
  
  -- Additional context
  lag_2,
  lag_3,
  roll13_mean,
  n_days_nonzero

FROM `{dataset_ref}.weekly_features_h4`
WHERE split = 'VAL'
;


-- Step 2: Evaluate heuristic classifier
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_heuristic_h4` AS
WITH confusion AS (
  SELECT
    SUM(CASE WHEN y_true = 1 AND y_pred_heuristic = 1 THEN 1 ELSE 0 END) AS tp,
    SUM(CASE WHEN y_true = 0 AND y_pred_heuristic = 1 THEN 1 ELSE 0 END) AS fp,
    SUM(CASE WHEN y_true = 1 AND y_pred_heuristic = 0 THEN 1 ELSE 0 END) AS fn,
    SUM(CASE WHEN y_true = 0 AND y_pred_heuristic = 0 THEN 1 ELSE 0 END) AS tn,
    COUNT(*) AS n_total,
    AVG(CASE WHEN y_true = 1 THEN 1.0 ELSE 0.0 END) AS prevalence
  FROM `{dataset_ref}.silver_label_heuristic_h4`
)
SELECT
  -- Confusion matrix
  tp,
  fp,
  fn,
  tn,
  n_total,
  prevalence,
  
  -- Metrics
  tp / (tp + fn) AS recall,  -- Sensitivity
  tp / (tp + fp) AS precision,
  tn / (tn + fp) AS specificity,
  (tp + tn) / n_total AS accuracy,
  2 * (tp / (tp + fp)) * (tp / (tp + fn)) / 
    ((tp / (tp + fp)) + (tp / (tp + fn))) AS f1_score,
  
  -- Agreement with silver labels
  (tp + tn) / n_total AS label_agreement,
  
  -- Verdict
  CASE
    WHEN (tp + tn) / n_total >= 0.95 THEN '🔴 CRITICAL: >95% agreement (labels too deterministic)'
    WHEN (tp + tn) / n_total >= 0.90 THEN '⚠️ HIGH: 90-95% agreement (labels highly deterministic)'
    WHEN (tp + tn) / n_total >= 0.80 THEN '⚠️ MODERATE: 80-90% agreement (labels somewhat deterministic)'
    ELSE '✅ LOW: <80% agreement (labels have complexity)'
  END AS determinism_verdict

FROM confusion
;


-- Step 3: Compare ML model (m_oos_h4) vs heuristic
-- =====================================================
WITH ml_performance AS (
  SELECT
    roc_auc AS ml_auc,
    precision AS ml_precision,
    recall AS ml_recall,
    f1_score AS ml_f1,
    log_loss AS ml_log_loss
  FROM `{dataset_ref}.eval_baseline_oos_h4`
  LIMIT 1
),
heuristic_performance AS (
  SELECT
    accuracy AS heuristic_accuracy,
    precision AS heuristic_precision,
    recall AS heuristic_recall,
    f1_score AS heuristic_f1,
    label_agreement AS heuristic_agreement
  FROM `{dataset_ref}.eval_heuristic_h4`
)
SELECT
  ml.ml_auc,
  h.heuristic_accuracy,
  h.heuristic_precision,
  ml.ml_precision,
  h.heuristic_recall,
  ml.ml_recall,
  h.heuristic_f1,
  ml.ml_f1,
  h.heuristic_agreement,
  
  -- Incremental value of ML over heuristic
  ml.ml_precision - h.heuristic_precision AS precision_gain,
  ml.ml_recall - h.heuristic_recall AS recall_gain,
  ml.ml_f1 - h.heuristic_f1 AS f1_gain,
  
  -- Interpretation
  CASE
    WHEN h.heuristic_agreement >= 0.95 THEN 
      'CRITICAL: Heuristic explains >95% of labels. ML model adds minimal value beyond simple rule.'
    WHEN h.heuristic_agreement >= 0.90 THEN
      'HIGH: Heuristic explains 90-95% of labels. ML model shows incremental improvement but labels are highly deterministic.'
    WHEN h.heuristic_agreement >= 0.80 THEN
      'MODERATE: Heuristic explains 80-90% of labels. ML model provides meaningful improvement over simple rule.'
    ELSE
      'LOW: Heuristic explains <80% of labels. ML model captures complex patterns beyond simple rule.'
  END AS interpretation

FROM ml_performance ml
CROSS JOIN heuristic_performance h
;


-- Step 4: Breakdown by case difficulty
-- =====================================================
CREATE OR REPLACE TABLE `{dataset_ref}.label_determinism_breakdown_h4` AS
WITH case_types AS (
  SELECT
    -- Case type classification
    CASE
      WHEN y_sales_h4 = 0 AND lag_1 = 0 AND roll4_mean = 0 THEN 'trivial_oos_cold_start'
      WHEN y_sales_h4 = 0 AND lag_1 > 5 AND roll4_mean > 5 THEN 'trivial_oos_active'
      WHEN y_sales_h4 > 10 AND lag_1 > 10 AND roll4_mean > 10 THEN 'trivial_not_oos_high_demand'
      WHEN y_sales_h4 > 0 AND lag_1 > 0 AND roll4_mean > 0 THEN 'ambiguous_moderate_activity'
      WHEN y_sales_h4 = 0 AND (lag_1 > 0 OR roll4_mean > 0) THEN 'ambiguous_dropout'
      ELSE 'other'
    END AS case_type,
    
    y_true,
    y_pred_heuristic

  FROM `{dataset_ref}.silver_label_heuristic_h4`
)
SELECT
  case_type,
  COUNT(*) AS n_cases,
  ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 1) AS pct_cases,
  AVG(CASE WHEN y_true = 1 THEN 1.0 ELSE 0.0 END) AS prevalence,
  AVG(CASE WHEN y_true = y_pred_heuristic THEN 1.0 ELSE 0.0 END) AS heuristic_accuracy,
  
  -- Verdict per case type
  CASE
    WHEN AVG(CASE WHEN y_true = y_pred_heuristic THEN 1.0 ELSE 0.0 END) >= 0.95 THEN '🔴 Trivial'
    WHEN AVG(CASE WHEN y_true = y_pred_heuristic THEN 1.0 ELSE 0.0 END) >= 0.80 THEN '⚠️ Easy'
    ELSE '✅ Complex'
  END AS difficulty_verdict

FROM case_types
GROUP BY case_type
ORDER BY n_cases DESC
;


-- Step 5: Feature importance for label heuristic (manual ranking)
-- =====================================================
SELECT
  'Manual Heuristic Importance' AS analysis_type,
  feature,
  importance_rank,
  usage_in_heuristic
FROM (
  SELECT 'lag_1' AS feature, 1 AS importance_rank, 'Direct: IF lag_1 > 5 THEN OOS' AS usage_in_heuristic
  UNION ALL
  SELECT 'roll4_mean', 2, 'Direct: IF roll4_mean > 5 THEN OOS'
  UNION ALL
  SELECT 'y_sales_h4', 3, 'Direct: IF y_sales_h4 = 0 THEN check lag/roll4'
  UNION ALL
  SELECT 'y_sales', 4, 'Indirect: Determines y_sales_h4 (future sales at h=4)'
  UNION ALL
  SELECT 'iso_week', 5, 'Indirect: Seasonality affects sales patterns'
)
ORDER BY importance_rank
;


-- =====================================================
-- Step 6: Summary verdict
-- =====================================================
SELECT
  'LABEL_DETERMINISM_AUDIT' AS test_id,
  CURRENT_TIMESTAMP() AS execution_timestamp,
  
  -- Key metrics
  h.heuristic_agreement AS heuristic_label_agreement,
  h.heuristic_accuracy,
  h.heuristic_precision,
  h.heuristic_recall,
  h.determinism_verdict,
  
  -- Comparison with ML
  ml.ml_auc AS ml_baseline_auc,
  ml.ml_precision - h.heuristic_precision AS ml_precision_gain,
  ml.ml_recall - h.heuristic_recall AS ml_recall_gain,
  
  -- Key takeaway
  CASE
    WHEN h.heuristic_agreement >= 0.95 THEN
      'CRITICAL FINDING: Silver labels are >95% predictable from simple heuristic (lag_1 > 5 OR roll4_mean > 5). ML model achieves 98.9% AUC primarily by learning this deterministic rule. For paper: Acknowledge silver label limitation and emphasize value is in production deployment, not label complexity.'
    WHEN h.heuristic_agreement >= 0.90 THEN
      'HIGH DETERMINISM: Heuristic explains 90-95% of labels. ML model shows incremental value but performance is largely driven by deterministic rule. For paper: Disclose silver label construction and quantify ML incremental contribution.'
    WHEN h.heuristic_agreement >= 0.80 THEN
      'MODERATE DETERMINISM: Heuristic explains 80-90% of labels. ML model captures additional patterns beyond simple rule. For paper: Standard disclosure of silver label methodology.'
    ELSE
      'LOW DETERMINISM: Heuristic explains <80% of labels. ML model captures complex non-linear patterns. Silver labels have meaningful complexity.'
  END AS key_takeaway,
  
  -- Recommendation for paper
  CONCAT(
    'Paper Methods section should include:\n',
    '1. Silver label construction: y_oos_h4 = 1 IF (y_sales_h4=0 AND (lag_1>5 OR roll4_mean>5))\n',
    '2. Label determinism: ', ROUND(h.heuristic_agreement * 100, 1), '% agreement with heuristic\n',
    '3. ML incremental value: +', ROUND((ml.ml_recall - h.heuristic_recall) * 100, 1), 'pp recall gain\n',
    '4. Justification: Focus is production readiness, not label complexity\n',
    '5. Limitation: Ground truth validation recommended for future work'
  ) AS paper_recommendation

FROM `{dataset_ref}.eval_heuristic_h4` h
CROSS JOIN (
  SELECT
    roc_auc AS ml_auc,
    precision AS ml_precision,
    recall AS ml_recall
  FROM `{dataset_ref}.eval_baseline_oos_h4`
  LIMIT 1
) ml
;
