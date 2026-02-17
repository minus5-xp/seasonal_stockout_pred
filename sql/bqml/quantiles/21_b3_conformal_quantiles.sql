-- B3-Q1: Mondrian split-conformal quantiles by season_group x hhi_bucket

CREATE OR REPLACE TABLE `{dataset_ref}.conformal_scores_h4` AS
SELECT
  season_group,
  hhi_bucket,
  ABS(y_true_uc - yhat_point) AS abs_resid
FROM `{dataset_ref}.pred_point_uc_h4`
WHERE split = 'CALIB'
  AND y_true_uc IS NOT NULL;

CREATE OR REPLACE TABLE `{dataset_ref}.conformal_bands_h4` AS
SELECT
  season_group,
  hhi_bucket,
  APPROX_QUANTILES(abs_resid, 100)[OFFSET(50)] AS q50_resid,
  APPROX_QUANTILES(abs_resid, 100)[OFFSET(90)] AS q90_resid,
  APPROX_QUANTILES(abs_resid, 100)[OFFSET(95)] AS q95_resid,
  COUNT(*) AS n_calib
FROM `{dataset_ref}.conformal_scores_h4`
GROUP BY season_group, hhi_bucket;

CREATE OR REPLACE TABLE `{dataset_ref}.pred_quantiles_h4` AS
SELECT
  p.week_start_date,
  p.sku_id,
  p.split,
  p.season_group,
  p.hhi_bucket,
  p.y_true_uc AS demand_uc_true,
  GREATEST(0.0, p.yhat_point) AS p50,
  GREATEST(0.0, p.yhat_point + COALESCE(b.q90_resid, 0.0)) AS p90,
  GREATEST(0.0, p.yhat_point + COALESCE(b.q95_resid, 0.0)) AS p95,
  COALESCE(b.n_calib, 0) AS calib_support,
  'mondrian_split_conformal' AS quantile_method
FROM `{dataset_ref}.pred_point_uc_h4` p
LEFT JOIN `{dataset_ref}.conformal_bands_h4` b
  ON p.season_group = b.season_group
 AND p.hhi_bucket = b.hhi_bucket
WHERE p.split IN ('CALIB', 'VAL');
