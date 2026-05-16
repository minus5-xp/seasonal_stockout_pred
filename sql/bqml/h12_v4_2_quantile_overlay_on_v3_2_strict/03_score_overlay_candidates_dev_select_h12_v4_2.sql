-- ============================================================================
-- PHASE 3: SCORE OVERLAY CANDIDATES ON DEV_SELECT (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Generate 4 overlay methods × 3 cap strategies × 3 min_n configs = 36 candidates
--   Evaluate on DEV_SELECT using coverage and spread efficiency metrics.
--
--   Methods:
--   - C1_ABS_SEGMENTED: q = p50 + spread_abs
--   - C2_LOG_SEGMENTED: q = exp(ln(p50+1) + spread_log) - 1
--   - C3_HYBRID_ZERO_AWARE: ABS for OFF_SEASON/REST, LOG for HIGH/ALWAYS_ON
--   - C4_MINIMAL_SPREAD: Small fixed spreads to avoid collapse
--
--   Caps:
--   - NO_CAP
--   - CAP_2X: q95 <= max(p50*2, p50 + hist_p95)
--   - CAP_3X: q95 <= max(p50*3, p50 + hist_p95)
--
--   min_n_segment: 300, 500, 1000
--
-- INPUTS:
--   - overlay_feature_matrix_h12_v4_2_strict (DEV_SELECT)
--   - residual_spread_calibration_h12_v4_2_strict
--
-- OUTPUTS:
--   - overlay_candidate_scores_dev_select_h12_v4_2_strict
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Join DEV_SELECT data with spreads (hierarchical fallback)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_dev_select_with_spreads_h12_v4_2` AS
WITH

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

joined AS (
  SELECT
    m.*,
    -- Hierarchical fallback: state → season → global
    COALESCE(ss.n_obs, sg.n_obs, sglobal.n_obs) AS segment_n_obs,
    COALESCE(ss.zero_rate, sg.zero_rate, sglobal.zero_rate) AS segment_zero_rate,
    COALESCE(ss.zero_regime, sg.zero_regime, sglobal.zero_regime) AS zero_regime,
    COALESCE(ss.q_res_80_abs, sg.q_res_80_abs, sglobal.q_res_80_abs) AS spread_80_abs,
    COALESCE(ss.q_res_90_abs, sg.q_res_90_abs, sglobal.q_res_90_abs) AS spread_90_abs,
    COALESCE(ss.q_res_95_abs, sg.q_res_95_abs, sglobal.q_res_95_abs) AS spread_95_abs,
    COALESCE(ss.q_res_80_log, sg.q_res_80_log, sglobal.q_res_80_log) AS spread_80_log,
    COALESCE(ss.q_res_90_log, sg.q_res_90_log, sglobal.q_res_90_log) AS spread_90_log,
    COALESCE(ss.q_res_95_log, sg.q_res_95_log, sglobal.q_res_95_log) AS spread_95_log,
    COALESCE(ss.hist_p95_segment, sg.hist_p95_segment, sglobal.hist_p95_segment) AS hist_p95_segment,
    COALESCE(ss.hist_p99_segment, sg.hist_p99_segment, sglobal.hist_p99_segment) AS hist_p99_segment
  FROM `thequantitativeledger.cruzber_models_eu.overlay_feature_matrix_h12_v4_2_strict` m
  LEFT JOIN spreads_state ss
    ON m.sku_season_state = ss.state_segment
  LEFT JOIN spreads_season sg
    ON m.season_group = sg.season_group_segment
  CROSS JOIN spreads_global sglobal
  WHERE m.eval_split_v3 = 'DEV_SELECT'
)

SELECT * FROM joined;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Generate overlay candidates with different configs
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_overlay_predictions_h12_v4_2` AS
WITH

base AS (
  SELECT *,
    p50_frozen_v3_2 AS p50  -- Frozen, never changes
  FROM `thequantitativeledger.cruzber_models_eu._temp_dev_select_with_spreads_h12_v4_2`
),

candidates AS (
  SELECT
    sku_id,
    decision_week,
    season_group,
    sku_season_state,
    y_true_12w,
    p50,
    zero_regime,
    segment_n_obs,
    hist_p95_segment,
    
    -- Generate all combinations: method × cap × min_n
    method,
    cap_strategy,
    min_n_segment,
    
    -- Method-specific quantile generation
    CASE method
      WHEN 'C1_ABS_SEGMENTED' THEN 
        CASE WHEN segment_n_obs >= min_n_segment THEN p50 + spread_80_abs ELSE p50 + spread_80_abs_global END
      WHEN 'C2_LOG_SEGMENTED' THEN
        CASE WHEN segment_n_obs >= min_n_segment 
          THEN GREATEST(0.0, EXP(LN(p50 + 1) + spread_80_log) - 1)
          ELSE GREATEST(0.0, EXP(LN(p50 + 1) + spread_80_log_global) - 1)
        END
      WHEN 'C3_HYBRID_ZERO_AWARE' THEN
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' THEN
            CASE WHEN segment_n_obs >= min_n_segment THEN p50 + spread_80_abs ELSE p50 + spread_80_abs_global END
          ELSE
            CASE WHEN segment_n_obs >= min_n_segment 
              THEN GREATEST(0.0, EXP(LN(p50 + 1) + spread_80_log) - 1)
              ELSE GREATEST(0.0, EXP(LN(p50 + 1) + spread_80_log_global) - 1)
            END
        END
      WHEN 'C4_MINIMAL_SPREAD' THEN p50 + (spread_80_abs * 0.5)  -- Intentionally narrow
    END AS q80_raw,
    
    CASE method
      WHEN 'C1_ABS_SEGMENTED' THEN 
        CASE WHEN segment_n_obs >= min_n_segment THEN p50 + spread_90_abs ELSE p50 + spread_90_abs_global END
      WHEN 'C2_LOG_SEGMENTED' THEN
        CASE WHEN segment_n_obs >= min_n_segment 
          THEN GREATEST(0.0, EXP(LN(p50 + 1) + spread_90_log) - 1)
          ELSE GREATEST(0.0, EXP(LN(p50 + 1) + spread_90_log_global) - 1)
        END
      WHEN 'C3_HYBRID_ZERO_AWARE' THEN
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' THEN
            CASE WHEN segment_n_obs >= min_n_segment THEN p50 + spread_90_abs ELSE p50 + spread_90_abs_global END
          ELSE
            CASE WHEN segment_n_obs >= min_n_segment 
              THEN GREATEST(0.0, EXP(LN(p50 + 1) + spread_90_log) - 1)
              ELSE GREATEST(0.0, EXP(LN(p50 + 1) + spread_90_log_global) - 1)
            END
        END
      WHEN 'C4_MINIMAL_SPREAD' THEN p50 + (spread_90_abs * 0.5)
    END AS q90_raw,
    
    CASE method
      WHEN 'C1_ABS_SEGMENTED' THEN 
        CASE WHEN segment_n_obs >= min_n_segment THEN p50 + spread_95_abs ELSE p50 + spread_95_abs_global END
      WHEN 'C2_LOG_SEGMENTED' THEN
        CASE WHEN segment_n_obs >= min_n_segment 
          THEN GREATEST(0.0, EXP(LN(p50 + 1) + spread_95_log) - 1)
          ELSE GREATEST(0.0, EXP(LN(p50 + 1) + spread_95_log_global) - 1)
        END
      WHEN 'C3_HYBRID_ZERO_AWARE' THEN
        CASE 
          WHEN sku_season_state IN ('OFF_SEASON', 'TRANSITION_DOWN') OR season_group = 'REST' THEN
            CASE WHEN segment_n_obs >= min_n_segment THEN p50 + spread_95_abs ELSE p50 + spread_95_abs_global END
          ELSE
            CASE WHEN segment_n_obs >= min_n_segment 
              THEN GREATEST(0.0, EXP(LN(p50 + 1) + spread_95_log) - 1)
              ELSE GREATEST(0.0, EXP(LN(p50 + 1) + spread_95_log_global) - 1)
            END
        END
      WHEN 'C4_MINIMAL_SPREAD' THEN p50 + (spread_95_abs * 0.5)
    END AS q95_raw
    
  FROM base
  CROSS JOIN (
    SELECT method FROM UNNEST(['C1_ABS_SEGMENTED', 'C2_LOG_SEGMENTED', 'C3_HYBRID_ZERO_AWARE', 'C4_MINIMAL_SPREAD']) AS method
  )
  CROSS JOIN (
    SELECT cap_strategy FROM UNNEST(['NO_CAP', 'CAP_2X', 'CAP_3X']) AS cap_strategy
  )
  CROSS JOIN (
    SELECT min_n_segment FROM UNNEST([300, 500, 1000]) AS min_n_segment
  )
  CROSS JOIN (
    -- Global spreads for fallback
    SELECT 
      q_res_80_abs AS spread_80_abs_global,
      q_res_90_abs AS spread_90_abs_global,
      q_res_95_abs AS spread_95_abs_global,
      q_res_80_log AS spread_80_log_global,
      q_res_90_log AS spread_90_log_global,
      q_res_95_log AS spread_95_log_global
    FROM `thequantitativeledger.cruzber_models_eu.residual_spread_calibration_h12_v4_2_strict`
    WHERE segment_level = 'global'
    LIMIT 1
  )
),

-- Apply caps
capped AS (
  SELECT
    *,
    -- Apply cap strategy
    CASE cap_strategy
      WHEN 'NO_CAP' THEN q80_raw
      WHEN 'CAP_2X' THEN LEAST(q80_raw, GREATEST(p50 * 2.0, p50 + COALESCE(hist_p95_segment, 50.0)))
      WHEN 'CAP_3X' THEN LEAST(q80_raw, GREATEST(p50 * 3.0, p50 + COALESCE(hist_p95_segment, 50.0)))
    END AS q80,
    CASE cap_strategy
      WHEN 'NO_CAP' THEN q90_raw
      WHEN 'CAP_2X' THEN LEAST(q90_raw, GREATEST(p50 * 2.0, p50 + COALESCE(hist_p95_segment, 50.0)))
      WHEN 'CAP_3X' THEN LEAST(q90_raw, GREATEST(p50 * 3.0, p50 + COALESCE(hist_p95_segment, 50.0)))
    END AS q90,
    CASE cap_strategy
      WHEN 'NO_CAP' THEN q95_raw
      WHEN 'CAP_2X' THEN LEAST(q95_raw, GREATEST(p50 * 2.0, p50 + COALESCE(hist_p95_segment, 50.0)))
      WHEN 'CAP_3X' THEN LEAST(q95_raw, GREATEST(p50 * 3.0, p50 + COALESCE(hist_p95_segment, 50.0)))
    END AS q95
  FROM candidates
),

-- Enforce monotonicity
monotonic AS (
  SELECT
    *,
    -- Ensure p50 <= q80 <= q90 <= q95
    GREATEST(p50, q80) AS q80_final,
    GREATEST(p50, q80, q90) AS q90_final,
    GREATEST(p50, q80, q90, q95) AS q95_final
  FROM capped
)

SELECT * FROM monotonic;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 3: Compute metrics for each candidate
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.overlay_candidate_scores_dev_select_h12_v4_2_strict` AS
WITH

metrics_global AS (
  SELECT
    method,
    cap_strategy,
    min_n_segment,
    CONCAT(method, '_', cap_strategy, '_N', CAST(min_n_segment AS STRING)) AS candidate_id,
    
    COUNT(*) AS n_obs,
    
    -- Point forecast metrics (should be identical to v3_2)
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    
    -- Quantile coverage
    AVG(CASE WHEN y_true_12w > q80_final THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q90_final THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q95_final THEN 1.0 ELSE 0.0 END) AS viol_p95,
    
    -- Spread efficiency
    AVG(q90_final - p50) AS avg_spread_p50_p90,
    AVG(q95_final - p50) AS avg_spread_p50_p95,
    APPROX_QUANTILES(q90_final - p50, 100)[OFFSET(50)] AS median_spread_p50_p90,
    
    -- Monotonicity
    AVG(CASE WHEN q80_final < p50 OR q90_final < q80_final OR q95_final < q90_final THEN 1.0 ELSE 0.0 END) AS monotonicity_violation_rate
    
  FROM `thequantitativeledger.cruzber_models_eu._temp_overlay_predictions_h12_v4_2`
  GROUP BY method, cap_strategy, min_n_segment
),

-- Metrics by season
metrics_season AS (
  SELECT
    method,
    cap_strategy,
    min_n_segment,
    season_group,
    COUNT(*) AS n_obs,
    AVG(CASE WHEN y_true_12w > q90_final THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(q90_final - p50) AS avg_spread_p50_p90
  FROM `thequantitativeledger.cruzber_models_eu._temp_overlay_predictions_h12_v4_2`
  GROUP BY method, cap_strategy, min_n_segment, season_group
),

-- Compute composite loss
loss_computation AS (
  SELECT
    g.*,
    -- Coverage penalty (relaxed targets)
    ABS(g.viol_p80 - 0.10) + ABS(g.viol_p90 - 0.04) + ABS(g.viol_p95 - 0.01) AS coverage_penalty,
    
    -- Spread efficiency penalty
    GREATEST(0.0, g.avg_spread_p50_p90 - 20.0) * 0.1 AS spread_efficiency_penalty,
    
    -- REST overspread penalty
    COALESCE(MAX(CASE WHEN ms.season_group = 'REST' THEN ms.avg_spread_p50_p90 END), 0.0) * 0.05 AS rest_overspread_penalty,
    
    -- HIGH_SEASON undercoverage penalty
    CASE WHEN MAX(CASE WHEN ms.season_group = 'HIGH_SEASON' THEN ms.viol_p90 END) < 0.02 
      THEN 1.0 ELSE 0.0 
    END AS highseason_undercoverage_penalty,
    
    -- Stability penalty (placeholder - would need temporal blocks)
    0.0 AS stability_penalty,
    
    -- p50 change penalty (should be 0)
    0.0 AS p50_change_penalty,
    
    -- Monotonicity penalty
    CASE WHEN g.monotonicity_violation_rate > 0 THEN 100.0 ELSE 0.0 END AS monotonicity_penalty
    
  FROM metrics_global g
  LEFT JOIN metrics_season ms
    ON g.method = ms.method
    AND g.cap_strategy = ms.cap_strategy
    AND g.min_n_segment = ms.min_n_segment
  GROUP BY 
    g.method, g.cap_strategy, g.min_n_segment, g.candidate_id, g.n_obs,
    g.wmape_all, g.wmape_ypos, g.viol_p80, g.viol_p90, g.viol_p95,
    g.avg_spread_p50_p90, g.avg_spread_p50_p95, g.median_spread_p50_p90, g.monotonicity_violation_rate
)

SELECT
  *,
  1.5 * coverage_penalty
  + 1.0 * spread_efficiency_penalty
  + 1.0 * rest_overspread_penalty
  + 1.0 * highseason_undercoverage_penalty
  + 2.0 * stability_penalty
  + 100.0 * p50_change_penalty
  + 100.0 * monotonicity_penalty
  AS composite_loss
FROM loss_computation;

-- Cleanup
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_dev_select_with_spreads_h12_v4_2`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_overlay_predictions_h12_v4_2`;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 3 Complete: Overlay Candidates Scored on DEV_SELECT' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Top candidates by composite loss
SELECT
  candidate_id,
  ROUND(composite_loss, 4) AS loss,
  ROUND(wmape_ypos, 4) AS wmape,
  ROUND(viol_p80, 3) AS p80,
  ROUND(viol_p90, 3) AS p90,
  ROUND(viol_p95, 3) AS p95,
  ROUND(avg_spread_p50_p90, 2) AS spread90,
  ROUND(monotonicity_violation_rate, 4) AS mono_viol
FROM `thequantitativeledger.cruzber_models_eu.overlay_candidate_scores_dev_select_h12_v4_2_strict`
ORDER BY composite_loss
LIMIT 10;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 4 will select and freeze best overlay policy' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
