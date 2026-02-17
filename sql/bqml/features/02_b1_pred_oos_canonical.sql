-- B1: Canonical p(OOS) table (proxy censoring probability)

CREATE OR REPLACE TABLE `{dataset_ref}.pred_oos_h4_canonical` AS
SELECT
  s.week_start_date,
  s.sku_id,
  s.split,
  s.season_group,
  s.hhi_bucket,
  s.segment_keys,
  s.is_demand_active,
  s.sales,
  COALESCE(c.prob_oos_platt, c.prob_oos_raw, 0.0) AS p_oos,
  c.y_oos_h4 AS y_oos_proxy,
  'proxy_oos_risk_sales_only' AS oos_semantics
FROM `{dataset_ref}.optionb_spine_h4` s
LEFT JOIN `{dataset_ref}.score_oos_h4_calibrated` c
  ON s.sku_id = c.sku_id
 AND s.week_start_date = c.week_start_date
WHERE s.split IN ('TRAIN', 'CALIB', 'VAL');
