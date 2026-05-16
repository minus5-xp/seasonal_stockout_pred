-- ============================================================================
-- STEP 03: RESIDUALS + SEGMENT QUANTILE LOOKUP  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   Compute scale-normalised conformity scores on CALIB split and build a
--   segment × quantile lookup table (Mondrian conformal prediction).
--
--   Segment key = season_group × demand_decile × volatility_bucket
--
-- ACTIVE DEMAND SCOPE:
--   amplitude >= 10.0   (H12 uses 10 instead of H4's 5.0 to reflect
--                        larger 12-week aggregation — threshold is in unit-weeks)
--   Rows below threshold contribute to volatility_bucket thresholds (NTILE)
--   but are set to NULL score — BigQuery APPROX_QUANTILES ignores NULLs.
--
-- QUANTILES:  q75, q80, q85, q90, q95, q99
--
-- INPUT:   base_scores_h12_v1  (from step 02b)
-- OUTPUT:
--   residuals_h12_v1
--   volatility_bucket_thresholds_h12_v1
--   quantile_lookup_h12_v1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 3a. RESIDUALS ON CALIB
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1` AS
WITH scored AS (
  SELECT
    sku_id,
    week_start_date,
    split,
    season_group,
    demand_decile,
    y_true_12w,
    yhat_p50_12w,
    scale,
    amplitude,
    cv_13w,
    stockout_event_12w,
    p_oos_h12,

    -- normalised conformity score (NULL for inactive demand)
    CASE
      WHEN amplitude >= 10.0
        THEN SAFE_DIVIDE(y_true_12w - yhat_p50_12w, scale)
      ELSE NULL
    END AS score,

    -- volatility bucket on ALL CALIB rows (stable, not population-dependent for score)
    NTILE(5) OVER (
      PARTITION BY season_group, demand_decile
      ORDER BY COALESCE(cv_13w, 0.0)
    ) AS volatility_bucket

  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split = 'CALIB'
)
SELECT
  *,
  CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'))
    AS segment_id_parent,
  CONCAT(
    season_group,
    '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
    '_V', CAST(volatility_bucket AS STRING)
  ) AS segment_id_child
FROM scored;

-- ---------------------------------------------------------------------------
-- 3b. EXPORT VOLATILITY BUCKET THRESHOLDS (CALIB percentiles of cv_13w)
-- ---------------------------------------------------------------------------
-- These are used in steps 04/05 to assign consistent volatility buckets
-- to TRAIN/VAL rows without re-running NTILE on a different population.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1` AS
WITH cv_sorted AS (
  SELECT
    season_group,
    demand_decile,
    COALESCE(cv_13w, 0.0) AS cv_13w_val,
    NTILE(5) OVER (
      PARTITION BY season_group, demand_decile
      ORDER BY COALESCE(cv_13w, 0.0)
    ) AS bucket
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split = 'CALIB'
),
thresholds AS (
  SELECT
    season_group,
    demand_decile,
    MAX(CASE WHEN bucket = 1 THEN cv_13w_val ELSE NULL END) AS cv_thresh_v1,
    MAX(CASE WHEN bucket = 2 THEN cv_13w_val ELSE NULL END) AS cv_thresh_v2,
    MAX(CASE WHEN bucket = 3 THEN cv_13w_val ELSE NULL END) AS cv_thresh_v3,
    MAX(CASE WHEN bucket = 4 THEN cv_13w_val ELSE NULL END) AS cv_thresh_v4
  FROM cv_sorted
  GROUP BY season_group, demand_decile
)
SELECT * FROM thresholds;

-- ---------------------------------------------------------------------------
-- 3c. SEGMENT QUANTILE LOOKUP (Mondrian conformal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1` AS

-- Child-level (season × decile × volatility)
WITH child_scores AS (
  SELECT
    segment_id_child,
    segment_id_parent,
    season_group,
    demand_decile,
    volatility_bucket,
    COUNT(score)  AS n_calib,          -- active-demand only (NULLs excluded)
    COUNT(*)      AS n_calib_all,
    -- empirical quantiles (NULLs = inactive rows ignored automatically)
    APPROX_QUANTILES(score, 100)[OFFSET(75)]  AS q_score_p75,
    APPROX_QUANTILES(score, 100)[OFFSET(80)]  AS q_score_p80,
    APPROX_QUANTILES(score, 100)[OFFSET(85)]  AS q_score_p85,
    APPROX_QUANTILES(score, 100)[OFFSET(90)]  AS q_score_p90,
    APPROX_QUANTILES(score, 100)[OFFSET(95)]  AS q_score_p95,
    APPROX_QUANTILES(score, 100)[OFFSET(99)]  AS q_score_p99
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1`
  GROUP BY segment_id_child, segment_id_parent, season_group, demand_decile, volatility_bucket
),

-- Parent fallback (season × decile)
parent_scores AS (
  SELECT
    segment_id_parent,
    season_group,
    demand_decile,
    COUNT(score)  AS n_calib_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(75)]  AS q_score_p75_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(80)]  AS q_score_p80_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(85)]  AS q_score_p85_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(90)]  AS q_score_p90_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(95)]  AS q_score_p95_parent,
    APPROX_QUANTILES(score, 100)[OFFSET(99)]  AS q_score_p99_parent
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1`
  GROUP BY segment_id_parent, season_group, demand_decile
),

-- Final with child fallback to parent
combined AS (
  SELECT
    c.segment_id_child,
    c.segment_id_parent,
    c.season_group,
    c.demand_decile,
    c.volatility_bucket,
    c.n_calib          AS n_calib_child,
    p.n_calib_parent,
    -- choose child if enough obs, otherwise parent
    CASE WHEN c.n_calib >= 30
      THEN c.q_score_p75  ELSE p.q_score_p75_parent END AS q_score_p75,
    CASE WHEN c.n_calib >= 30
      THEN c.q_score_p80  ELSE p.q_score_p80_parent END AS q_score_p80,
    CASE WHEN c.n_calib >= 30
      THEN c.q_score_p85  ELSE p.q_score_p85_parent END AS q_score_p85,
    CASE WHEN c.n_calib >= 30
      THEN c.q_score_p90  ELSE p.q_score_p90_parent END AS q_score_p90,
    CASE WHEN c.n_calib >= 30
      THEN c.q_score_p95  ELSE p.q_score_p95_parent END AS q_score_p95,
    CASE WHEN c.n_calib >= 30
      THEN c.q_score_p99  ELSE p.q_score_p99_parent END AS q_score_p99,
    CASE WHEN c.n_calib >= 30 THEN 'child' ELSE 'parent' END AS fallback_level
  FROM child_scores c
  LEFT JOIN parent_scores p USING (segment_id_parent, season_group, demand_decile)
)
SELECT * FROM combined;

-- Diagnostic: coverage of lookup table
SELECT
  fallback_level,
  COUNT(*) AS n_segments,
  ROUND(AVG(n_calib_child), 1) AS avg_n_calib,
  ROUND(AVG(q_score_p90), 3)   AS avg_q90_score,
  ROUND(AVG(q_score_p95), 3)   AS avg_q95_score
FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1`
GROUP BY fallback_level;
