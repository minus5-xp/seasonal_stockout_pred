-- B3 FIX v2: Volatility bucketing for refined Mondrian segmentation
-- Computes coefficient of variation (CV) per SKU over rolling window
-- and assigns volatility buckets within each (season_group, hhi_bucket) stratum

CREATE OR REPLACE TABLE `{dataset_ref}.volatility_buckets_h4` AS
WITH rolling_stats AS (
  SELECT
    sku_id,
    season_group,
    hhi_bucket,
    split,
    -- Rolling 12-week window for CV calculation
    AVG(y_true_uc) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS mean_12w,
    STDDEV(y_true_uc) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS sd_12w,
    COUNT(*) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
    ) AS n_obs_12w
  FROM `{dataset_ref}.pred_point_uc_h4`
  WHERE split IN ('calib', 'val')
),
cv_per_sku AS (
  SELECT
    sku_id,
    season_group,
    hhi_bucket,
    -- Coefficient of variation: CV = sd / mean (robust to scale)
    CASE
      WHEN mean_12w > 0.1 AND n_obs_12w >= 8 
      THEN sd_12w / mean_12w
      ELSE NULL
    END AS cv_12w,
    n_obs_12w
  FROM rolling_stats
  WHERE split = 'calib'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY sku_id ORDER BY n_obs_12w DESC) = 1
),
global_quantiles AS (
  SELECT
    APPROX_QUANTILES(cv_12w, 4) AS cv_quartiles
  FROM cv_per_sku
  WHERE cv_12w IS NOT NULL
)
SELECT
  c.sku_id,
  c.season_group,
  c.hhi_bucket,
  c.cv_12w,
  -- Assign volatility bucket using global quartiles
  CASE
    WHEN c.cv_12w IS NULL THEN 'UNK'
    WHEN c.cv_12w <= (SELECT cv_quartiles[OFFSET(1)] FROM global_quantiles) THEN 'LOW_VOL'
    WHEN c.cv_12w <= (SELECT cv_quartiles[OFFSET(2)] FROM global_quantiles) THEN 'MED_VOL'
    WHEN c.cv_12w <= (SELECT cv_quartiles[OFFSET(3)] FROM global_quantiles) THEN 'HIGH_VOL'
    ELSE 'EXTREME_VOL'
  END AS volatility_bucket,
  c.n_obs_12w
FROM cv_per_sku c;
