-- ============================================================================
-- PHASE 3: CALIBRATE SEGMENTED RESIDUAL SPREADS (Layer B: h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   For each point forecast candidate (A0-A3), compute residuals on DEV_TUNE
--   and calibrate empirical quantiles by segment hierarchy:
--     1. state (sku_season_state) - most granular
--     2. season_group (HIGH_SEASON, REST) - fallback
--     3. global - final fallback
--
--   Store both absolute and ln(1+x) versions to support different spread methods.
--   These spreads will be applied in Phase 4 to create conformal quantile candidates.
--
-- INPUTS:
--   - point_forecast_candidates_h12_v4_1_strict
--
-- OUTPUTS:
--   - residual_spread_calibration_h12_v4_1_strict
--     (one row per candidate × segment, with q50/q80/q90/q95 residual spreads)
--
-- ANTI-LEAKAGE:
--   - All spreads calibrated only on DEV_TUNE
--   - No LOCKED_TEST data used
--   - Minimum n_obs thresholds enforced (50 for state, 200 for season_group)
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Compute residuals for all 4 point forecast candidates on DEV_TUNE
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1` AS
SELECT
  sku_id,
  decision_week,
  season_group,
  sku_season_state,
  zero_regime,
  y_true_12w,
  -- A0 residuals
  p50_A0_BASE AS p50_A0,
  GREATEST(0.0, y_true_12w - p50_A0_BASE) AS residual_abs_A0,
  LN(1 + GREATEST(0.0, y_true_12w - p50_A0_BASE)) AS residual_log_A0,
  -- A1 residuals
  p50_A1_V3_2_GATED AS p50_A1,
  GREATEST(0.0, y_true_12w - p50_A1_V3_2_GATED) AS residual_abs_A1,
  LN(1 + GREATEST(0.0, y_true_12w - p50_A1_V3_2_GATED)) AS residual_log_A1,
  -- A2 residuals
  p50_A2_ZERO_AWARE_SHRINK AS p50_A2,
  GREATEST(0.0, y_true_12w - p50_A2_ZERO_AWARE_SHRINK) AS residual_abs_A2,
  LN(1 + GREATEST(0.0, y_true_12w - p50_A2_ZERO_AWARE_SHRINK)) AS residual_log_A2,
  -- A3 residuals
  p50_A3_HURDLE_CONSERVATIVE AS p50_A3,
  GREATEST(0.0, y_true_12w - p50_A3_HURDLE_CONSERVATIVE) AS residual_abs_A3,
  LN(1 + GREATEST(0.0, y_true_12w - p50_A3_HURDLE_CONSERVATIVE)) AS residual_log_A3
FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
WHERE eval_split_v3 = 'DEV_TUNE';

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Calibrate empirical quantiles by sku_season_state (most granular)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_spreads_by_state_h12_v4_1` AS
SELECT
  'by_state' AS segment_level,
  sku_season_state AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  sku_season_state AS state_segment,
  zero_regime,
  -- A0 spreads
  'A0_BASE' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY sku_season_state, zero_regime
HAVING COUNT(*) >= 50  -- Minimum threshold

UNION ALL

SELECT
  'by_state' AS segment_level,
  sku_season_state AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  sku_season_state AS state_segment,
  zero_regime,
  'A1_V3_2_GATED' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY sku_season_state, zero_regime
HAVING COUNT(*) >= 50

UNION ALL

SELECT
  'by_state' AS segment_level,
  sku_season_state AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  sku_season_state AS state_segment,
  zero_regime,
  'A2_ZERO_AWARE_SHRINK' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY sku_season_state, zero_regime
HAVING COUNT(*) >= 50

UNION ALL

SELECT
  'by_state' AS segment_level,
  sku_season_state AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  sku_season_state AS state_segment,
  zero_regime,
  'A3_HURDLE_CONSERVATIVE' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY sku_season_state, zero_regime
HAVING COUNT(*) >= 50;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 3: Calibrate empirical quantiles by season_group (fallback)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_spreads_by_season_h12_v4_1` AS
SELECT
  'by_season' AS segment_level,
  season_group AS segment_key,
  season_group AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  zero_regime,
  'A0_BASE' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY season_group, zero_regime
HAVING COUNT(*) >= 200

UNION ALL

SELECT
  'by_season' AS segment_level,
  season_group AS segment_key,
  season_group AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  zero_regime,
  'A1_V3_2_GATED' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY season_group, zero_regime
HAVING COUNT(*) >= 200

UNION ALL

SELECT
  'by_season' AS segment_level,
  season_group AS segment_key,
  season_group AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  zero_regime,
  'A2_ZERO_AWARE_SHRINK' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY season_group, zero_regime
HAVING COUNT(*) >= 200

UNION ALL

SELECT
  'by_season' AS segment_level,
  season_group AS segment_key,
  season_group AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  zero_regime,
  'A3_HURDLE_CONSERVATIVE' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`
GROUP BY season_group, zero_regime
HAVING COUNT(*) >= 200;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 4: Calibrate global fallback (used when segment has insufficient data)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_spreads_global_h12_v4_1` AS
SELECT
  'global' AS segment_level,
  'GLOBAL' AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  'A0_BASE' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A0, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A0, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`

UNION ALL

SELECT
  'global' AS segment_level,
  'GLOBAL' AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  'A1_V3_2_GATED' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A1, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A1, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`

UNION ALL

SELECT
  'global' AS segment_level,
  'GLOBAL' AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  'A2_ZERO_AWARE_SHRINK' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A2, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A2, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`

UNION ALL

SELECT
  'global' AS segment_level,
  'GLOBAL' AS segment_key,
  CAST(NULL AS STRING) AS season_group_segment,
  CAST(NULL AS STRING) AS state_segment,
  CAST(NULL AS STRING) AS zero_regime,
  'A3_HURDLE_CONSERVATIVE' AS candidate,
  COUNT(*) AS n_obs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(50)] AS q_res_50_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(80)] AS q_res_80_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(90)] AS q_res_90_abs,
  APPROX_QUANTILES(residual_abs_A3, 100)[OFFSET(95)] AS q_res_95_abs,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(50)] AS q_res_50_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(80)] AS q_res_80_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(90)] AS q_res_90_log,
  APPROX_QUANTILES(residual_log_A3, 100)[OFFSET(95)] AS q_res_95_log
FROM `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 5: Combine all levels and enforce monotonicity
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict` AS
WITH

combined AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu._temp_spreads_by_state_h12_v4_1`
  UNION ALL
  SELECT * FROM `thequantitativeledger.cruzber_models_eu._temp_spreads_by_season_h12_v4_1`
  UNION ALL
  SELECT * FROM `thequantitativeledger.cruzber_models_eu._temp_spreads_global_h12_v4_1`
),

monotonic AS (
  SELECT
    *,
    -- Enforce monotonicity: q80 >= q50, q90 >= q80, q95 >= q90
    GREATEST(q_res_50_abs, 0.0) AS q_res_50_abs_mono,
    GREATEST(q_res_80_abs, q_res_50_abs, 0.0) AS q_res_80_abs_mono,
    GREATEST(q_res_90_abs, q_res_80_abs, q_res_50_abs, 0.0) AS q_res_90_abs_mono,
    GREATEST(q_res_95_abs, q_res_90_abs, q_res_80_abs, q_res_50_abs, 0.0) AS q_res_95_abs_mono,
    -- Same for log
    GREATEST(q_res_50_log, 0.0) AS q_res_50_log_mono,
    GREATEST(q_res_80_log, q_res_50_log, 0.0) AS q_res_80_log_mono,
    GREATEST(q_res_90_log, q_res_80_log, q_res_50_log, 0.0) AS q_res_90_log_mono,
    GREATEST(q_res_95_log, q_res_90_log, q_res_80_log, q_res_50_log, 0.0) AS q_res_95_log_mono,
    CURRENT_TIMESTAMP() AS created_at
  FROM combined
)

SELECT * FROM monotonic
ORDER BY candidate, segment_level, segment_key;

-- Cleanup temp tables
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_residuals_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_spreads_by_state_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_spreads_by_season_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_spreads_global_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Validation: Spread summary
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 3 Complete: Residual Spreads Calibrated' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Count segments per candidate and level
SELECT
  candidate,
  segment_level,
  COUNT(*) AS n_segments,
  SUM(n_obs) AS total_obs
FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict`
GROUP BY candidate, segment_level
ORDER BY candidate, segment_level;

-- Sample spreads for A1_V3_2_GATED (baseline) by state
SELECT
  'Sample spreads (A1_V3_2_GATED by state)' AS sample_name,
  state_segment,
  n_obs,
  ROUND(q_res_50_abs_mono, 2) AS q50_abs,
  ROUND(q_res_80_abs_mono, 2) AS q80_abs,
  ROUND(q_res_90_abs_mono, 2) AS q90_abs,
  ROUND(q_res_95_abs_mono, 2) AS q95_abs
FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict`
WHERE candidate = 'A1_V3_2_GATED'
  AND segment_level = 'by_state'
ORDER BY n_obs DESC
LIMIT 10;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 4 will apply spreads to create A×B quantile candidates' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
