-- ============================================================================
-- PHASE 7: COMPARE v3_2 vs v4_2 (h12 Models)
-- ============================================================================
-- PURPOSE:
--   Side-by-side comparison of v3_2 baseline vs v4_2 overlay on LOCKED_TEST.
--   Key question: Does v4_2 preserve p50 and improve quantiles?
--
-- INPUTS:
--   - v3_2_baseline_reproduced_h12_v4_2_strict
--   - final_locked_test_metrics_h12_v4_2_strict
--
-- OUTPUTS:
--   - compare_v3_2_vs_v4_2_h12_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_2_h12_strict` AS
WITH

v3_2_metrics AS (
  SELECT
    COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
    REPLACE(metric_level, 'v3_2_', '') AS metric_level,
    n_obs,
    wmape_all AS v3_2_wmape_all,
    wmape_ypos AS v3_2_wmape_ypos,
    bias_pct AS v3_2_bias_pct,
    zero_overforecast_rate AS v3_2_zero_overf,
    viol_p80 AS v3_2_viol_p80,
    viol_p90 AS v3_2_viol_p90,
    viol_p95 AS v3_2_viol_p95
  FROM `thequantitativeledger.cruzber_models_eu.v3_2_baseline_reproduced_h12_v4_2_strict`
),

v4_2_metrics AS (
  SELECT
    COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
    REPLACE(metric_level, 'v4_2_', '') AS metric_level,
    n_obs,
    wmape_all AS v4_2_wmape_all,
    wmape_ypos AS v4_2_wmape_ypos,
    bias_pct AS v4_2_bias_pct,
    zero_overforecast_rate AS v4_2_zero_overf,
    viol_p80 AS v4_2_viol_p80,
    viol_p90 AS v4_2_viol_p90,
    viol_p95 AS v4_2_viol_p95,
    avg_spread_p50_p90 AS v4_2_avg_spread_p90,
    monotonicity_violation_rate AS v4_2_mono_viol
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict`
),

joined AS (
  SELECT
    COALESCE(v32.segment, v42.segment) AS segment,
    COALESCE(v32.metric_level, v42.metric_level) AS metric_level,
    COALESCE(v32.n_obs, v42.n_obs) AS n_obs,
    -- v3_2 metrics
    v32.v3_2_wmape_all,
    v32.v3_2_wmape_ypos,
    v32.v3_2_bias_pct,
    v32.v3_2_zero_overf,
    v32.v3_2_viol_p80,
    v32.v3_2_viol_p90,
    v32.v3_2_viol_p95,
    -- v4_2 metrics
    v42.v4_2_wmape_all,
    v42.v4_2_wmape_ypos,
    v42.v4_2_bias_pct,
    v42.v4_2_zero_overf,
    v42.v4_2_viol_p80,
    v42.v4_2_viol_p90,
    v42.v4_2_viol_p95,
    v42.v4_2_avg_spread_p90,
    v42.v4_2_mono_viol
  FROM v3_2_metrics v32
  FULL OUTER JOIN v4_2_metrics v42
    ON v32.segment = v42.segment
    AND v32.metric_level = v42.metric_level
)

SELECT
  segment,
  metric_level,
  n_obs,
  -- v3_2
  v3_2_wmape_all,
  v3_2_wmape_ypos,
  v3_2_bias_pct,
  v3_2_zero_overf,
  v3_2_viol_p80,
  v3_2_viol_p90,
  v3_2_viol_p95,
  -- v4_2
  v4_2_wmape_all,
  v4_2_wmape_ypos,
  v4_2_bias_pct,
  v4_2_zero_overf,
  v4_2_viol_p80,
  v4_2_viol_p90,
  v4_2_viol_p95,
  v4_2_avg_spread_p90,
  v4_2_mono_viol,
  
  -- Deltas
  v4_2_wmape_ypos - v3_2_wmape_ypos AS delta_wmape_ypos,
  v4_2_viol_p90 - v3_2_viol_p90 AS delta_viol_p90,
  
  -- Verdict
  CASE
    -- p50 must be identical
    WHEN ABS(v4_2_wmape_ypos - v3_2_wmape_ypos) > 0.01 THEN 'REJECT_P50_CHANGED'
    -- Monotonicity must be perfect
    WHEN v4_2_mono_viol > 0 THEN 'REJECT_MONOTONICITY'
    -- Quantiles must improve
    WHEN v4_2_viol_p90 > v3_2_viol_p90 + 0.01 AND v4_2_viol_p90 >= 0.03 THEN 'WIN_QUANTILES'
    -- Quantiles still collapsed
    WHEN v4_2_viol_p90 < 0.01 THEN 'KEEP_V3_2_STILL_COLLAPSED'
    -- Quantiles marginally better but spreads too large
    WHEN v4_2_avg_spread_p90 > 50.0 THEN 'EXPERIMENTAL_LARGE_SPREADS'
    ELSE 'EXPERIMENTAL_REVIEW'
  END AS verdict
  
FROM joined;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 7 Complete: v3_2 vs v4_2 Comparison' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Comparison summary
SELECT
  segment,
  n_obs,
  ROUND(v3_2_wmape_ypos, 3) AS v3_2_wmape,
  ROUND(v4_2_wmape_ypos, 3) AS v4_2_wmape,
  ROUND(delta_wmape_ypos, 4) AS delta_wmape,
  ROUND(v3_2_viol_p90, 3) AS v3_2_p90,
  ROUND(v4_2_viol_p90, 3) AS v4_2_p90,
  ROUND(delta_viol_p90, 4) AS delta_p90,
  ROUND(v4_2_avg_spread_p90, 2) AS spread90,
  verdict
FROM `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_2_h12_strict`
WHERE metric_level = 'global' OR metric_level = 'by_season'
ORDER BY 
  CASE segment 
    WHEN 'GLOBAL' THEN 1 
    WHEN 'HIGH_SEASON' THEN 2 
    WHEN 'REST' THEN 3 
    ELSE 4 
  END;

-- Summary counts
WITH summary AS (
  SELECT
    COUNTIF(verdict = 'WIN_QUANTILES') AS n_wins,
    COUNTIF(verdict LIKE 'REJECT%') AS n_rejects,
    COUNTIF(verdict LIKE 'EXPERIMENTAL%') AS n_experimental,
    COUNTIF(verdict LIKE 'KEEP_V3_2%') AS n_keep_v3_2
  FROM `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_2_h12_strict`
)
SELECT 
  'Verdict summary' AS summary_type,
  n_wins,
  n_rejects,
  n_experimental,
  n_keep_v3_2
FROM summary;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 99 will run leakage audit' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
