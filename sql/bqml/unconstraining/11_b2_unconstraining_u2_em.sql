-- B2-U2: EM-like likelihood/reweighting unconstraining with probabilistic censoring
-- Iteration approximated analytically to keep pure SQL reproducibility in BQ

CREATE OR REPLACE TABLE `{dataset_ref}.demand_uc_u2_em_h4` AS
WITH base AS (
  SELECT
    p.*,
    AVG(sales) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 13 PRECEDING AND 1 PRECEDING
    ) AS mean13_hist,
    STDDEV(sales) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 26 PRECEDING AND 1 PRECEDING
    ) AS sd26_hist
  FROM `{dataset_ref}.pred_oos_h4_canonical` p
),
estep AS (
  SELECT
    *,
    GREATEST(0.0, COALESCE(mean13_hist, sales) - sales) AS expected_gap,
    LEAST(0.95, GREATEST(0.0, p_oos)) AS w_censor
  FROM base
),
mstep AS (
  SELECT
    *,
    sales + w_censor * expected_gap + 0.15 * w_censor * COALESCE(sd26_hist, 0.0) AS demand_iter1
  FROM estep
),
iter2 AS (
  SELECT
    *,
    AVG(demand_iter1) OVER (
      PARTITION BY sku_id
      ORDER BY week_start_date
      ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING
    ) AS local_uc_mean
  FROM mstep
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
    0.65 * demand_iter1 + 0.35 * COALESCE(local_uc_mean, demand_iter1)
  ) AS demand_uc_u2,
  'u2_em_like_prob_censoring' AS uc_method
FROM iter2;
