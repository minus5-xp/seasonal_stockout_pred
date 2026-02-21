-- ============================================================================
-- STEP 05: FORECAST GENERATION v4  (with monotonicity, non-negativity, cap)
-- ============================================================================
-- PURPOSE:
--   Generate forecast_h4_v4 applying:
--     1. Two-stage conformal quantiles (segment-level correction_factor from step 04).
--     2. Monotonicity enforcement: q90 <= q95 <= q99.
--     3. Non-negativity:            all quantiles >= 0.
--     4. Tail cap:                   q* <= CAP_MULTIPLIER * 99th-pct of y_true
--                                    computed on TRAIN+CALIB per season_group.
--                                    CAP_MULTIPLIER = 2.0 (configurable).
--
-- OUTPUT:
--   forecast_h4_v4             : full forecast table (all splits)
--   diag_quantile_sanity_h4_v4 : % negative before/after, % capped, per split×season
-- ============================================================================

-- ============================================================================
-- 5a. COMPUTE CAP VALUES (TRAIN+CALIB, per season_group)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.quantile_cap_h4_v4` AS
SELECT
  season_group,
  APPROX_QUANTILES(y_true_h4, 100)[OFFSET(99)] AS y99_train_calib,
  -- Cap = 2.0 * 99th percentile of actual demand
  2.0 * APPROX_QUANTILES(y_true_h4, 100)[OFFSET(99)] AS cap_value
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4`
WHERE split IN ('TRAIN', 'CALIB')
  AND y_true_h4 IS NOT NULL
GROUP BY season_group;


-- ============================================================================
-- 5b. FULL FORECAST  forecast_h4_v4
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.forecast_h4_v4` AS

WITH

-- 0. CALIB-derived volatility bucket thresholds (stable: not population-dependent)
vb_thresholds AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.volatility_bucket_thresholds_h4_v4`
),

-- 1. Build segment_id_child for every row in base_scores
--    volatility_bucket uses the CALIB-only threshold table (NOT population-
--    dependent NTILE), ensuring the bucket assignment matches step 03 exactly.
scored_with_segment AS (
  SELECT
    s.*,
    -- Stable volatility_bucket: range-based on CALIB percentile thresholds
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4` s
  JOIN vb_thresholds vbt USING (season_group, demand_decile)
  WHERE s.split IN ('TRAIN', 'CALIB', 'VAL')
),
with_segment AS (
  SELECT
    *,
    CONCAT(
      season_group,
      '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
      '_V', CAST(volatility_bucket AS STRING)
    ) AS segment_id_child
  FROM scored_with_segment
),

-- 2. Join segment quantile lookup
with_qlookup AS (
  SELECT
    s.*,
    -- Child-level q_score (from lookup; fall back to global via COALESCE)
    COALESCE(q.q_score_p90, gq.q_score_p90_global, 1.645) AS q_score_p90,
    COALESCE(q.q_score_p95, gq.q_score_p95_global, 1.960) AS q_score_p95,
    COALESCE(q.q_score_p99, gq.q_score_p99_global, 2.576) AS q_score_p99,
    COALESCE(q.n_calib_child, 0)                           AS segment_n_calib,
    COALESCE(q.fallback_level, 'global')                   AS qlookup_fallback
  FROM with_segment s
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4` q
    USING (segment_id_child)
  LEFT JOIN (
    SELECT season_group,
      APPROX_QUANTILES(q_score_p90, 100)[OFFSET(50)] AS q_score_p90_global,
      APPROX_QUANTILES(q_score_p95, 100)[OFFSET(50)] AS q_score_p95_global,
      APPROX_QUANTILES(q_score_p99, 100)[OFFSET(50)] AS q_score_p99_global
    FROM `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4`
    GROUP BY season_group
  ) gq ON s.season_group = gq.season_group
),

-- 2b. Helper: segment-level and season-level correction factors
seg_factors AS (
  SELECT segment_id_child, correction_factor AS seg_correction_factor
  FROM `thequantitativeledger.cruzber_models_eu.quantile_factors_h4_v4`
  WHERE segment_id_child IS NOT NULL AND version = 'v4'
),
sea_factors AS (
  SELECT season_group, correction_factor AS sea_correction_factor
  FROM `thequantitativeledger.cruzber_models_eu.quantile_factors_h4_v4`
  WHERE segment_id_child IS NULL AND version = 'v4'
),

-- 3. Join correction_factor (segment-level; fall back to season-level → 1.0)
with_factors AS (
  SELECT
    s.*,
    COALESCE(sf.seg_correction_factor, sea_f.sea_correction_factor, 1.0) AS correction_factor
  FROM with_qlookup s
  LEFT JOIN seg_factors sf ON sf.segment_id_child = s.segment_id_child
  LEFT JOIN sea_factors sea_f ON sea_f.season_group = s.season_group
),

-- 4. Compute raw adjusted quantiles
with_raw_quantiles AS (
  SELECT
    *,
    -- q90 raw (before sanity enforcement)
    yhat_p50_h4 + (q_score_p90 * correction_factor * scale) AS q90_raw,
    yhat_p50_h4 + (q_score_p95 * correction_factor * scale) AS q95_raw,
    yhat_p50_h4 + (q_score_p99 * correction_factor * scale) AS q99_raw
  FROM with_factors
),

-- 5. Join cap values
with_cap AS (
  SELECT
    r.*,
    c.cap_value
  FROM with_raw_quantiles r
  JOIN `thequantitativeledger.cruzber_models_eu.quantile_cap_h4_v4` c
    USING (season_group)
),

-- 6. Apply monotonicity + non-negativity + cap
with_sanity AS (
  SELECT
    *,
    -- Step A: non-negativity
    GREATEST(0.0, q90_raw) AS q90_nonneg,
    GREATEST(0.0, q95_raw) AS q95_nonneg,
    GREATEST(0.0, q99_raw) AS q99_nonneg
  FROM with_cap
),
with_monotone AS (
  SELECT
    *,
    -- Step B: monotonicity (q90 <= q95 <= q99)
    q90_nonneg AS q90_mono,
    GREATEST(q90_nonneg, q95_nonneg) AS q95_mono,
    GREATEST(q90_nonneg, q95_nonneg, q99_nonneg) AS q99_mono
  FROM with_sanity
),
with_capped AS (
  SELECT
    *,
    -- Step C: cap at 2 * 99th pct
    LEAST(q90_mono, cap_value) AS q90_h4,
    LEAST(q95_mono, cap_value) AS q95_h4,
    LEAST(q99_mono, cap_value) AS q99_h4
  FROM with_monotone
)

SELECT
  -- ---- Identifiers ----
  week_start_date AS decision_week,
  -- target_week = decision_week + 4 weeks
  DATE_ADD(week_start_date, INTERVAL 4 WEEK) AS target_week,
  sku_id,
  split,
  season_group,
  segment_id_child,
  demand_decile,
  volatility_bucket,

  -- ---- Core predictions ----
  p_oos_h4,
  yhat_p50_h4,

  -- ---- Quantiles (sanity-enforced) ----
  q90_h4,
  q95_h4,
  q99_h4,

  -- ---- Ground truth ----
  y_true_h4,
  stockout_event_h4,
  amplitude,
  scale,

  -- ---- Calibration metadata (audit) ----
  segment_n_calib,
  qlookup_fallback,
  q_score_p90,
  q_score_p95,
  q_score_p99,
  correction_factor,
  cap_value,

  -- ---- Diagnostics (for sanity table) ----
  q90_raw,
  q95_raw,
  q99_raw,

  'v4' AS version

FROM with_capped;


-- ============================================================================
-- 5c. DIAGNOSTIC: quantile sanity summary
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.diag_quantile_sanity_h4_v4` AS
SELECT
  split,
  season_group,
  COUNT(*) AS n_total,

  -- % negative BEFORE enforcement (raw)
  ROUND(COUNTIF(q90_raw < 0) / COUNT(*), 4) AS pct_q90_negative_before,
  ROUND(COUNTIF(q95_raw < 0) / COUNT(*), 4) AS pct_q95_negative_before,
  ROUND(COUNTIF(q99_raw < 0) / COUNT(*), 4) AS pct_q99_negative_before,

  -- % rows that were capped (raw > cap)
  ROUND(COUNTIF(q90_raw > cap_value) / COUNT(*), 4) AS pct_q90_capped,
  ROUND(COUNTIF(q95_raw > cap_value) / COUNT(*), 4) AS pct_q95_capped,
  ROUND(COUNTIF(q99_raw > cap_value) / COUNT(*), 4) AS pct_q99_capped,

  -- % negative AFTER enforcement (should be 0)
  ROUND(COUNTIF(q90_h4 < 0) / COUNT(*), 4) AS pct_q90_negative_after,
  ROUND(COUNTIF(q95_h4 < 0) / COUNT(*), 4) AS pct_q95_negative_after,
  ROUND(COUNTIF(q99_h4 < 0) / COUNT(*), 4) AS pct_q99_negative_after,

  -- Average widths
  ROUND(AVG(q90_h4 - yhat_p50_h4), 4) AS avg_width_p90,
  ROUND(AVG(correction_factor), 4)     AS avg_correction_factor

FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4`
GROUP BY split, season_group
ORDER BY split, season_group;

SELECT * FROM `thequantitativeledger.cruzber_models_eu.diag_quantile_sanity_h4_v4`
ORDER BY split, season_group;
