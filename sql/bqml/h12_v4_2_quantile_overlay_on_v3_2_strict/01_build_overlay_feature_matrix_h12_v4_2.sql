-- ============================================================================
-- PHASE 1: BUILD OVERLAY FEATURE MATRIX (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Join v3_2 forecasts with state/seasonality features.
--   p50_frozen = yhat_p50_season_state_12w from v3_2 (gated).
--   NO POINT FORECAST TRAINING - p50 is locked.
--
-- INPUTS:
--   - forecast_gated_h12_v3_2_season_state_strict
--   - sku_season_state_h12_v3_2_season_state_strict
--   - sku_week_seasonality_features_h12_v3_2_season_state_strict
--
-- OUTPUTS:
--   - overlay_feature_matrix_h12_v4_2_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict` AS
SELECT
  -- Identifiers
  f.sku_id,
  f.decision_week,
  f.eval_split_v3,
  f.season_group,
  s.sku_season_state,
  
  -- Target (actual demand)
  f.y_true_12w,
  
  -- FROZEN p50 from v3_2 (gated)
  f.yhat_p50_season_state_12w AS p50_frozen_v3_2,
  
  -- For reference: original BQML p50 (ungated, but NOT used as overlay base)
  f.yhat_p50_original_12w AS p50_bqml_raw_reference,
  
  -- Historical features from TRAIN+CALIB only
  h.hist_avg_units_same_week,
  h.hist_median_units_same_week,
  h.hist_p90_units_same_week,
  h.hist_positive_rate_same_week,
  h.seasonal_index_same_week,
  h.annual_avg_units_sku,
  h.n_hist_obs_available,
  
  -- State-level features
  s.annual_positive_rate_sku,
  s.hist_avg_units_same_week AS state_hist_avg_same_week,
  s.hist_p90_units_same_week AS state_hist_p90_same_week,
  s.transition_slope_avg_units,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at
  
FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict` f
LEFT JOIN `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict` s
  ON f.sku_id = s.sku_id
  AND f.decision_week = s.decision_week
LEFT JOIN `thequantitativeledger.cruzber_models_eu.sku_week_seasonality_features_h12_v3_2_season_state_strict` h
  ON f.sku_id = h.sku_id
  AND f.decision_week = h.decision_week
WHERE f.y_true_12w IS NOT NULL;

-- ──────────────────────────────────────────────────────────────────────────
-- Validation: Anti-leakage checks
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 1 Complete: Overlay Feature Matrix Built' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Check 1: Record counts by split
SELECT 
  'CHECK 1: Record counts by split' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_records,
  COUNT(DISTINCT sku_id) AS n_skus,
  COUNT(DISTINCT decision_week) AS n_weeks
FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict`
GROUP BY eval_split_v3
ORDER BY 
  CASE eval_split_v3
    WHEN 'DEV_TUNE' THEN 1
    WHEN 'DEV_SELECT' THEN 2
    WHEN 'EMBARGO' THEN 3
    WHEN 'LOCKED_TEST' THEN 4
    ELSE 5
  END;

-- Check 2: p50_frozen == v3_2 (should be identical)
SELECT
  'CHECK 2: p50 frozen identity' AS check_name,
  eval_split_v3,
  COUNT(*) AS total_obs,
  COUNTIF(ABS(p50_frozen_v3_2 - yhat_p50_season_state_12w) < 0.0001) AS identical_count,
  SAFE_DIVIDE(
    COUNTIF(ABS(p50_frozen_v3_2 - yhat_p50_season_state_12w) < 0.0001),
    COUNT(*)
  ) AS identity_rate
FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict` m
JOIN `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict` f
  ON m.sku_id = f.sku_id
  AND m.decision_week = f.decision_week
GROUP BY eval_split_v3;

-- Check 3: Missing critical features
SELECT 
  'CHECK 3: Missing critical features' AS check_name,
  COUNTIF(sku_season_state IS NULL) AS missing_state,
  COUNTIF(p50_frozen_v3_2 IS NULL) AS missing_p50,
  COUNTIF(seasonal_index_same_week IS NULL) AS missing_seas_idx,
  COUNT(*) AS total_records
FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict`;

-- Check 4: State distribution
SELECT 
  'CHECK 4: State distribution' AS check_name,
  sku_season_state,
  COUNT(*) AS n_obs,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) AS pct_total
FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict`
WHERE eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
GROUP BY sku_season_state
ORDER BY n_obs DESC;

-- Check 5: p50_frozen vs actual
SELECT
  'CHECK 5: p50_frozen performance' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  ROUND(AVG(y_true_12w), 2) AS avg_actual,
  ROUND(AVG(p50_frozen_v3_2), 2) AS avg_p50_frozen,
  ROUND(SAFE_DIVIDE(
    SUM(ABS(y_true_12w - p50_frozen_v3_2)),
    SUM(y_true_12w)
  ), 4) AS wmape_all,
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50_frozen_v3_2) END),
    SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
  ), 4) AS wmape_ypos
FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict`
WHERE eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
GROUP BY eval_split_v3
ORDER BY 
  CASE eval_split_v3
    WHEN 'DEV_TUNE' THEN 1
    WHEN 'DEV_SELECT' THEN 2
    WHEN 'LOCKED_TEST' THEN 3
  END;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Expected: ~119,857 records (DEV_TUNE: 33k, DEV_SELECT: 33k, LOCKED_TEST: 54k)' AS expectation;
SELECT 'Next: Phase 2 will calibrate residual spreads on DEV_TUNE' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
