-- B3 FIX v2: Split calibration window into CALIB_A (first 13w) and CALIB_B (last 13w)
-- for nested tuning of coverage targets

CREATE OR REPLACE TABLE `{dataset_ref}.calibration_windows_h4` AS
WITH calib_dates AS (
  SELECT
    MIN(week_start_date) AS calib_start,
    MAX(week_start_date) AS calib_end,
    DATE_ADD(MIN(week_start_date), INTERVAL 13 WEEK) AS calib_mid
  FROM `{dataset_ref}.pred_point_uc_h4`
  WHERE split = 'calib'
)
SELECT
  p.week_start_date,
  p.sku_id,
  p.split,
  p.season_group,
  p.hhi_bucket,
  p.yhat_point,
  p.y_true_uc,
  v.volatility_bucket,
  -- Define sub-splits within calibration
  CASE
    WHEN p.split = 'calib' AND p.week_start_date < (SELECT calib_mid FROM calib_dates) THEN 'calib_a'
    WHEN p.split = 'calib' AND p.week_start_date >= (SELECT calib_mid FROM calib_dates) THEN 'calib_b'
    ELSE p.split
  END AS split_refined,
  -- Residual for conformity score
  p.y_true_uc - p.yhat_point AS residual
FROM `{dataset_ref}.pred_point_uc_h4` p
LEFT JOIN `{dataset_ref}.volatility_buckets_h4` v
  ON p.sku_id = v.sku_id;
