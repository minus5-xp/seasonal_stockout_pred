-- B3 FIX v2: Apply tuned coverage targets to VAL split and generate final quantiles

CREATE OR REPLACE TABLE `{dataset_ref}.pred_quantiles_v2_h4` AS
WITH calib_a_scores AS (
  SELECT
    seg2,
    residual AS score_upper
  FROM `{dataset_ref}.mondrian_quantiles_v2_h4`
  WHERE split_refined = 'calib_a'
),
quantiles_tuned AS (
  SELECT
    s.seg2,
    t.tuned_coverage_target,
    APPROX_QUANTILES(s.score_upper, 1000)[
      OFFSET(CAST(t.tuned_coverage_target * 1000 AS INT64))
    ] AS qhat_tuned_p90
  FROM calib_a_scores s
  LEFT JOIN `{dataset_ref}.segment_coverage_targets_v2_h4` t
    ON s.seg2 = t.seg2
  WHERE t.seg2 IS NOT NULL  -- Only seg2 with tuned targets
  GROUP BY s.seg2, t.tuned_coverage_target
),
val_predictions AS (
  SELECT
    m.week_start_date,
    m.sku_id,
    m.split,
    m.season_group,
    m.hhi_bucket,
    m.volatility_bucket,
    m.seg2,
    m.yhat_point,
    m.y_true_uc,
    COALESCE(q.qhat_tuned_p90, m.qhat_p90_final) AS qhat_applied,
    COALESCE(q.tuned_coverage_target, 0.90) AS coverage_target_applied,
    CASE WHEN q.seg2 IS NOT NULL THEN 'tuned' ELSE 'default' END AS tuning_source
  FROM `{dataset_ref}.mondrian_quantiles_v2_h4` m
  LEFT JOIN quantiles_tuned q
    ON m.seg2 = q.seg2
  WHERE m.split = 'val'
)
SELECT
  week_start_date,
  sku_id,
  split,
  season_group,
  hhi_bucket,
  volatility_bucket,
  seg2,
  yhat_point AS pred_p50,
  yhat_point + qhat_applied AS pred_p90,
  -- For completeness, also provide P95 (slightly higher multiplier)
  yhat_point + (qhat_applied * 1.15) AS pred_p95,
  y_true_uc,
  qhat_applied,
  coverage_target_applied,
  tuning_source,
  -- Evaluate coverage
  CASE WHEN y_true_uc > 0 THEN 1 ELSE 0 END AS is_demand_active,
  CASE WHEN y_true_uc <= (yhat_point + qhat_applied) THEN 1 ELSE 0 END AS covered_p90
FROM val_predictions;
