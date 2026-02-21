-- ============================================================================
-- STEP 03: RESIDUALS + SEGMENT QUANTILE LOOKUP  (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   Compute scale-normalised conformity scores on CALIB split and build a
--   segment × quantile lookup table (Mondrian conformal prediction).
--
--   Segment key = season_group × demand_decile × volatility_bucket
--   (same 3-D segment as v2/v3 for comparability; no change here)
--
-- CALIBRATION POPULATION:
--   score = (y_true - yhat) / scale  is set to NULL for rows with
--   amplitude < DEMAND_ACTIVE_THR (5.0).  This restricts the empirical
--   quantile to the active-demand population, matching the gate B3
--   evaluation scope.  BigQuery APPROX_QUANTILES ignores NULLs.
--
--   The NTILE(5) for volatility_bucket is still derived on ALL CALIB rows
--   (stable bucket thresholds).  Thresholds are exported to
--   volatility_bucket_thresholds_h4_v4 so step 05 can assign consistent
--   buckets to TRAIN and VAL rows without recomputing NTILE on a
--   population-dependent window.
--
-- INPUT:  base_scores_h4_v4  (from step 02)
-- OUTPUT:
--   residuals_h4_v4                   : per-row scores on CALIB
--   volatility_bucket_thresholds_h4_v4: cv_13w breakpoints per (season,decile)
--   quantile_lookup_h4_v4             : q_score_{p90,p95,p99} per segment
-- ============================================================================

-- ============================================================================
-- 3a: RESIDUALS ON CALIB
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.residuals_h4_v4` AS
WITH scored AS (
  SELECT
    sku_id,
    week_start_date,
    split,
    season_group,
    demand_decile,
    y_true_h4,
    yhat_p50_h4,
    scale,
    amplitude,
    roll13_std,
    cv_13w,
    stockout_event_h4,
    p_oos_h4,

    -- normalised residual (conformity score)
    -- NULL for amplitude < DEMAND_ACTIVE_THR (5.0): inactive rows must NOT
    -- influence the conformal quantile (gate B3 only evaluates active demand).
    -- BigQuery APPROX_QUANTILES ignores NULL values automatically.
    CASE
      WHEN amplitude >= 5.0
        THEN SAFE_DIVIDE(y_true_h4 - yhat_p50_h4, scale)
      ELSE NULL
    END AS score,

    -- volatility bucket (NTILE 5 within segment — on ALL CALIB rows for stability)
    -- Bucket thresholds are exported below to volatility_bucket_thresholds_h4_v4
    -- so step 05 can assign the SAME buckets without population-dependent NTILE.
    NTILE(5) OVER (
      PARTITION BY season_group, demand_decile
      ORDER BY COALESCE(cv_13w, 0.0)
    ) AS volatility_bucket

  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4`
  WHERE split = 'CALIB'
)
SELECT
  *,
  -- segment IDs (kept identical to v2 for cross-version comparability)
  CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'))
    AS segment_id_parent,
  CONCAT(
    season_group,
    '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
    '_V', CAST(volatility_bucket AS STRING)
  ) AS segment_id_child
FROM scored;


-- ============================================================================
-- 3b: SEGMENT QUANTILE LOOKUP (conformal empirical quantiles)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4` AS

-- ---- child-level (season × decile × volatility) --------------------------
-- NOTE: COUNT(score) counts only non-NULL rows, i.e. active-demand observations.
WITH child_scores AS (
  SELECT
    segment_id_child,
    segment_id_parent,
    season_group,
    demand_decile,
    volatility_bucket,
    COUNT(score)   AS n_calib,             -- active-demand rows only
    COUNT(*)       AS n_calib_all,         -- all rows (audit)
    -- empirical quantiles of the conformity score (NULLs ignored = active only)
    APPROX_QUANTILES(score, 100)[OFFSET(90)] AS q_score_p90,
    APPROX_QUANTILES(score, 100)[OFFSET(95)] AS q_score_p95,
    APPROX_QUANTILES(score, 100)[OFFSET(99)] AS q_score_p99
  FROM `thequantitativeledger.cruzber_models_eu.residuals_h4_v4`
  GROUP BY segment_id_child, segment_id_parent, season_group, demand_decile, volatility_bucket
),

-- ---- parent-level fallback (season × decile) -----------------------------
parent_scores AS (
  SELECT
    segment_id_parent,
    COUNT(score)   AS n_calib_parent,      -- active-demand rows only
    APPROX_QUANTILES(score, 100)[OFFSET(90)] AS q_score_p90_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(95)] AS q_score_p95_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(99)] AS q_score_p99_parent
  FROM `thequantitativeledger.cruzber_models_eu.residuals_h4_v4`
  GROUP BY segment_id_parent
),

-- ---- global fallback (per season) ----------------------------------------
global_scores AS (
  SELECT
    season_group,
    COUNT(score)   AS n_calib_global,      -- active-demand rows only
    APPROX_QUANTILES(score, 100)[OFFSET(90)] AS q_score_p90_global,
    APPROX_QUANTILES(score, 100)[OFFSET(95)] AS q_score_p95_global,
    APPROX_QUANTILES(score, 100)[OFFSET(99)] AS q_score_p99_global
  FROM `thequantitativeledger.cruzber_models_eu.residuals_h4_v4`
  GROUP BY season_group
)

SELECT
  c.segment_id_child,
  c.segment_id_parent,
  c.season_group,
  c.demand_decile,
  c.volatility_bucket,

  -- n_calib at each level (for shrinkage diagnostics)
  c.n_calib                   AS n_calib_child,
  p.n_calib_parent,
  g.n_calib_global,

  -- Final q_score with 3-level fallback
  -- MIN_N_TUNE constant = 200; use DECLARE if BigQuery Scripting is available,
  -- otherwise inline the constant.
  CASE
    WHEN c.n_calib >= 200 THEN c.q_score_p90
    WHEN p.n_calib_parent >= 200 THEN p.q_score_p90_parent
    ELSE g.q_score_p90_global
  END AS q_score_p90,

  CASE
    WHEN c.n_calib >= 200 THEN c.q_score_p95
    WHEN p.n_calib_parent >= 200 THEN p.q_score_p95_parent
    ELSE g.q_score_p95_global
  END AS q_score_p95,

  CASE
    WHEN c.n_calib >= 200 THEN c.q_score_p99
    WHEN p.n_calib_parent >= 200 THEN p.q_score_p99_parent
    ELSE g.q_score_p99_global
  END AS q_score_p99,

  -- Which level was used (audit)
  CASE
    WHEN c.n_calib >= 200 THEN 'child'
    WHEN p.n_calib_parent >= 200 THEN 'parent'
    ELSE 'global'
  END AS fallback_level,

  -- Raw child scores (for diagnostics)
  c.q_score_p90 AS q_score_p90_raw_child,
  c.q_score_p95 AS q_score_p95_raw_child,
  c.q_score_p99 AS q_score_p99_raw_child

FROM child_scores c
JOIN parent_scores p USING (segment_id_parent)
JOIN global_scores g USING (season_group);

-- Diagnostic
SELECT fallback_level, COUNT(*) n_segments,
       ROUND(AVG(n_calib_child), 1) avg_n_active_calib,
       ROUND(AVG(q_score_p90), 4) avg_q_score_p90
FROM `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4`
GROUP BY fallback_level ORDER BY fallback_level;


-- ============================================================================
-- 3c. STABLE VOLATILITY BUCKET THRESHOLDS  (CALIB-only population)
-- ============================================================================
-- Export the cv_13w percentile breakpoints so step 05 can assign the same
-- volatility_bucket to TRAIN/VAL rows without a population-dependent NTILE.
-- The 4 thresholds divide the [0, 1] cv_13w range into 5 equal-count buckets
-- as measured on CALIB rows only.
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.volatility_bucket_thresholds_h4_v4` AS
SELECT
  season_group,
  demand_decile,
  -- APPROX_QUANTILES(x, 5) returns 6 values: [min, p20, p40, p60, p80, max]
  APPROX_QUANTILES(COALESCE(cv_13w, 0.0), 5)[OFFSET(1)] AS cv_thresh_v1,
  APPROX_QUANTILES(COALESCE(cv_13w, 0.0), 5)[OFFSET(2)] AS cv_thresh_v2,
  APPROX_QUANTILES(COALESCE(cv_13w, 0.0), 5)[OFFSET(3)] AS cv_thresh_v3,
  APPROX_QUANTILES(COALESCE(cv_13w, 0.0), 5)[OFFSET(4)] AS cv_thresh_v4
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4`
WHERE split = 'CALIB'
GROUP BY season_group, demand_decile;

SELECT season_group, demand_decile,
       ROUND(cv_thresh_v1, 4) AS t1, ROUND(cv_thresh_v2, 4) AS t2,
       ROUND(cv_thresh_v3, 4) AS t3, ROUND(cv_thresh_v4, 4) AS t4
FROM `thequantitativeledger.cruzber_models_eu.volatility_bucket_thresholds_h4_v4`
ORDER BY season_group, demand_decile;
