-- ============================================================================
-- STEP 03: FORECAST BALANCE GUARDRAILS  (h12_v2_final)
-- ============================================================================
-- PURPOSE:
--   Analyse q90/p50 ratio warning (3.68) without modifying q90.
--   The warning is driven by low-volume SKUs; active-demand ratio is expected ≤ 3.5.
--   Produces ratio_gate_final: PASS_ACTIVE_RATIO or WARN_LOW_VOLUME_RATIO (not FAIL).
--
-- INPUTS (read-only from h12_v2_final):
--   forecast_national_h12_v2_final
--   gate_verdict_h12_v2
--
-- OUTPUTS:
--   forecast_balance_guardrails_h12_v2_final
--   forecast_balance_examples_h12_v2_final
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_balance_guardrails_h12_v2_final` AS
WITH

val_gate_rows AS (
  SELECT
    f.*,
    SAFE_DIVIDE(f.q90_12w, NULLIF(f.yhat_p50_12w, 0)) AS q90_p50_ratio,
    COALESCE(r.cap_value, 1e9) AS cap_value
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2_final` f
  LEFT JOIN (
    SELECT decision_week, sku_id, cap_value
    FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2`
    WHERE split_original = 'VAL'
  ) r ON r.sku_id = f.sku_id AND r.decision_week = f.decision_week
  WHERE f.eval_split_v2 = 'VAL_GATE'
    AND f.yhat_p50_12w IS NOT NULL
),

cov_gate AS (
  SELECT viol_rate_p90_val_gate, viol_rate_p95_val_gate, q90_cap_rate, over_under_ratio_q90
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2`
),

-- Global metrics
global_m AS (
  SELECT
    COUNT(*)                                                         AS n_rows,
    -- ratio: all rows
    ROUND(APPROX_QUANTILES(q90_p50_ratio, 100)[OFFSET(50)], 3)     AS q90_p50_ratio_median_all,
    ROUND(APPROX_QUANTILES(q90_p50_ratio, 100)[OFFSET(75)], 3)     AS q90_p50_ratio_p75_all,
    ROUND(APPROX_QUANTILES(q90_p50_ratio, 100)[OFFSET(90)], 3)     AS q90_p50_ratio_p90_all,
    -- ratio: active volume (p50 >= 5)
    ROUND(APPROX_QUANTILES(
      CASE WHEN yhat_p50_12w >= 5 THEN q90_p50_ratio END, 100
    )[OFFSET(50)], 3)                                               AS q90_p50_ratio_median_p50_ge_5,
    ROUND(APPROX_QUANTILES(
      CASE WHEN yhat_p50_12w >= 5 THEN q90_p50_ratio END, 100
    )[OFFSET(75)], 3)                                               AS q90_p50_ratio_p75_p50_ge_5,
    ROUND(APPROX_QUANTILES(
      CASE WHEN yhat_p50_12w >= 5 THEN q90_p50_ratio END, 100
    )[OFFSET(90)], 3)                                               AS q90_p50_ratio_p90_p50_ge_5,
    -- low-volume stats (p50 < 5)
    ROUND(APPROX_QUANTILES(
      CASE WHEN yhat_p50_12w < 5 THEN GREATEST(q90_12w - yhat_p50_12w, 0) END, 100
    )[OFFSET(50)], 3)                                               AS median_abs_buffer_low_vol,
    ROUND(APPROX_QUANTILES(
      CASE WHEN yhat_p50_12w < 5 THEN GREATEST(q90_12w - yhat_p50_12w, 0) END, 100
    )[OFFSET(90)], 3)                                               AS p90_abs_buffer_low_vol,
    ROUND(SAFE_DIVIDE(COUNTIF(yhat_p50_12w < 5), COUNT(*)), 4)     AS share_low_volume,
    -- coverage
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p90_recheck,
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p95_recheck,
    -- cap / monotonicity
    ROUND(SAFE_DIVIDE(COUNTIF(q90_12w >= cap_value), COUNT(*)), 4) AS q90_cap_rate_recheck,
    ROUND(SAFE_DIVIDE(COUNTIF(q95_12w >= cap_value), COUNT(*)), 4) AS q95_cap_rate_recheck,
    COUNTIF(q90_12w = q95_12w)                                      AS n_q90_equal_q95,
    COUNTIF(q90_12w = q99_12w)                                      AS n_q90_equal_q99,
    -- value-weighted ratios
    ROUND(SAFE_DIVIDE(
      SUM(q90_p50_ratio * yhat_p50_12w),
      NULLIF(SUM(yhat_p50_12w), 0)
    ), 3)                                                            AS weighted_q90_p50_ratio_by_p50,
    ROUND(SAFE_DIVIDE(
      SUM(q90_p50_ratio * alert_score_final),
      NULLIF(SUM(alert_score_final), 0)
    ), 3)                                                            AS weighted_q90_p50_ratio_by_alert,
    ROUND(AVG(GREATEST(q90_12w - yhat_p50_12w, 0)), 2)             AS avg_expected_buffer_q90,
    -- over-under proxy (fresh recompute)
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w IS NOT NULL THEN GREATEST(q90_12w - y_true_12w, 0) ELSE 0 END),
      NULLIF(SUM(CASE WHEN y_true_12w IS NOT NULL THEN GREATEST(y_true_12w - q90_12w, 0) ELSE 0 END), 0)
    ), 3)                                                            AS over_under_ratio_recheck
  FROM val_gate_rows
  WHERE y_true_12w IS NOT NULL
),

-- Combine with coverage gate metrics
combined AS (
  SELECT g.*, c.viol_rate_p90_val_gate, c.viol_rate_p95_val_gate, c.q90_cap_rate, c.over_under_ratio_q90
  FROM global_m g, cov_gate c
)

SELECT
  *,
  -- ratio_gate_final: does NOT reduce q90
  CASE
    WHEN q90_cap_rate > 0.05                          THEN 'FAIL_CAP_RATE'
    WHEN over_under_ratio_q90 > 3.0                   THEN 'FAIL_OVERSTOCK'
    WHEN NOT (viol_rate_p90_val_gate BETWEEN 0.08 AND 0.12) THEN 'FAIL_COVERAGE'
    WHEN q90_p50_ratio_median_p50_ge_5 <= 3.5         THEN 'PASS_ACTIVE_RATIO'
    WHEN weighted_q90_p50_ratio_by_p50 <= 3.5         THEN 'PASS_WEIGHTED_RATIO'
    ELSE                                                    'WARN_LOW_VOLUME_RATIO'
  END AS ratio_gate_final
FROM combined;

SELECT
  q90_p50_ratio_median_all,
  q90_p50_ratio_median_p50_ge_5,
  q90_cap_rate,
  over_under_ratio_q90,
  ratio_gate_final
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_balance_guardrails_h12_v2_final`;

-- ---------------------------------------------------------------------------
-- Examples table
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_balance_examples_h12_v2_final` AS
WITH val_gate_rows AS (
  SELECT
    f.*,
    SAFE_DIVIDE(f.q90_12w, NULLIF(f.yhat_p50_12w, 0)) AS q90_p50_ratio,
    COALESCE(r.cap_value, 1e9) AS cap_value
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2_final` f
  LEFT JOIN (
    SELECT decision_week, sku_id, cap_value
    FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2`
    WHERE split_original = 'VAL'
  ) r ON r.sku_id = f.sku_id AND r.decision_week = f.decision_week
  WHERE f.eval_split_v2 = 'VAL_GATE'
    AND f.yhat_p50_12w IS NOT NULL
    AND f.y_true_12w IS NOT NULL
)
-- Low-volume high-ratio
SELECT * FROM (
  SELECT 'low_vol_high_ratio' AS example_type, sku_id, decision_week,
    yhat_p50_12w, q90_12w, q95_12w, q90_p50_ratio,
    y_true_12w, p_oos_12w_report, alert_score_final, season_group
  FROM val_gate_rows
  WHERE yhat_p50_12w < 5 AND q90_p50_ratio > 3.5
  ORDER BY q90_p50_ratio DESC LIMIT 20
)

UNION ALL

-- High-volume high-ratio
SELECT * FROM (
  SELECT 'high_vol_high_ratio' AS example_type, sku_id, decision_week,
    yhat_p50_12w, q90_12w, q95_12w, q90_p50_ratio,
    y_true_12w, p_oos_12w_report, alert_score_final, season_group
  FROM val_gate_rows
  WHERE yhat_p50_12w >= 5 AND q90_p50_ratio > 3.5
  ORDER BY q90_p50_ratio DESC LIMIT 20
)

UNION ALL

-- Capped forecasts
SELECT * FROM (
  SELECT 'capped' AS example_type, sku_id, decision_week,
    yhat_p50_12w, q90_12w, q95_12w, q90_p50_ratio,
    y_true_12w, p_oos_12w_report, alert_score_final, season_group
  FROM val_gate_rows
  WHERE q90_12w >= cap_value
  ORDER BY q90_12w DESC LIMIT 20
)

UNION ALL

-- Top 20 alerts
SELECT * FROM (
  SELECT 'top_alert' AS example_type, sku_id, decision_week,
    yhat_p50_12w, q90_12w, q95_12w, q90_p50_ratio,
    y_true_12w, p_oos_12w_report, alert_score_final, season_group
  FROM val_gate_rows
  ORDER BY alert_score_final DESC LIMIT 20
);
