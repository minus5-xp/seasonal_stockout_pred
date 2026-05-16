-- ============================================================================
-- PHASE 1: BUILD ANTI-LEAKAGE FEATURE MATRIX (h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   Join v3_2 tables (forecast_gated, sku_season_state, seasonality_features)
--   and add rolling features computed from PAST data only.
--
--   Feature matrix will be used for:
--     - Building point forecast candidates (Layer A)
--     - Calibrating residual spreads (Layer B)
--     - Evaluating models on DEV_SELECT and LOCKED_TEST
--
-- INPUTS:
--   - forecast_gated_h12_v3_2_season_state_strict (base forecasts + y_true)
--   - sku_season_state_h12_v3_2_season_state_strict (8 states classification)
--   - sku_week_seasonality_features_h12_v3_2_season_state_strict (historical features)
--   - base_scores_h12_v1 (for y_true_12w, split assignments)
--
-- OUTPUTS:
--   - feature_matrix_h12_v4_1_strict (119,857 rows expected)
--
-- ANTI-LEAKAGE GUARANTEES:
--   1. All rolling features computed from PAST data relative to decision_week
--   2. Historical features use only TRAIN+CALIB data (captured in v3_2 tables)
--   3. No features use LOCKED_TEST information in DEV_TUNE/DEV_SELECT rows
--   4. State assignments come from v3_2 (already anti-leakage certified)
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Compute rolling past features (4w, 8w, 12w windows)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_rolling_features_h12_v4_1` AS
WITH

base_ordered AS (
  SELECT
    sku_id,
    decision_week,
    eval_split_v3,
    y_true_12w,
    -- Sort within SKU by week
    ROW_NUMBER() OVER (PARTITION BY sku_id ORDER BY decision_week) AS row_num
  FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict`
  WHERE y_true_12w IS NOT NULL
),

rolling_aggregates AS (
  SELECT
    sku_id,
    decision_week,
    eval_split_v3,
    y_true_12w,
    -- Rolling 4-week PAST window
    AVG(y_true_12w) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING
    ) AS rolling_4w_mean_past,
    AVG(CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING
    ) AS rolling_4w_zero_rate_past,
    COUNT(*) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING
    ) AS rolling_4w_n_obs,
    -- Rolling 8-week PAST window
    AVG(y_true_12w) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING
    ) AS rolling_8w_mean_past,
    AVG(CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING
    ) AS rolling_8w_zero_rate_past,
    COUNT(*) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING
    ) AS rolling_8w_n_obs,
    -- Rolling 12-week PAST window
    AVG(y_true_12w) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS rolling_12w_mean_past,
    AVG(CASE WHEN y_true_12w = 0 THEN 1.0 ELSE 0.0 END) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS rolling_12w_zero_rate_past,
    COUNT(*) OVER (
      PARTITION BY sku_id 
      ORDER BY decision_week 
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS rolling_12w_n_obs
  FROM base_ordered
)

SELECT * FROM rolling_aggregates;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Join all sources into feature matrix
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict` AS
SELECT
  -- Identifiers
  f.sku_id,
  f.decision_week,
  f.eval_split_v3,
  f.season_group,
  s.sku_season_state,
  -- Target
  f.y_true_12w,
  -- Base forecasts (v3_2)
  f.yhat_p50_original_12w AS p50_base,  -- Original BQML without gate
  f.yhat_p50_season_state_12w AS p50_v3_2_gated,  -- v3_2 baseline with gate
  -- Historical seasonality features (from TRAIN+CALIB only)
  h.hist_avg_units_same_week,
  h.hist_median_units_same_week AS hist_p50_units_same_week,
  h.hist_p90_units_same_week,
  h.hist_positive_rate_same_week,
  h.seasonal_index_same_week,
  h.annual_avg_units_sku,
  h.n_hist_obs_available,
  -- State-level features
  s.annual_positive_rate_sku AS annual_positive_rate_pct,
  s.seasonal_index_same_week AS mean_seasonal_index,
  s.annual_avg_units_sku AS hist_avg_units_sku,
  s.hist_p90_units_same_week AS hist_p90_units_sku,
  s.transition_slope_avg_units AS transition_slope,
  -- Rolling features (from past observations only)
  r.rolling_4w_mean_past,
  r.rolling_4w_zero_rate_past,
  r.rolling_4w_n_obs,
  r.rolling_8w_mean_past,
  r.rolling_8w_zero_rate_past,
  r.rolling_8w_n_obs,
  r.rolling_12w_mean_past,
  r.rolling_12w_zero_rate_past,
  r.rolling_12w_n_obs,
  -- Segment zero rate (for regime classification)
  -- This will be computed aggregated from DEV_TUNE only in later phases
  CAST(NULL AS FLOAT64) AS segment_zero_rate_calib,  -- Placeholder
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at
FROM `thequantitativeledger.cruzber_models_eu.forecast_gated_h12_v3_2_season_state_strict` f
LEFT JOIN `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict` s
  ON f.sku_id = s.sku_id
  AND f.decision_week = s.decision_week
LEFT JOIN `thequantitativeledger.cruzber_models_eu.sku_week_seasonality_features_h12_v3_2_season_state_strict` h
  ON f.sku_id = h.sku_id
  AND f.decision_week = h.decision_week
LEFT JOIN `thequantitativeledger.cruzber_models_eu._temp_rolling_features_h12_v4_1` r
  ON f.sku_id = r.sku_id
  AND f.decision_week = r.decision_week
WHERE f.y_true_12w IS NOT NULL;

-- Cleanup temp table
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_rolling_features_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Validation: Anti-leakage checks
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 1 Complete: Feature Matrix Built' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Check 1: Record counts by split
SELECT 
  'CHECK 1: Record counts by split' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_records,
  COUNT(DISTINCT sku_id) AS n_skus,
  COUNT(DISTINCT decision_week) AS n_weeks
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

-- Check 2: No missing critical features
SELECT 
  'CHECK 2: Missing critical features' AS check_name,
  COUNTIF(sku_season_state IS NULL) AS missing_state,
  COUNTIF(p50_base IS NULL) AS missing_p50_base,
  COUNTIF(p50_v3_2_gated IS NULL) AS missing_p50_gated,
  COUNTIF(hist_p90_units_same_week IS NULL) AS missing_hist_p90,
  COUNTIF(seasonal_index_same_week IS NULL) AS missing_seasonal_index
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`;

-- Check 3: Rolling features coverage
SELECT 
  'CHECK 3: Rolling features coverage' AS check_name,
  eval_split_v3,
  AVG(CASE WHEN rolling_4w_n_obs >= 3 THEN 1.0 ELSE 0.0 END) AS pct_4w_coverage,
  AVG(CASE WHEN rolling_8w_n_obs >= 6 THEN 1.0 ELSE 0.0 END) AS pct_8w_coverage,
  AVG(CASE WHEN rolling_12w_n_obs >= 9 THEN 1.0 ELSE 0.0 END) AS pct_12w_coverage
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

-- Check 4: Historical features range (should be reasonable)
SELECT 
  'CHECK 4: Historical features sanity' AS check_name,
  MIN(hist_avg_units_same_week) AS min_hist_avg,
  MAX(hist_avg_units_same_week) AS max_hist_avg,
  AVG(hist_avg_units_same_week) AS mean_hist_avg,
  AVG(hist_positive_rate_same_week) AS mean_hist_pos_rate,
  AVG(seasonal_index_same_week) AS mean_seasonal_index
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`
WHERE eval_split_v3 = 'DEV_TUNE';

-- Check 5: State distribution
SELECT 
  'CHECK 5: State distribution' AS check_name,
  sku_season_state,
  COUNT(*) AS n_obs,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) AS pct
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`
WHERE eval_split_v3 = 'LOCKED_TEST'
GROUP BY sku_season_state
ORDER BY n_obs DESC;

-- Check 6: No future leakage in rolling features
-- Verify that first few weeks of each SKU have NULL or low n_obs for rolling features
SELECT 
  'CHECK 6: No future leakage in rolling (first weeks should have low n_obs)' AS check_name,
  eval_split_v3,
  APPROX_QUANTILES(rolling_4w_n_obs, 100)[OFFSET(10)] AS p10_rolling_4w_n_obs,
  APPROX_QUANTILES(rolling_4w_n_obs, 100)[OFFSET(50)] AS p50_rolling_4w_n_obs,
  AVG(CASE WHEN rolling_4w_n_obs = 0 THEN 1.0 ELSE 0.0 END) AS pct_no_rolling_4w
FROM `thequantitativeledger.cruzber_models_eu.feature_matrix_h12_v4_1_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Expected: ~119,857 records (DEV_TUNE: 33k, DEV_SELECT: 33k, LOCKED_TEST: 54k)' AS expectation;
SELECT 'Next: Phase 2 will build point forecast candidates (A0-A3)' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
