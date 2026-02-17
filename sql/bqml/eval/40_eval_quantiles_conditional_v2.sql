-- B3 FIX v2: Evaluation of conditional coverage on VAL split by segment

CREATE OR REPLACE TABLE `{dataset_ref}.eval_quantiles_conditional_v2_h4` AS
WITH seg2_stats AS (
  SELECT
    'seg2' AS scope,
    season_group,
    hhi_bucket,
    COALESCE(volatility_bucket, 'UNK') AS volatility_bucket,
    seg2,
    COUNT(*) AS n_obs,
    COUNTIF(is_demand_active = 1) AS n_active,
    -- Conditional coverage (only when demand > 0)
    SAFE_DIVIDE(
      COUNTIF(is_demand_active = 1 AND covered_p90 = 0),
      COUNTIF(is_demand_active = 1)
    ) AS viol_rate_p90_cond,
    -- Sharpness: average interval width
    AVG(pred_p90 - pred_p50) AS sharpness_p90_p50,
    -- Pinball loss for P90 (α = 0.9)
    AVG(
      CASE
        WHEN y_true_uc > pred_p90 THEN 0.9 * (y_true_uc - pred_p90)
        ELSE 0.1 * (pred_p90 - y_true_uc)
      END
    ) AS pinball_p90
  FROM `{dataset_ref}.pred_quantiles_v2_h4`
  WHERE split = 'val'
  GROUP BY season_group, hhi_bucket, volatility_bucket, seg2
  HAVING COUNTIF(is_demand_active = 1) >= 5  -- Minimum support (lowered to 5 for smaller segments)
)
SELECT
  scope,
  season_group,
  hhi_bucket,
  volatility_bucket,
  seg2,
  n_obs,
  n_active,
  ROUND(viol_rate_p90_cond, 4) AS viol_rate_p90_cond,
  ROUND(ABS(viol_rate_p90_cond - 0.10), 4) AS deviation_p90_cond,
  ROUND(sharpness_p90_p50, 2) AS sharpness_p90_p50,
  ROUND(pinball_p90, 3) AS pinball_p90,
  CASE
    WHEN viol_rate_p90_cond BETWEEN 0.08 AND 0.12 THEN 'PASS'
    ELSE 'FAIL'
  END AS gate_status
FROM seg2_stats
ORDER BY 
  ABS(viol_rate_p90_cond - 0.10) ASC;
