-- B3 FIX v2: Nested tuning of coverage_target per segment using CALIB_B
-- Searches grid [0.88, 0.90, 0.92, 0.94, 0.96, 0.98] to find target that achieves [8%, 12%] violation

CREATE OR REPLACE TABLE `{dataset_ref}.segment_coverage_targets_v2_h4` AS
WITH coverage_grid AS (
  SELECT target FROM UNNEST([0.88, 0.90, 0.92, 0.94, 0.96, 0.98]) AS target
),
calib_a_scores AS (
  SELECT
    seg2,
    residual AS score_upper
  FROM `{dataset_ref}.mondrian_quantiles_v2_h4`
  WHERE split_refined = 'calib_a'
),
calib_b_data AS (
  SELECT
    seg2,
    y_true_uc,
    yhat_point,
    residual,
    CASE WHEN y_true_uc > 0 THEN 1 ELSE 0 END AS is_demand_active
  FROM `{dataset_ref}.mondrian_quantiles_v2_h4`
  WHERE split_refined = 'calib_b'
),
quantiles_per_target AS (
  SELECT
    s.seg2,
    g.target AS coverage_target,
    APPROX_QUANTILES(s.score_upper, 1000)[OFFSET(CAST(g.target * 1000 AS INT64))] AS qhat
  FROM calib_a_scores s
  CROSS JOIN coverage_grid g
  GROUP BY s.seg2, g.target
),
evaluate_calib_b AS (
  SELECT
    q.seg2,
    q.coverage_target,
    q.qhat,
    COUNT(*) AS n_total,
    COUNTIF(b.is_demand_active = 1) AS n_active,
    COUNTIF(b.is_demand_active = 1 AND b.y_true_uc > (b.yhat_point + q.qhat)) AS n_violations_active,
    SAFE_DIVIDE(
      COUNTIF(b.is_demand_active = 1 AND b.y_true_uc > (b.yhat_point + q.qhat)),
      COUNTIF(b.is_demand_active = 1)
    ) AS viol_rate_conditional
  FROM quantiles_per_target q
  JOIN calib_b_data b
    ON q.seg2 = b.seg2
  GROUP BY q.seg2, q.coverage_target, q.qhat
),
best_target_per_segment AS (
  SELECT
    seg2,
    coverage_target,
    qhat,
    n_total,
    n_active,
    viol_rate_conditional,
    ABS(viol_rate_conditional - 0.10) AS deviation_from_10pct,
    -- Rank by deviation from 10% (ideal target)
    ROW_NUMBER() OVER (
      PARTITION BY seg2
      ORDER BY 
        CASE WHEN viol_rate_conditional BETWEEN 0.08 AND 0.12 THEN 0 ELSE 1 END,
        ABS(viol_rate_conditional - 0.10)
    ) AS rn
  FROM evaluate_calib_b
  WHERE n_active >= 20  -- Minimum support for tuning (lowered from 50)
)
SELECT
  seg2,
  coverage_target AS tuned_coverage_target,
  qhat AS tuned_qhat,
  n_total,
  n_active,
  viol_rate_conditional AS calibb_viol_rate,
  deviation_from_10pct,
  CASE
    WHEN viol_rate_conditional BETWEEN 0.08 AND 0.12 THEN 'PASS'
    ELSE 'FAIL'
  END AS calibb_gate_status
FROM best_target_per_segment
WHERE rn = 1;
