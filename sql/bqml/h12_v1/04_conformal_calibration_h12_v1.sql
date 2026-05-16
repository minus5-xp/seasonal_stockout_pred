-- ============================================================================
-- STEP 04: TWO-STAGE CONFORMAL CALIBRATION  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   Derive a principled correction_factor per segment that replaces a
--   fixed global multiplier.
--
-- METHOD:
--   Stage 1: Conformal base quantiles from CALIB (step 03).
--   Stage 2: Measure observed viol_rate_p90 on VAL_TUNE (first 2/3 of VAL weeks).
--            correction_factor = CLIP(viol_rate_p90 / 0.10, 0.80, 2.00)
--   Fallback hierarchy (when n_obs_tune < 200):
--            child segment -> season_group -> 1.0
--
-- PARAMETERS:
--   DEMAND_ACTIVE_THR  = 10.0     (active demand scope for coverage)
--   MIN_N_TUNE         = 50       (lowered: more segments get own factor)
--   FACTOR_CLIP_LO     = 0.80
--   FACTOR_CLIP_HI     = 3.00     (raised: viol_rate_p90=0.15 needs factor ~1.5, allow headroom)
--
-- OUTPUT TABLES:
--   val_tune_test_split_h12_v1
--   viol_rate_valtune_h12_v1      (provisional, no correction applied)
--   quantile_factors_h12_v1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 4a. VAL_TUNE / VAL_TEST SPLIT
-- First 2/3 of distinct VAL decision_weeks -> VAL_TUNE
-- Last  1/3                                -> VAL_TEST
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.val_tune_test_split_h12_v1` AS
WITH distinct_weeks AS (
  SELECT DISTINCT week_start_date AS decision_week
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split = 'VAL'
),
val_weeks AS (
  SELECT
    decision_week,
    ROW_NUMBER() OVER (ORDER BY decision_week) AS wk_rank
  FROM distinct_weeks
),
counts AS (SELECT COUNT(*) AS total_weeks FROM val_weeks)
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

SELECT paper_split, COUNT(*) AS n_weeks FROM `{PROJECT_ID}.{BQ_DATASET}.val_tune_test_split_h12_v1`
GROUP BY paper_split;

-- ---------------------------------------------------------------------------
-- 4b. PROVISIONAL VIOLATION RATE ON VAL_TUNE
-- (Uses raw conformal quantiles from step 03 — no correction factor yet)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.viol_rate_valtune_h12_v1` AS
WITH vb_thresholds AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1`
),
val_tune_scores AS (
  SELECT
    s.sku_id,
    s.week_start_date AS decision_week,
    s.season_group,
    s.amplitude,
    s.y_true_12w,
    s.yhat_p50_12w,
    s.scale,
    s.demand_decile,
    -- stable volatility bucket via CALIB thresholds
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` s
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_test_split_h12_v1` sp
    ON s.week_start_date = sp.decision_week AND sp.paper_split = 'VAL_TUNE'
  LEFT JOIN vb_thresholds vbt
    ON vbt.season_group = s.season_group AND vbt.demand_decile = s.demand_decile
  WHERE s.split = 'VAL'
    AND s.amplitude >= 10.0  -- active demand scope only
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
with_q90 AS (
  SELECT
    t.*,
    -- provisional q90 (no correction)
    GREATEST(0.0,
      t.yhat_p50_12w + COALESCE(q.q_score_p90, 1.645) * t.scale
    ) AS q90_provisional
  FROM with_segment t
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1` q
    ON q.segment_id_child = t.segment_id_child
)
SELECT
  *,
  CASE WHEN y_true_12w > q90_provisional THEN 1 ELSE 0 END AS viol_p90_provisional
FROM with_q90;

-- ---------------------------------------------------------------------------
-- 4c. CORRECTION FACTORS  -> quantile_factors_h12_v1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.quantile_factors_h12_v1` AS

WITH

-- Child-level viol_rate and n_obs on VAL_TUNE
child_viol AS (
  SELECT
    segment_id_child,
    season_group,
    COUNT(*)                            AS n_obs_tune,
    AVG(viol_p90_provisional)           AS viol_rate_p90
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_valtune_h12_v1`
  GROUP BY segment_id_child, season_group
),

-- Season-level fallback viol_rate
season_viol AS (
  SELECT
    season_group,
    COUNT(*)                AS n_obs_tune_season,
    AVG(viol_p90_provisional) AS viol_rate_p90_season
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_valtune_h12_v1`
  GROUP BY season_group
),

-- All segments from lookup
all_segments AS (
  SELECT DISTINCT segment_id_child, season_group
  FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1`
),

joined AS (
  SELECT
    a.segment_id_child,
    a.season_group,
    COALESCE(cv.n_obs_tune, 0)    AS n_obs_tune,
    cv.viol_rate_p90              AS viol_rate_p90_child,
    sv.viol_rate_p90_season       AS viol_rate_p90_season,
    sv.n_obs_tune_season
  FROM all_segments a
  LEFT JOIN child_viol cv USING (segment_id_child, season_group)
  LEFT JOIN season_viol sv USING (season_group)
),

with_factor AS (
  SELECT
    *,
    -- pick the most granular rate with sufficient data
    CASE
      WHEN n_obs_tune >= 50        THEN viol_rate_p90_child
      WHEN n_obs_tune_season >= 20 THEN viol_rate_p90_season
      ELSE 0.10  -- target rate (correction = 1.0)
    END AS effective_viol_rate_p90,
    CASE
      WHEN n_obs_tune >= 50        THEN 'child'
      WHEN n_obs_tune_season >= 20 THEN 'season'
      ELSE 'global'
    END AS factor_source
  FROM joined
)
SELECT
  *,
  -- correction_factor = clip(viol_rate / target, lo, hi)
  LEAST(3.00, GREATEST(0.80,
    SAFE_DIVIDE(effective_viol_rate_p90, 0.10)
  )) AS correction_factor
FROM with_factor;

SELECT
  factor_source,
  COUNT(*) AS n_segments,
  ROUND(AVG(correction_factor), 4) AS avg_correction,
  ROUND(MIN(correction_factor), 4) AS min_correction,
  ROUND(MAX(correction_factor), 4) AS max_correction
FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_factors_h12_v1`
GROUP BY factor_source;
