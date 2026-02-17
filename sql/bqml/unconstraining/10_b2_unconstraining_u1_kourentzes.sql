-- B2-U1: Kourentzes-inspired unconstraining (small-demand robust uplift)
-- Sales-only adaptation: uplift observed sales by censoring risk and local amplitude

CREATE OR REPLACE TABLE `{dataset_ref}.demand_uc_u1_kourentzes_h4` AS
WITH local_stats AS (
  SELECT
    sku_id,
    week_start_date,
    sales,
    p_oos,
    split,
    season_group,
    hhi_bucket,
    segment_keys,
    is_demand_active,
    -- Approximate p80 using mean + 0.84*stddev (z-score for 80th percentile)
    -- BigQuery does not support PERCENTILE_CONT with ORDER BY in window frames
    AVG(sales) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING
    ) + 0.84 * COALESCE(
      STDDEV(sales) OVER (
        PARTITION BY sku_id
        ORDER BY week_start_date
        ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING
      ), 0.0
    ) AS p80_hist,
    AVG(sales) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING
    ) AS mean13_hist
  FROM `{dataset_ref}.pred_oos_h4_canonical`
)
SELECT
  week_start_date,
  sku_id,
  split,
  season_group,
  hhi_bucket,
  segment_keys,
  sales,
  p_oos,
  is_demand_active,
  GREATEST(
    sales,
    sales + LEAST(0.85, GREATEST(0.0, p_oos)) * GREATEST(COALESCE(p80_hist, mean13_hist, sales), sales) * 0.35
  ) AS demand_uc_u1,
  'u1_kourentzes_inspired_sales_only' AS uc_method
FROM local_stats;
