-- B3-Q1: Point forecast model over unconstrained demand (for split-conformal)

CREATE OR REPLACE MODEL `{dataset_ref}.m_demand_uc_point_h4`
OPTIONS(
  model_type = 'BOOSTED_TREE_REGRESSOR',
  input_label_cols = ['target_demand'],
  max_iterations = 80,
  max_tree_depth = 6,
  subsample = 0.8,
  min_split_loss = 0.0
) AS
SELECT
  u.demand_uc_u2 AS target_demand,
  w.lag_1,
  w.lag_2,
  w.lag_4,
  w.roll4_mean,
  w.roll13_mean,
  w.amplitude,
  w.hhi_base_roll13,
  w.is_high_season,
  w.iso_week,
  w.month
FROM `{dataset_ref}.demand_unconstrained_h4` u
JOIN `{dataset_ref}.weekly_features_h4` w
  ON u.sku_id = w.sku_id
 AND u.week_start_date = w.week_start_date
WHERE u.flags.split = 'TRAIN'
  AND u.flags.is_demand_active = 1;

CREATE OR REPLACE TABLE `{dataset_ref}.pred_point_uc_h4` AS
SELECT
  p.week_start_date,
  p.sku_id,
  p.split,
  s.season_group,
  s.hhi_bucket,
  p.predicted_target_demand AS yhat_point,
  u.demand_uc_u2 AS y_true_uc
FROM ML.PREDICT(
  MODEL `{dataset_ref}.m_demand_uc_point_h4`,
  (
    SELECT
      week_start_date,
      sku_id,
      split,
      lag_1,
      lag_2,
      lag_4,
      roll4_mean,
      roll13_mean,
      amplitude,
      hhi_base_roll13,
      is_high_season,
      iso_week,
      month
    FROM `{dataset_ref}.weekly_features_h4`
    WHERE split IN ('CALIB', 'VAL')
  )
) p
LEFT JOIN `{dataset_ref}.optionb_spine_h4` s
  ON p.sku_id = s.sku_id
 AND p.week_start_date = s.week_start_date
LEFT JOIN `{dataset_ref}.demand_unconstrained_h4` u
  ON p.sku_id = u.sku_id
 AND p.week_start_date = u.week_start_date;
