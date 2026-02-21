-- ============================================================================
-- STEP 04: TWO-STAGE CONFORMAL CALIBRATION  (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   Derive a principled correction_factor per (season_group, segment_id_child)
--   that replaces the single "magic number" global multiplier of v3.
--
-- METHOD (Option A from spec):
--   Stage 1: Conformal base quantiles from CALIB (step 03).
--   Stage 2: Measure observed viol_rate_p90 on VAL_TUNE window (first 2/3 of VAL).
--            correction_factor = CLIP( viol_rate_p90 / 0.10 , 0.80, 1.50 )
--            This widens intervals if the base is too tight and tightens if over-wide.
--   Fallback hierarchy (when n_obs_tune < 200):
--            segment → season_group → 1.0
--
-- NOTE ON PAPER / PRODUCTION UNIFICATION:
--   VAL_TUNE and VAL_TEST are defined ONCE in this script and reused everywhere.
--   No 999 placeholders.  Empty cells emit explicit 'INSUFFICIENT_DATA' rows.
--
-- CONSTANTS (inline; see 00_config for documentation):
--   DEMAND_ACTIVE_THR = 5.0
--   MIN_N_TUNE        = 200
--   FACTOR_CLIP_LO    = 0.80
--   FACTOR_CLIP_HI    = 3.00   (raised: viol_rate formula underestimates for right-tailed residuals)
--
-- OUTPUT TABLES:
--   val_tune_test_split_h4_v4   : canonical VAL_TUNE / VAL_TEST week assignment
--   quantile_factors_h4_v4      : correction_factor per (season, segment)
-- ============================================================================

-- ============================================================================
-- 4a. CANONICAL VAL_TUNE / VAL_TEST SPLIT  (replaces paper_val_split_h4)
-- ============================================================================
-- First 2/3 of distinct VAL decision_weeks => VAL_TUNE
-- Last  1/3                                 => VAL_TEST
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.val_tune_test_split_h4_v4` AS
-- NOTE: window functions run BEFORE DISTINCT, so we must do DISTINCT in a
--       subquery first, then apply ROW_NUMBER() in the outer query.
WITH distinct_weeks AS (
  SELECT DISTINCT week_start_date AS decision_week
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4`
  WHERE split = 'VAL'
),
val_weeks AS (
  SELECT
    decision_week,
    ROW_NUMBER() OVER (ORDER BY decision_week) AS wk_rank
  FROM distinct_weeks
),
counts AS (
  SELECT COUNT(*) AS total_weeks FROM val_weeks
)
SELECT
  v.decision_week,
  v.wk_rank,
  c.total_weeks,
  CASE
    WHEN v.wk_rank <= CAST(FLOOR(c.total_weeks * 0.67) AS INT64) THEN 'VAL_TUNE'
    ELSE 'VAL_TEST'
  END AS paper_split
FROM val_weeks v
CROSS JOIN counts c
ORDER BY v.decision_week;


-- ============================================================================
-- 4b. MEASURE VIOLATION RATE ON VAL_TUNE (base = raw conformal, NO correction yet)
-- ============================================================================
-- We need a provisional forecast using the raw quantile lookup (no correction)
-- to measure where coverage is before applying the correction.

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.viol_rate_valtune_h4_v4` AS
WITH
-- Stable CALIB-based volatility bucket thresholds (not population-dependent)
vb_thresholds AS (
  SELECT * FROM `thequantitativeledger.cruzber_models_eu.volatility_bucket_thresholds_h4_v4`
),
val_tune_scores AS (
  SELECT
    s.sku_id,
    s.week_start_date                     AS decision_week,
    s.season_group,
    s.amplitude,
    s.y_true_h4,
    s.yhat_p50_h4,
    s.scale,

    -- Stable volatility_bucket via CALIB thresholds (not population-dependent NTILE)
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket,

    s.demand_decile

  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4` s
  INNER JOIN `thequantitativeledger.cruzber_models_eu.val_tune_test_split_h4_v4` sp
    ON s.week_start_date = sp.decision_week
  JOIN vb_thresholds vbt USING (season_group, demand_decile)
  WHERE s.split = 'VAL'
    AND sp.paper_split = 'VAL_TUNE'
    AND s.amplitude >= 5.0   -- DEMAND_ACTIVE_THR
),
with_segment AS (
  SELECT
    *,
    CONCAT(
      season_group,
      '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
      '_V', CAST(volatility_bucket AS STRING)
    ) AS segment_id_child
  FROM val_tune_scores
),
joined_lookup AS (
  SELECT
    t.*,
    -- quantile_lookup already has its own child→parent→global fallback hierarchy,
    -- so q.q_score_p90 is always non-null when segment_id_child matches any lookup row.
    COALESCE(q.q_score_p90, 1.645) AS q_score_p90,
    -- raw conformal q90 (no correction factor yet)
    t.yhat_p50_h4 + COALESCE(q.q_score_p90, 1.645) * t.scale AS q90_base
  FROM with_segment t
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4` q
    USING (segment_id_child)
)
SELECT
  season_group,
  segment_id_child,
  COUNT(*) AS n_obs_tune,
  COUNTIF(y_true_h4 > q90_base) AS n_viol,
  SAFE_DIVIDE(COUNTIF(y_true_h4 > q90_base), COUNT(*)) AS viol_rate_p90_tune,
  -- Empirical 90th-percentile conformal score on VAL_TUNE active rows.
  -- Used for the EXACT correction factor: CF = empirical_q90 / calib_q90.
  APPROX_QUANTILES(SAFE_DIVIDE(y_true_h4 - yhat_p50_h4, scale), 10)[OFFSET(9)]
    AS empirical_q90_score_tune
FROM joined_lookup
GROUP BY season_group, segment_id_child;


-- ============================================================================
-- 4c. BUILD correction_factor TABLE  (segment → season fallback → 1.0)
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.quantile_factors_h4_v4` AS

WITH
-- Season-level aggregates + weighted-mean empirical q90 (used as fallback)
season_viol AS (
  SELECT
    season_group,
    SUM(n_obs_tune)                             AS n_obs_season,
    SAFE_DIVIDE(SUM(n_viol), SUM(n_obs_tune))   AS viol_rate_p90_season,
    -- weighted-mean empirical q90 across segments for season-level fallback
    SAFE_DIVIDE(
      SUM(empirical_q90_score_tune * n_obs_tune),
      SUM(n_obs_tune)
    ) AS empirical_q90_season
  FROM `thequantitativeledger.cruzber_models_eu.viol_rate_valtune_h4_v4`
  GROUP BY season_group
),

-- Global-level CALIB q_score (for season-fallback correction_factor)
-- Use ANY_VALUE since all 'global' rows for the same season have identical q_score.
global_q AS (
  SELECT season_group, ANY_VALUE(q_score_p90) AS global_calib_q90
  FROM `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4`
  WHERE fallback_level = 'global'
  GROUP BY season_group
),

-- Per-segment correction with fallback
base_factors AS (
  SELECT
    sv.season_group,
    vv.segment_id_child,
    vv.n_obs_tune,
    vv.viol_rate_p90_tune,
    sv.viol_rate_p90_season,
    q.q_score_p90 AS calib_q_score_p90,

    -- Empirical q90 to use (segment or season fallback)
    CASE
      WHEN vv.n_obs_tune >= 200 THEN vv.empirical_q90_score_tune
      ELSE sv.empirical_q90_season
    END AS effective_empirical_q90,

    CASE
      WHEN vv.n_obs_tune >= 200 THEN vv.viol_rate_p90_tune
      ELSE sv.viol_rate_p90_season
    END AS effective_viol_rate,

    CASE
      WHEN vv.n_obs_tune >= 200 THEN 'segment'
      ELSE 'season'
    END AS factor_source

  FROM `thequantitativeledger.cruzber_models_eu.viol_rate_valtune_h4_v4` vv
  JOIN season_viol sv USING (season_group)
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.quantile_lookup_h4_v4` q
    USING (segment_id_child)
),

-- Apply CLIP
clipped_factors AS (
  SELECT
    season_group,
    segment_id_child,
    n_obs_tune,
    viol_rate_p90_tune,
    viol_rate_p90_season,
    effective_viol_rate,
    effective_empirical_q90,
    calib_q_score_p90,
    factor_source,
    -- EXACT conformal correction: ratio of VAL_TUNE empirical p90 score
    -- to CALIB p90 score.  This is the inductive split-conformal predictor's
    -- exact calibration and replaces the viol_rate/0.10 approximation.
    -- Clipped to [0.80, 3.00] to bound interval expansion.
    GREATEST(0.80, LEAST(3.00,
      SAFE_DIVIDE(effective_empirical_q90, NULLIF(calib_q_score_p90, 0))
    )) AS correction_factor
  FROM base_factors
)

SELECT
  'v4' AS version,
  season_group,
  segment_id_child,
  n_obs_tune,
  viol_rate_p90_tune,
  viol_rate_p90_season,
  effective_viol_rate,
  factor_source,
  correction_factor,
  CURRENT_TIMESTAMP() AS computed_at
FROM clipped_factors

UNION ALL

-- Season-level rows (production fallback when segment not found in lookup)
SELECT
  'v4' AS version,
  sv.season_group,
  NULL AS segment_id_child,
  sv.n_obs_season AS n_obs_tune,
  sv.viol_rate_p90_season AS viol_rate_p90_tune,
  sv.viol_rate_p90_season,
  sv.viol_rate_p90_season AS effective_viol_rate,
  'season_level' AS factor_source,
  GREATEST(0.80, LEAST(3.00,
    SAFE_DIVIDE(sv.empirical_q90_season, NULLIF(gq.global_calib_q90, 0))
  )) AS correction_factor,
  CURRENT_TIMESTAMP() AS computed_at
FROM season_viol sv
JOIN global_q gq USING (season_group);


-- Diagnostic: show season-level factors
SELECT season_group, factor_source, ROUND(correction_factor, 4) AS corr_factor,
       n_obs_tune, ROUND(viol_rate_p90_tune, 4) AS viol_tune
FROM `thequantitativeledger.cruzber_models_eu.quantile_factors_h4_v4`
WHERE segment_id_child IS NULL
ORDER BY season_group;
