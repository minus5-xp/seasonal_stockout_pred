-- ============================================================================
-- PHASE 2: CALIBRATE RESIDUAL SPREADS ON DEV_TUNE (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Compute empirical quantiles of upper residuals by segment on DEV_TUNE.
--   residual_upper = max(y_true - p50_frozen, 0)
--   residual_upper_log = max(ln(1+y_true) - ln(1+p50_frozen), 0)
--
--   Hierarchical segments: state → season → global
--   Test multiple min_n_segment thresholds: 300, 500, 1000
--
-- INPUTS:
--   - overlay_feature_matrix_h12_v4_2_strict (DEV_TUNE only)
--
-- OUTPUTS:
--   - residual_spread_calibration_h12_v4_2_strict
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Compute residuals on DEV_TUNE
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_residuals_dev_tune_h12_v4_2` AS
SELECT
  sku_id,
  decision_week,
  season_group,
  sku_season_state,
  y_true_12w,
  p50_frozen_v3_2,
  -- Upper residuals (for overprediction protection)
  GREATEST(y_true_12w - p50_frozen_v3_2, 0.0) AS residual_upper_abs,
  GREATEST(LN(1 + y_true_12w) - LN(1 + p50_frozen_v3_2), 0.0) AS residual_upper_log,
  -- Zero rate flag
  CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END AS is_zero
FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict`
WHERE eval_split_v3 = 'DEV_TUNE';

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Calibrate spreads by STATE (most granular)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_spreads_by_state_h12_v4_2` AS
SELECT
  'by_state' AS segment_level,
  CAST(NULL AS STRING) AS season_group_segment,
  sku_season_state AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  COUNT(*) AS n_obs,
  AVG(is_zero) AS zero_rate,
  -- Absolute residual quantiles
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(95)] AS q_res_95_abs,
  -- Log residual quantiles
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(95)] AS q_res_95_log,
  -- Historical reference percentiles
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(90)] AS hist_p90_segment,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(95)] AS hist_p95_segment,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS hist_p99_segment
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_dev_tune_h12_v4_2`
GROUP BY sku_season_state;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 3: Calibrate spreads by SEASON (medium granularity)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_spreads_by_season_h12_v4_2` AS
SELECT
  'by_season' AS segment_level,
  season_group AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  COUNT(*) AS n_obs,
  AVG(is_zero) AS zero_rate,
  -- Absolute residual quantiles
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(95)] AS q_res_95_abs,
  -- Log residual quantiles
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(95)] AS q_res_95_log,
  -- Historical reference percentiles
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(90)] AS hist_p90_segment,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(95)] AS hist_p95_segment,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS hist_p99_segment
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_dev_tune_h12_v4_2`
GROUP BY season_group;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 4: Calibrate spreads GLOBAL (fallback)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_spreads_global_h12_v4_2` AS
SELECT
  'global' AS segment_level,
  CAST(NULL AS STRING) AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  COUNT(*) AS n_obs,
  AVG(is_zero) AS zero_rate,
  -- Absolute residual quantiles
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_upper_abs, 100)[OFFSET(95)] AS q_res_95_abs,
  -- Log residual quantiles
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_upper_log, 100)[OFFSET(95)] AS q_res_95_log,
  -- Historical reference percentiles
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(90)] AS hist_p90_segment,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(95)] AS hist_p95_segment,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS hist_p99_segment
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_dev_tune_h12_v4_2`;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 5: Union all segments and add zero regime classification
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict` AS
SELECT
  segment_level,
  season_group_segment,
  state_segment,
  -- Zero regime classification
  CASE
    WHEN zero_rate >= 0.80 THEN 'EXTREME_ZERO'
    WHEN zero_rate >= 0.65 THEN 'HIGH_ZERO'
    WHEN zero_rate >= 0.50 THEN 'MODERATE_ZERO'
    ELSE 'LOW_ZERO'
  END AS zero_regime,
  n_obs,
  zero_rate,
  q_res_80_abs,
  q_res_90_abs,
  q_res_95_abs,
  q_res_80_log,
  q_res_90_log,
  q_res_95_log,
  hist_p90_segment,
  hist_p95_segment,
  hist_p99_segment,
  CURRENT_TIMESTAMP() AS calibrated_at
FROM (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu._temp_spreads_by_state_h12_v4_2`
  UNION ALL
  SELECT * FROM `thequantitativeledger.cruzber_models_eu._temp_spreads_by_season_h12_v4_2`
  UNION ALL
  SELECT * FROM `thequantitativeledger.cruzber_models_eu._temp_spreads_global_h12_v4_2`
);

-- Cleanup
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_residuals_dev_tune_h12_v4_2`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_spreads_by_state_h12_v4_2`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_spreads_by_season_h12_v4_2`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_spreads_global_h12_v4_2`;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 2 Complete: Residual Spreads Calibrated on DEV_TUNE' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Summary
SELECT
  segment_level,
  COUNT(*) AS n_segments,
  SUM(n_obs) AS total_obs,
  ROUND(AVG(zero_rate), 3) AS avg_zero_rate,
  ROUND(AVG(q_res_90_abs), 2) AS avg_spread_90_abs,
  ROUND(AVG(q_res_90_log), 3) AS avg_spread_90_log
FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`
GROUP BY segment_level
ORDER BY 
  CASE segment_level
    WHEN 'by_state' THEN 1
    WHEN 'by_season' THEN 2
    WHEN 'global' THEN 3
  END;

-- Sample spreads by state
SELECT
  'Sample spreads by state' AS sample_name,
  state_segment,
  zero_regime,
  n_obs,
  ROUND(zero_rate, 3) AS zero_rate,
  ROUND(q_res_80_abs, 2) AS s80_abs,
  ROUND(q_res_90_abs, 2) AS s90_abs,
  ROUND(q_res_95_abs, 2) AS s95_abs,
  ROUND(q_res_90_log, 3) AS s90_log
FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`
WHERE segment_level = 'by_state'
ORDER BY n_obs DESC
LIMIT 10;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 3 will apply overlay candidates on DEV_SELECT' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
