-- B3 Gate: conditional P90 coverage diagnostics by segment

CREATE OR REPLACE TABLE `{dataset_ref}.b3_quantiles_gate_h4` AS
WITH base AS (
  SELECT
    q.season_group,
    q.hhi_bucket,
    q.split,
    q.demand_uc_true,
    q.p90,
    q.p95,
    u.flags.is_demand_active AS is_demand_active,
    CASE WHEN q.demand_uc_true > q.p90 THEN 1 ELSE 0 END AS viol90,
    CASE WHEN q.demand_uc_true > q.p95 THEN 1 ELSE 0 END AS viol95
  FROM `{dataset_ref}.pred_quantiles_h4` q
  LEFT JOIN `{dataset_ref}.demand_unconstrained_h4` u
    ON q.sku_id = u.sku_id
   AND q.week_start_date = u.week_start_date
  WHERE q.split = 'VAL'
),
agg AS (
  SELECT
    season_group,
    hhi_bucket,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(viol90), COUNT(*)) AS viol_rate_p90,
    SAFE_DIVIDE(SUM(viol95), COUNT(*)) AS viol_rate_p95,
    SAFE_DIVIDE(SUM(CASE WHEN is_demand_active = 1 THEN viol90 ELSE 0 END),
                NULLIF(SUM(CASE WHEN is_demand_active = 1 THEN 1 ELSE 0 END), 0)) AS viol_rate_p90_cond,
    SAFE_DIVIDE(SUM(CASE WHEN is_demand_active = 1 THEN viol95 ELSE 0 END),
                NULLIF(SUM(CASE WHEN is_demand_active = 1 THEN 1 ELSE 0 END), 0)) AS viol_rate_p95_cond
  FROM base
  GROUP BY season_group, hhi_bucket
)
SELECT
  season_group,
  hhi_bucket,
  n_obs,
  viol_rate_p90,
  viol_rate_p95,
  viol_rate_p90_cond,
  viol_rate_p95_cond,
  ABS(viol_rate_p90_cond - 0.10) AS deviation_p90_cond,
  ABS(viol_rate_p95_cond - 0.05) AS deviation_p95_cond,
  CASE
    WHEN viol_rate_p90_cond BETWEEN 0.08 AND 0.12 THEN 'PASS'
    ELSE 'FAIL'
  END AS gate_b3_p90_cond_status
FROM agg;
