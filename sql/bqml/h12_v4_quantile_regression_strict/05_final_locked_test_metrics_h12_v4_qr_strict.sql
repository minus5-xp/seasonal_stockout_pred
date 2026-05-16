-- ============================================================================
-- STEP 05: FINAL LOCKED TEST METRICS (h=12 v4_quantile_regression_strict)
-- ============================================================================
-- PURPOSE:
--   Apply frozen QR model to LOCKED_TEST and compute final evaluation metrics.
--   This is the ONE-TIME use of LOCKED_TEST for v4 evaluation.
--
-- ANTI-LEAKAGE:
--   - Uses frozen_qr_model_type selected on DEV_SELECT (phase 04)
--   - LOCKED_TEST predictions generated in phase 03 (scoring)
--   - No re-selection, no tuning, read-only evaluation
--
-- METRICS BREAKDOWN:
--   1. GLOBAL
--   2. BY_SEASON_GROUP (HIGH_SEASON, REST)
--   3. BY_SKU_SEASON_STATE (OFF_SEASON, IN_SEASON, TRANSITION_*, etc.)
--
-- OUTPUT TABLE:
--   final_locked_test_metrics_h12_v4_qr_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v4_qr_strict` AS
WITH

-- ── Retrieve frozen model_type from selection phase ────────────────────────
frozen_model AS (
  SELECT frozen_qr_model_type
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_qr_policy_h12_v4_qr_strict`
  LIMIT 1
),

-- ── Apply frozen model to LOCKED_TEST predictions ──────────────────────────
locked_test_predictions AS (
  SELECT
    p.sku_id,
    p.decision_week,
    p.y_true_12w,
    p.season_group,
    p.sku_season_state,
    
    -- Select quantiles based on frozen model_type
    CASE 
      WHEN fm.frozen_qr_model_type = 'QR_DIRECT' THEN p.q50_qr_direct
      WHEN fm.frozen_qr_model_type = 'QR_RESIDUAL' THEN p.q50_qr_residual
      WHEN fm.frozen_qr_model_type = 'QR_ZERO_AWARE' THEN p.q50_qr_zero_aware
    END AS q50,
    
    CASE 
      WHEN fm.frozen_qr_model_type = 'QR_DIRECT' THEN p.q80_qr_direct
      WHEN fm.frozen_qr_model_type = 'QR_RESIDUAL' THEN p.q80_qr_residual
      WHEN fm.frozen_qr_model_type = 'QR_ZERO_AWARE' THEN p.q80_qr_zero_aware
    END AS q80,
    
    CASE 
      WHEN fm.frozen_qr_model_type = 'QR_DIRECT' THEN p.q90_qr_direct
      WHEN fm.frozen_qr_model_type = 'QR_RESIDUAL' THEN p.q90_qr_residual
      WHEN fm.frozen_qr_model_type = 'QR_ZERO_AWARE' THEN p.q90_qr_zero_aware
    END AS q90,
    
    CASE 
      WHEN fm.frozen_qr_model_type = 'QR_DIRECT' THEN p.q95_qr_direct
      WHEN fm.frozen_qr_model_type = 'QR_RESIDUAL' THEN p.q95_qr_residual
      WHEN fm.frozen_qr_model_type = 'QR_ZERO_AWARE' THEN p.q95_qr_zero_aware
    END AS q95,
    
    fm.frozen_qr_model_type
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.qr_predictions_h12_v4_qr_strict` p
  CROSS JOIN frozen_model fm
  WHERE p.eval_split_v3 = 'LOCKED_TEST'
),

-- ── GLOBAL metrics ──────────────────────────────────────────────────────────
global_metrics AS (
  SELECT
    'GLOBAL' AS breakdown_level,
    CAST(NULL AS STRING) AS season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    
    -- WMAPE
    ROUND(SAFE_DIVIDE(
      SUM(ABS(y_true_12w - q50)),
      SUM(y_true_12w)
    ), 4) AS wmape_all,
    
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - q50) ELSE 0 END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w ELSE 0 END)
    ), 4) AS wmape_y_positive,
    
    -- Bias
    ROUND(100.0 * SAFE_DIVIDE(
      SUM(q50 - y_true_12w),
      SUM(y_true_12w)
    ), 2) AS bias_pct,
    
    -- MAE
    ROUND(AVG(ABS(y_true_12w - q50)), 3) AS mae,
    
    -- Violation rates
    ROUND(AVG(CASE WHEN y_true_12w > q80 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p95,
    
    -- Zero handling
    ROUND(AVG(CASE WHEN y_true_12w = 0 AND q50 > 0 THEN 1.0 ELSE 0.0 END), 4) AS zero_demand_overforecast_rate,
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN q50 ELSE NULL END), 3) AS avg_pred_when_y_zero,
    
    -- Monotonicity
    ROUND(AVG(CASE WHEN q80 < q50 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_q50,
    ROUND(AVG(CASE WHEN q90 < q80 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN q95 < q90 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90,
    
    -- Quantile spread (diagnostic)
    ROUND(AVG(q90 - q50), 3) AS avg_spread_p50_to_p90,
    ROUND(STDDEV(q90 - q50), 3) AS std_spread_p50_to_p90
    
  FROM locked_test_predictions
),

-- ── BY SEASON GROUP ─────────────────────────────────────────────────────────
by_season_group AS (
  SELECT
    'BY_SEASON_GROUP' AS breakdown_level,
    season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - q50)), SUM(y_true_12w)), 4) AS wmape_all,
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - q50) ELSE 0 END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w ELSE 0 END)
    ), 4) AS wmape_y_positive,
    ROUND(100.0 * SAFE_DIVIDE(SUM(q50 - y_true_12w), SUM(y_true_12w)), 2) AS bias_pct,
    ROUND(AVG(ABS(y_true_12w - q50)), 3) AS mae,
    
    ROUND(AVG(CASE WHEN y_true_12w > q80 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p95,
    
    ROUND(AVG(CASE WHEN y_true_12w = 0 AND q50 > 0 THEN 1.0 ELSE 0.0 END), 4) AS zero_demand_overforecast_rate,
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN q50 ELSE NULL END), 3) AS avg_pred_when_y_zero,
    
    ROUND(AVG(CASE WHEN q80 < q50 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_q50,
    ROUND(AVG(CASE WHEN q90 < q80 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN q95 < q90 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90,
    
    ROUND(AVG(q90 - q50), 3) AS avg_spread_p50_to_p90,
    ROUND(STDDEV(q90 - q50), 3) AS std_spread_p50_to_p90
    
  FROM locked_test_predictions
  WHERE season_group IS NOT NULL
  GROUP BY season_group
),

-- ── BY SKU SEASON STATE ─────────────────────────────────────────────────────
by_sku_season_state AS (
  SELECT
    'BY_SKU_SEASON_STATE' AS breakdown_level,
    CAST(NULL AS STRING) AS season_group,
    sku_season_state,
    
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - q50)), SUM(y_true_12w)), 4) AS wmape_all,
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - q50) ELSE 0 END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w ELSE 0 END)
    ), 4) AS wmape_y_positive,
    ROUND(100.0 * SAFE_DIVIDE(SUM(q50 - y_true_12w), SUM(y_true_12w)), 2) AS bias_pct,
    ROUND(AVG(ABS(y_true_12w - q50)), 3) AS mae,
    
    ROUND(AVG(CASE WHEN y_true_12w > q80 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95 THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p95,
    
    ROUND(AVG(CASE WHEN y_true_12w = 0 AND q50 > 0 THEN 1.0 ELSE 0.0 END), 4) AS zero_demand_overforecast_rate,
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN q50 ELSE NULL END), 3) AS avg_pred_when_y_zero,
    
    ROUND(AVG(CASE WHEN q80 < q50 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_q50,
    ROUND(AVG(CASE WHEN q90 < q80 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN q95 < q90 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90,
    
    ROUND(AVG(q90 - q50), 3) AS avg_spread_p50_to_p90,
    ROUND(STDDEV(q90 - q50), 3) AS std_spread_p50_to_p90
    
  FROM locked_test_predictions
  WHERE sku_season_state IS NOT NULL
  GROUP BY sku_season_state
),

-- ── Union all breakdowns ────────────────────────────────────────────────────
all_metrics AS (
  SELECT * FROM global_metrics
  UNION ALL
  SELECT * FROM by_season_group
  UNION ALL
  SELECT * FROM by_sku_season_state
),

-- ── Add frozen model metadata ───────────────────────────────────────────────
with_metadata AS (
  SELECT
    am.*,
    fm.frozen_qr_model_type,
    FALSE AS post_selection_bias,
    FALSE AS selected_using_locked_test,
    'h12_v4_quantile_regression_strict' AS model_version,
    CURRENT_TIMESTAMP() AS computed_at
  FROM all_metrics am
  CROSS JOIN frozen_model fm
)

SELECT * FROM with_metadata
ORDER BY 
  CASE breakdown_level 
    WHEN 'GLOBAL' THEN 1
    WHEN 'BY_SEASON_GROUP' THEN 2
    WHEN 'BY_SKU_SEASON_STATE' THEN 3
  END,
  season_group,
  sku_season_state;


-- ============================================================================
-- DIAGNOSTIC SUMMARY QUERIES
-- ============================================================================

-- Global summary
SELECT '=== GLOBAL LOCKED_TEST METRICS ===' AS header;

SELECT
  frozen_qr_model_type,
  n_obs,
  n_skus,
  wmape_all,
  wmape_y_positive,
  bias_pct,
  viol_rate_p80,
  viol_rate_p90,
  viol_rate_p95,
  zero_demand_overforecast_rate,
  avg_spread_p50_to_p90,
  pct_q90_lt_q80
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v4_qr_strict`
WHERE breakdown_level = 'GLOBAL';


-- By season_group
SELECT '=== BY SEASON GROUP ===' AS header;

SELECT
  season_group,
  n_obs,
  wmape_y_positive,
  bias_pct,
  viol_rate_p90,
  zero_demand_overforecast_rate
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v4_qr_strict`
WHERE breakdown_level = 'BY_SEASON_GROUP'
ORDER BY season_group;


-- By sku_season_state (top states)
SELECT '=== BY SKU SEASON STATE (top 5 by n_obs) ===' AS header;

SELECT
  sku_season_state,
  n_obs,
  wmape_y_positive,
  viol_rate_p90,
  avg_spread_p50_to_p90
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v4_qr_strict`
WHERE breakdown_level = 'BY_SKU_SEASON_STATE'
ORDER BY n_obs DESC
LIMIT 5;


-- Success criteria evaluation
SELECT '=== SUCCESS CRITERIA EVALUATION ===' AS header;

SELECT
  frozen_qr_model_type,
  
  -- Violation targets
  CASE 
    WHEN viol_rate_p80 BETWEEN 0.15 AND 0.25 THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS viol_p80_check,
  viol_rate_p80,
  
  CASE 
    WHEN viol_rate_p90 BETWEEN 0.05 AND 0.15 THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS viol_p90_check,
  viol_rate_p90,
  
  CASE 
    WHEN viol_rate_p95 BETWEEN 0.02 AND 0.08 THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS viol_p95_check,
  viol_rate_p95,
  
  -- WMAPE target (global y>0)
  CASE 
    WHEN wmape_y_positive <= 1.000 THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS wmape_global_check,
  wmape_y_positive,
  
  -- Zero overforecast target
  CASE 
    WHEN zero_demand_overforecast_rate < 0.70 THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS zero_overforecast_check,
  zero_demand_overforecast_rate,
  
  -- Monotonicity
  CASE 
    WHEN pct_q90_lt_q80 < 0.01 THEN '✓ PASS'
    ELSE '✗ FAIL'
  END AS monotonicity_check,
  pct_q90_lt_q80

FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v4_qr_strict`
WHERE breakdown_level = 'GLOBAL';
