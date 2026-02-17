-- B3 FIX v2: Mondrian split-conformal with hierarchical fallback
-- Segments: seg3 (season|hhi|vol) → seg2 (season|hhi) → seg1 (season) → seg0 (global)
-- Uses CALIB_A for conformity scores, applies N_MIN threshold for fallback

CREATE OR REPLACE TABLE `{dataset_ref}.mondrian_quantiles_v2_h4` AS
WITH segment_keys AS (
  SELECT
    *,
    CONCAT(season_group, '|', hhi_bucket, '|', COALESCE(volatility_bucket, 'UNK')) AS seg3,
    CONCAT(season_group, '|', hhi_bucket) AS seg2,
    season_group AS seg1,
    'GLOBAL' AS seg0
  FROM `{dataset_ref}.calibration_windows_h4`
),
calib_a_scores AS (
  SELECT
    seg3,
    seg2,
    seg1,
    seg0,
    -- Conformity score for upper quantile (one-sided)
    residual AS score_upper
  FROM segment_keys
  WHERE split_refined = 'calib_a'
),
-- Compute quantiles per seg3 (season|hhi|vol)
qhat_seg3 AS (
  SELECT
    seg3,
    APPROX_QUANTILES(score_upper, 100)[OFFSET(90)] AS qhat_p90_seg3,
    COUNT(*) AS n_seg3
  FROM calib_a_scores
  GROUP BY seg3
),
-- Compute quantiles per seg2 (season|hhi)
qhat_seg2 AS (
  SELECT
    seg2,
    APPROX_QUANTILES(score_upper, 100)[OFFSET(90)] AS qhat_p90_seg2,
    COUNT(*) AS n_seg2
  FROM calib_a_scores
  GROUP BY seg2
),
-- Compute quantiles per seg1 (season)
qhat_seg1 AS (
  SELECT
    seg1,
    APPROX_QUANTILES(score_upper, 100)[OFFSET(90)] AS qhat_p90_seg1,
    COUNT(*) AS n_seg1
  FROM calib_a_scores
  GROUP BY seg1
),
-- Compute global quantile
qhat_global AS (
  SELECT
    APPROX_QUANTILES(score_upper, 100)[OFFSET(90)] AS qhat_p90_global,
    COUNT(*) AS n_global
  FROM calib_a_scores
),
-- Join all quantiles + counts for each unique seg3
quantiles_with_counts AS (
  SELECT DISTINCT
    s.seg3,
    s.seg2,
    s.seg1,
    q3.qhat_p90_seg3,
    q3.n_seg3,
    q2.qhat_p90_seg2,
    q2.n_seg2,
    q1.qhat_p90_seg1,
    q1.n_seg1,
    qg.qhat_p90_global,
    qg.n_global
  FROM calib_a_scores s
  LEFT JOIN qhat_seg3 q3 ON s.seg3 = q3.seg3
  LEFT JOIN qhat_seg2 q2 ON s.seg2 = q2.seg2
  LEFT JOIN qhat_seg1 q1 ON s.seg1 = q1.seg1
  CROSS JOIN qhat_global qg
),
fallback_logic AS (
  SELECT
    seg3,
    seg2,
    seg1,
    n_seg3,
    n_seg2,
    n_seg1,
    n_global,
    qhat_p90_seg3,
    qhat_p90_seg2,
    qhat_p90_seg1,
    qhat_p90_global,
    -- Hierarchical fallback: use finest segment with N >= N_MIN
    CASE
      WHEN n_seg3 >= 200 THEN qhat_p90_seg3
      WHEN n_seg2 >= 150 THEN qhat_p90_seg2
      WHEN n_seg1 >= 100 THEN qhat_p90_seg1
      ELSE qhat_p90_global
    END AS qhat_p90_final,
    CASE
      WHEN n_seg3 >= 200 THEN 'seg3'
      WHEN n_seg2 >= 150 THEN 'seg2'
      WHEN n_seg1 >= 100 THEN 'seg1'
      ELSE 'global'
    END AS fallback_level
  FROM quantiles_with_counts
)
SELECT
  s.week_start_date,
  s.sku_id,
  s.split,
  s.split_refined,
  s.season_group,
  s.hhi_bucket,
  s.volatility_bucket,
  s.seg3,
  s.seg2,
  s.seg1,
  s.yhat_point,
  s.y_true_uc,
  s.residual,
  f.qhat_p90_final,
  f.fallback_level,
  f.n_seg3,
  f.n_seg2,
  f.n_seg1,
  -- Construct prediction interval
  s.yhat_point AS pred_p50,
  s.yhat_point + f.qhat_p90_final AS pred_p90,
  -- Evaluate coverage
  CASE WHEN s.y_true_uc <= (s.yhat_point + f.qhat_p90_final) THEN 1 ELSE 0 END AS covered_p90
FROM segment_keys s
LEFT JOIN fallback_logic f
  ON s.seg3 = f.seg3;
