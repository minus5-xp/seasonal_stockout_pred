-- ============================================================================
-- PHASE 6: FINAL LOCKED_TEST METRICS (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Compute comprehensive metrics on LOCKED_TEST (one-time use).
--   Compare p50, quantile coverage, spreads, monotonicity.
--
-- INPUTS:
--   - forecast_final_h12_v4_2_strict (LOCKED_TEST only)
--
-- OUTPUTS:
--   - final_locked_test_metrics_h12_v4_2_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict` AS
WITH

-- Global metrics
metrics_global AS (
  SELECT
    'v4_2_global' AS metric_level,
    CAST(NULL AS STRING) AS season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    COUNT(DISTINCT decision_week) AS n_weeks,
    
    -- Actuals vs predictions
    AVG(y_true_12w) AS mean_actual,
    AVG(yhat_p50_v4_2_12w) AS mean_pred,
    AVG(ABS(y_true_12w - yhat_p50_v4_2_12w)) AS mae,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_v4_2_12w)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_v4_2_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(yhat_p50_v4_2_12w) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    
    -- Zero behavior
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_v4_2_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_v4_2_12w END) AS avg_pred_when_y_zero,
    
    -- Quantile coverage
    AVG(CASE WHEN y_true_12w > q80_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q90_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q95_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p95,
    
    -- Spreads
    AVG(spread80_v4_2) AS avg_spread_p50_p80,
    AVG(spread90_v4_2) AS avg_spread_p50_p90,
    AVG(spread95_v4_2) AS avg_spread_p50_p95,
    APPROX_QUANTILES(spread90_v4_2, 100)[OFFSET(50)] AS median_spread_p50_p90,
    APPROX_QUANTILES(spread90_v4_2, 100)[OFFSET(90)] AS p90_spread_p50_p90,
    
    -- Monotonicity
    AVG(CASE WHEN q80_v4_2_12w < yhat_p50_v4_2_12w OR q90_v4_2_12w < q80_v4_2_12w OR q95_v4_2_12w < q90_v4_2_12w THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate
    
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
),

-- By season_group
metrics_season AS (
  SELECT
    'v4_2_by_season' AS metric_level,
    season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    COUNT(DISTINCT decision_week) AS n_weeks,
    AVG(y_true_12w) AS mean_actual,
    AVG(yhat_p50_v4_2_12w) AS mean_pred,
    AVG(ABS(y_true_12w - yhat_p50_v4_2_12w)) AS mae,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_v4_2_12w)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_v4_2_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(yhat_p50_v4_2_12w) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_v4_2_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_v4_2_12w END) AS avg_pred_when_y_zero,
    AVG(CASE WHEN y_true_12w > q80_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q90_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q95_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(spread80_v4_2) AS avg_spread_p50_p80,
    AVG(spread90_v4_2) AS avg_spread_p50_p90,
    AVG(spread95_v4_2) AS avg_spread_p50_p95,
    APPROX_QUANTILES(spread90_v4_2, 100)[OFFSET(50)] AS median_spread_p50_p90,
    APPROX_QUANTILES(spread90_v4_2, 100)[OFFSET(90)] AS p90_spread_p50_p90,
    AVG(CASE WHEN q80_v4_2_12w < yhat_p50_v4_2_12w OR q90_v4_2_12w < q80_v4_2_12w OR q95_v4_2_12w < q90_v4_2_12w THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
  GROUP BY season_group
),

-- By sku_season_state
metrics_state AS (
  SELECT
    'v4_2_by_state' AS metric_level,
    CAST(NULL AS STRING) AS season_group,
    sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    COUNT(DISTINCT decision_week) AS n_weeks,
    AVG(y_true_12w) AS mean_actual,
    AVG(yhat_p50_v4_2_12w) AS mean_pred,
    AVG(ABS(y_true_12w - yhat_p50_v4_2_12w)) AS mae,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_v4_2_12w)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_v4_2_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(yhat_p50_v4_2_12w) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_v4_2_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_v4_2_12w END) AS avg_pred_when_y_zero,
    AVG(CASE WHEN y_true_12w > q80_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q90_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q95_v4_2_12w THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(spread80_v4_2) AS avg_spread_p50_p80,
    AVG(spread90_v4_2) AS avg_spread_p50_p90,
    AVG(spread95_v4_2) AS avg_spread_p50_p95,
    APPROX_QUANTILES(spread90_v4_2, 100)[OFFSET(50)] AS median_spread_p50_p90,
    APPROX_QUANTILES(spread90_v4_2, 100)[OFFSET(90)] AS p90_spread_p50_p90,
    AVG(CASE WHEN q80_v4_2_12w < yhat_p50_v4_2_12w OR q90_v4_2_12w < q80_v4_2_12w OR q95_v4_2_12w < q90_v4_2_12w THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
  GROUP BY sku_season_state
)

SELECT * FROM metrics_global
UNION ALL
SELECT * FROM metrics_season
UNION ALL
SELECT * FROM metrics_state;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 6 Complete: LOCKED_TEST Evaluation (ONE-TIME USE)' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Summary
SELECT
  'LOCKED_TEST Metrics' AS summary,
  COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
  n_obs,
  ROUND(wmape_all, 4) AS wmape_all,
  ROUND(wmape_ypos, 4) AS wmape_ypos,
  ROUND(viol_p80, 3) AS p80,
  ROUND(viol_p90, 3) AS p90,
  ROUND(viol_p95, 3) AS p95,
  ROUND(avg_spread_p50_p90, 2) AS spread90,
  ROUND(monotonicity_violation_rate, 4) AS mono_viol
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict`
ORDER BY 
  CASE metric_level 
    WHEN 'v4_2_global' THEN 1 
    WHEN 'v4_2_by_season' THEN 2 
    ELSE 3 
  END,
  n_obs DESC
LIMIT 15;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 7 will compare v3_2 vs v4_2' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
