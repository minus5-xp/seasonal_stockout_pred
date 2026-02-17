-- B2: Canonical unconstrained demand output table for paper experiments

CREATE OR REPLACE TABLE `{dataset_ref}.demand_unconstrained_h4` AS
SELECT
  p.week_start_date,
  p.sku_id,
  p.segment_keys,
  p.sales,
  p.p_oos,
  u1.demand_uc_u1,
  u2.demand_uc_u2,
  CAST(p.sales AS FLOAT64) AS demand_uc_naive,
  STRUCT(
    p.split AS split,
    p.season_group AS season_group,
    p.hhi_bucket AS hhi_bucket,
    p.is_demand_active AS is_demand_active,
    'proxy_oos_sales_only' AS censoring_semantics,
    CURRENT_TIMESTAMP() AS created_at
  ) AS flags
FROM `{dataset_ref}.pred_oos_h4_canonical` p
LEFT JOIN `{dataset_ref}.demand_uc_u1_kourentzes_h4` u1
  ON p.sku_id = u1.sku_id
 AND p.week_start_date = u1.week_start_date
LEFT JOIN `{dataset_ref}.demand_uc_u2_em_h4` u2
  ON p.sku_id = u2.sku_id
 AND p.week_start_date = u2.week_start_date;
