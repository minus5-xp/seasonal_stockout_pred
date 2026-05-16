-- ============================================================================
-- STEP 05: FORECAST GENERATION  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   Generate forecast_h12_v1 applying:
--     1. Two-stage conformal quantiles (segment correction_factor from step 04).
--     2. Monotonicity enforcement: q75 <= q80 <= q85 <= q90 <= q95 <= q99.
--     3. Non-negativity: all quantiles >= 0.
--     4. Tail cap: q* <= 2.0 * 99th-pct of y_true_12w on TRAIN+CALIB.
--
-- QUANTILES:  q75_12w, q80_12w, q85_12w, q90_12w, q95_12w, q99_12w
--
-- COLUMN NAMING:
--   yhat_p50_12w  = median demand forecast (12W cumulative)
--   qNN_12w       = calibrated upper quantile (12W cumulative)
--   p_oos_h12     = calibrated OOS probability
--   These names are deliberately distinct from H4 columns (no overlap).
--
-- INPUT:  base_scores_h12_v1, quantile_lookup_h12_v1,
--         volatility_bucket_thresholds_h12_v1, quantile_factors_h12_v1
-- OUTPUT: quantile_cap_h12_v1, forecast_h12_v1, diag_quantile_sanity_h12_v1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5a. CAP VALUES (TRAIN+CALIB per season_group)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.quantile_cap_h12_v1` AS
SELECT
  season_group,
  APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS y99_train_calib,
  2.0 * APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS cap_value
FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
WHERE split IN ('TRAIN', 'CALIB')
  AND y_true_12w IS NOT NULL
GROUP BY season_group;

-- ---------------------------------------------------------------------------
-- 5b. FULL FORECAST  forecast_h12_v1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1` AS
WITH

-- 0. CALIB-derived volatility bucket thresholds (stable)
vb_thresholds AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1`
),

-- 1. Assign stable volatility_bucket to every row (via CALIB thresholds)
scored_with_vb AS (
  SELECT
    s.*,
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` s
  LEFT JOIN vb_thresholds vbt
    ON vbt.season_group = s.season_group AND vbt.demand_decile = s.demand_decile
  WHERE s.split IN ('TRAIN', 'CALIB', 'VAL')
),

with_segment AS (
  SELECT
    *,
    CONCAT(
      season_group,
      '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
      '_V', CAST(volatility_bucket AS STRING)
    ) AS segment_id_child,
    CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'))
      AS segment_id_parent
  FROM scored_with_vb
),

-- 2. Join quantile lookup (child -> global fallback)
global_q AS (
  SELECT
    season_group,
    APPROX_QUANTILES(q_score_p75, 100)[OFFSET(50)] AS q_score_p75_global,
    APPROX_QUANTILES(q_score_p80, 100)[OFFSET(50)] AS q_score_p80_global,
    APPROX_QUANTILES(q_score_p85, 100)[OFFSET(50)] AS q_score_p85_global,
    APPROX_QUANTILES(q_score_p90, 100)[OFFSET(50)] AS q_score_p90_global,
    APPROX_QUANTILES(q_score_p95, 100)[OFFSET(50)] AS q_score_p95_global,
    APPROX_QUANTILES(q_score_p99, 100)[OFFSET(50)] AS q_score_p99_global
  FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1`
  GROUP BY season_group
),

with_qlookup AS (
  SELECT
    s.*,
    COALESCE(q.q_score_p75, gq.q_score_p75_global, 1.036) AS q_score_p75,
    COALESCE(q.q_score_p80, gq.q_score_p80_global, 1.282) AS q_score_p80,
    COALESCE(q.q_score_p85, gq.q_score_p85_global, 1.440) AS q_score_p85,
    COALESCE(q.q_score_p90, gq.q_score_p90_global, 1.645) AS q_score_p90,
    COALESCE(q.q_score_p95, gq.q_score_p95_global, 1.960) AS q_score_p95,
    COALESCE(q.q_score_p99, gq.q_score_p99_global, 2.576) AS q_score_p99,
    COALESCE(q.n_calib_child, 0)                           AS segment_n_calib,
    COALESCE(q.fallback_level, 'global')                   AS qlookup_fallback
  FROM with_segment s
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1` q
    ON q.segment_id_child = s.segment_id_child
  LEFT JOIN global_q gq ON gq.season_group = s.season_group
),

-- 3. Join correction factors (child -> season fallback -> 1.0)
with_factors AS (
  SELECT
    s.*,
    COALESCE(f.correction_factor, 1.0) AS correction_factor
  FROM with_qlookup s
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_factors_h12_v1` f
    ON f.segment_id_child = s.segment_id_child
),

-- 4. Compute raw quantiles (before non-negativity and monotonicity)
raw_quantiles AS (
  SELECT
    *,
    yhat_p50_12w + q_score_p75 * correction_factor * scale AS q75_raw,
    yhat_p50_12w + q_score_p80 * correction_factor * scale AS q80_raw,
    yhat_p50_12w + q_score_p85 * correction_factor * scale AS q85_raw,
    yhat_p50_12w + q_score_p90 * correction_factor * scale AS q90_raw,
    yhat_p50_12w + q_score_p95 * correction_factor * scale AS q95_raw,
    yhat_p50_12w + q_score_p99 * correction_factor * scale AS q99_raw
  FROM with_factors
),

-- 5. Join cap values
with_cap AS (
  SELECT r.*, COALESCE(c.cap_value, 1e9) AS cap_value
  FROM raw_quantiles r
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_cap_h12_v1` c
    ON c.season_group = r.season_group
),

-- 6. Non-negativity + monotonicity + cap
final_quantiles AS (
  SELECT
    *,
    -- Step A: non-negativity
    GREATEST(0.0, q75_raw) AS q75_nn,
    GREATEST(0.0, q80_raw) AS q80_nn,
    GREATEST(0.0, q85_raw) AS q85_nn,
    GREATEST(0.0, q90_raw) AS q90_nn,
    GREATEST(0.0, q95_raw) AS q95_nn,
    GREATEST(0.0, q99_raw) AS q99_nn
  FROM with_cap
)

SELECT
  -- identifiers
  week_start_date AS decision_week,
  target_start_week,
  target_end_week,
  sku_id,
  split,
  season_group,
  segment_id_child,
  segment_id_parent,
  demand_decile,
  volatility_bucket,

  -- OOS / demand predictions
  p_oos_h12,
  yhat_p50_12w,

  -- monotone calibrated quantiles (q75 <= q80 <= q85 <= q90 <= q95 <= q99, capped)
  LEAST(cap_value, q75_nn)                              AS q75_12w,
  LEAST(cap_value, GREATEST(q75_nn, q80_nn))            AS q80_12w,
  LEAST(cap_value, GREATEST(q80_nn, q85_nn))            AS q85_12w,
  LEAST(cap_value, GREATEST(q85_nn, q90_nn))            AS q90_12w,
  LEAST(cap_value, GREATEST(q90_nn, q95_nn))            AS q95_12w,
  LEAST(cap_value, GREATEST(q95_nn, q99_nn))            AS q99_12w,

  -- actuals / labels
  y_true_12w,
  y_sales,
  stockout_event_12w,
  n_stockout_weeks_12w,
  lost_units_proxy_12w,

  -- diagnostics
  amplitude,
  scale,
  segment_n_calib,
  qlookup_fallback,
  correction_factor,
  cap_value,

  -- version tag
  'h12_v1' AS version

FROM final_quantiles
WHERE split IN ('TRAIN', 'CALIB', 'VAL');

-- ---------------------------------------------------------------------------
-- 5c. QUANTILE SANITY DIAGNOSTICS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_quantile_sanity_h12_v1` AS
SELECT
  split,
  season_group,
  COUNT(*)                                           AS n_rows,
  -- monotonicity violations (after enforcement should be 0)
  COUNTIF(q80_12w < q75_12w)                        AS n_viol_q80_lt_q75,
  COUNTIF(q85_12w < q80_12w)                        AS n_viol_q85_lt_q80,
  COUNTIF(q90_12w < q85_12w)                        AS n_viol_q90_lt_q85,
  COUNTIF(q95_12w < q90_12w)                        AS n_viol_q95_lt_q90,
  COUNTIF(q99_12w < q95_12w)                        AS n_viol_q99_lt_q95,
  -- negativity (after enforcement should be 0)
  COUNTIF(q90_12w < 0)                              AS n_negative_q90,
  COUNTIF(q95_12w < 0)                              AS n_negative_q95,
  -- cap rate
  ROUND(SAFE_DIVIDE(COUNTIF(q90_12w >= cap_value), COUNT(*)), 4) AS pct_q90_capped,
  ROUND(SAFE_DIVIDE(COUNTIF(q95_12w >= cap_value), COUNT(*)), 4) AS pct_q95_capped,
  -- coverage
  ROUND(AVG(CASE WHEN y_true_12w <= q90_12w THEN 1.0 ELSE 0.0 END), 4) AS coverage_q90,
  ROUND(AVG(CASE WHEN y_true_12w <= q95_12w THEN 1.0 ELSE 0.0 END), 4) AS coverage_q95
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE amplitude >= 10.0
GROUP BY split, season_group
ORDER BY split, season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.diag_quantile_sanity_h12_v1`
WHERE split = 'VAL';
