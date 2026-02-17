-- B3 FIX v2: Summary gate check

CREATE OR REPLACE TABLE `{dataset_ref}.b3_fix_gate_summary_h4` AS
WITH global_stats AS (
  SELECT
    'GLOBAL' AS segment_level,
    'ALL' AS segment_name,
    COUNT(*) AS n_obs,
    COUNTIF(is_demand_active = 1) AS n_active,
    ROUND(SAFE_DIVIDE(
      COUNTIF(is_demand_active = 1 AND covered_p90 = 0),
      COUNTIF(is_demand_active = 1)
    ), 4) AS viol_rate_p90_cond,
    ROUND(AVG(pred_p90 - pred_p50), 2) AS sharpness_p90_p50
  FROM `{dataset_ref}.pred_quantiles_v2_h4`
  WHERE split = 'val'
),
seg2_stats AS (
  SELECT
    'SEG2' AS segment_level,
    seg2 AS segment_name,
    n_obs,
    n_active,
    viol_rate_p90_cond,
    sharpness_p90_p50
  FROM `{dataset_ref}.eval_quantiles_conditional_v2_h4`
  WHERE scope = 'seg2'
),
combined AS (
  SELECT * FROM global_stats
  UNION ALL
  SELECT * FROM seg2_stats
),
gate_check AS (
  SELECT
    segment_level,
    segment_name,
    n_obs,
    n_active,
    viol_rate_p90_cond,
    sharpness_p90_p50,
    CASE
      WHEN viol_rate_p90_cond BETWEEN 0.08 AND 0.12 THEN 'PASS'
      ELSE 'FAIL'
    END AS gate_status
  FROM combined
)
SELECT
  segment_level,
  segment_name,
  n_obs,
  n_active,
  viol_rate_p90_cond,
  sharpness_p90_p50,
  gate_status,
  CURRENT_TIMESTAMP() AS evaluated_at
FROM gate_check
ORDER BY
  CASE segment_level WHEN 'GLOBAL' THEN 0 ELSE 1 END,
  gate_status DESC,
  viol_rate_p90_cond;
