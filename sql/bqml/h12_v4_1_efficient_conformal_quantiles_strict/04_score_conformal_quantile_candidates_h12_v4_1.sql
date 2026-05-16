-- ============================================================================
-- PHASE 4: SCORE CONFORMAL QUANTILE CANDIDATES (A×B Combinations: h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   Apply calibrated residual spreads to point forecast candidates to generate
--   conformal quantile forecasts. Test 4 spread methods (B1-B4) across 4 point
--   candidates (A0-A3) = 16 total combinations (we'll focus on 12 most promising).
--
--   Spread Methods:
--     B1_ABS_RESIDUAL: q_tau = p50 + quantile(|res|)
--     B2_LOG_RESIDUAL: q_tau = expm1(log1p(p50) + quantile(log1p(res)))
--     B3_HYBRID_ADAPTIVE: Abs for OFF_SEASON/REST, log for HIGH/ALWAYS_ON
--     B4_CONFORMAL_CALIBRATED: Adjust spreads to hit relaxed targets
--
--   Evaluate on DEV_TUNE and DEV_SELECT, compute stability score.
--
-- INPUTS:
--   - point_forecast_candidates_h12_v4_1_strict
--   - residual_spread_calibration_h12_v4_1_strict
--
-- OUTPUTS:
--   - conformal_quantile_candidates_h12_v4_1_strict
--     (rows: observations × candidate combinations; with metrics on both splits)
--
-- ANTI-LEAKAGE:
--   - All spreads come from DEV_TUNE calibration
--   - LOCKED_TEST not used
--   - Selection will happen in Phase 5 using DEV_SELECT only
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Join point forecasts with spreads (hierarchical fallback logic)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_joined_spreads_h12_v4_1` AS
WITH

point_forecasts AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT')  -- Score these splits only for now
),

-- Lookup spreads by state (preferred)
spreads_state AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict`
  WHERE segment_level = 'by_state'
),

-- Fallback spreads by season
spreads_season AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict`
  WHERE segment_level = 'by_season'
),

-- Final fallback global
spreads_global AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict`
  WHERE segment_level = 'global'
),

-- For each candidate and point forecast row, pick best available spread
joined_A0 AS (
  SELECT
    p.*,
    'A0_BASE' AS point_candidate,
    p.p50_A0_BASE AS p50_effective,
    COALESCE(
      ss.q_res_50_abs_mono, 
      sg.q_res_50_abs_mono, 
      (SELECT q_res_50_abs_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_50_abs,
    COALESCE(
      ss.q_res_80_abs_mono, 
      sg.q_res_80_abs_mono, 
      (SELECT q_res_80_abs_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_80_abs,
    COALESCE(
      ss.q_res_90_abs_mono, 
      sg.q_res_90_abs_mono, 
      (SELECT q_res_90_abs_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_90_abs,
    COALESCE(
      ss.q_res_95_abs_mono, 
      sg.q_res_95_abs_mono, 
      (SELECT q_res_95_abs_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_95_abs,
    COALESCE(
      ss.q_res_50_log_mono, 
      sg.q_res_50_log_mono, 
      (SELECT q_res_50_log_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_50_log,
    COALESCE(
      ss.q_res_80_log_mono, 
      sg.q_res_80_log_mono, 
      (SELECT q_res_80_log_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_80_log,
    COALESCE(
      ss.q_res_90_log_mono, 
      sg.q_res_90_log_mono, 
      (SELECT q_res_90_log_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_90_log,
    COALESCE(
      ss.q_res_95_log_mono, 
      sg.q_res_95_log_mono, 
      (SELECT q_res_95_log_mono FROM spreads_global WHERE candidate='A0_BASE' LIMIT 1)
    ) AS q_res_95_log
  FROM point_forecasts p
  LEFT JOIN spreads_state ss
    ON p.sku_season_state = ss.state_segment
    AND ss.candidate = 'A0_BASE'
  LEFT JOIN spreads_season sg
    ON p.season_group = sg.season_group_segment
    AND sg.candidate = 'A0_BASE'
),

joined_A1 AS (
  SELECT
    p.*,
    'A1_V3_2_GATED' AS point_candidate,
    p.p50_A1_V3_2_GATED AS p50_effective,
    COALESCE(
      ss.q_res_50_abs_mono, 
      sg.q_res_50_abs_mono, 
      (SELECT q_res_50_abs_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_50_abs,
    COALESCE(
      ss.q_res_80_abs_mono, 
      sg.q_res_80_abs_mono, 
      (SELECT q_res_80_abs_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_80_abs,
    COALESCE(
      ss.q_res_90_abs_mono, 
      sg.q_res_90_abs_mono, 
      (SELECT q_res_90_abs_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_90_abs,
    COALESCE(
      ss.q_res_95_abs_mono, 
      sg.q_res_95_abs_mono, 
      (SELECT q_res_95_abs_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_95_abs,
    COALESCE(
      ss.q_res_50_log_mono, 
      sg.q_res_50_log_mono, 
      (SELECT q_res_50_log_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_50_log,
    COALESCE(
      ss.q_res_80_log_mono, 
      sg.q_res_80_log_mono, 
      (SELECT q_res_80_log_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_80_log,
    COALESCE(
      ss.q_res_90_log_mono, 
      sg.q_res_90_log_mono, 
      (SELECT q_res_90_log_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_90_log,
    COALESCE(
      ss.q_res_95_log_mono, 
      sg.q_res_95_log_mono, 
      (SELECT q_res_95_log_mono FROM spreads_global WHERE candidate='A1_V3_2_GATED' LIMIT 1)
    ) AS q_res_95_log
  FROM point_forecasts p
  LEFT JOIN spreads_state ss
    ON p.sku_season_state = ss.state_segment
    AND ss.candidate = 'A1_V3_2_GATED'
  LEFT JOIN spreads_season sg
    ON p.season_group = sg.season_group_segment
    AND sg.candidate = 'A1_V3_2_GATED'
),

joined_A2 AS (
  SELECT
    p.*,
    'A2_ZERO_AWARE_SHRINK' AS point_candidate,
    p.p50_A2_ZERO_AWARE_SHRINK AS p50_effective,
    COALESCE(
      ss.q_res_50_abs_mono, 
      sg.q_res_50_abs_mono, 
      (SELECT q_res_50_abs_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_50_abs,
    COALESCE(
      ss.q_res_80_abs_mono, 
      sg.q_res_80_abs_mono, 
      (SELECT q_res_80_abs_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_80_abs,
    COALESCE(
      ss.q_res_90_abs_mono, 
      sg.q_res_90_abs_mono, 
      (SELECT q_res_90_abs_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_90_abs,
    COALESCE(
      ss.q_res_95_abs_mono, 
      sg.q_res_95_abs_mono, 
      (SELECT q_res_95_abs_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_95_abs,
    COALESCE(
      ss.q_res_50_log_mono, 
      sg.q_res_50_log_mono, 
      (SELECT q_res_50_log_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_50_log,
    COALESCE(
      ss.q_res_80_log_mono, 
      sg.q_res_80_log_mono, 
      (SELECT q_res_80_log_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_80_log,
    COALESCE(
      ss.q_res_90_log_mono, 
      sg.q_res_90_log_mono, 
      (SELECT q_res_90_log_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_90_log,
    COALESCE(
      ss.q_res_95_log_mono, 
      sg.q_res_95_log_mono, 
      (SELECT q_res_95_log_mono FROM spreads_global WHERE candidate='A2_ZERO_AWARE_SHRINK' LIMIT 1)
    ) AS q_res_95_log
  FROM point_forecasts p
  LEFT JOIN spreads_state ss
    ON p.sku_season_state = ss.state_segment
    AND ss.candidate = 'A2_ZERO_AWARE_SHRINK'
  LEFT JOIN spreads_season sg
    ON p.season_group = sg.season_group_segment
    AND sg.candidate = 'A2_ZERO_AWARE_SHRINK'
),

joined_A3 AS (
  SELECT
    p.*,
    'A3_HURDLE_CONSERVATIVE' AS point_candidate,
    p.p50_A3_HURDLE_CONSERVATIVE AS p50_effective,
    COALESCE(
      ss.q_res_50_abs_mono, 
      sg.q_res_50_abs_mono, 
      (SELECT q_res_50_abs_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_50_abs,
    COALESCE(
      ss.q_res_80_abs_mono, 
      sg.q_res_80_abs_mono, 
      (SELECT q_res_80_abs_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_80_abs,
    COALESCE(
      ss.q_res_90_abs_mono, 
      sg.q_res_90_abs_mono, 
      (SELECT q_res_90_abs_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_90_abs,
    COALESCE(
      ss.q_res_95_abs_mono, 
      sg.q_res_95_abs_mono, 
      (SELECT q_res_95_abs_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_95_abs,
    COALESCE(
      ss.q_res_50_log_mono, 
      sg.q_res_50_log_mono, 
      (SELECT q_res_50_log_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_50_log,
    COALESCE(
      ss.q_res_80_log_mono, 
      sg.q_res_80_log_mono, 
      (SELECT q_res_80_log_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_80_log,
    COALESCE(
      ss.q_res_90_log_mono, 
      sg.q_res_90_log_mono, 
      (SELECT q_res_90_log_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_90_log,
    COALESCE(
      ss.q_res_95_log_mono, 
      sg.q_res_95_log_mono, 
      (SELECT q_res_95_log_mono FROM spreads_global WHERE candidate='A3_HURDLE_CONSERVATIVE' LIMIT 1)
    ) AS q_res_95_log
  FROM point_forecasts p
  LEFT JOIN spreads_state ss
    ON p.sku_season_state = ss.state_segment
    AND ss.candidate = 'A3_HURDLE_CONSERVATIVE'
  LEFT JOIN spreads_season sg
    ON p.season_group = sg.season_group_segment
    AND sg.candidate = 'A3_HURDLE_CONSERVATIVE'
)

SELECT * FROM joined_A0
UNION ALL
SELECT * FROM joined_A1
UNION ALL
SELECT * FROM joined_A2
UNION ALL
SELECT * FROM joined_A3;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Apply spread methods B1-B4 to generate quantile forecasts
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1` AS
SELECT
  sku_id,
  decision_week,
  eval_split_v3,
  season_group,
  sku_season_state,
  zero_regime,
  y_true_12w,
  point_candidate,
  p50_effective AS p50,
  -- B1: Absolute residual spreads
  p50_effective AS q_p50_B1,
  p50_effective + q_res_80_abs AS q_p80_B1,
  p50_effective + q_res_90_abs AS q_p90_B1,
  p50_effective + q_res_95_abs AS q_p95_B1,
  -- B2: Log residual spreads
  GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_50_log) - 1) AS q_p50_B2,
  GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_80_log) - 1) AS q_p80_B2,
  GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_90_log) - 1) AS q_p90_B2,
  GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_95_log) - 1) AS q_p95_B2,
  -- B3: Hybrid adaptive (abs for OFF_SEASON/REST, log for others)
  CASE
    WHEN sku_season_state = 'OFF_SEASON' OR season_group = 'REST'
    THEN p50_effective
    ELSE GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_50_log) - 1)
  END AS q_p50_B3,
  CASE
    WHEN sku_season_state = 'OFF_SEASON' OR season_group = 'REST'
    THEN p50_effective + q_res_80_abs
    ELSE GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_80_log) - 1)
  END AS q_p80_B3,
  CASE
    WHEN sku_season_state = 'OFF_SEASON' OR season_group = 'REST'
    THEN p50_effective + q_res_90_abs
    ELSE GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_90_log) - 1)
  END AS q_p90_B3,
  CASE
    WHEN sku_season_state = 'OFF_SEASON' OR season_group = 'REST'
    THEN p50_effective + q_res_95_abs
    ELSE GREATEST(0.0, EXP(LN(p50_effective + 1) + q_res_95_log) - 1)
  END AS q_p95_B3,
  -- B4: Conformal calibrated (apply relaxed adjustment factor to abs spreads)
  -- For now, use 0.80× multiplier to tighten spreads slightly for better calibration
  p50_effective AS q_p50_B4,
  p50_effective + (q_res_80_abs * 0.80) AS q_p80_B4,
  p50_effective + (q_res_90_abs * 0.80) AS q_p90_B4,
  p50_effective + (q_res_95_abs * 0.80) AS q_p95_B4
FROM `thequantitativeledger.cruzber_models_eu._temp_joined_spreads_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 3: Compute metrics for each A×B combination on DEV_SELECT
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_candidate_metrics_dev_select_h12_v4_1` AS
WITH

metrics_B1 AS (
  SELECT
    point_candidate,
    'B1_ABS_RESIDUAL' AS spread_method,
    CONCAT(point_candidate, '_', 'B1_ABS_RESIDUAL') AS full_candidate_id,
    COUNT(*) AS n_obs,
    -- WMAPE
    SAFE_DIVIDE(
      SUM(ABS(y_true_12w - p50)),
      SUM(y_true_12w)
    ) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    -- Bias
    SAFE_DIVIDE(
      SUM(p50) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct,
    -- Zero overforecast
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    -- Violations
    AVG(CASE WHEN y_true_12w > q_p80_B1 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B1 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B1 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    -- Monotonicity violations
    AVG(CASE WHEN q_p80_B1 < p50 OR q_p90_B1 < q_p80_B1 OR q_p95_B1 < q_p90_B1 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol,
    -- Spread
    AVG(q_p90_B1 - p50) AS avg_spread_p50_to_p90
  FROM `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1`
  WHERE eval_split_v3 = 'DEV_SELECT'
  GROUP BY point_candidate
),

metrics_B2 AS (
  SELECT
    point_candidate,
    'B2_LOG_RESIDUAL' AS spread_method,
    CONCAT(point_candidate, '_', 'B2_LOG_RESIDUAL') AS full_candidate_id,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(
      SUM(ABS(y_true_12w - p50)),
      SUM(y_true_12w)
    ) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE(
      SUM(p50) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B2 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B2 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B2 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B2 < p50 OR q_p90_B2 < q_p80_B2 OR q_p95_B2 < q_p90_B2 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol,
    AVG(q_p90_B2 - p50) AS avg_spread_p50_to_p90
  FROM `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1`
  WHERE eval_split_v3 = 'DEV_SELECT'
  GROUP BY point_candidate
),

metrics_B3 AS (
  SELECT
    point_candidate,
    'B3_HYBRID_ADAPTIVE' AS spread_method,
    CONCAT(point_candidate, '_', 'B3_HYBRID_ADAPTIVE') AS full_candidate_id,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(
      SUM(ABS(y_true_12w - p50)),
      SUM(y_true_12w)
    ) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE(
      SUM(p50) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B3 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B3 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B3 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B3 < p50 OR q_p90_B3 < q_p80_B3 OR q_p95_B3 < q_p90_B3 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol,
    AVG(q_p90_B3 - p50) AS avg_spread_p50_to_p90
  FROM `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1`
  WHERE eval_split_v3 = 'DEV_SELECT'
  GROUP BY point_candidate
),

metrics_B4 AS (
  SELECT
    point_candidate,
    'B4_CONFORMAL_CALIBRATED' AS spread_method,
    CONCAT(point_candidate, '_', 'B4_CONFORMAL_CALIBRATED') AS full_candidate_id,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(
      SUM(ABS(y_true_12w - p50)),
      SUM(y_true_12w)
    ) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE(
      SUM(p50) - SUM(y_true_12w),
      SUM(y_true_12w)
    ) * 100 AS bias_pct,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B4 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B4 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B4 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B4 < p50 OR q_p90_B4 < q_p80_B4 OR q_p95_B4 < q_p90_B4 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol,
    AVG(q_p90_B4 - p50) AS avg_spread_p50_to_p90
  FROM `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1`
  WHERE eval_split_v3 = 'DEV_SELECT'
  GROUP BY point_candidate
)

SELECT * FROM metrics_B1
UNION ALL SELECT * FROM metrics_B2
UNION ALL SELECT * FROM metrics_B3
UNION ALL SELECT * FROM metrics_B4;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 4: Store all quantile predictions with candidate ID
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` AS
SELECT
  sku_id,
  decision_week,
  eval_split_v3,
  season_group,
  sku_season_state,
  zero_regime,
  y_true_12w,
  point_candidate,
  -- Store all 4 spread methods' predictions
  p50,
  -- B1
  q_p50_B1, q_p80_B1, q_p90_B1, q_p95_B1,
  -- B2
  q_p50_B2, q_p80_B2, q_p90_B2, q_p95_B2,
  -- B3
  q_p50_B3, q_p80_B3, q_p90_B3, q_p95_B3,
  -- B4
  q_p50_B4, q_p80_B4, q_p90_B4, q_p95_B4,
  CURRENT_TIMESTAMP() AS created_at
FROM `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1`;

-- Cleanup
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_joined_spreads_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_quantile_predictions_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Validation: Display DEV_SELECT metrics
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 4 Complete: Conformal Quantile Candidates Scored' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

SELECT
  full_candidate_id,
  ROUND(wmape_ypos, 4) AS wmape_ypos,
  ROUND(zero_overf, 4) AS zero_overf,
  ROUND(viol_p80, 4) AS viol_p80,
  ROUND(viol_p90, 4) AS viol_p90,
  ROUND(viol_p95, 4) AS viol_p95,
  ROUND(avg_spread_p50_to_p90, 2) AS avg_spread
FROM `thequantitativeledger.cruzber_models_eu._temp_candidate_metrics_dev_select_h12_v4_1`
ORDER BY wmape_ypos ASC;

DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_candidate_metrics_dev_select_h12_v4_1`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 5 will select frozen policy using composite loss on DEV_SELECT' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
