-- ============================================================================
-- PHASE 2: BUILD POINT FORECAST CANDIDATES (Layer A: h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   Generate 4 point forecast candidates (p50) using different strategies:
--     A0_BASE: Original BQML p50 without gate (simple baseline)
--     A1_V3_2_GATED: v3_2 gated forecast (benchmark to beat)
--     A2_ZERO_AWARE_SHRINK: v3_2 + additional segment-specific shrink factors
--     A3_HURDLE_CONSERVATIVE: Allow p50=0 when segment evidence supports it
--
--   A2 shrink factors calibrated on DEV_TUNE to minimize:
--     2×WMAPE_ypos + 1×zero_overforecast + 0.5×|bias|
--
--   A3 hurdle logic: If segment_zero_rate >= 80% AND hist_p50_same_week = 0,
--   then allow p50 = 0 (instead of forcing positive prediction).
--
-- INPUTS:
--   - feature_matrix_h12_v4_1_strict
--
-- OUTPUTS:
--   - point_forecast_candidates_h12_v4_1_strict (4 p50 variants per row)
--
-- ANTI-LEAKAGE:
--   - Shrink factors calibrated only on DEV_TUNE
--   - Segment zero rates computed only from DEV_TUNE
--   - No LOCKED_TEST data used in calibration
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Compute segment zero rates from DEV_TUNE only (for regime logic)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_segment_zero_rates_h12_v4_1` AS
SELECT
  season_group,
  sku_season_state,
  COUNT(*) AS n_obs_calib,
  AVG(CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END) AS segment_zero_rate
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`
WHERE eval_split_v3 = 'DEV_TUNE'
GROUP BY season_group, sku_season_state;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Grid search for A2 shrink factors on DEV_TUNE
-- ──────────────────────────────────────────────────────────────────────────
-- We'll test shrink factors: [0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.00]
-- for REST and OFF_SEASON segments specifically.
-- Other segments use shrink=1.00 (no change).
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_shrink_grid_search_h12_v4_1` AS
WITH

shrink_candidates AS (
  SELECT shrink_factor
  FROM UNNEST([0.70, 0.75, 0.80, 0.85, 0.90, 0.95, 1.00]) AS shrink_factor
),

grid_cross AS (
  SELECT
    f.sku_id,
    f.decision_week,
    f.y_true_12w,
    f.season_group,
    f.sku_season_state,
    f.p50_v3_2_gated AS p50_base,
    s.shrink_factor,
    -- Apply shrink only to REST season_group or OFF_SEASON state
    CASE
      WHEN f.season_group = 'REST' OR f.sku_season_state = 'OFF_SEASON'
      THEN f.p50_v3_2_gated * s.shrink_factor
      ELSE f.p50_v3_2_gated
    END AS p50_shrunk
  FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict` f
  CROSS JOIN shrink_candidates s
  WHERE f.eval_split_v3 = 'DEV_TUNE'
),

metrics_per_shrink AS (
  SELECT
    shrink_factor,
    COUNT(*) AS n_obs,
    -- WMAPE on all
    SAFE_DIVIDE(
      SUM(ABS(y_true_12w - p50_shrunk)),
      SUM(y_true_12w)
    ) AS wmape_all,
    -- WMAPE on y>0
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50_shrunk) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    -- Bias
    SAFE_DIVIDE(
      SUM(p50_shrunk) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct,
    -- Zero overforecast
    AVG(CASE WHEN y_true_12w = 0 AND p50_shrunk > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf
  FROM grid_cross
  GROUP BY shrink_factor
),

loss_computed AS (
  SELECT
    *,
    -- Loss function: 2×WMAPE_ypos + 1×zero_overf + 0.5×|bias|
    (2.0 * wmape_ypos) + (1.0 * zero_overf) + (0.5 * ABS(bias_pct / 100.0)) AS loss
  FROM metrics_per_shrink
)

SELECT * FROM loss_computed
ORDER BY loss ASC;

-- Select best shrink factor
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_best_shrink_factor_h12_v4_1` AS
SELECT shrink_factor
FROM `thequantitativeledger.cruzber_models_eu._temp_shrink_grid_search_h12_v4_1`
ORDER BY loss ASC
LIMIT 1;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 3: Build all 4 point forecast candidates
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict` AS
WITH

best_shrink AS (
  SELECT shrink_factor FROM `thequantitativeledger.cruzber_models_eu._temp_best_shrink_factor_h12_v4_1`
)

SELECT
  f.sku_id,
  f.decision_week,
  f.eval_split_v3,
  f.season_group,
  f.sku_season_state,
  f.y_true_12w,
  -- Segment metadata
  z.segment_zero_rate,
  CASE 
    WHEN z.segment_zero_rate >= 0.80 THEN 'EXTREME_ZERO'
    WHEN z.segment_zero_rate >= 0.65 THEN 'HIGH_ZERO'
    WHEN z.segment_zero_rate >= 0.50 THEN 'MODERATE_ZERO'
    ELSE 'LOW_ZERO'
  END AS zero_regime,
  -- A0: Base BQML p50 (no gate, no shrink)
  f.p50_base AS p50_A0_BASE,
  -- A1: v3_2 gated (baseline to beat)
  f.p50_v3_2_gated AS p50_A1_V3_2_GATED,
  -- A2: Zero-aware shrink (apply best shrink to REST / OFF_SEASON)
  CASE
    WHEN f.season_group = 'REST' OR f.sku_season_state = 'OFF_SEASON'
    THEN f.p50_v3_2_gated * (SELECT shrink_factor FROM best_shrink)
    ELSE f.p50_v3_2_gated
  END AS p50_A2_ZERO_AWARE_SHRINK,
  -- A3: Hurdle conservative (allow p50=0 when segment and historical evidence align)
  CASE
    WHEN z.segment_zero_rate >= 0.80 
     AND COALESCE(f.hist_p50_units_same_week, 0) = 0
     AND COALESCE(f.rolling_8w_zero_rate_past, 0) >= 0.70
    THEN 0.0
    ELSE f.p50_v3_2_gated
  END AS p50_A3_HURDLE_CONSERVATIVE,
  -- Store best shrink factor for reference
  (SELECT shrink_factor FROM best_shrink) AS shrink_factor_a2,
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict` f
LEFT JOIN `thequantitativeledger.cruzber_models_eu._temp_segment_zero_rates_h12_v4_1` z
  ON f.season_group = z.season_group
  AND f.sku_season_state = z.sku_season_state;

-- Cleanup temp tables
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_segment_zero_rates_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_shrink_grid_search_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_best_shrink_factor_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Validation: Metrics on DEV_TUNE (calibration set)
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 2 Complete: Point Forecast Candidates Built' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Metrics on DEV_TUNE
WITH

candidate_metrics AS (
  SELECT
    'A0_BASE' AS candidate,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50_A0_BASE) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    AVG(CASE WHEN y_true_12w = 0 AND p50_A0_BASE > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    SAFE_DIVIDE(
      SUM(p50_A0_BASE) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct
  FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_TUNE'
  
  UNION ALL
  
  SELECT
    'A1_V3_2_GATED' AS candidate,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50_A1_V3_2_GATED) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    AVG(CASE WHEN y_true_12w = 0 AND p50_A1_V3_2_GATED > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    SAFE_DIVIDE(
      SUM(p50_A1_V3_2_GATED) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct
  FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_TUNE'
  
  UNION ALL
  
  SELECT
    'A2_ZERO_AWARE_SHRINK' AS candidate,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50_A2_ZERO_AWARE_SHRINK) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    AVG(CASE WHEN y_true_12w = 0 AND p50_A2_ZERO_AWARE_SHRINK > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    SAFE_DIVIDE(
      SUM(p50_A2_ZERO_AWARE_SHRINK) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct
  FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_TUNE'
  
  UNION ALL
  
  SELECT
    'A3_HURDLE_CONSERVATIVE' AS candidate,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50_A3_HURDLE_CONSERVATIVE) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    AVG(CASE WHEN y_true_12w = 0 AND p50_A3_HURDLE_CONSERVATIVE > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    SAFE_DIVIDE(
      SUM(p50_A3_HURDLE_CONSERVATIVE) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct
  FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_TUNE'
)

SELECT
  candidate,
  ROUND(wmape_ypos, 4) AS wmape_ypos,
  ROUND(zero_overf, 4) AS zero_overf,
  ROUND(bias_pct, 2) AS bias_pct
FROM candidate_metrics
ORDER BY wmape_ypos ASC;

-- Check how many predictions became zero in A3
SELECT
  'A3_HURDLE: Zero predictions summary' AS check_name,
  COUNT(*) AS total_obs,
  COUNTIF(p50_A3_HURDLE_CONSERVATIVE = 0) AS n_pred_zero,
  ROUND(COUNTIF(p50_A3_HURDLE_CONSERVATIVE = 0) * 100.0 / COUNT(*), 2) AS pct_pred_zero,
  COUNTIF(p50_A3_HURDLE_CONSERVATIVE = 0 AND y_true_12w = 0) AS n_correct_zero,
  COUNTIF(p50_A3_HURDLE_CONSERVATIVE = 0 AND y_true_12w > 0) AS n_false_zero
FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
WHERE eval_split_v3 = 'DEV_TUNE';

-- Segment zero rates summary
SELECT
  'Segment zero rates (from DEV_TUNE)' AS check_name,
  sku_season_state,
  zero_regime,
  COUNT(DISTINCT sku_id || '_' || decision_week) AS n_obs,
  ROUND(AVG(segment_zero_rate), 3) AS avg_segment_zero_rate
FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
WHERE eval_split_v3 = 'DEV_TUNE'
GROUP BY sku_season_state, zero_regime
ORDER BY avg_segment_zero_rate DESC;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 3 will calibrate residual spreads by segment' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
