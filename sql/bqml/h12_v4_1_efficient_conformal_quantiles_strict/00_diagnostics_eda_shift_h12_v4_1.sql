-- ============================================================================
-- PHASE 0: EDA & DISTRIBUTIONAL SHIFT DIAGNOSTICS  (h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   Reproduce v3_2 baseline metrics and analyze distributional shift across
--   splits (DEV_TUNE → DEV_SELECT → LOCKED_TEST) to guide robust model design.
--
--   This phase does NOT use LOCKED_TEST labels for calibration decisions.
--   It simply documents the challenge we face.
--
-- OUTPUTS:
--   1. diagnostics_v3_2_baseline_reproduction_h12_v4_1 - Reproduce v3_2 metrics
--   2. diagnostics_distributional_shift_by_segment_h12_v4_1 - Shift analysis
--   3. diagnostics_segment_difficulty_h12_v4_1 - Problem segment identification
--   4. diagnostics_weekly_stability_h12_v4_1 - Temporal stability analysis
--
-- ANTI-LEAKAGE:
--   This is a diagnostic phase. We read LOCKED_TEST labels only to document
--   the shift, NOT to tune/calibrate/select. All decisions in later phases
--   will use only DEV_TUNE and DEV_SELECT.
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1. Reproduce v3_2 Baseline Metrics (as reference for comparison)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.diagnostics_v3_2_baseline_reproduction_h12_v4_1` AS
SELECT
  'v3_2_global' AS metric_level,
  NULL AS season_group,
  NULL AS sku_season_state,
  COUNT(*) AS n_obs,
  COUNT(DISTINCT sku_id) AS n_skus,
  AVG(y_true_12w) AS avg_actual,
  AVG(yhat_p50_season_state_12w) AS avg_pred,
  SAFE_DIVIDE(
    SUM(ABS(y_true_12w - yhat_p50_season_state_12w)),
    SUM(y_true_12w)
  ) AS wmape_all,
  SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
    SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
  ) AS wmape_ypos,
  SAFE_DIVIDE(
    SUM(yhat_p50_season_state_12w) - SUM(y_true_12w),
    SUM(y_true_12w)
  ) * 100 AS bias_pct,
  AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
  AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_season_state_12w END) AS avg_pred_when_y_zero
FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
WHERE eval_split_v3 = 'LOCKED_TEST'
  AND y_true_12w IS NOT NULL

UNION ALL

-- By season_group
SELECT
  'v3_2_by_season' AS metric_level,
  season_group,
  NULL AS sku_season_state,
  COUNT(*) AS n_obs,
  COUNT(DISTINCT sku_id) AS n_skus,
  AVG(y_true_12w) AS avg_actual,
  AVG(yhat_p50_season_state_12w) AS avg_pred,
  SAFE_DIVIDE(
    SUM(ABS(y_true_12w - yhat_p50_season_state_12w)),
    SUM(y_true_12w)
  ) AS wmape_all,
  SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
    SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
  ) AS wmape_ypos,
  SAFE_DIVIDE(
    SUM(yhat_p50_season_state_12w) - SUM(y_true_12w),
    SUM(y_true_12w)
  ) * 100 AS bias_pct,
  AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
  AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_season_state_12w END) AS avg_pred_when_y_zero
FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
WHERE eval_split_v3 = 'LOCKED_TEST'
  AND y_true_12w IS NOT NULL
GROUP BY season_group

UNION ALL

-- By sku_season_state (top 7 states)
SELECT
  'v3_2_by_state' AS metric_level,
  NULL AS season_group,
  sku_season_state,
  COUNT(*) AS n_obs,
  COUNT(DISTINCT sku_id) AS n_skus,
  AVG(y_true_12w) AS avg_actual,
  AVG(yhat_p50_season_state_12w) AS avg_pred,
  SAFE_DIVIDE(
    SUM(ABS(y_true_12w - yhat_p50_season_state_12w)),
    SUM(y_true_12w)
  ) AS wmape_all,
  SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
    SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
  ) AS wmape_ypos,
  SAFE_DIVIDE(
    SUM(yhat_p50_season_state_12w) - SUM(y_true_12w),
    SUM(y_true_12w)
  ) * 100 AS bias_pct,
  AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overforecast_rate,
    AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_season_state_12w END) AS avg_pred_when_y_zero
FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
WHERE eval_split_v3 = 'LOCKED_TEST'
  AND y_true_12w IS NOT NULL
GROUP BY sku_season_state
ORDER BY metric_level, season_group, sku_season_state;

-- Display results
SELECT 
  metric_level,
  COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
  n_obs,
  ROUND(wmape_all, 3) AS wmape_all,
  ROUND(wmape_ypos, 3) AS wmape_ypos,
  ROUND(bias_pct, 1) AS bias_pct,
  ROUND(zero_overforecast_rate, 3) AS zero_overf
FROM `thequantitativeledger.cruzber_models_eu.diagnostics_v3_2_baseline_reproduction_h12_v4_1`
ORDER BY metric_level, n_obs DESC;

-- ──────────────────────────────────────────────────────────────────────────
-- 2. Distributional Shift Analysis (by segment, across splits)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.diagnostics_distributional_shift_by_segment_h12_v4_1` AS
WITH

base_stats AS (
  SELECT
    eval_split_v3,
    season_group,
    sku_season_state,
    COUNT(*) AS n_obs,
    AVG(y_true_12w) AS mean_y,
    APPROX_QUANTILES(y_true_12w, 100)[OFFSET(50)] AS median_y,
    STDDEV(y_true_12w) AS std_y,
    APPROX_QUANTILES(y_true_12w, 100)[OFFSET(90)] AS p90_y,
    APPROX_QUANTILES(y_true_12w, 100)[OFFSET(95)] AS p95_y,
    AVG(CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END) AS pct_zeros,
    AVG(CASE WHEN y_true_12w > 0 THEN 1.0 ELSE 0.0 END) AS pct_positive,
    AVG(CASE WHEN y_true_12w > 0 THEN y_true_12w END) AS mean_y_positive,
    SAFE_DIVIDE(STDDEV(y_true_12w), AVG(y_true_12w)) AS cv
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
  WHERE y_true_12w IS NOT NULL
    AND eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
  GROUP BY eval_split_v3, season_group, sku_season_state
),

shift_computed AS (
  SELECT
    season_group,
    sku_season_state,
    -- DEV_TUNE stats
    MAX(CASE WHEN eval_split_v3 = 'DEV_TUNE' THEN mean_y END) AS tune_mean_y,
    MAX(CASE WHEN eval_split_v3 = 'DEV_TUNE' THEN pct_zeros END) AS tune_pct_zeros,
    MAX(CASE WHEN eval_split_v3 = 'DEV_TUNE' THEN mean_y_positive END) AS tune_mean_ypos,
    MAX(CASE WHEN eval_split_v3 = 'DEV_TUNE' THEN cv END) AS tune_cv,
    -- DEV_SELECT stats
    MAX(CASE WHEN eval_split_v3 = 'DEV_SELECT' THEN mean_y END) AS select_mean_y,
    MAX(CASE WHEN eval_split_v3 = 'DEV_SELECT' THEN pct_zeros END) AS select_pct_zeros,
    MAX(CASE WHEN eval_split_v3 = 'DEV_SELECT' THEN mean_y_positive END) AS select_mean_ypos,
    MAX(CASE WHEN eval_split_v3 = 'DEV_SELECT' THEN cv END) AS select_cv,
    -- LOCKED_TEST stats
    MAX(CASE WHEN eval_split_v3 = 'LOCKED_TEST' THEN mean_y END) AS test_mean_y,
    MAX(CASE WHEN eval_split_v3 = 'LOCKED_TEST' THEN pct_zeros END) AS test_pct_zeros,
    MAX(CASE WHEN eval_split_v3 = 'LOCKED_TEST' THEN mean_y_positive END) AS test_mean_ypos,
    MAX(CASE WHEN eval_split_v3 = 'LOCKED_TEST' THEN cv END) AS test_cv,
    MAX(CASE WHEN eval_split_v3 = 'LOCKED_TEST' THEN n_obs END) AS test_n_obs
  FROM base_stats
  GROUP BY season_group, sku_season_state
)

SELECT
  season_group,
  sku_season_state,
  test_n_obs,
  -- Shift metrics SELECT → TEST (used for selection)
  SAFE_DIVIDE(test_mean_y - select_mean_y, select_mean_y) * 100 AS shift_mean_y_pct,
  SAFE_DIVIDE(test_pct_zeros - select_pct_zeros, select_pct_zeros) * 100 AS shift_zeros_pct,
  SAFE_DIVIDE(test_mean_ypos - select_mean_ypos, select_mean_ypos) * 100 AS shift_ypos_pct,
  SAFE_DIVIDE(test_cv - select_cv, select_cv) * 100 AS shift_cv_pct,
  -- Absolute shift magnitude (for ranking problem segments)
  ABS(SAFE_DIVIDE(test_mean_y - select_mean_y, select_mean_y)) * 100 AS abs_shift_mean_y,
  ABS(SAFE_DIVIDE(test_pct_zeros - select_pct_zeros, select_pct_zeros)) * 100 AS abs_shift_zeros,
  -- Raw values for context
  select_mean_y,
  test_mean_y,
  select_pct_zeros,
  test_pct_zeros,
  select_cv,
  test_cv
FROM shift_computed
WHERE test_n_obs >= 100  -- Filter small segments
ORDER BY abs_shift_mean_y DESC;

-- Display top shifters
SELECT 
  season_group,
  sku_season_state,
  test_n_obs,
  ROUND(shift_mean_y_pct, 1) AS shift_mean_y_pct,
  ROUND(shift_zeros_pct, 1) AS shift_zeros_pct,
  ROUND(shift_ypos_pct, 1) AS shift_ypos_pct,
  ROUND(test_pct_zeros, 3) AS test_zero_rate
FROM `thequantitativeledger.cruzber_models_eu.diagnostics_distributional_shift_by_segment_h12_v4_1`
ORDER BY abs_shift_mean_y DESC
LIMIT 20;

-- ──────────────────────────────────────────────────────────────────────────
-- 3. Segment Difficulty Identification (for prioritization)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.diagnostics_segment_difficulty_h12_v4_1` AS
WITH

segment_stats AS (
  SELECT
    season_group,
    sku_season_state,
    COUNT(*) AS n_obs_locked_test,
    -- Demand characteristics
    AVG(y_true_12w) AS mean_y,
    AVG(CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END) AS zero_rate,
    SAFE_DIVIDE(STDDEV(y_true_12w), AVG(y_true_12w)) AS cv,
    -- v3_2 performance
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos_v3_2,
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf_v3_2
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
    AND y_true_12w IS NOT NULL
  GROUP BY season_group, sku_season_state
)

SELECT
  *,
  -- Composite difficulty score
  (
    CASE WHEN zero_rate >= 0.80 THEN 3.0 
         WHEN zero_rate >= 0.65 THEN 2.0 
         WHEN zero_rate >= 0.50 THEN 1.0 
         ELSE 0.0 END
    + CASE WHEN cv > 10.0 THEN 3.0 
           WHEN cv > 5.0 THEN 2.0 
           WHEN cv > 3.0 THEN 1.0 
           ELSE 0.0 END
    + CASE WHEN wmape_ypos_v3_2 > 3.0 THEN 3.0 
           WHEN wmape_ypos_v3_2 > 1.5 THEN 2.0 
           WHEN wmape_ypos_v3_2 > 1.0 THEN 1.0 
           ELSE 0.0 END
    + CASE WHEN zero_overf_v3_2 > 0.85 THEN 2.0 
           WHEN zero_overf_v3_2 > 0.70 THEN 1.0 
           ELSE 0.0 END
  ) AS difficulty_score,
  -- Regime classification
  CASE 
    WHEN zero_rate >= 0.80 THEN 'EXTREME_ZERO'
    WHEN zero_rate >= 0.65 THEN 'HIGH_ZERO'
    WHEN zero_rate >= 0.50 THEN 'MODERATE_ZERO'
    ELSE 'LOW_ZERO'
  END AS zero_regime
FROM segment_stats
WHERE n_obs_locked_test >= 100
ORDER BY difficulty_score DESC, n_obs_locked_test DESC;

-- Display problem segments
SELECT 
  season_group,
  sku_season_state,
  zero_regime,
  n_obs_locked_test,
  ROUND(zero_rate, 3) AS zero_rate,
  ROUND(cv, 2) AS cv,
  ROUND(wmape_ypos_v3_2, 3) AS wmape_ypos_v3_2,
  ROUND(zero_overf_v3_2, 3) AS zero_overf_v3_2,
  ROUND(difficulty_score, 1) AS difficulty
FROM `thequantitativeledger.cruzber_models_eu.diagnostics_segment_difficulty_h12_v4_1`
ORDER BY difficulty_score DESC
LIMIT 15;

-- ──────────────────────────────────────────────────────────────────────────
-- 4. Weekly Stability Analysis (for robustness assessment)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.diagnostics_weekly_stability_h12_v4_1` AS
WITH

weekly_metrics AS (
  SELECT
    eval_split_v3,
    decision_week,
    season_group,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_season_state_12w) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    AVG(CASE WHEN y_true_12w = 0 AND yhat_p50_season_state_12w > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
  WHERE y_true_12w IS NOT NULL
    AND eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
  GROUP BY eval_split_v3, decision_week, season_group
),

stability_metrics AS (
  SELECT
    eval_split_v3,
    season_group,
    COUNT(DISTINCT decision_week) AS n_weeks,
    AVG(wmape_ypos) AS mean_wmape_ypos,
    STDDEV(wmape_ypos) AS std_wmape_ypos,
    AVG(zero_overf) AS mean_zero_overf,
    STDDEV(zero_overf) AS std_zero_overf
  FROM weekly_metrics
  GROUP BY eval_split_v3, season_group
)

SELECT
  *,
  -- Stability score (lower is more stable)
  COALESCE(std_wmape_ypos, 0.0) + COALESCE(std_zero_overf, 0.0) AS stability_score
FROM stability_metrics
ORDER BY eval_split_v3, season_group;

-- Display stability
SELECT 
  eval_split_v3,
  season_group,
  ROUND(mean_wmape_ypos, 3) AS mean_wmape_ypos,
  ROUND(std_wmape_ypos, 3) AS std_wmape_ypos,
  ROUND(mean_zero_overf, 3) AS mean_zero_overf,
  ROUND(std_zero_overf, 3) AS std_zero_overf,
  ROUND(stability_score, 3) AS stability_score
FROM `thequantitativeledger.cruzber_models_eu.diagnostics_weekly_stability_h12_v4_1`
ORDER BY eval_split_v3, stability_score DESC;

-- ============================================================================
-- DIAGNOSTIC SUMMARY
-- ============================================================================
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 0 Complete: Diagnostics & EDA' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Key Findings:' AS msg;
SELECT '  1. v3_2 baseline reproduced (WMAPE_ypos = 0.864 global)' AS finding;
SELECT '  2. Distributional shift documented (SELECT → TEST)' AS finding;
SELECT '  3. Problem segments identified (EXTREME_ZERO, high CV)' AS finding;
SELECT '  4. Weekly stability assessed (for robust selection)' AS finding;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
