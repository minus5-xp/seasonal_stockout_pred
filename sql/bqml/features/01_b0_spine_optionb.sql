-- B0: Canonical spine with segment keys and active-demand flag

CREATE OR REPLACE TABLE `{dataset_ref}.optionb_spine_h4` AS
WITH base AS (
  SELECT
    sku_id,
    week_start_date,
    y_sales AS sales,
    split,
    is_high_season,
    CASE
      WHEN is_high_season = 1 THEN 'HIGH_SEASON'
      WHEN is_high_season = 0 THEN 'REST'
      ELSE 'UNK'
    END AS season_group,
    hhi_base_roll13,
    CASE
      WHEN hhi_base_roll13 IS NULL THEN 'UNK'
      WHEN hhi_base_roll13 < 0.33 THEN 'LOW'
      WHEN hhi_base_roll13 < 0.66 THEN 'MEDIUM'
      ELSE 'HIGH'
    END AS hhi_bucket,
    roll13_mean,
    amplitude,
    y_oos_h4,
    CASE
      WHEN y_sales > 0 OR COALESCE(roll13_mean, 0) >= 1 THEN 1
      ELSE 0
    END AS is_demand_active
  FROM `{dataset_ref}.weekly_features_h4`
)
SELECT
  b.*,
  CONCAT(
    'season=', COALESCE(season_group, 'UNK'),
    '|hhi=', COALESCE(hhi_bucket, 'UNK')
  ) AS segment_keys,
  f.fold_id
FROM base b
LEFT JOIN `{dataset_ref}.optionb_rolling_folds_h4` f
  ON b.week_start_date BETWEEN f.fold_start AND f.fold_end;
