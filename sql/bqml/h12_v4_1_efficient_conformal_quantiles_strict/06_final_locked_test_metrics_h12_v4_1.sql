-- ============================================================================
-- PHASE 6: FINAL LOCKED_TEST METRICS (h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   Apply frozen policy to LOCKED_TEST (one-time use) and report final metrics.
--   This is the true out-of-sample evaluation.
--
-- INPUTS:
--   - frozen_efficient_policy_h12_v4_1_strict (winner candidate)
--   - conformal_quantile_candidates_h12_v4_1_strict (predictions)
--
-- OUTPUTS:
--   - final_locked_test_metrics_h12_v4_1_strict (3 levels: global, season, state)
--
-- ANTI-LEAKAGE:
--   - This is ONE-TIME evaluation on LOCKED_TEST
--   - NO calibration, NO selection, NO tuning based on these results
--   - Results are for reporting only
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_1_strict` AS
WITH

frozen_policy AS (
  SELECT 
    frozen_candidate_id,
    spread_method,
    point_candidate
  FROM `thequantitativeledger.cruzber_models_eu.frozen_efficient_policy_h12_v4_1_strict`
),

-- Get spreads for the frozen candidate's point forecast
spreads_by_state AS (
  SELECT * 
  FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict` 
  WHERE segment_level = 'by_state'
),
spreads_by_season AS (
  SELECT * 
  FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict` 
  WHERE segment_level = 'by_season'
),
spreads_global AS (
  SELECT * 
  FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_1_strict` 
  WHERE segment_level = 'global'
),

-- Get LOCKED_TEST predictions with spreads applied
locked_test_data AS (
  SELECT
    p.*,
    f.frozen_candidate_id,
    f.spread_method,
    f.point_candidate,
    -- Select the correct point forecast
    CASE f.point_candidate
      WHEN 'A0_BASE' THEN p.p50_A0_BASE
      WHEN 'A1_V3_2_GATED' THEN p.p50_A1_V3_2_GATED
      WHEN 'A2_ZERO_AWARE_SHRINK' THEN p.p50_A2_ZERO_AWARE_SHRINK
      WHEN 'A3_HURDLE_CONSERVATIVE' THEN p.p50_A3_HURDLE_CONSERVATIVE
    END AS final_p50,
    -- Get spreads with hierarchical fallback (state → season → global)
    COALESCE(ss.q_res_80_abs, sg.q_res_80_abs, sglobal.q_res_80_abs) AS q_res_80_abs,
    COALESCE(ss.q_res_90_abs, sg.q_res_90_abs, sglobal.q_res_90_abs) AS q_res_90_abs,
    COALESCE(ss.q_res_95_abs, sg.q_res_95_abs, sglobal.q_res_95_abs) AS q_res_95_abs,
    COALESCE(ss.q_res_80_log, sg.q_res_80_log, sglobal.q_res_80_log) AS q_res_80_log,
    COALESCE(ss.q_res_90_log, sg.q_res_90_log, sglobal.q_res_90_log) AS q_res_90_log,
    COALESCE(ss.q_res_95_log, sg.q_res_95_log, sglobal.q_res_95_log) AS q_res_95_log
  FROM `thequantitativeledger.cruzber_models_eu.point_forecast_candidates_h12_v4_1_strict` p
  CROSS JOIN frozen_policy f
  LEFT JOIN spreads_by_state ss
    ON p.sku_season_state = ss.state_segment
    AND ss.candidate = f.point_candidate
  LEFT JOIN spreads_by_season sg
    ON p.season_group = sg.season_group_segment
    AND sg.candidate = f.point_candidate
  LEFT JOIN spreads_global sglobal
    ON sglobal.candidate = f.point_candidate
  WHERE p.eval_split_v3 = 'LOCKED_TEST'
),

-- Apply spread method to generate final quantiles
locked_test_with_quantiles AS (
  SELECT
    *,
    CASE spread_method
      WHEN 'B1_ABS_RESIDUAL' THEN final_p50 + q_res_80_abs
      WHEN 'B2_LOG_RESIDUAL' THEN GREATEST(0.0, EXP(LN(final_p50 + 1) + q_res_80_log) - 1)
      WHEN 'B3_HYBRID_ADAPTIVE' THEN 
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' 
            THEN final_p50 + q_res_80_abs
          ELSE GREATEST(0.0, EXP(LN(final_p50 + 1) + q_res_80_log) - 1)
        END
      WHEN 'B4_CONFORMAL_CALIBRATED' THEN final_p50 + (q_res_80_abs * 0.8)
    END AS final_p80,
    CASE spread_method
      WHEN 'B1_ABS_RESIDUAL' THEN final_p50 + q_res_90_abs
      WHEN 'B2_LOG_RESIDUAL' THEN GREATEST(0.0, EXP(LN(final_p50 + 1) + q_res_90_log) - 1)
      WHEN 'B3_HYBRID_ADAPTIVE' THEN 
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' 
            THEN final_p50 + q_res_90_abs
          ELSE GREATEST(0.0, EXP(LN(final_p50 + 1) + q_res_90_log) - 1)
        END
      WHEN 'B4_CONFORMAL_CALIBRATED' THEN final_p50 + (q_res_90_abs * 0.8)
    END AS final_p90,
    CASE spread_method
      WHEN 'B1_ABS_RESIDUAL' THEN final_p50 + q_res_95_abs
      WHEN 'B2_LOG_RESIDUAL' THEN GREATEST(0.0, EXP(LN(final_p50 + 1) + q_res_95_log) - 1)
      WHEN 'B3_HYBRID_ADAPTIVE' THEN 
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' 
            THEN final_p50 + q_res_95_abs
          ELSE GREATEST(0.0, EXP(LN(final_p50 + 1) + q_res_95_log) - 1)
        END
      WHEN 'B4_CONFORMAL_CALIBRATED' THEN final_p50 + (q_res_95_abs * 0.8)
    END AS final_p95
  FROM locked_test_data
),

-- Global metrics
metrics_global AS (
  SELECT
    'v4_1_global' AS metric_level,
    CAST(NULL AS STRING) AS season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    AVG(y_true_12w) AS mean_actual,
    AVG(final_p50) AS mean_pred,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - final_p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - final_p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(final_p50) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(ABS(y_true_12w - final_p50)) AS mae,
    AVG(CASE WHEN y_true_12w = 0 AND final_p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN final_p50 END) AS avg_pred_when_y_zero,
    AVG(CASE WHEN y_true_12w > final_p80 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > final_p90 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > final_p95 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN final_p80 < final_p50 OR final_p90 < final_p80 OR final_p95 < final_p90 THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate,
    AVG(final_p90 - final_p50) AS avg_spread_p50_to_p90
  FROM locked_test_with_quantiles
),

-- By season_group
metrics_season AS (
  SELECT
    'v4_1_by_season' AS metric_level,
    season_group,
    CAST(NULL AS STRING) AS sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    AVG(y_true_12w) AS mean_actual,
    AVG(final_p50) AS mean_pred,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - final_p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - final_p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(final_p50) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(ABS(y_true_12w - final_p50)) AS mae,
    AVG(CASE WHEN y_true_12w = 0 AND final_p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN final_p50 END) AS avg_pred_when_y_zero,
    AVG(CASE WHEN y_true_12w > final_p80 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > final_p90 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > final_p95 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN final_p80 < final_p50 OR final_p90 < final_p80 OR final_p95 < final_p90 THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate,
    AVG(final_p90 - final_p50) AS avg_spread_p50_to_p90
  FROM locked_test_with_quantiles
  GROUP BY season_group
),

-- By sku_season_state (top states)
metrics_state AS (
  SELECT
    'v4_1_by_state' AS metric_level,
    CAST(NULL AS STRING) AS season_group,
    sku_season_state,
    COUNT(*) AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    AVG(y_true_12w) AS mean_actual,
    AVG(final_p50) AS mean_pred,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - final_p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - final_p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(final_p50) - SUM(y_true_12w)), SUM(y_true_12w)) * 100 AS bias_pct,
    AVG(ABS(y_true_12w - final_p50)) AS mae,
    AVG(CASE WHEN y_true_12w = 0 AND final_p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN final_p50 END) AS avg_pred_when_y_zero,
    AVG(CASE WHEN y_true_12w > final_p80 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > final_p90 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > final_p95 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN final_p80 < final_p50 OR final_p90 < final_p80 OR final_p95 < final_p90 THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate,
    AVG(final_p90 - final_p50) AS avg_spread_p50_to_p90
  FROM locked_test_with_quantiles
  GROUP BY sku_season_state
)

SELECT * FROM metrics_global
UNION ALL SELECT * FROM metrics_season
UNION ALL SELECT * FROM metrics_state
ORDER BY metric_level, season_group, sku_season_state;

-- ──────────────────────────────────────────────────────────────────────────
-- Display results
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 6 Complete: LOCKED_TEST Evaluation (ONE-TIME USE)' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Global summary
SELECT
  'LOCKED_TEST Global Metrics' AS summary,
  COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
  n_obs,
  ROUND(wmape_all, 3) AS wmape_all,
  ROUND(wmape_ypos, 3) AS wmape_ypos,
  ROUND(bias_pct, 1) AS bias_pct,
  ROUND(zero_overforecast_rate, 3) AS zero_overf,
  ROUND(viol_p80, 3) AS viol_p80,
  ROUND(viol_p90, 3) AS viol_p90,
  ROUND(viol_p95, 3) AS viol_p95,
  ROUND(avg_spread_p50_to_p90, 2) AS avg_spread
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_1_strict`
ORDER BY metric_level, n_obs DESC;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 7 will compare v3_2 vs v4_1 results' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
