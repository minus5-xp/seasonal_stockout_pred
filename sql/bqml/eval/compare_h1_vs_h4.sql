-- ============================================================================
-- H1 vs H4 COMPARISON EVALUATION SCRIPT
-- ============================================================================
-- Purpose: Compare performance of 1-week vs 4-week ahead forecasting models
--
-- Prerequisites: Both h1 and h4 pipelines must have been executed successfully
-- Required tables:
--   - {PROJECT_ID}.{BQ_DATASET}.eval_classifier_h1
--   - {PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4
--   - {PROJECT_ID}.{BQ_DATASET}.eval_regressor_h1
--   - {PROJECT_ID}.{BQ_DATASET}.eval_regressor_h4
--   - {PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h1_pooled
--   - {PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled
--   - {PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h1_conditional
--   - {PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional
--
-- Outputs:
--   - compare_run_summary_h1_h4: Single consolidated comparison table
-- ============================================================================

-- ----------------------------------------------------------------------------
-- SECTION 1: CLASSIFIER COMPARISON (OOS PREDICTION)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.compare_classifier_h1_h4` AS
WITH h1_metrics AS (
  SELECT
    'h1' AS horizon,
    roc_auc,
    precision,
    recall,
    f1_score,
    log_loss,
    accuracy
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h1`
),
h4_metrics AS (
  SELECT
    'h4' AS horizon,
    roc_auc,
    precision,
    recall,
    f1_score,
    log_loss,
    accuracy
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_classifier_h4`
),
combined AS (
  SELECT * FROM h1_metrics
  UNION ALL
  SELECT * FROM h4_metrics
)
SELECT
  h1.horizon AS horizon_h1,
  h4.horizon AS horizon_h4,
  
  -- ROC AUC comparison (higher is better)
  h1.roc_auc AS roc_auc_h1,
  h4.roc_auc AS roc_auc_h4,
  h1.roc_auc - h4.roc_auc AS delta_roc_auc,
  CASE 
    WHEN h1.roc_auc > h4.roc_auc THEN 'h1 BETTER'
    WHEN h4.roc_auc > h1.roc_auc THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_roc_auc,
  
  -- Precision comparison (higher is better)
  h1.precision AS precision_h1,
  h4.precision AS precision_h4,
  h1.precision - h4.precision AS delta_precision,
  CASE 
    WHEN h1.precision > h4.precision THEN 'h1 BETTER'
    WHEN h4.precision > h1.precision THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_precision,
  
  -- Recall comparison (higher is better)
  h1.recall AS recall_h1,
  h4.recall AS recall_h4,
  h1.recall - h4.recall AS delta_recall,
  CASE 
    WHEN h1.recall > h4.recall THEN 'h1 BETTER'
    WHEN h4.recall > h1.recall THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_recall,
  
  -- F1 Score comparison (higher is better)
  h1.f1_score AS f1_h1,
  h4.f1_score AS f1_h4,
  h1.f1_score - h4.f1_score AS delta_f1,
  CASE 
    WHEN h1.f1_score > h4.f1_score THEN 'h1 BETTER'
    WHEN h4.f1_score > h1.f1_score THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_f1,
  
  -- Log Loss comparison (lower is better)
  h1.log_loss AS log_loss_h1,
  h4.log_loss AS log_loss_h4,
  h1.log_loss - h4.log_loss AS delta_log_loss,
  CASE 
    WHEN h1.log_loss < h4.log_loss THEN 'h1 BETTER'
    WHEN h4.log_loss < h1.log_loss THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_log_loss
  
FROM h1_metrics h1
CROSS JOIN h4_metrics h4;

-- ----------------------------------------------------------------------------
-- SECTION 2: REGRESSOR COMPARISON (DEMAND PREDICTION)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.compare_regressor_h1_h4` AS
WITH h1_metrics AS (
  SELECT
    'h1' AS horizon,
    mean_absolute_error,
    mean_squared_error,
    mean_squared_log_error,
    median_absolute_error,
    r2_score,
    explained_variance
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_regressor_h1`
),
h4_metrics AS (
  SELECT
    'h4' AS horizon,
    mean_absolute_error,
    mean_squared_error,
    mean_squared_log_error,
    median_absolute_error,
    r2_score,
    explained_variance
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_regressor_h4`
)
SELECT
  h1.horizon AS horizon_h1,
  h4.horizon AS horizon_h4,
  
  -- MAE comparison (lower is better)
  h1.mean_absolute_error AS mae_h1,
  h4.mean_absolute_error AS mae_h4,
  h1.mean_absolute_error - h4.mean_absolute_error AS delta_mae,
  CASE 
    WHEN h1.mean_absolute_error < h4.mean_absolute_error THEN 'h1 BETTER'
    WHEN h4.mean_absolute_error < h1.mean_absolute_error THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_mae,
  
  -- MSE comparison (lower is better)
  h1.mean_squared_error AS mse_h1,
  h4.mean_squared_error AS mse_h4,
  h1.mean_squared_error - h4.mean_squared_error AS delta_mse,
  CASE 
    WHEN h1.mean_squared_error < h4.mean_squared_error THEN 'h1 BETTER'
    WHEN h4.mean_squared_error < h1.mean_squared_error THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_mse,
  
  -- R² comparison (higher is better)
  h1.r2_score AS r2_h1,
  h4.r2_score AS r2_h4,
  h1.r2_score - h4.r2_score AS delta_r2,
  CASE 
    WHEN h1.r2_score > h4.r2_score THEN 'h1 BETTER'
    WHEN h4.r2_score > h1.r2_score THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_r2,
  
  -- Median Absolute Error comparison (lower is better)
  h1.median_absolute_error AS median_ae_h1,
  h4.median_absolute_error AS median_ae_h4,
  h1.median_absolute_error - h4.median_absolute_error AS delta_median_ae,
  CASE 
    WHEN h1.median_absolute_error < h4.median_absolute_error THEN 'h1 BETTER'
    WHEN h4.median_absolute_error < h1.median_absolute_error THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_median_ae
  
FROM h1_metrics h1
CROSS JOIN h4_metrics h4;

-- ----------------------------------------------------------------------------
-- SECTION 3: ALERTS COMPARISON (TOP-100 PRECISION/RECALL/LIFT)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.compare_alerts_h1_h4` AS
WITH h1_alerts AS (
  SELECT
    'h1' AS horizon,
    season_group,
    precision_at_100_model AS precision_100,
    recall_at_100_model AS recall_100,
    lift_at_100_model AS lift_100,
    n_true_positives_in_top100_model AS n_tp,
    n_total_stockouts_model AS n_total_stockouts
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h1_pooled`
),
h4_alerts AS (
  SELECT
    'h4' AS horizon,
    season_group,
    precision_at_100_model AS precision_100,
    recall_at_100_model AS recall_100,
    lift_at_100_model AS lift_100,
    n_true_positives_in_top100_model AS n_tp,
    n_total_stockouts_model AS n_total_stockouts
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_alerts_top100_h4_pooled`
)
SELECT
  h1.season_group,
  
  -- Precision@100 comparison (higher is better)
  h1.precision_100 AS precision_100_h1,
  h4.precision_100 AS precision_100_h4,
  h1.precision_100 - h4.precision_100 AS delta_precision_100,
  CASE 
    WHEN h1.precision_100 > h4.precision_100 THEN 'h1 BETTER'
    WHEN h4.precision_100 > h1.precision_100 THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_precision_100,
  
  -- Recall@100 comparison (higher is better)
  h1.recall_100 AS recall_100_h1,
  h4.recall_100 AS recall_100_h4,
  h1.recall_100 - h4.recall_100 AS delta_recall_100,
  CASE 
    WHEN h1.recall_100 > h4.recall_100 THEN 'h1 BETTER'
    WHEN h4.recall_100 > h1.recall_100 THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_recall_100,
  
  -- Lift@100 comparison (higher is better)
  h1.lift_100 AS lift_100_h1,
  h4.lift_100 AS lift_100_h4,
  h1.lift_100 - h4.lift_100 AS delta_lift_100,
  CASE 
    WHEN h1.lift_100 > h4.lift_100 THEN 'h1 BETTER'
    WHEN h4.lift_100 > h1.lift_100 THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_lift_100,
  
  -- True positives count
  h1.n_tp AS n_tp_h1,
  h4.n_tp AS n_tp_h4,
  h1.n_total_stockouts AS n_total_stockouts_h1,
  h4.n_total_stockouts AS n_total_stockouts_h4
  
FROM h1_alerts h1
JOIN h4_alerts h4
  USING (season_group)
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- SECTION 4: QUANTILE COVERAGE COMPARISON (CONDITIONAL ON ACTIVE DEMAND)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.compare_coverage_h1_h4` AS
WITH h1_coverage AS (
  SELECT
    'h1' AS horizon,
    season_group,
    viol_rate_p90,
    viol_rate_p95,
    deviation_p90,
    deviation_p95,
    n_obs_total
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h1_conditional`
),
h4_coverage AS (
  SELECT
    'h4' AS horizon,
    season_group,
    viol_rate_p90,
    viol_rate_p95,
    deviation_p90,
    deviation_p95,
    n_obs_total
  FROM `{PROJECT_ID}.{BQ_DATASET}.eval_coverage_summary_h4_conditional`
)
SELECT
  h1.season_group,
  
  -- P90 violation rate comparison (closer to 0.10 is better)
  h1.viol_rate_p90 AS viol_rate_p90_h1,
  h4.viol_rate_p90 AS viol_rate_p90_h4,
  h1.deviation_p90 AS dev_p90_h1,
  h4.deviation_p90 AS dev_p90_h4,
  ABS(h1.deviation_p90) AS abs_dev_p90_h1,
  ABS(h4.deviation_p90) AS abs_dev_p90_h4,
  CASE 
    WHEN ABS(h1.deviation_p90) < ABS(h4.deviation_p90) THEN 'h1 BETTER'
    WHEN ABS(h4.deviation_p90) < ABS(h1.deviation_p90) THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_p90_calibration,
  
  -- P95 violation rate comparison (closer to 0.05 is better)
  h1.viol_rate_p95 AS viol_rate_p95_h1,
  h4.viol_rate_p95 AS viol_rate_p95_h4,
  h1.deviation_p95 AS dev_p95_h1,
  h4.deviation_p95 AS dev_p95_h4,
  ABS(h1.deviation_p95) AS abs_dev_p95_h1,
  ABS(h4.deviation_p95) AS abs_dev_p95_h4,
  CASE 
    WHEN ABS(h1.deviation_p95) < ABS(h4.deviation_p95) THEN 'h1 BETTER'
    WHEN ABS(h4.deviation_p95) < ABS(h1.deviation_p95) THEN 'h4 BETTER'
    ELSE 'TIE'
  END AS winner_p95_calibration,
  
  -- Observation counts
  h1.n_obs_total AS n_obs_h1,
  h4.n_obs_total AS n_obs_h4
  
FROM h1_coverage h1
JOIN h4_coverage h4
  USING (season_group)
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- SECTION 5: CONSOLIDATED SUMMARY (ONE TABLE TO RULE THEM ALL)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.compare_run_summary_h1_h4` AS
WITH classifier_summary AS (
  SELECT
    'OOS_CLASSIFIER' AS metric_category,
    CONCAT('ROC_AUC: h1=', ROUND(roc_auc_h1, 4), ' vs h4=', ROUND(roc_auc_h4, 4), ' (Δ=', ROUND(delta_roc_auc, 4), ')') AS metric_detail,
    winner_roc_auc AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_classifier_h1_h4`
  UNION ALL
  SELECT
    'OOS_CLASSIFIER' AS metric_category,
    CONCAT('F1: h1=', ROUND(f1_h1, 4), ' vs h4=', ROUND(f1_h4, 4), ' (Δ=', ROUND(delta_f1, 4), ')') AS metric_detail,
    winner_f1 AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_classifier_h1_h4`
  UNION ALL
  SELECT
    'OOS_CLASSIFIER' AS metric_category,
    CONCAT('LOG_LOSS: h1=', ROUND(log_loss_h1, 4), ' vs h4=', ROUND(log_loss_h4, 4), ' (Δ=', ROUND(delta_log_loss, 4), ')') AS metric_detail,
    winner_log_loss AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_classifier_h1_h4`
),
regressor_summary AS (
  SELECT
    'DEMAND_REGRESSOR' AS metric_category,
    CONCAT('MAE: h1=', ROUND(mae_h1, 2), ' vs h4=', ROUND(mae_h4, 2), ' (Δ=', ROUND(delta_mae, 2), ')') AS metric_detail,
    winner_mae AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_regressor_h1_h4`
  UNION ALL
  SELECT
    'DEMAND_REGRESSOR' AS metric_category,
    CONCAT('R²: h1=', ROUND(r2_h1, 4), ' vs h4=', ROUND(r2_h4, 4), ' (Δ=', ROUND(delta_r2, 4), ')') AS metric_detail,
    winner_r2 AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_regressor_h1_h4`
),
alerts_summary AS (
  SELECT
    CONCAT('ALERTS_', season_group) AS metric_category,
    CONCAT('PRECISION@100: h1=', ROUND(precision_100_h1, 4), ' vs h4=', ROUND(precision_100_h4, 4), ' (Δ=', ROUND(delta_precision_100, 4), ')') AS metric_detail,
    winner_precision_100 AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_alerts_h1_h4`
  UNION ALL
  SELECT
    CONCAT('ALERTS_', season_group) AS metric_category,
    CONCAT('RECALL@100: h1=', ROUND(recall_100_h1, 4), ' vs h4=', ROUND(recall_100_h4, 4), ' (Δ=', ROUND(delta_recall_100, 4), ')') AS metric_detail,
    winner_recall_100 AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_alerts_h1_h4`
  UNION ALL
  SELECT
    CONCAT('ALERTS_', season_group) AS metric_category,
    CONCAT('LIFT@100: h1=', ROUND(lift_100_h1, 2), ' vs h4=', ROUND(lift_100_h4, 2), ' (Δ=', ROUND(delta_lift_100, 2), ')') AS metric_detail,
    winner_lift_100 AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_alerts_h1_h4`
),
coverage_summary AS (
  SELECT
    CONCAT('COVERAGE_', season_group) AS metric_category,
    CONCAT('P90_CALIBRATION: h1_dev=', ROUND(dev_p90_h1, 4), ' vs h4_dev=', ROUND(dev_p90_h4, 4), ' (abs: h1=', ROUND(abs_dev_p90_h1, 4), ' vs h4=', ROUND(abs_dev_p90_h4, 4), ')') AS metric_detail,
    winner_p90_calibration AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_coverage_h1_h4`
  UNION ALL
  SELECT
    CONCAT('COVERAGE_', season_group) AS metric_category,
    CONCAT('P95_CALIBRATION: h1_dev=', ROUND(dev_p95_h1, 4), ' vs h4_dev=', ROUND(dev_p95_h4, 4), ' (abs: h1=', ROUND(abs_dev_p95_h1, 4), ' vs h4=', ROUND(abs_dev_p95_h4, 4), ')') AS metric_detail,
    winner_p95_calibration AS winner
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_coverage_h1_h4`
)
SELECT
  metric_category,
  metric_detail,
  winner,
  CASE 
    WHEN winner = 'h1 BETTER' THEN '🟢 h1'
    WHEN winner = 'h4 BETTER' THEN '🟢 h4'
    ELSE '⚪ TIE'
  END AS visual_winner
FROM (
  SELECT * FROM classifier_summary
  UNION ALL
  SELECT * FROM regressor_summary
  UNION ALL
  SELECT * FROM alerts_summary
  UNION ALL
  SELECT * FROM coverage_summary
)
ORDER BY metric_category, metric_detail;

-- ----------------------------------------------------------------------------
-- SECTION 6: WINNER SCORECARD
-- ----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.compare_scorecard_h1_h4` AS
WITH winner_counts AS (
  SELECT
    winner,
    COUNT(*) AS n_metrics_won
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_run_summary_h1_h4`
  GROUP BY winner
)
SELECT
  winner,
  n_metrics_won,
  ROUND(100.0 * n_metrics_won / SUM(n_metrics_won) OVER (), 2) AS pct_metrics_won,
  CASE 
    WHEN winner = 'h1 BETTER' THEN '🏆 h1 WINS'
    WHEN winner = 'h4 BETTER' THEN '🏆 h4 WINS'
    ELSE '⚖️ TIES'
  END AS verdict
FROM winner_counts
ORDER BY n_metrics_won DESC;

-- ----------------------------------------------------------------------------
-- QUERY RESULTS FOR MANUAL INSPECTION
-- ----------------------------------------------------------------------------

SELECT '============================================================' AS sep;
SELECT 'H1 vs H4 COMPARISON — EXECUTION COMPLETE' AS title;
SELECT '============================================================' AS sep;

SELECT 'OVERALL SCORECARD:' AS section;
SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.compare_scorecard_h1_h4`;

SELECT '------------------------------------------------------------' AS sep;
SELECT 'DETAILED METRIC COMPARISON:' AS section;
SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.compare_run_summary_h1_h4`;

SELECT '------------------------------------------------------------' AS sep;
SELECT 'CLASSIFIER METRICS:' AS section;
SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.compare_classifier_h1_h4`;

SELECT '------------------------------------------------------------' AS sep;
SELECT 'REGRESSOR METRICS:' AS section;
SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.compare_regressor_h1_h4`;

SELECT '------------------------------------------------------------' AS sep;
SELECT 'ALERTS METRICS (BY SEASON):' AS section;
SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.compare_alerts_h1_h4`;

SELECT '------------------------------------------------------------' AS sep;
SELECT 'QUANTILE COVERAGE (BY SEASON):' AS section;
SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.compare_coverage_h1_h4`;

SELECT '============================================================' AS sep;
SELECT 'RECOMMENDATION:' AS section;

WITH scores AS (
  SELECT
    SUM(CASE WHEN winner = 'h1 BETTER' THEN 1 ELSE 0 END) AS h1_wins,
    SUM(CASE WHEN winner = 'h4 BETTER' THEN 1 ELSE 0 END) AS h4_wins,
    SUM(CASE WHEN winner = 'TIE' THEN 1 ELSE 0 END) AS ties
  FROM `{PROJECT_ID}.{BQ_DATASET}.compare_run_summary_h1_h4`
)
SELECT
  CASE 
    WHEN h1_wins > h4_wins THEN '✅ Use h1 for near-term operational decisions (better short-horizon accuracy)'
    WHEN h4_wins > h1_wins THEN '✅ Use h4 for strategic planning (better long-horizon foresight)'
    ELSE '⚠️ Performance is comparable. Consider using BOTH: h1 for urgency, h4 for planning.'
  END AS recommended_horizon_strategy
FROM scores;

SELECT '============================================================' AS sep;
