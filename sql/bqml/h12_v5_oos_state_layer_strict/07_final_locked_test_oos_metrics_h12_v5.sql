-- ============================================================================
-- PHASE 7: LOCKED_TEST OOS METRICS (h12_v5) - ONE-TIME USE - COMPREHENSIVE
-- ============================================================================
-- PURPOSE:
--   Compute comprehensive OOS detection metrics on LOCKED_TEST holdout split.
--   This is the TRUE GENERALIZATION TEST (unseen until this moment).
--
--   METRICS COMPUTED:
--   1. Threshold metrics (oos_flag): precision, recall, F1, lift, FPR, expected_lost_sales
--   2. Top-K ranking metrics: precision@K, recall@K, lift@K for K=50,100,200,500,1000
--   3. Weekly ranking metrics: top10, top20, top50 per decision_week
--
-- INPUTS:
--   - oos_final_scores_h12_v5_strict (LOCKED_TEST only)
--
-- OUTPUTS:
--   - oos_locked_test_metrics_h12_v5_strict (comprehensive metrics)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_locked_test_metrics_h12_v5_strict` AS
WITH

locked_test_data AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
),

-- ──────────────────────────────────────────────────────────────────────────
-- 1. THRESHOLD METRICS (oos_flag) - GLOBAL
-- ──────────────────────────────────────────────────────────────────────────
threshold_global AS (
  SELECT
    'threshold_metrics' AS metric_family,
    'GLOBAL' AS segment_type,
    'ALL' AS segment_value,
    COUNT(*) AS n_obs,
    SUM(oos_flag) AS n_flagged_oos,
    SUM(CAST(stockout_event_12w AS INT64)) AS n_true_oos_events,
    
    -- Precision (how many flagged are actually OOS)
    SAFE_DIVIDE(
      SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END),
      NULLIF(SUM(oos_flag), 0)
    ) AS precision_at_top_n,
    
    -- Recall (how many true OOS were flagged)
    SAFE_DIVIDE(
      SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END),
      NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0)
    ) AS recall_at_top_n,
    
    -- F1 score
    SAFE_DIVIDE(
      2.0 * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) 
          * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0)),
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) 
        + SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0))
    ) AS f1_score,
    
    -- Lift (precision / base_rate)
    SAFE_DIVIDE(
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)),
      SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*))
    ) AS lift,
    
    -- False positive rate
    SAFE_DIVIDE(
      SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 0.0 THEN 1 ELSE 0 END),
      NULLIF(SUM(CASE WHEN stockout_event_12w = 0.0 THEN 1 ELSE 0 END), 0)
    ) AS false_positive_rate,
    
    -- Expected lost sales captured
    SAFE_DIVIDE(
      SUM(CASE WHEN oos_flag = 1 THEN expected_lost_sales_if_oos ELSE 0 END),
      NULLIF(SUM(expected_lost_sales_if_oos), 0)
    ) AS pct_expected_lost_sales_captured
    
  FROM locked_test_data
),

-- ──────────────────────────────────────────────────────────────────────────
-- 1b. THRESHOLD METRICS - BY SEGMENT (season_group, sku_season_state)
-- ──────────────────────────────────────────────────────────────────────────
threshold_by_season_group AS (
  SELECT
    'threshold_metrics' AS metric_family,
    'season_group' AS segment_type,
    season_group AS segment_value,
    COUNT(*) AS n_obs,
    SUM(oos_flag) AS n_flagged_oos,
    SUM(CAST(stockout_event_12w AS INT64)) AS n_true_oos_events,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) AS precision_at_top_n,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0)) AS recall_at_top_n,
    SAFE_DIVIDE(
      2.0 * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) 
          * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0)),
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) 
        + SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0))
    ) AS f1_score,
    SAFE_DIVIDE(SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)), SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*))) AS lift,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 0.0 THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN stockout_event_12w = 0.0 THEN 1 ELSE 0 END), 0)) AS false_positive_rate,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 THEN expected_lost_sales_if_oos ELSE 0 END), NULLIF(SUM(expected_lost_sales_if_oos), 0)) AS pct_expected_lost_sales_captured
  FROM locked_test_data
  GROUP BY season_group
),

threshold_by_sku_season_state AS (
  SELECT
    'threshold_metrics' AS metric_family,
    'sku_season_state' AS segment_type,
    sku_season_state AS segment_value,
    COUNT(*) AS n_obs,
    SUM(oos_flag) AS n_flagged_oos,
    SUM(CAST(stockout_event_12w AS INT64)) AS n_true_oos_events,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) AS precision_at_top_n,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0)) AS recall_at_top_n,
    SAFE_DIVIDE(
      2.0 * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) 
          * SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0)),
      SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)) 
        + SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(CAST(stockout_event_12w AS INT64)), 0))
    ) AS f1_score,
    SAFE_DIVIDE(SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 1.0 THEN 1 ELSE 0 END), NULLIF(SUM(oos_flag), 0)), SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*))) AS lift,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 AND stockout_event_12w = 0.0 THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN stockout_event_12w = 0.0 THEN 1 ELSE 0 END), 0)) AS false_positive_rate,
    SAFE_DIVIDE(SUM(CASE WHEN oos_flag = 1 THEN expected_lost_sales_if_oos ELSE 0 END), NULLIF(SUM(expected_lost_sales_if_oos), 0)) AS pct_expected_lost_sales_captured
  FROM locked_test_data
  GROUP BY sku_season_state
),

-- ──────────────────────────────────────────────────────────────────────────
-- 2. TOP-K RANKING METRICS (precision@K, recall@K, lift@K)
-- ──────────────────────────────────────────────────────────────────────────
ranked_data AS (
  SELECT
    *,
    ROW_NUMBER() OVER (ORDER BY p_suspected_oos DESC, audit_priority_score DESC) AS global_rank
  FROM locked_test_data
),

topk_metrics AS (
  SELECT
    'topk_ranking' AS metric_family,
    'GLOBAL' AS segment_type,
    CAST(k AS STRING) AS segment_value,
    k AS n_obs,
    SUM(CAST(stockout_event_12w AS INT64)) AS n_flagged_oos,
    total_oos AS n_true_oos_events,
    
    SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), k) AS precision_at_top_n,
    SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), total_oos) AS recall_at_top_n,
    SAFE_DIVIDE(SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), k), base_rate) AS f1_score,
    SAFE_DIVIDE(SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), k), base_rate) AS lift,
    0.0 AS false_positive_rate,
    SAFE_DIVIDE(SUM(expected_lost_sales_if_oos), total_expected_sales) AS pct_expected_lost_sales_captured
    
  FROM ranked_data
  CROSS JOIN UNNEST([50, 100, 200, 500, 1000]) AS k
  CROSS JOIN (
    SELECT 
      SUM(CAST(stockout_event_12w AS INT64)) AS total_oos,
      SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*)) AS base_rate,
      SUM(expected_lost_sales_if_oos) AS total_expected_sales
    FROM locked_test_data
  )
  WHERE global_rank <= k
  GROUP BY k, total_oos, base_rate, total_expected_sales
),

-- ──────────────────────────────────────────────────────────────────────────
-- 3. WEEKLY RANKING METRICS (top10/top20/top50 per decision_week)
-- ──────────────────────────────────────────────────────────────────────────
weekly_ranked_data AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY p_suspected_oos DESC, audit_priority_score DESC) AS weekly_rank
  FROM locked_test_data
),

weekly_topk_metrics AS (
  SELECT
    'weekly_topk' AS metric_family,
    'top' || CAST(k AS STRING) || '_per_week' AS segment_type,
    'GLOBAL' AS segment_value,
    COUNT(*) AS n_obs,
    SUM(CAST(stockout_event_12w AS INT64)) AS n_flagged_oos,
    total_oos AS n_true_oos_events,
    
    SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*)) AS precision_at_top_n,
    SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), total_oos) AS recall_at_top_n,
    SAFE_DIVIDE(
      2.0 * SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*)) 
          * SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), total_oos),
      SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*)) 
        + SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), total_oos)
    ) AS f1_score,
    SAFE_DIVIDE(SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*)), base_rate) AS lift,
    0.0 AS false_positive_rate,
    SAFE_DIVIDE(SUM(expected_lost_sales_if_oos), total_expected_sales) AS pct_expected_lost_sales_captured
    
  FROM weekly_ranked_data
  CROSS JOIN UNNEST([10, 20, 50]) AS k
  CROSS JOIN (
    SELECT 
      SUM(CAST(stockout_event_12w AS INT64)) AS total_oos,
      SAFE_DIVIDE(SUM(CAST(stockout_event_12w AS INT64)), COUNT(*)) AS base_rate,
      SUM(expected_lost_sales_if_oos) AS total_expected_sales
    FROM locked_test_data
  )
  WHERE weekly_rank <= k
  GROUP BY k, total_oos, base_rate, total_expected_sales
),

-- ──────────────────────────────────────────────────────────────────────────
-- COMBINE ALL METRICS
-- ──────────────────────────────────────────────────────────────────────────
all_metrics AS (
  SELECT * FROM threshold_global
  UNION ALL
  SELECT * FROM threshold_by_season_group
  UNION ALL
  SELECT * FROM threshold_by_sku_season_state
  UNION ALL
  SELECT * FROM topk_metrics
  UNION ALL
  SELECT * FROM weekly_topk_metrics
)

SELECT * FROM all_metrics
ORDER BY 
  CASE metric_family 
    WHEN 'threshold_metrics' THEN 1 
    WHEN 'topk_ranking' THEN 2 
    WHEN 'weekly_topk' THEN 3 
  END,
  segment_type,
  segment_value;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 7 Complete: LOCKED_TEST Comprehensive Metrics Computed' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Metrics summary' AS check_name,
  metric_family,
  COUNT(*) AS n_metric_rows,
  ROUND(AVG(precision_at_top_n), 3) AS avg_precision,
  ROUND(AVG(recall_at_top_n), 3) AS avg_recall,
  ROUND(AVG(lift), 2) AS avg_lift
FROM `thequantitativeledger.cruzber_models_eu.oos_locked_test_metrics_h12_v5_strict`
GROUP BY metric_family
ORDER BY metric_family;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 8 will create v3/v4/v5 comparison table' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
