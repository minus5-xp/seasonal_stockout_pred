-- B4 gate helper: summary table expected from Python simulation output
-- policy_sim.py writes/updates `{dataset_ref}.policy_sim_results_h4` externally.

CREATE OR REPLACE TABLE `{dataset_ref}.b4_policy_gate_h4` AS
SELECT
  policy_name,
  lead_time_weeks,
  beta_target,
  AVG(fill_rate) AS fill_rate_avg,
  AVG(lost_sales_proxy) AS lost_sales_proxy_avg,
  AVG(holding_proxy) AS holding_proxy_avg,
  AVG(total_cost_proxy) AS total_cost_proxy_avg,
  CASE
    WHEN AVG(fill_rate) >= beta_target - 0.01 THEN 'PASS'
    ELSE 'FAIL'
  END AS fill_rate_status
FROM `{dataset_ref}.policy_sim_results_h4`
GROUP BY policy_name, lead_time_weeks, beta_target;
