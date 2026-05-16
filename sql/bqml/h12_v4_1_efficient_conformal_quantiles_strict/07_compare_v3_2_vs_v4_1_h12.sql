-- ============================================================================
-- PHASE 7: COMPARE v3_2 vs v4_1 (h12 Models)
-- ============================================================================
-- PURPOSE:
--   Side-by-side comparison of v3_2 baseline vs v4_1 on LOCKED_TEST.
--   Compute deltas to understand improvements/degradations.
--
-- INPUTS:
--   - diagnostics_v3_2_baseline_reproduction_h12_v4_1
--   - final_locked_test_metrics_h12_v4_1_strict
--
-- OUTPUTS:
--   - compare_v3_2_vs_v4_1_h12_strict (comparison table)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_1_h12_strict` AS
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
    0.0 AS v3_2_viol_p80,  -- v3_2 had collapsed quantiles
    0.0 AS v3_2_viol_p90,
    0.0 AS v3_2_viol_p95
  FROM `thequantitativeledger.cruzber_models_eu.diagnostics_v3_2_baseline_reproduction_h12_v4_1`
),

v4_1_metrics AS (
  SELECT
    COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
    REPLACE(metric_level, 'v4_1_', '') AS metric_level,
    n_obs,
    wmape_all AS v4_1_wmape_all,
    wmape_ypos AS v4_1_wmape_ypos,
    bias_pct AS v4_1_bias_pct,
    zero_overforecast_rate AS v4_1_zero_overf,
    viol_p80 AS v4_1_viol_p80,
    viol_p90 AS v4_1_viol_p90,
    viol_p95 AS v4_1_viol_p95
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_1_strict`
),

joined AS (
  SELECT
    COALESCE(v32.segment, v41.segment) AS segment,
    COALESCE(v32.metric_level, v41.metric_level) AS metric_level,
    COALESCE(v32.n_obs, v41.n_obs) AS n_obs,
    -- v3_2 metrics
    v32.v3_2_wmape_all,
    v32.v3_2_wmape_ypos,
    v32.v3_2_bias_pct,
    v32.v3_2_zero_overf,
    v32.v3_2_viol_p80,
    v32.v3_2_viol_p90,
    v32.v3_2_viol_p95,
    -- v4_1 metrics
    v41.v4_1_wmape_all,
    v41.v4_1_wmape_ypos,
    v41.v4_1_bias_pct,
    v41.v4_1_zero_overf,
    v41.v4_1_viol_p80,
    v41.v4_1_viol_p90,
    v41.v4_1_viol_p95
  FROM v3_2_metrics v32
  FULL OUTER JOIN v4_1_metrics v41
    ON v32.segment = v41.segment
    AND v32.metric_level = v41.metric_level
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
  v3_2_viol_p90,
  -- v4_1
  v4_1_wmape_all,
  v4_1_wmape_ypos,
  v4_1_bias_pct,
  v4_1_zero_overf,
  v4_1_viol_p90,
  -- Deltas (v4_1 - v3_2)
  (v4_1_wmape_all - v3_2_wmape_all) AS delta_wmape_all,
  (v4_1_wmape_ypos - v3_2_wmape_ypos) AS delta_wmape_ypos,
  (v4_1_bias_pct - v3_2_bias_pct) AS delta_bias_pct,
  (v4_1_zero_overf - v3_2_zero_overf) AS delta_zero_overf,
  (v4_1_viol_p90 - v3_2_viol_p90) AS delta_viol_p90,  -- Positive is GOOD (quantiles no longer collapsed)
  -- Relative changes (%)
  SAFE_DIVIDE((v4_1_wmape_ypos - v3_2_wmape_ypos), v3_2_wmape_ypos) * 100 AS pct_change_wmape_ypos,
  -- Win/loss indicator
  CASE
    WHEN v4_1_wmape_ypos < v3_2_wmape_ypos * 0.95 AND v4_1_viol_p90 > 0.04 THEN 'WIN'
    WHEN v4_1_wmape_ypos > v3_2_wmape_ypos * 1.05 THEN 'LOSS_WMAPE'
    WHEN v4_1_viol_p90 < 0.04 THEN 'LOSS_QUANTILES'
    ELSE 'NEUTRAL'
  END AS verdict
FROM joined
ORDER BY 
  CASE metric_level 
    WHEN 'v4_1_global' THEN 1 
    WHEN 'v4_1_by_season' THEN 2 
    WHEN 'v4_1_by_state' THEN 3 
  END,
  n_obs DESC;

-- ──────────────────────────────────────────────────────────────────────────
-- Display comparison
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 7 Complete: v3_2 vs v4_1 Comparison' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

SELECT
  segment,
  n_obs,
  ROUND(v3_2_wmape_ypos, 3) AS v3_2_wmape,
  ROUND(v4_1_wmape_ypos, 3) AS v4_1_wmape,
  ROUND(delta_wmape_ypos, 3) AS delta_wmape,
  ROUND(v3_2_viol_p90, 3) AS v3_2_viol,
  ROUND(v4_1_viol_p90, 3) AS v4_1_viol,
  ROUND(pct_change_wmape_ypos, 1) AS pct_change,
  verdict
FROM `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_1_h12_strict`
ORDER BY n_obs DESC;

-- Summary interpretation
WITH summary AS (
  SELECT
    COUNTIF(verdict = 'WIN') AS n_wins,
    COUNTIF(verdict = 'LOSS_WMAPE') AS n_loss_wmape,
    COUNTIF(verdict = 'LOSS_QUANTILES') AS n_loss_quantiles,
    COUNTIF(verdict = 'NEUTRAL') AS n_neutral,
    -- Global metrics
    MAX(CASE WHEN segment = 'GLOBAL' THEN v4_1_wmape_ypos END) AS v4_1_global_wmape,
    MAX(CASE WHEN segment = 'GLOBAL' THEN v3_2_wmape_ypos END) AS v3_2_global_wmape,
    MAX(CASE WHEN segment = 'GLOBAL' THEN v4_1_viol_p90 END) AS v4_1_global_viol_p90
  FROM `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_1_h12_strict`
)

SELECT
  '════════════════ SUMMARY VERDICT ════════════════' AS header,
  n_wins AS segments_improved,
  n_loss_wmape AS segments_degraded_wmape,
  n_loss_quantiles AS segments_poor_quantiles,
  ROUND(v4_1_global_wmape, 3) AS v4_1_wmape_global,
  ROUND(v3_2_global_wmape, 3) AS v3_2_wmape_global,
  ROUND((v4_1_global_wmape - v3_2_global_wmape) / v3_2_global_wmape * 100, 1) AS pct_change,
  ROUND(v4_1_global_viol_p90, 3) AS v4_1_viol_p90,
  CASE
    WHEN v4_1_global_wmape <= v3_2_global_wmape * 1.05 AND v4_1_global_viol_p90 >= 0.04
    THEN '✓ PROMOTE v4_1 (maintains WMAPE + adds useful quantiles)'
    WHEN v4_1_global_wmape > v3_2_global_wmape * 1.10
    THEN '✗ KEEP v3_2 (v4_1 degrades WMAPE significantly)'
    WHEN v4_1_global_viol_p90 < 0.04
    THEN '✗ KEEP v3_2 (v4_1 quantiles still too tight)'
    ELSE '~ EXPERIMENTAL (marginal improvement, needs business review)'
  END AS recommendation
FROM summary;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 99 will run leakage audit' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
