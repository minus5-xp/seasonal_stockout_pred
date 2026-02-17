-- B4: Policy scenario inputs (lead-time sensitivity and service targets)

CREATE OR REPLACE TABLE `{dataset_ref}.policy_scenarios_h4` AS
SELECT 1 AS lead_time_weeks, 0.90 AS beta_target UNION ALL
SELECT 2 AS lead_time_weeks, 0.90 AS beta_target UNION ALL
SELECT 4 AS lead_time_weeks, 0.90 AS beta_target UNION ALL
SELECT 1 AS lead_time_weeks, 0.95 AS beta_target UNION ALL
SELECT 2 AS lead_time_weeks, 0.95 AS beta_target UNION ALL
SELECT 4 AS lead_time_weeks, 0.95 AS beta_target;

CREATE OR REPLACE TABLE `{dataset_ref}.policy_sim_inputs_h4` AS
SELECT
  q.week_start_date,
  q.sku_id,
  q.season_group,
  q.hhi_bucket,
  q.demand_uc_true AS demand_proxy,
  q.p50,
  q.p90,
  q.p95,
  u.demand_uc_naive,
  u.demand_uc_u1,
  u.demand_uc_u2,
  s.lead_time_weeks,
  s.beta_target
FROM `{dataset_ref}.pred_quantiles_h4` q
JOIN `{dataset_ref}.demand_unconstrained_h4` u
  ON q.sku_id = u.sku_id
 AND q.week_start_date = u.week_start_date
CROSS JOIN `{dataset_ref}.policy_scenarios_h4` s
WHERE q.split = 'VAL';
