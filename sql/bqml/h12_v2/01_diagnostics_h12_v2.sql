-- ============================================================================
-- STEP 01: DIAGNOSTICS  (h=12 v2)
-- ============================================================================
-- PURPOSE:
--   Audit h12_v1 before any recalibration. Identifies root causes of B3 failure.
--   All queries read from h12_v1 tables. Nothing is modified.
--
-- OUTPUT TABLES (all _h12_v2 suffix, new tables):
--   diag_b3_by_season_h12_v2
--   diag_b3_by_demand_decile_h12_v2
--   diag_b3_by_volatility_bucket_h12_v2
--   diag_b3_by_segment_h12_v2
--   diag_correction_factor_h12_v2
--   diag_score_shift_calib_val_h12_v2
--   diag_cap_rate_h12_v2
--   diag_scale_adequacy_h12_v2
--   diag_active_scope_h12_v2
--   diag_q_ratio_guardrails_h12_v2
-- ============================================================================

-- ---------------------------------------------------------------------------
-- D1. viol_rate by season_group
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_b3_by_season_h12_v2` AS
SELECT
  season_group,
  COUNT(*)                                          AS n_rows,
  ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p80,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p95,
  ROUND(AVG(q90_12w),         2)                   AS avg_q90,
  ROUND(AVG(y_true_12w),      2)                   AS avg_y_true,
  ROUND(AVG(yhat_p50_12w),    2)                   AS avg_yhat_p50,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END) - 0.10, 4) AS deviation_from_target
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0
GROUP BY season_group
ORDER BY season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.diag_b3_by_season_h12_v2`;

-- ---------------------------------------------------------------------------
-- D2. viol_rate by demand_decile
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_b3_by_demand_decile_h12_v2` AS
SELECT
  demand_decile,
  COUNT(*)                                                        AS n_rows,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
  ROUND(AVG(q90_12w), 2)        AS avg_q90,
  ROUND(AVG(y_true_12w), 2)     AS avg_y_true,
  ROUND(AVG(amplitude), 2)      AS avg_amplitude
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0
GROUP BY demand_decile
ORDER BY demand_decile;

-- ---------------------------------------------------------------------------
-- D3. viol_rate by volatility_bucket
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_b3_by_volatility_bucket_h12_v2` AS
SELECT
  volatility_bucket,
  COUNT(*)                                                                AS n_rows,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p95,
  ROUND(AVG(q90_12w), 2)        AS avg_q90,
  ROUND(AVG(correction_factor), 4) AS avg_correction_factor
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0
GROUP BY volatility_bucket
ORDER BY volatility_bucket;

-- ---------------------------------------------------------------------------
-- D4. Top segments by viol_p90 (worst offenders)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_b3_by_segment_h12_v2` AS
SELECT
  segment_id_child,
  season_group,
  demand_decile,
  volatility_bucket,
  COUNT(*)                                                                AS n_rows,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4)  AS viol_p95,
  ROUND(AVG(correction_factor), 4) AS avg_correction_factor,
  ROUND(AVG(CASE WHEN qlookup_fallback = 'global' THEN 1.0 ELSE 0.0 END), 4) AS pct_global_fallback
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0
GROUP BY segment_id_child, season_group, demand_decile, volatility_bucket
ORDER BY viol_p90 DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- D5. Correction factor distribution
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_correction_factor_h12_v2` AS
SELECT
  factor_source,
  COUNT(*)                                                             AS n_segments,
  ROUND(AVG(correction_factor), 4)                                    AS avg_cf,
  ROUND(MIN(correction_factor), 4)                                    AS min_cf,
  ROUND(MAX(correction_factor), 4)                                    AS max_cf,
  ROUND(SAFE_DIVIDE(COUNTIF(correction_factor >= 3.00 - 0.001), COUNT(*)), 4) AS pct_at_clip_hi,
  ROUND(SAFE_DIVIDE(COUNTIF(correction_factor <= 0.80 + 0.001), COUNT(*)), 4) AS pct_at_clip_lo,
  ROUND(SAFE_DIVIDE(COUNTIF(correction_factor = 1.0), COUNT(*)), 4)  AS pct_at_default
FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_factors_h12_v1`
GROUP BY factor_source
ORDER BY factor_source;

-- How many segments fall to global fallback?
SELECT
  'global_fallback_summary' AS metric,
  COUNT(*) AS total_segments,
  COUNTIF(factor_source = 'global') AS n_global,
  COUNTIF(factor_source = 'season') AS n_season,
  COUNTIF(factor_source = 'child')  AS n_child,
  ROUND(SAFE_DIVIDE(COUNTIF(factor_source = 'global'), COUNT(*)), 4) AS pct_global
FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_factors_h12_v1`;

-- ---------------------------------------------------------------------------
-- D6. Score shift CALIB vs VAL (distribution check)
-- Scores on CALIB come from residuals_h12_v1 (computed).
-- Scores on VAL computed here ad hoc: (y_true - yhat) / scale.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_score_shift_calib_val_h12_v2` AS
WITH val_scores AS (
  SELECT
    'VAL'         AS split,
    season_group,
    SAFE_DIVIDE(y_true_12w - yhat_p50_12w, scale) AS score
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split = 'VAL'
    AND amplitude >= 10.0
),
calib_scores AS (
  SELECT
    'CALIB'       AS split,
    season_group,
    score
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1`
  WHERE score IS NOT NULL
),
combined AS (
  SELECT * FROM val_scores
  UNION ALL
  SELECT * FROM calib_scores
)
SELECT
  split,
  season_group,
  COUNT(*)                                              AS n_rows,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(50)], 3)  AS q50_score,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(80)], 3)  AS q80_score,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(90)], 3)  AS q90_score,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(95)], 3)  AS q95_score,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(99)], 3)  AS q99_score,
  ROUND(AVG(score),    3)                              AS avg_score,
  ROUND(STDDEV(score), 3)                              AS std_score,
  -- skew proxy = q95 - q50 (right tail weight)
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(95)]
      - APPROX_QUANTILES(score, 100)[OFFSET(50)], 3)  AS skew_proxy_q95_q50
FROM combined
GROUP BY split, season_group
ORDER BY season_group, split;

-- Overall (no season split)
SELECT
  split,
  'ALL' AS season_group,
  COUNT(*)                                              AS n_rows,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(90)], 3)  AS q90_score,
  ROUND(APPROX_QUANTILES(score, 100)[OFFSET(95)], 3)  AS q95_score,
  ROUND(AVG(score), 3)                                 AS avg_score,
  ROUND(STDDEV(score), 3)                              AS std_score
FROM (
  SELECT 'VAL' AS split, SAFE_DIVIDE(y_true_12w - yhat_p50_12w, scale) AS score
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split = 'VAL' AND amplitude >= 10.0
  UNION ALL
  SELECT 'CALIB' AS split, score
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1`
  WHERE score IS NOT NULL
)
GROUP BY split
ORDER BY split;

-- ---------------------------------------------------------------------------
-- D7. Cap rate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_cap_rate_h12_v2` AS
SELECT
  season_group,
  COUNT(*)                                                                   AS n_rows,
  ROUND(SAFE_DIVIDE(COUNTIF(q80_12w >= cap_value), COUNT(*)), 4)            AS pct_q80_capped,
  ROUND(SAFE_DIVIDE(COUNTIF(q90_12w >= cap_value), COUNT(*)), 4)            AS pct_q90_capped,
  ROUND(SAFE_DIVIDE(COUNTIF(q95_12w >= cap_value), COUNT(*)), 4)            AS pct_q95_capped,
  ROUND(AVG(cap_value), 2)                                                   AS avg_cap_value,
  ROUND(APPROX_QUANTILES(q90_12w, 100)[OFFSET(99)], 2)                      AS p99_q90
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
GROUP BY season_group
ORDER BY season_group;

-- ---------------------------------------------------------------------------
-- D8. Scale adequacy (abs_error / scale ratio)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_scale_adequacy_h12_v2` AS
SELECT
  season_group,
  volatility_bucket,
  COUNT(*)                                                                   AS n_rows,
  -- Ratio of actual absolute error to scale estimate
  ROUND(AVG(SAFE_DIVIDE(ABS(y_true_12w - yhat_p50_12w), scale)), 3)        AS avg_abs_err_per_scale,
  ROUND(APPROX_QUANTILES(
    SAFE_DIVIDE(ABS(y_true_12w - yhat_p50_12w), scale), 100)[OFFSET(90)], 3) AS q90_abs_err_per_scale,
  -- Positive residual share (right-skew check)
  ROUND(AVG(CASE WHEN y_true_12w >= yhat_p50_12w THEN 1.0 ELSE 0.0 END), 4) AS pos_residual_rate,
  -- Mean scale vs mean abs error (should be similar)
  ROUND(AVG(scale), 2) AS avg_scale,
  ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)), 2) AS avg_abs_error
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0
GROUP BY season_group, volatility_bucket
ORDER BY season_group, volatility_bucket;

-- ---------------------------------------------------------------------------
-- D9. Active scope analysis
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_active_scope_h12_v2` AS
SELECT
  CASE WHEN amplitude >= 10.0 THEN 'active' ELSE 'inactive' END AS scope,
  season_group,
  COUNT(*) AS n_rows,
  ROUND(AVG(amplitude), 2) AS avg_amplitude,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
GROUP BY scope, season_group
ORDER BY scope, season_group;

-- ---------------------------------------------------------------------------
-- D10. q90/p50 and q95/p50 ratio guardrails
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.diag_q_ratio_guardrails_h12_v2` AS
SELECT
  season_group,
  demand_decile,
  COUNT(*) AS n_rows,
  ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(50)], 3) AS median_q90_p50_ratio,
  ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q95_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(50)], 3) AS median_q95_p50_ratio,
  ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(90)], 3) AS p90_q90_p50_ratio,
  -- Over/under proxy: rows where q90 > 3x p50
  ROUND(SAFE_DIVIDE(
    COUNTIF(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)) > 3.0),
    COUNT(*)
  ), 4) AS pct_q90_over_3x_p50
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL'
  AND amplitude >= 10.0
  AND yhat_p50_12w > 0
GROUP BY season_group, demand_decile
ORDER BY season_group, demand_decile;

-- Global summary
SELECT
  'GLOBAL_GUARDRAIL_SUMMARY' AS metric,
  ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(50)], 3) AS median_q90_p50_ratio,
  ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q95_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(50)], 3) AS median_q95_p50_ratio,
  ROUND(SAFE_DIVIDE(COUNTIF(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)) > 3.0), COUNT(*)), 4) AS pct_q90_over_3x
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
WHERE split = 'VAL' AND amplitude >= 10.0 AND yhat_p50_12w > 0;
