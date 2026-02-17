-- B5: Option B ablation scorecard (requires quantile and policy outputs)

CREATE OR REPLACE TABLE `{dataset_ref}.optionb_ablation_scorecard_h4` AS
WITH q_gate AS (
  SELECT
    COUNTIF(gate_b3_p90_cond_status = 'PASS') AS n_segments_pass,
    COUNT(*) AS n_segments
  FROM `{dataset_ref}.b3_quantiles_gate_h4`
),
policy_gate AS (
  SELECT
    COUNTIF(fill_rate_status = 'PASS') AS n_policy_pass,
    COUNT(*) AS n_policy
  FROM `{dataset_ref}.b4_policy_gate_h4`
)
SELECT
  'B3_conditional_coverage' AS check_name,
  SAFE_DIVIDE(n_segments_pass, n_segments) AS score,
  CASE WHEN SAFE_DIVIDE(n_segments_pass, n_segments) >= 0.7 THEN 'PASS' ELSE 'FAIL' END AS status
FROM q_gate
UNION ALL
SELECT
  'B4_fill_rate_constraint' AS check_name,
  SAFE_DIVIDE(n_policy_pass, n_policy) AS score,
  CASE WHEN SAFE_DIVIDE(n_policy_pass, n_policy) >= 0.7 THEN 'PASS' ELSE 'FAIL' END AS status
FROM policy_gate;
