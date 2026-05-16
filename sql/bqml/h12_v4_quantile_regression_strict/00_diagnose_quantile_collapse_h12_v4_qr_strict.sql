-- ============================================================================
-- STEP 00: DIAGNOSE QUANTILE COLLAPSE  (h=12 v4_quantile_regression_strict)
-- ============================================================================
-- PURPOSE:
--   Before building a quantile regression layer, diagnose whether the quantile
--   collapse (viol_p80=viol_p90=viol_p95=0.000) originates from:
--   1. BQML model raw predictions already collapsed (q80≈q90≈q95≈p50)
--   2. Post-processing/calibration in v3_2 causing collapse
--
-- ANALYSIS:
--   Compare spreads at different stages:
--   - Raw BQML: base_scores_h12_v1 (q80_12w, q90_12w, q95_12w)
--   - v3_strict calibrated: forecast_recalibrated_h12_v3_strict
--   - v3_2 gated: forecast_gated_h12_v3_2_season_state_strict
--
-- OUTPUT TABLE:
--   diagnostics_quantile_collapse_h12_v4_qr_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diagnostics_quantile_collapse_h12_v4_qr_strict` AS
WITH

-- ── Base BQML (no quantiles, just p50 and scale) ──────────────────────────
-- Note: base_scores_h12_v1 only has yhat_p50_12w, no raw quantiles from BQML
-- Quantiles are computed in v3_strict calibration layer
base_bqml AS (
  SELECT
    'base_bqml_p50_only' AS source,
    tc.eval_split_v3,
    base.season_group,
    ss.sku_season_state,
    
    COUNT(*) AS n_obs,
    
    -- Only p50 available at base level
    ROUND(AVG(base.yhat_p50_12w), 2) AS avg_p50,
    CAST(NULL AS FLOAT64) AS avg_q80,
    CAST(NULL AS FLOAT64) AS avg_q90,
    CAST(NULL AS FLOAT64) AS avg_q95,
    
    CAST(NULL AS FLOAT64) AS avg_spread_p50_to_p80,
    CAST(NULL AS FLOAT64) AS avg_spread_p50_to_p90,
    CAST(NULL AS FLOAT64) AS avg_spread_p50_to_p95,
    
    CAST(NULL AS FLOAT64) AS std_spread_p50_to_p90,
    
    CAST(NULL AS FLOAT64) AS viol_p80,
    CAST(NULL AS FLOAT64) AS viol_p90,
    CAST(NULL AS FLOAT64) AS viol_p95,
    
    CAST(NULL AS FLOAT64) AS pct_q80_lt_p50,
    CAST(NULL AS FLOAT64) AS pct_q90_lt_q80,
    CAST(NULL AS FLOAT64) AS pct_q95_lt_q90,
    
    CAST(NULL AS FLOAT64) AS pct_q80_equals_p50,
    CAST(NULL AS FLOAT64) AS pct_q90_equals_p50,
    CAST(NULL AS FLOAT64) AS pct_q95_equals_p50
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` base
  JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = base.week_start_date
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = base.sku_id AND ss.decision_week = base.week_start_date
  WHERE base.split = 'VAL'
    AND tc.eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
  GROUP BY source, tc.eval_split_v3, base.season_group, ss.sku_season_state
),

-- ── v3_strict calibrated quantiles ─────────────────────────────────────────
v3_strict_cal AS (
  SELECT
    'v3_strict_calibrated' AS source,
    f.eval_split_v3,
    f.season_group,
    ss.sku_season_state,
    
    COUNT(*) AS n_obs,
    
    ROUND(AVG(f.yhat_p50_12w), 2) AS avg_p50,
    ROUND(AVG(f.q80_12w), 2) AS avg_q80,
    ROUND(AVG(f.q90_12w), 2) AS avg_q90,
    ROUND(AVG(f.q95_12w), 2) AS avg_q95,
    
    ROUND(AVG(f.q80_12w - f.yhat_p50_12w), 3) AS avg_spread_p50_to_p80,
    ROUND(AVG(f.q90_12w - f.yhat_p50_12w), 3) AS avg_spread_p50_to_p90,
    ROUND(AVG(f.q95_12w - f.yhat_p50_12w), 3) AS avg_spread_p50_to_p95,
    
    ROUND(STDDEV(f.q90_12w - f.yhat_p50_12w), 3) AS std_spread_p50_to_p90,
    
    ROUND(AVG(CASE WHEN f.y_true_12w > f.q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
    ROUND(AVG(CASE WHEN f.y_true_12w > f.q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
    ROUND(AVG(CASE WHEN f.y_true_12w > f.q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
    
    ROUND(AVG(CASE WHEN f.q80_12w < f.yhat_p50_12w THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_p50,
    ROUND(AVG(CASE WHEN f.q90_12w < f.q80_12w THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN f.q95_12w < f.q90_12w THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90,
    
    ROUND(AVG(CASE WHEN ABS(f.q80_12w - f.yhat_p50_12w) < 0.01 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_equals_p50,
    ROUND(AVG(CASE WHEN ABS(f.q90_12w - f.yhat_p50_12w) < 0.01 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_equals_p50,
    ROUND(AVG(CASE WHEN ABS(f.q95_12w - f.yhat_p50_12w) < 0.01 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_equals_p50
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = f.sku_id AND ss.decision_week = f.decision_week
  WHERE f.split_original = 'VAL'
  GROUP BY source, f.eval_split_v3, f.season_group, ss.sku_season_state
),

-- ── v3_2 gated quantiles ────────────────────────────────────────────────────
v3_2_gated AS (
  SELECT
    'v3_2_gated' AS source,
    fg.eval_split_v3,
    fg.season_group,
    ss.sku_season_state,
    
    COUNT(*) AS n_obs,
    
    ROUND(AVG(fg.yhat_p50_season_state_12w), 2) AS avg_p50,
    ROUND(AVG(fg.q80_12w), 2) AS avg_q80,
    ROUND(AVG(fg.q90_12w), 2) AS avg_q90,
    ROUND(AVG(fg.q95_12w), 2) AS avg_q95,
    
    ROUND(AVG(fg.q80_12w - fg.yhat_p50_season_state_12w), 3) AS avg_spread_p50_to_p80,
    ROUND(AVG(fg.q90_12w - fg.yhat_p50_season_state_12w), 3) AS avg_spread_p50_to_p90,
    ROUND(AVG(fg.q95_12w - fg.yhat_p50_season_state_12w), 3) AS avg_spread_p50_to_p95,
    
    ROUND(STDDEV(fg.q90_12w - fg.yhat_p50_season_state_12w), 3) AS std_spread_p50_to_p90,
    
    ROUND(AVG(CASE WHEN fg.y_true_12w > fg.q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
    ROUND(AVG(CASE WHEN fg.y_true_12w > fg.q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
    ROUND(AVG(CASE WHEN fg.y_true_12w > fg.q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
    
    ROUND(AVG(CASE WHEN fg.q80_12w < fg.yhat_p50_season_state_12w THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_lt_p50,
    ROUND(AVG(CASE WHEN fg.q90_12w < fg.q80_12w THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_lt_q80,
    ROUND(AVG(CASE WHEN fg.q95_12w < fg.q90_12w THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_lt_q90,
    
    ROUND(AVG(CASE WHEN ABS(fg.q80_12w - fg.yhat_p50_season_state_12w) < 0.01 THEN 1.0 ELSE 0.0 END), 4) AS pct_q80_equals_p50,
    ROUND(AVG(CASE WHEN ABS(fg.q90_12w - fg.yhat_p50_season_state_12w) < 0.01 THEN 1.0 ELSE 0.0 END), 4) AS pct_q90_equals_p50,
    ROUND(AVG(CASE WHEN ABS(fg.q95_12w - fg.yhat_p50_season_state_12w) < 0.01 THEN 1.0 ELSE 0.0 END), 4) AS pct_q95_equals_p50
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` fg
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = fg.sku_id AND ss.decision_week = fg.decision_week
  WHERE fg.split_original = 'VAL'
  GROUP BY source, fg.eval_split_v3, fg.season_group, ss.sku_season_state
)

-- ── Union all sources ───────────────────────────────────────────────────────
SELECT * FROM base_bqml
UNION ALL
SELECT * FROM v3_strict_cal
UNION ALL
SELECT * FROM v3_2_gated

ORDER BY source, eval_split_v3, season_group, sku_season_state;


-- ============================================================================
-- DIAGNOSTIC SUMMARY QUERY (to display after table creation)
-- ============================================================================
SELECT 
  source,
  eval_split_v3,
  season_group,
  sku_season_state,
  n_obs,
  avg_spread_p50_to_p90,
  std_spread_p50_to_p90,
  viol_p90,
  pct_q90_equals_p50,
  pct_q90_lt_q80
FROM `{PROJECT_ID}.{BQ_DATASET}.diagnostics_quantile_collapse_h12_v4_qr_strict`
WHERE eval_split_v3 IN ('DEV_TUNE', 'LOCKED_TEST')
  AND (season_group IS NULL OR season_group IN ('HIGH_SEASON', 'REST'))
ORDER BY 
  source, 
  eval_split_v3, 
  season_group, 
  CASE WHEN sku_season_state IS NULL THEN 0 ELSE 1 END,
  sku_season_state
LIMIT 50;
