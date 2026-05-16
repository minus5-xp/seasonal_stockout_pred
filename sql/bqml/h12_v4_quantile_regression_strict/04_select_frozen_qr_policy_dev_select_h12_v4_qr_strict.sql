-- ============================================================================
-- STEP 04: SELECT FROZEN QR POLICY (h=12 v4_quantile_regression_strict)
-- ============================================================================
-- PURPOSE:
--   Evaluate all three QR candidate models on DEV_SELECT split and freeze
--   the winning configuration based on composite loss function.
--
-- ANTI-LEAKAGE:
--   - Evaluation ONLY on DEV_SELECT
--   - LOCKED_TEST is never used for selection
--   - Frozen decision applied to LOCKED_TEST in phase 05
--
-- LOSS FUNCTION (composite, multi-objective):
--   loss = 2.0 * ABS(viol_p80 - 0.20)
--        + 3.0 * ABS(viol_p90 - 0.10)
--        + 2.0 * ABS(viol_p95 - 0.05)
--        + 1.0 * WMAPE_y_positive
--        + 0.5 * zero_overforecast_rate
--        + penalty_non_monotonic
--        + penalty_highseason_degradation
--
-- PENALTIES:
--   - penalty_non_monotonic = 10 * (pct_q90_lt_q80 + pct_q95_lt_q90)
--   - penalty_highseason_degradation = MAX(0, HIGH_SEASON_WMAPE_ypos - 0.700) * 5.0
--
-- OUTPUT TABLES:
--   1. qr_candidate_evaluation_dev_select_h12_v4_qr_strict
--      - Metrics for all 3 candidates on DEV_SELECT
--   2. frozen_qr_policy_h12_v4_qr_strict
--      - Winning model_type for final use
-- ============================================================================

-- ── STEP 1: Compute metrics for all candidates on DEV_SELECT ───────────────

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.qr_candidate_evaluation_dev_select_h12_v4_qr_strict` AS
WITH

base_predictions AS (
  SELECT
    sku_id,
    decision_week,
    eval_split_v3,
    y_true_12w,
    season_group,
    sku_season_state,
    
    -- QR_DIRECT
    q50_qr_direct,
    q80_qr_direct,
    q90_qr_direct,
    q95_qr_direct,
    
    -- QR_RESIDUAL
    q50_qr_residual,
    q80_qr_residual,
    q90_qr_residual,
    q95_qr_residual,
    
    -- QR_ZERO_AWARE
    q50_qr_zero_aware,
    q80_qr_zero_aware,
    q90_qr_zero_aware,
    q95_qr_zero_aware
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.qr_predictions_h12_v4_qr_strict`
  WHERE eval_split_v3 = 'DEV_SELECT'
),

-- ── Reshape to model_type dimension ─────────────────────────────────────────
unpivoted AS (
  SELECT sku_id, decision_week, y_true_12w, season_group, sku_season_state,
         'QR_DIRECT' AS model_type,
         q50_qr_direct AS q50, q80_qr_direct AS q80, q90_qr_direct AS q90, q95_qr_direct AS q95
  FROM base_predictions
  
  UNION ALL
  
  SELECT sku_id, decision_week, y_true_12w, season_group, sku_season_state,
         'QR_RESIDUAL' AS model_type,
         q50_qr_residual AS q50, q80_qr_residual AS q80, q90_qr_residual AS q90, q95_qr_residual AS q95
  FROM base_predictions
  
  UNION ALL
  
  SELECT sku_id, decision_week, y_true_12w, season_group, sku_season_state,
         'QR_ZERO_AWARE' AS model_type,
         q50_qr_zero_aware AS q50, q80_qr_zero_aware AS q80, q90_qr_zero_aware AS q90, q95_qr_zero_aware AS q95
  FROM base_predictions
),

-- ── Global metrics per model_type ───────────────────────────────────────────
global_metrics AS (
  SELECT
    model_type,
    'GLOBAL' AS breakdown,
    
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    
    -- WMAPE (all cases)
    ROUND(SAFE_DIVIDE(
      SUM(ABS(y_true_12w - q50)),
      SUM(y_true_12w)
    ), 4) AS wmape_all,
    
    -- WMAPE (y > 0 only)
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - q50) ELSE 0 END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w ELSE 0 END)
    ), 4) AS wmape_y_positive,
    
    -- Bias
    ROUND(100.0 * SAFE_DIVIDE(
      SUM(q50 - y_true_12w),
      SUM(y_true_12w)
    ), 2) AS bias_pct,
    
    -- Violation rates
    ROUND(AVG(CASE WHEN y_true_12w > q80 THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90 THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95 THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
    
    -- Zero overforecast rate
    ROUND(AVG(CASE WHEN y_true_12w = 0 AND q50 > 0 THEN 1.0 ELSE 0.0 END), 4) AS zero_overforecast_rate,
    
    -- Monotonicity violations
    ROUND(AVG(CASE WHEN q80 < q50 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_q50,
    ROUND(AVG(CASE WHEN q90 < q80 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN q95 < q90 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90
    
  FROM unpivoted
  GROUP BY model_type
),

-- ── By season_group metrics ─────────────────────────────────────────────────
by_season_group AS (
  SELECT
    model_type,
    CONCAT('BY_SEASON_', season_group) AS breakdown,
    
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    
    ROUND(SAFE_DIVIDE(
      SUM(ABS(y_true_12w - q50)),
      SUM(y_true_12w)
    ), 4) AS wmape_all,
    
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - q50) ELSE 0 END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w ELSE 0 END)
    ), 4) AS wmape_y_positive,
    
    ROUND(100.0 * SAFE_DIVIDE(
      SUM(q50 - y_true_12w),
      SUM(y_true_12w)
    ), 2) AS bias_pct,
    
    ROUND(AVG(CASE WHEN y_true_12w > q80 THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90 THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95 THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
    
    ROUND(AVG(CASE WHEN y_true_12w = 0 AND q50 > 0 THEN 1.0 ELSE 0.0 END), 4) AS zero_overforecast_rate,
    
    ROUND(AVG(CASE WHEN q80 < q50 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_q50,
    ROUND(AVG(CASE WHEN q90 < q80 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN q95 < q90 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90
    
  FROM unpivoted
  WHERE season_group IN ('HIGH_SEASON', 'REST')
  GROUP BY model_type, season_group
),

-- ── Union all metrics ───────────────────────────────────────────────────────
all_metrics AS (
  SELECT * FROM global_metrics
  UNION ALL
  SELECT * FROM by_season_group
),

-- ── Calculate composite loss ────────────────────────────────────────────────
with_loss AS (
  SELECT
    model_type,
    breakdown,
    n_obs,
    n_skus,
    wmape_all,
    wmape_y_positive,
    bias_pct,
    viol_p80,
    viol_p90,
    viol_p95,
    zero_overforecast_rate,
    pct_q80_lt_q50,
    pct_q90_lt_q80,
    pct_q95_lt_q90,
    
    -- Violation targets: p80=0.20, p90=0.10, p95=0.05
    ABS(viol_p80 - 0.20) AS viol_p80_error,
    ABS(viol_p90 - 0.10) AS viol_p90_error,
    ABS(viol_p95 - 0.05) AS viol_p95_error,
    
    -- Monotonicity penalty
    10.0 * (pct_q90_lt_q80 + pct_q95_lt_q90) AS penalty_non_monotonic,
    
    -- HIGH_SEASON degradation penalty (from global breakdown only)
    CASE 
      WHEN breakdown = 'BY_SEASON_HIGH_SEASON' AND wmape_y_positive > 0.700
      THEN 5.0 * (wmape_y_positive - 0.700)
      ELSE 0.0
    END AS penalty_highseason_degradation,
    
    -- Composite loss (only for global breakdown, for ranking)
    CASE WHEN breakdown = 'GLOBAL' THEN
      2.0 * ABS(viol_p80 - 0.20)
      + 3.0 * ABS(viol_p90 - 0.10)
      + 2.0 * ABS(viol_p95 - 0.05)
      + 1.0 * wmape_y_positive
      + 0.5 * zero_overforecast_rate
      + 10.0 * (pct_q90_lt_q80 + pct_q95_lt_q90)
    ELSE NULL
    END AS composite_loss
    
  FROM all_metrics
)

SELECT
  model_type,
  breakdown,
  n_obs,
  n_skus,
  wmape_all,
  wmape_y_positive,
  bias_pct,
  viol_p80,
  viol_p90,
  viol_p95,
  viol_p80_error,
  viol_p90_error,
  viol_p95_error,
  zero_overforecast_rate,
  pct_q80_lt_q50,
  pct_q90_lt_q80,
  pct_q95_lt_q90,
  penalty_non_monotonic,
  penalty_highseason_degradation,
  composite_loss,
  
  -- Metadata
  'h12_v4_quantile_regression_strict' AS model_version,
  CURRENT_TIMESTAMP() AS evaluated_at

FROM with_loss
ORDER BY model_type, breakdown;


-- ── STEP 2: Freeze winning model_type ──────────────────────────────────────

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_qr_policy_h12_v4_qr_strict` AS
WITH

-- Select model_type with lowest composite_loss on DEV_SELECT GLOBAL
winner AS (
  SELECT
    model_type,
    composite_loss,
    wmape_y_positive,
    viol_p80,
    viol_p90,
    viol_p95,
    zero_overforecast_rate
  FROM `{PROJECT_ID}.{BQ_DATASET}.qr_candidate_evaluation_dev_select_h12_v4_qr_strict`
  WHERE breakdown = 'GLOBAL'
  ORDER BY composite_loss ASC
  LIMIT 1
)

SELECT
  model_type AS frozen_qr_model_type,
  composite_loss AS dev_select_composite_loss,
  wmape_y_positive AS dev_select_wmape_y_positive,
  viol_p80 AS dev_select_viol_p80,
  viol_p90 AS dev_select_viol_p90,
  viol_p95 AS dev_select_viol_p95,
  zero_overforecast_rate AS dev_select_zero_overforecast_rate,
  
  -- Metadata
  'DEV_SELECT' AS selected_using_split,
  TRUE AS selected_without_locked_test,
  FALSE AS post_selection_bias,
  'h12_v4_quantile_regression_strict' AS model_version,
  CURRENT_TIMESTAMP() AS frozen_at
  
FROM winner;


-- ============================================================================
-- DIAGNOSTIC SUMMARY QUERIES
-- ============================================================================

-- Show all candidates ranked by composite loss
SELECT
  '=== CANDIDATE RANKING (DEV_SELECT GLOBAL) ===' AS header;

SELECT
  model_type,
  ROUND(composite_loss, 4) AS composite_loss,
  ROUND(wmape_y_positive, 4) AS wmape_ypos,
  viol_p80,
  viol_p90,
  viol_p95,
  zero_overforecast_rate,
  penalty_non_monotonic
FROM `{PROJECT_ID}.{BQ_DATASET}.qr_candidate_evaluation_dev_select_h12_v4_qr_strict`
WHERE breakdown = 'GLOBAL'
ORDER BY composite_loss ASC;


-- Show HIGH_SEASON performance
SELECT
  '=== HIGH_SEASON METRICS ===' AS header;

SELECT
  model_type,
  wmape_y_positive,
  viol_p90,
  zero_overforecast_rate,
  penalty_highseason_degradation
FROM `{PROJECT_ID}.{BQ_DATASET}.qr_candidate_evaluation_dev_select_h12_v4_qr_strict`
WHERE breakdown = 'BY_SEASON_HIGH_SEASON'
ORDER BY wmape_y_positive ASC;


-- Show REST performance
SELECT
  '=== REST METRICS ===' AS header;

SELECT
  model_type,
  wmape_y_positive,
  viol_p90,
  zero_overforecast_rate
FROM `{PROJECT_ID}.{BQ_DATASET}.qr_candidate_evaluation_dev_select_h12_v4_qr_strict`
WHERE breakdown = 'BY_SEASON_REST'
ORDER BY wmape_y_positive ASC;


-- Show frozen winner
SELECT
  '=== FROZEN WINNER ===' AS header;

SELECT
  frozen_qr_model_type,
  ROUND(dev_select_composite_loss, 4) AS composite_loss,
  dev_select_viol_p80,
  dev_select_viol_p90,
  dev_select_viol_p95,
  ROUND(dev_select_wmape_y_positive, 4) AS wmape_ypos,
  selected_without_locked_test,
  post_selection_bias
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_qr_policy_h12_v4_qr_strict`;
