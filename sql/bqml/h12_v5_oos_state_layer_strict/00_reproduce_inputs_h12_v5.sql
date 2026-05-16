-- ============================================================================
-- PHASE 0: REPRODUCE INPUTS AND VALIDATE SOURCE TABLES (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Validate that all input tables exist and have expected structure.
--   Join base_scores, v3_2 forecast, season_state, and v4_2 (optional).
--   Create consolidated input table for feature engineering.
--
-- INPUTS:
--   - base_scores_h12_v1
--   - forecast_gated_h12_v3_2_season_state_strict
--   - sku_season_state_h12_v3_2_season_state_strict
--   - sku_week_seasonality_features_h12_v3_2_season_state_strict
--   - forecast_final_h12_v4_2_strict (optional)
--
-- OUTPUTS:
--   - oos_state_inputs_h12_v5_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_state_inputs_h12_v5_strict` AS
WITH

base AS (
  SELECT
    sku_id,
    week_start_date,
    week_start_date AS decision_week,  -- base_scores uses week_start_date, not decision_week
    y_sales,
    y_true_12w,
    stockout_event_12w,
    p_oos_h12,
    yhat_p50_12w AS yhat_p50_bqml_raw_12w,
    season_group,
    -- Map split values to v5 nomenclature
    CASE split
      WHEN 'TRAIN' THEN 'DEV_TUNE'
      WHEN 'CALIB' THEN 'DEV_SELECT'
      WHEN 'VAL' THEN 'LOCKED_TEST'
      ELSE split
    END AS eval_split_v3
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v1`
),

v3_2_forecast AS (
  SELECT
    sku_id,
    decision_week,
    yhat_p50_season_state_12w AS yhat_p50_v3_2_12w
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
),

season_state AS (
  SELECT
    sku_id,
    decision_week,
    sku_season_state,
    hist_positive_rate_same_week,
    hist_zero_rate_same_week,
    annual_positive_rate_sku,
    seasonal_index_same_week,
    hist_avg_units_same_week,
    hist_median_units_same_week,
    hist_p90_units_same_week
  FROM `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict`
),

seasonality_features AS (
  SELECT
    sku_id,
    decision_week,
    hist_avg_units_same_week,
    hist_p90_units_same_week,
    hist_positive_rate_same_week,
    n_hist_years_available
  FROM `thequantitativeledger.cruzber_models_eu.sku_week_seasonality_features_h12_v3_2_season_state_strict`
),

v4_2_overlay AS (
  SELECT
    sku_id,
    decision_week,
    q90_v4_2_12w,
    spread90_v4_2,
    zero_regime
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
)

SELECT
  b.sku_id,
  b.week_start_date,
  b.decision_week,
  b.eval_split_v3,
  b.season_group,
  ss.sku_season_state,
  
  -- Actuals
  b.y_sales,
  b.y_true_12w,
  b.stockout_event_12w,
  
  -- Forecasts
  b.yhat_p50_bqml_raw_12w,
  COALESCE(v32.yhat_p50_v3_2_12w, b.yhat_p50_bqml_raw_12w) AS yhat_p50_v3_2_12w,
  
  -- OOS signal
  b.p_oos_h12,
  
  -- Season state features
  ss.hist_positive_rate_same_week,
  ss.hist_zero_rate_same_week,
  ss.annual_positive_rate_sku,
  ss.seasonal_index_same_week,
  ss.hist_avg_units_same_week AS state_hist_avg_units_same_week,
  ss.hist_median_units_same_week,
  ss.hist_p90_units_same_week AS state_hist_p90_units_same_week,
  
  -- Seasonality same-week features
  sf.hist_avg_units_same_week,
  sf.hist_p90_units_same_week,
  sf.hist_positive_rate_same_week AS sf_hist_positive_rate_same_week,
  sf.n_hist_years_available,
  
  -- v4_2 overlay (optional)
  v42.q90_v4_2_12w,
  v42.spread90_v4_2,
  v42.zero_regime,
  
  -- Metadata
  'h12_v5_oos_state_layer_strict' AS model_version,
  CURRENT_TIMESTAMP() AS created_at
  
FROM base b
LEFT JOIN v3_2_forecast v32
  ON b.sku_id = v32.sku_id AND b.decision_week = v32.decision_week
LEFT JOIN season_state ss
  ON b.sku_id = ss.sku_id AND b.decision_week = ss.decision_week
LEFT JOIN seasonality_features sf
  ON b.sku_id = sf.sku_id AND b.decision_week = sf.decision_week
LEFT JOIN v4_2_overlay v42
  ON b.sku_id = v42.sku_id AND b.decision_week = v42.decision_week;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 0 Complete: Inputs Reproduced' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Input summary' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  COUNT(DISTINCT sku_id) AS n_skus,
  COUNT(DISTINCT decision_week) AS n_weeks,
  ROUND(AVG(CASE WHEN y_sales = 0 THEN 1.0 ELSE 0.0 END), 3) AS zero_rate,
  ROUND(AVG(y_true_12w), 2) AS avg_y_true,
  ROUND(AVG(yhat_p50_v3_2_12w), 2) AS avg_forecast,
  ROUND(AVG(CAST(stockout_event_12w AS FLOAT64)), 3) AS stockout_rate
FROM `thequantitativeledger.cruzber_models_eu.oos_state_inputs_h12_v5_strict`
GROUP BY eval_split_v3
ORDER BY 
  CASE eval_split_v3
    WHEN 'DEV_TUNE' THEN 1
    WHEN 'DEV_SELECT' THEN 2
    WHEN 'EMBARGO' THEN 3
    WHEN 'LOCKED_TEST' THEN 4
    ELSE 5
  END;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 1 will build OOS state feature matrix' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
