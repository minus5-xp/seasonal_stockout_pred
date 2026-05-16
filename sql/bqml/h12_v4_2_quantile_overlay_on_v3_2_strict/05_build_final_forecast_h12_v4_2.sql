-- ============================================================================
-- PHASE 5: BUILD FINAL FORECAST TABLE (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Apply frozen overlay policy to ALL data (DEV_TUNE, DEV_SELECT, LOCKED_TEST).
--   Generate final quantile forecasts: q80, q90, q95.
--   p50 remains frozen from v3_2.
--
-- INPUTS:
--   - overlay_feature_matrix_h12_v4_2_strict (all splits)
--   - residual_spread_calibration_h12_v4_2_strict
--   - frozen_overlay_policy_h12_v4_2_strict
--
-- OUTPUTS:
--   - forecast_final_h12_v4_2_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict` AS
WITH

frozen_policy AS (
  SELECT 
    method,
    cap_strategy,
    min_n_segment
  FROM `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict`
  LIMIT 1
),

spreads_state AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`
  WHERE segment_level = 'by_state'
),
spreads_season AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`
  WHERE segment_level = 'by_season'
),
spreads_global AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`
  WHERE segment_level = 'global'
  LIMIT 1
),

base_with_spreads AS (
  SELECT
    m.*,
    p.method AS frozen_method,
    p.cap_strategy AS frozen_cap,
    p.min_n_segment AS frozen_min_n,
    -- Hierarchical fallback
    COALESCE(ss.n_obs, sg.n_obs, sglobal.n_obs) AS segment_n_obs,
    COALESCE(ss.zero_regime, sg.zero_regime, sglobal.zero_regime) AS zero_regime,
    COALESCE(ss.q_res_80_abs, sg.q_res_80_abs, sglobal.q_res_80_abs) AS spread_80_abs,
    COALESCE(ss.q_res_90_abs, sg.q_res_90_abs, sglobal.q_res_90_abs) AS spread_90_abs,
    COALESCE(ss.q_res_95_abs, sg.q_res_95_abs, sglobal.q_res_95_abs) AS spread_95_abs,
    COALESCE(ss.q_res_80_log, sg.q_res_80_log, sglobal.q_res_80_log) AS spread_80_log,
    COALESCE(ss.q_res_90_log, sg.q_res_90_log, sglobal.q_res_90_log) AS spread_90_log,
    COALESCE(ss.q_res_95_log, sg.q_res_95_log, sglobal.q_res_95_log) AS spread_95_log,
    COALESCE(ss.hist_p95_segment, sg.hist_p95_segment, sglobal.hist_p95_segment) AS hist_p95_segment,
    sglobal.q_res_80_abs AS spread_80_abs_global,
    sglobal.q_res_90_abs AS spread_90_abs_global,
    sglobal.q_res_95_abs AS spread_95_abs_global,
    sglobal.q_res_80_log AS spread_80_log_global,
    sglobal.q_res_90_log AS spread_90_log_global,
    sglobal.q_res_95_log AS spread_95_log_global
  FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict` m
  CROSS JOIN frozen_policy p
  LEFT JOIN spreads_state ss
    ON m.sku_season_state = ss.state_segment
  LEFT JOIN spreads_season sg
    ON m.season_group = sg.season_group_segment
  CROSS JOIN spreads_global sglobal
),

quantiles_generated AS (
  SELECT
    *,
    p50_frozen_v3_2 AS p50_final,  -- Frozen, never changes
    
    -- q80
    CASE frozen_method
      WHEN 'C1_ABS_SEGMENTED' THEN 
        CASE WHEN segment_n_obs >= frozen_min_n THEN p50_frozen_v3_2 + spread_80_abs ELSE p50_frozen_v3_2 + spread_80_abs_global END
      WHEN 'C2_LOG_SEGMENTED' THEN
        CASE WHEN segment_n_obs >= frozen_min_n 
          THEN GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_80_log) - 1)
          ELSE GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_80_log_global) - 1)
        END
      WHEN 'C3_HYBRID_ZERO_AWARE' THEN
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' THEN
            CASE WHEN segment_n_obs >= frozen_min_n THEN p50_frozen_v3_2 + spread_80_abs ELSE p50_frozen_v3_2 + spread_80_abs_global END
          ELSE
            CASE WHEN segment_n_obs >= frozen_min_n 
              THEN GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_80_log) - 1)
              ELSE GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_80_log_global) - 1)
            END
        END
      WHEN 'C4_MINIMAL_SPREAD' THEN p50_frozen_v3_2 + (spread_80_abs * 0.5)
    END AS q80_raw,
    
    -- q90
    CASE frozen_method
      WHEN 'C1_ABS_SEGMENTED' THEN 
        CASE WHEN segment_n_obs >= frozen_min_n THEN p50_frozen_v3_2 + spread_90_abs ELSE p50_frozen_v3_2 + spread_90_abs_global END
      WHEN 'C2_LOG_SEGMENTED' THEN
        CASE WHEN segment_n_obs >= frozen_min_n 
          THEN GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_90_log) - 1)
          ELSE GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_90_log_global) - 1)
        END
      WHEN 'C3_HYBRID_ZERO_AWARE' THEN
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' THEN
            CASE WHEN segment_n_obs >= frozen_min_n THEN p50_frozen_v3_2 + spread_90_abs ELSE p50_frozen_v3_2 + spread_90_abs_global END
          ELSE
            CASE WHEN segment_n_obs >= frozen_min_n 
              THEN GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_90_log) - 1)
              ELSE GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_90_log_global) - 1)
            END
        END
      WHEN 'C4_MINIMAL_SPREAD' THEN p50_frozen_v3_2 + (spread_90_abs * 0.5)
    END AS q90_raw,
    
    -- q95
    CASE frozen_method
      WHEN 'C1_ABS_SEGMENTED' THEN 
        CASE WHEN segment_n_obs >= frozen_min_n THEN p50_frozen_v3_2 + spread_95_abs ELSE p50_frozen_v3_2 + spread_95_abs_global END
      WHEN 'C2_LOG_SEGMENTED' THEN
        CASE WHEN segment_n_obs >= frozen_min_n 
          THEN GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_95_log) - 1)
          ELSE GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_95_log_global) - 1)
        END
      WHEN 'C3_HYBRID_ZERO_AWARE' THEN
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' THEN
            CASE WHEN segment_n_obs >= frozen_min_n THEN p50_frozen_v3_2 + spread_95_abs ELSE p50_frozen_v3_2 + spread_95_abs_global END
          ELSE
            CASE WHEN segment_n_obs >= frozen_min_n 
              THEN GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_95_log) - 1)
              ELSE GREATEST(0.0, EXP(LN(p50_frozen_v3_2 + 1) + spread_95_log_global) - 1)
            END
        END
      WHEN 'C4_MINIMAL_SPREAD' THEN p50_frozen_v3_2 + (spread_95_abs * 0.5)
    END AS q95_raw
  FROM base_with_spreads
),

capped AS (
  SELECT
    *,
    -- Apply frozen cap strategy
    CASE frozen_cap
      WHEN 'NO_CAP' THEN q80_raw
      WHEN 'CAP_2X' THEN LEAST(q80_raw, GREATEST(p50_final * 2.0, p50_final + COALESCE(hist_p95_segment, 50.0)))
      WHEN 'CAP_3X' THEN LEAST(q80_raw, GREATEST(p50_final * 3.0, p50_final + COALESCE(hist_p95_segment, 50.0)))
    END AS q80_capped,
    CASE frozen_cap
      WHEN 'NO_CAP' THEN q90_raw
      WHEN 'CAP_2X' THEN LEAST(q90_raw, GREATEST(p50_final * 2.0, p50_final + COALESCE(hist_p95_segment, 50.0)))
      WHEN 'CAP_3X' THEN LEAST(q90_raw, GREATEST(p50_final * 3.0, p50_final + COALESCE(hist_p95_segment, 50.0)))
    END AS q90_capped,
    CASE frozen_cap
      WHEN 'NO_CAP' THEN q95_raw
      WHEN 'CAP_2X' THEN LEAST(q95_raw, GREATEST(p50_final * 2.0, p50_final + COALESCE(hist_p95_segment, 50.0)))
      WHEN 'CAP_3X' THEN LEAST(q95_raw, GREATEST(p50_final * 3.0, p50_final + COALESCE(hist_p95_segment, 50.0)))
    END AS q95_capped
  FROM quantiles_generated
)

SELECT
  sku_id,
  decision_week,
  eval_split_v3,
  season_group,
  sku_season_state,
  y_true_12w,
  
  -- FINAL OUTPUTS
  p50_final AS yhat_p50_v4_2_12w,
  GREATEST(p50_final, q80_capped) AS q80_v4_2_12w,
  GREATEST(p50_final, q80_capped, q90_capped) AS q90_v4_2_12w,
  GREATEST(p50_final, q80_capped, q90_capped, q95_capped) AS q95_v4_2_12w,
  
  -- Spreads
  GREATEST(p50_final, q80_capped) - p50_final AS spread80_v4_2,
  GREATEST(p50_final, q80_capped, q90_capped) - p50_final AS spread90_v4_2,
  GREATEST(p50_final, q80_capped, q90_capped, q95_capped) - p50_final AS spread95_v4_2,
  
  -- Metadata
  frozen_method AS overlay_method,
  frozen_cap AS cap_strategy,
  frozen_min_n AS min_n_segment,
  zero_regime,
  segment_n_obs AS conformal_segment_n_obs,
  'h12_v4_2_quantile_overlay_on_v3_2_strict' AS model_version,
  CURRENT_TIMESTAMP() AS forecast_created_at
  
FROM capped;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 5 Complete: Final Forecast Table Built' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Forecast summary by split' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  ROUND(AVG(yhat_p50_v4_2_12w), 2) AS avg_p50,
  ROUND(AVG(q90_v4_2_12w), 2) AS avg_q90,
  ROUND(AVG(spread90_v4_2), 2) AS avg_spread90,
  ROUND(AVG(CASE WHEN q80_v4_2_12w < yhat_p50_v4_2_12w OR q90_v4_2_12w < q80_v4_2_12w OR q95_v4_2_12w < q90_v4_2_12w THEN 1.0 ELSE 0.0 END), 4) AS mono_viol_rate
FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
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
SELECT 'Next: Phase 6 will compute final LOCKED_TEST metrics' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
