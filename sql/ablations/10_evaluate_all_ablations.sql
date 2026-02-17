-- ============================================================================
-- HITO 4: Evaluate All Ablation Models with Segmentation
-- ============================================================================
-- Purpose: Score all 5 models (A0-A4) on validation set and compute:
--   1. Overall metrics: AUC, PR-AUC, Precision@100, Lift@100
--   2. HIGH_SEASON segmentation: Performance in tourism peaks vs rest
--   3. HHI quartile segmentation: Performance by concentration level
--
-- Models evaluated:
--   A0: m_oos_h4 (FULL, 14 features)
--   A1: m_ablation_a1_no_whales (11 features)
--   A2: m_ablation_a2_no_seasonal (12 features)
--   A3: m_ablation_a3_season_only (2 features)
--   A4: m_ablation_a4_whales_only (3 features)
--
-- Outputs:
--   - ablation_scores_all (unified scores table)
--   - ablation_metrics_overall (AUC, PR-AUC for each model)
--   - ablation_metrics_by_season (HIGH vs REST performance)
--   - ablation_metrics_by_hhi_quartile (Q1-Q4 performance)
--   - ablation_precision_at_k (Prec@100, Lift@100 for all models)
-- ============================================================================

-- Step 1: Score all models on validation set
CREATE OR REPLACE TABLE `{dataset_ref}.ablation_scores_all` AS
WITH base_features AS (
  SELECT 
    sku_id,
    week_start_date,
    y_oos_h4 AS label,
    is_high_season,
    hhi_base_roll13,
    -- Create HHI quartiles for segmentation
    NTILE(4) OVER (ORDER BY hhi_base_roll13) AS hhi_quartile,
    -- All features needed for prediction
    lag_1, lag_2, lag_4,
    roll4_mean, roll13_mean, roll13_std,
    iso_week, is_high_season AS season_flag,
    hhi_base_roll13 AS hhi, 
    n_customers_roll13, 
    top_customer_share,
    amplitude, cv_roll13, n_days_nonzero
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE split = 'VAL'
    AND ever_sold_flag = 1
    AND y_oos_h4 IS NOT NULL
),
scores_a0 AS (
  SELECT 
    b.sku_id,
    b.week_start_date,
    b.label,
    b.is_high_season,
    b.hhi_quartile,
    'A0_FULL' AS model_id,
    p.predicted_y_oos_h4_probs[OFFSET(1)] AS score
  FROM base_features b
  INNER JOIN ML.PREDICT(
    MODEL `{dataset_ref}.m_oos_h4`,
    TABLE base_features
  ) p USING(sku_id, week_start_date)
),
scores_a1 AS (
  SELECT 
    b.sku_id,
    b.week_start_date,
    b.label,
    b.is_high_season,
    b.hhi_quartile,
    'A1_NO_WHALES' AS model_id,
    p.predicted_y_oos_h4_probs[OFFSET(1)] AS score
  FROM base_features b
  INNER JOIN ML.PREDICT(
    MODEL `{dataset_ref}.m_ablation_a1_no_whales`,
    TABLE base_features
  ) p USING(sku_id, week_start_date)
),
scores_a2 AS (
  SELECT 
    b.sku_id,
    b.week_start_date,
    b.label,
    b.is_high_season,
    b.hhi_quartile,
    'A2_NO_SEASONAL' AS model_id,
    p.predicted_y_oos_h4_probs[OFFSET(1)] AS score
  FROM base_features b
  INNER JOIN ML.PREDICT(
    MODEL `{dataset_ref}.m_ablation_a2_no_seasonal`,
    TABLE base_features
  ) p USING(sku_id, week_start_date)
),
scores_a3 AS (
  SELECT 
    b.sku_id,
    b.week_start_date,
    b.label,
    b.is_high_season,
    b.hhi_quartile,
    'A3_SEASON_ONLY' AS model_id,
    p.predicted_y_oos_h4_probs[OFFSET(1)] AS score
  FROM base_features b
  INNER JOIN ML.PREDICT(
    MODEL `{dataset_ref}.m_ablation_a3_season_only`,
    TABLE base_features
  ) p USING(sku_id, week_start_date)
),
scores_a4 AS (
  SELECT 
    b.sku_id,
    b.week_start_date,
    b.label,
    b.is_high_season,
    b.hhi_quartile,
    'A4_WHALES_ONLY' AS model_id,
    p.predicted_y_oos_h4_probs[OFFSET(1)] AS score
  FROM base_features b
  INNER JOIN ML.PREDICT(
    MODEL `{dataset_ref}.m_ablation_a4_whales_only`,
    TABLE base_features
  ) p USING(sku_id, week_start_date)
)
SELECT * FROM scores_a0
UNION ALL SELECT * FROM scores_a1
UNION ALL SELECT * FROM scores_a2
UNION ALL SELECT * FROM scores_a3
UNION ALL SELECT * FROM scores_a4;


-- Step 2: Compute overall AUC and PR-AUC for each model
CREATE OR REPLACE TABLE `{dataset_ref}.ablation_metrics_overall` AS
WITH roc_metrics AS (
  SELECT
    model_id,
    COUNT(*) AS n_val_samples,
    AVG(label) AS prevalence,
    AVG(score) AS mean_score
  FROM `{dataset_ref}.ablation_scores_all`
  GROUP BY model_id
),
auc_from_ml AS (
  -- Use ML.EVALUATE for quick AUC computation
  SELECT 
    'A0_FULL' AS model_id,
    roc_auc AS auc_roc
  FROM ML.EVALUATE(
    MODEL `{dataset_ref}.m_oos_h4`,
    (SELECT * FROM `{dataset_ref}.weekly_features_h4` 
     WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
  )
  UNION ALL
  SELECT 
    'A1_NO_WHALES' AS model_id,
    roc_auc
  FROM ML.EVALUATE(
    MODEL `{dataset_ref}.m_ablation_a1_no_whales`,
    (SELECT * FROM `{dataset_ref}.weekly_features_h4` 
     WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
  )
  UNION ALL
  SELECT 
    'A2_NO_SEASONAL' AS model_id,
    roc_auc
  FROM ML.EVALUATE(
    MODEL `{dataset_ref}.m_ablation_a2_no_seasonal`,
    (SELECT * FROM `{dataset_ref}.weekly_features_h4` 
     WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
  )
  UNION ALL
  SELECT 
    'A3_SEASON_ONLY' AS model_id,
    roc_auc
  FROM ML.EVALUATE(
    MODEL `{dataset_ref}.m_ablation_a3_season_only`,
    (SELECT * FROM `{dataset_ref}.weekly_features_h4` 
     WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
  )
  UNION ALL
  SELECT 
    'A4_WHALES_ONLY' AS model_id,
    roc_auc
  FROM ML.EVALUATE(
    MODEL `{dataset_ref}.m_ablation_a4_whales_only`,
    (SELECT * FROM `{dataset_ref}.weekly_features_h4` 
     WHERE split = 'VAL' AND ever_sold_flag = 1 AND y_oos_h4 IS NOT NULL)
  )
)
SELECT 
  r.model_id,
  r.n_val_samples,
  ROUND(r.prevalence, 6) AS prevalence,
  ROUND(r.mean_score, 6) AS mean_score,
  ROUND(a.auc_roc, 4) AS auc_roc,
  -- Compute delta vs A0 (FULL model)
  ROUND(
    a.auc_roc - (SELECT auc_roc FROM auc_from_ml WHERE model_id = 'A0_FULL'), 
    4
  ) AS delta_auc_vs_a0,
  CASE
    WHEN ABS(a.auc_roc - (SELECT auc_roc FROM auc_from_ml WHERE model_id = 'A0_FULL')) < 0.01 THEN 'NEGLIGIBLE (<1pp)'
    WHEN a.auc_roc < (SELECT auc_roc FROM auc_from_ml WHERE model_id = 'A0_FULL') - 0.02 THEN 'SIGNIFICANT (>2pp loss)'
    ELSE 'MODERATE (1-2pp loss)'
  END AS impact_assessment
FROM roc_metrics r
JOIN auc_from_ml a ON r.model_id = a.model_id
ORDER BY auc_roc DESC;


-- Step 3: Segmented AUC by HIGH_SEASON (tourism peaks vs rest)
CREATE OR REPLACE TABLE `{dataset_ref}.ablation_metrics_by_season` AS
WITH season_segments AS (
  SELECT 
    model_id,
    CASE WHEN is_high_season = 1 THEN 'HIGH_SEASON' ELSE 'REST' END AS segment,
    COUNT(*) AS n_samples,
    AVG(label) AS prevalence
  FROM `{dataset_ref}.ablation_scores_all`
  GROUP BY model_id, segment
)
SELECT 
  s.model_id,
  s.segment,
  s.n_samples,
  ROUND(s.prevalence, 4) AS prevalence,
  -- TODO: Manual AUC computation or use ML.EVALUATE with filtered data
  NULL AS auc_roc,  -- Placeholder for manual computation
  NULL AS delta_vs_a0
FROM season_segments s
ORDER BY model_id, segment;


-- Step 4: Segmented AUC by HHI quartile (concentration level)
CREATE OR REPLACE TABLE `{dataset_ref}.ablation_metrics_by_hhi_quartile` AS
WITH hhi_segments AS (
  SELECT 
    model_id,
    hhi_quartile,
    COUNT(*) AS n_samples,
    AVG(label) AS prevalence
  FROM `{dataset_ref}.ablation_scores_all`
  GROUP BY model_id, hhi_quartile
)
SELECT 
  h.model_id,
  h.hhi_quartile,
  h.n_samples,
  ROUND(h.prevalence, 4) AS prevalence,
  -- TODO: Manual AUC computation
  NULL AS auc_roc,
  NULL AS delta_vs_a0
FROM hhi_segments h
ORDER BY model_id, hhi_quartile;


-- Step 5: Precision@100 and Lift@100 for all models
CREATE OR REPLACE TABLE `{dataset_ref}.ablation_precision_at_100` AS
WITH score_ranks AS (
  SELECT 
    model_id,
    label,
    score,
    ROW_NUMBER() OVER (PARTITION BY model_id ORDER BY score DESC, label DESC) AS rank_num
  FROM `{dataset_ref}.ablation_scores_all`
),
top_100 AS (
  SELECT 
    model_id,
    SUM(label) AS tp_at_100,
    COUNT(*) AS predictions_at_100
  FROM score_ranks
  WHERE rank_num <= 100
  GROUP BY model_id
),
metadata AS (
  SELECT 
    model_id,
    SUM(label) AS total_positives,
    AVG(label) AS prevalence
  FROM `{dataset_ref}.ablation_scores_all`
  GROUP BY model_id
)
SELECT 
  t.model_id,
  t.tp_at_100,
  t.predictions_at_100,
  m.total_positives,
  ROUND(t.tp_at_100 / t.predictions_at_100, 4) AS precision_at_100,
  ROUND(t.tp_at_100 / m.total_positives, 4) AS recall_at_100,
  ROUND((t.tp_at_100 / t.predictions_at_100) / m.prevalence, 2) AS lift_at_100,
  -- Delta vs A0
  ROUND(
    (t.tp_at_100 / t.predictions_at_100) - 
    (SELECT tp_at_100 / predictions_at_100 FROM top_100 WHERE model_id = 'A0_FULL'),
    4
  ) AS delta_prec100_vs_a0
FROM top_100 t
JOIN metadata m ON t.model_id = m.model_id
ORDER BY precision_at_100 DESC;


-- ============================================================================
-- Execution summary
-- ============================================================================
-- Tables created:
--   1. ablation_scores_all (all 5 models scored on VAL set)
--   2. ablation_metrics_overall (AUC, delta vs A0)
--   3. ablation_metrics_by_season (HIGH vs REST performance)
--   4. ablation_metrics_by_hhi_quartile (Q1-Q4 performance)
--   5. ablation_precision_at_100 (Prec@100, Lift@100)
--
-- Next steps:
--   - Complete manual AUC computation for segments (if needed)
--   - Export results to CSV for report generation
--   - Generate visualizations (AUC by segment bar charts)
-- ============================================================================
