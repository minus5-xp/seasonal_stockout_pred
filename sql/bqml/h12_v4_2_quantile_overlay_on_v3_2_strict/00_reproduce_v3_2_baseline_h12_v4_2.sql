-- ============================================================================
-- PHASE 0: REPRODUCE v3_2 BASELINE (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Reproduce exact v3_2 metrics on LOCKED_TEST to establish baseline.
--   This ensures v4_2 overlay preserves p50 performance.
--
-- INPUTS:
--   - forecast_gated_h12_v3_2_season_state_strict
--
-- OUTPUTS:
--   - v3_2_baseline_reproduced_h12_v4_2_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.v3_2_baseline_reproduced_h12_v4_2_strict` AS
WITH

-- Global metrics
metrics_global AS (
  SELECT
    'v3_2_global' AS metric_level,
    CAST(NULL AS STRING) AS season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    COUNT(DISTINCT decision_week) AS n_weeks,
    AVG(y_true_12w) AS mean_actual,
    AVG(yhat_p50_season_state_12w) AS mean_pred,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_season_state_12w)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(yhat_p50_season_state_12w) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(ABS(y_true_12w - yhat_p50_season_state_12w)) AS mae,
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_season_state_12w END) AS avg_pred_when_y_zero,
    0.0 AS viol_p80,  -- v3_2 has collapsed quantiles
    0.0 AS viol_p90,
    0.0 AS viol_p95
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
),

-- By season_group
metrics_season AS (
  SELECT
    'v3_2_by_season' AS metric_level,
    season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    COUNT(DISTINCT decision_week) AS n_weeks,
    AVG(y_true_12w) AS mean_actual,
    AVG(yhat_p50_season_state_12w) AS mean_pred,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_season_state_12w)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(yhat_p50_season_state_12w) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(ABS(y_true_12w - yhat_p50_season_state_12w)) AS mae,
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_season_state_12w END) AS avg_pred_when_y_zero,
    0.0 AS viol_p80,
    0.0 AS viol_p90,
    0.0 AS viol_p95
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
  GROUP BY season_group
),

-- By sku_season_state
metrics_state AS (
  SELECT
    'v3_2_by_state' AS metric_level,
    CAST(NULL AS STRING) AS season_group,
    s.sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT f.sku_id) AS n_skus,
    COUNT(DISTINCT f.decision_week) AS n_weeks,
    AVG(f.y_true_12w) AS mean_actual,
    AVG(f.yhat_p50_season_state_12w) AS mean_pred,
    SAFE_DIVIDE(SUM(ABS(f.y_true_12w - f.yhat_p50_season_state_12w)), SUM(f.y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN f.y_true_12w > 0 THEN ABS(f.y_true_12w - f.yhat_p50_season_state_12w) END),
      SUM(CASE WHEN f.y_true_12w > 0 THEN f.y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(f.yhat_p50_season_state_12w) - SUM(f.y_true_12w)), SUM(f.y_true_12w)) * 100 AS bias_pct,
    AVG(ABS(f.y_true_12w - f.yhat_p50_season_state_12w)) AS mae,
    AVG(CASE WHEN f.y_true_12w = 0 AND f.yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN f.y_true_12w = 0 THEN f.yhat_p50_season_state_12w END) AS avg_pred_when_y_zero,
    0.0 AS viol_p80,
    0.0 AS viol_p90,
    0.0 AS viol_p95
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict` f
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict` s
    ON f.sku_id = s.sku_id
    AND f.decision_week = s.decision_week
  WHERE f.eval_split_v3 = 'LOCKED_TEST'
  GROUP BY s.sku_season_state
)

SELECT * FROM metrics_global
UNION ALL
SELECT * FROM metrics_season
UNION ALL
SELECT * FROM metrics_state;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 0 Complete: v3_2 Baseline Reproduced' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Verification
SELECT
  metric_level,
  COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
  n_obs,
  ROUND(wmape_all, 4) AS wmape_all,
  ROUND(wmape_ypos, 4) AS wmape_ypos,
  ROUND(bias_pct, 2) AS bias_pct,
  ROUND(zero_overforecast_rate, 4) AS zero_overf
FROM `thequantitativeledger.cruzber_models_eu.v3_2_baseline_reproduced_h12_v4_2_strict`
ORDER BY 
  CASE metric_level 
    WHEN 'v3_2_global' THEN 1 
    WHEN 'v3_2_by_season' THEN 2 
    ELSE 3 
  END,
  n_obs DESC
LIMIT 15;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 1 will build overlay feature matrix' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
