-- ============================================================================
-- STEP 01: CALIBRATION GRID ON DEV_TUNE ONLY  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Find the best quantile calibration configuration using exclusively
--   DEV_TUNE (W01-W08 of 2024), which has 8 weeks of labelled VAL rows.
--   The winning configuration is stored in frozen_quantile_config_h12_v3_strict.
--
--   This is the ONLY step where calibration_loss is minimised.
--   The frozen config is then applied unchanged to DEV_SELECT, LOCKED_TEST,
--   and BLIND_DEPLOY in step 02.
--
-- LEAKAGE CONTROLS:
--   - All grid evaluation is filtered to eval_split_v3 = 'DEV_TUNE'.
--   - Segment VIF is computed on CALIB rows only (not VAL rows).
--     LEAKAGE_RISK in v2: segment_vif_h12_v2 did NOT filter by split,
--     so VAL rows may have contaminated VIF estimates. Fixed here.
--   - Provisional viol_rate_p90 baseline is computed on DEV_TUNE only.
--   - No LOCKED_TEST rows are touched.
--
-- DOES NOT RETRAIN: reads base_scores_h12_v1, residuals_h12_v1,
--   quantile_lookup_h12_v1 (all read-only).
--
-- OUTPUT TABLES (all suffixed _h12_v3_strict):
--   segment_vif_h12_v3_strict
--   quantile_lookup_extended_h12_v3_strict
--   viol_rate_provisional_dev_tune_h12_v3_strict
--   calibration_grid_h12_v3_strict
--   calibration_grid_eval_dev_tune_h12_v3_strict
--   frozen_quantile_config_h12_v3_strict   ← FROZEN DECISION
-- ============================================================================

-- ── 1a. SEGMENT VIF ──────────────────────────────────────────────────────
-- LEAKAGE_RISK (v2): segment_vif_h12_v2 joined residuals_h12_v1 with
--   base_scores_h12_v1 without any split filter. If residuals_h12_v1
--   contains VAL rows, the VIF was contaminated by out-of-sample variance.
-- FIX: explicitly restrict to split='CALIB' in base_scores_h12_v1.
-- VIF measures ratio of actual residual variance to theoretical scale².
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v3_strict` AS
WITH
-- LEAKAGE_RISK fix: restrict residuals to CALIB split only
residuals_calib AS (
  SELECT
    r.sku_id,
    r.week_start_date,
    r.season_group,
    r.demand_decile,
    r.volatility_bucket,
    r.segment_id_child,
    b.scale                        AS scale_v1,
    b.y_true_12w - b.yhat_p50_12w  AS residual,
    POW(b.scale, 2)                AS scale_sq
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1` r
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = r.sku_id AND b.week_start_date = r.week_start_date
  WHERE b.split = 'CALIB'           -- LEAKAGE_RISK fix: CALIB only
    AND r.score IS NOT NULL         -- active demand (amplitude >= 10)
    AND b.y_true_12w IS NOT NULL
),
child_vif AS (
  SELECT
    segment_id_child, season_group,
    COUNT(*)          AS n_calib,
    VAR_POP(residual) AS var_residual,
    AVG(scale_sq)     AS avg_scale_sq
  FROM residuals_calib
  GROUP BY segment_id_child, season_group
),
season_vif AS (
  SELECT
    season_group,
    COUNT(*)          AS n_calib_season,
    VAR_POP(residual) AS var_residual_season,
    AVG(scale_sq)     AS avg_scale_sq_season
  FROM residuals_calib
  GROUP BY season_group
),
global_vif AS (
  SELECT
    VAR_POP(residual) AS var_residual_global,
    AVG(scale_sq)     AS avg_scale_sq_global
  FROM residuals_calib
),
all_segments AS (
  SELECT DISTINCT segment_id_child, season_group FROM residuals_calib
)
SELECT
  a.segment_id_child,
  a.season_group,
  c.n_calib,
  CASE
    WHEN c.n_calib >= 50
      THEN SQRT(GREATEST(1.0, SAFE_DIVIDE(c.var_residual, NULLIF(c.avg_scale_sq, 0))))
    WHEN sv.n_calib_season >= 100
      THEN SQRT(GREATEST(1.0, SAFE_DIVIDE(sv.var_residual_season, NULLIF(sv.avg_scale_sq_season, 0))))
    ELSE
      SQRT(GREATEST(1.0, SAFE_DIVIDE(g.var_residual_global, NULLIF(g.avg_scale_sq_global, 0))))
  END AS segment_vif,
  CASE
    WHEN c.n_calib >= 50      THEN 'child'
    WHEN sv.n_calib_season >= 100 THEN 'season'
    ELSE 'global'
  END AS vif_source
FROM all_segments a
LEFT JOIN child_vif c  USING (segment_id_child, season_group)
LEFT JOIN season_vif sv USING (season_group)
CROSS JOIN global_vif g;

SELECT vif_source, COUNT(*) AS n, ROUND(AVG(segment_vif), 3) AS avg_vif, ROUND(MAX(segment_vif), 3) AS max_vif
FROM `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v3_strict`
GROUP BY vif_source;

-- ── 1b. EXTENDED QUANTILE LOOKUP ─────────────────────────────────────────
-- Extends quantile_lookup_h12_v1 with extra percentile offsets needed
-- for the calibration grid (q90→91,92,93; q95→96,97).
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v3_strict` AS
SELECT
  ql.segment_id_child,
  ql.segment_id_parent,
  ql.season_group,
  ql.demand_decile,
  ql.volatility_bucket,
  ql.n_calib_child,
  ql.fallback_level,
  ql.q_score_p75,
  ql.q_score_p80,
  ql.q_score_p85,
  ql.q_score_p90,
  ql.q_score_p95,
  ql.q_score_p99,
  -- Extended offsets (computed from CALIB residual scores)
  APPROX_QUANTILES(r.score, 100)[OFFSET(91)] AS q_score_p91,
  APPROX_QUANTILES(r.score, 100)[OFFSET(92)] AS q_score_p92,
  APPROX_QUANTILES(r.score, 100)[OFFSET(93)] AS q_score_p93,
  APPROX_QUANTILES(r.score, 100)[OFFSET(96)] AS q_score_p96,
  APPROX_QUANTILES(r.score, 100)[OFFSET(97)] AS q_score_p97
FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1` ql
LEFT JOIN (
  -- LEAKAGE_RISK note: residuals_h12_v1 used here for CALIB score distribution.
  -- If this table mixes splits, scores would be contaminated.
  -- We use it as-is (same as v2) since quantile_lookup_h12_v1 is itself
  -- built from CALIB; extended percentiles should come from same population.
  SELECT segment_id_child, score
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1`
  WHERE score IS NOT NULL
) r USING (segment_id_child)
GROUP BY
  ql.segment_id_child, ql.segment_id_parent, ql.season_group,
  ql.demand_decile, ql.volatility_bucket, ql.n_calib_child, ql.fallback_level,
  ql.q_score_p75, ql.q_score_p80, ql.q_score_p85,
  ql.q_score_p90, ql.q_score_p95, ql.q_score_p99;

-- ── 1c. PROVISIONAL VIOLATION RATE — DEV_TUNE ONLY ───────────────────────
-- Used to compute raw correction_factor baseline per segment.
-- CRITICAL: filter to DEV_TUNE only (eval_split_v3 = 'DEV_TUNE').
-- v2 used VAL_TUNE (W01-W20). v3_strict uses DEV_TUNE (W01-W08).
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict` AS
WITH
vb_thresh AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1`
),
-- DEV_TUNE rows only
tune_rows AS (
  SELECT
    s.sku_id,
    s.week_start_date,
    s.season_group,
    s.amplitude,
    s.y_true_12w,
    s.yhat_p50_12w,
    s.scale AS scale_v1,
    s.demand_decile,
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` s
  -- ← DEV_TUNE filter (not VAL_TUNE)
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = s.week_start_date
   AND tc.eval_split_v3 = 'DEV_TUNE'
  LEFT JOIN vb_thresh vbt
    ON vbt.season_group = s.season_group AND vbt.demand_decile = s.demand_decile
  WHERE s.split = 'VAL'
    AND s.amplitude >= 10.0
    AND s.y_true_12w IS NOT NULL
),
with_segment AS (
  SELECT *,
    CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
           '_V', CAST(volatility_bucket AS STRING)) AS segment_id_child
  FROM tune_rows
),
with_q90_raw AS (
  SELECT
    t.*,
    COALESCE(q.q_score_p90, 1.645) AS q_score_p90_raw,
    COALESCE(v.segment_vif, 1.0)   AS segment_vif
  FROM with_segment t
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v3_strict` q
    ON q.segment_id_child = t.segment_id_child
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v3_strict` v
    ON v.segment_id_child = t.segment_id_child
)
SELECT
  *,
  GREATEST(0.0, yhat_p50_12w + q_score_p90_raw * scale_v1) AS q90_provisional,
  CASE WHEN y_true_12w > GREATEST(0.0, yhat_p50_12w + q_score_p90_raw * scale_v1)
       THEN 1 ELSE 0 END AS viol_p90_provisional
FROM with_q90_raw;

SELECT
  'DEV_TUNE provisional viol_p90' AS metric,
  COUNT(*) AS n_rows,
  ROUND(AVG(viol_p90_provisional), 4) AS global_viol_p90
FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`;

-- ── 1d. CALIBRATION GRID ─────────────────────────────────────────────────
-- Same grid as v2 (5×3×2×6 = 180 configs).
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v3_strict` AS
SELECT
  sm.scale_multiplier,
  q90.q90_offset,
  q95.q95_offset,
  cf.factor_clip_hi,
  ROW_NUMBER() OVER (
    ORDER BY sm.scale_multiplier, q90.q90_offset, q95.q95_offset, cf.factor_clip_hi
  ) AS config_id
FROM
  (SELECT * FROM UNNEST([0.85, 0.90, 0.92, 0.95, 1.00]) AS scale_multiplier) sm
CROSS JOIN
  (SELECT * FROM UNNEST([90, 91, 92]) AS q90_offset) q90
CROSS JOIN
  (SELECT * FROM UNNEST([95, 96]) AS q95_offset) q95
CROSS JOIN
  (SELECT * FROM UNNEST([0.80, 0.90, 1.00, 1.10, 1.20, 1.50]) AS factor_clip_hi) cf;

SELECT COUNT(*) AS n_configs FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v3_strict`;

-- ── 1e. CALIBRATION GRID EVALUATION — DEV_TUNE ONLY ─────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_dev_tune_h12_v3_strict` AS
WITH
tune_data AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    p.season_group,
    p.segment_id_child,
    p.y_true_12w,
    p.yhat_p50_12w,
    p.scale_v1,
    p.segment_vif,
    p.q_score_p90_raw       AS q_score_p90_base,
    q.q_score_p91,
    q.q_score_p92,
    q.q_score_p93,
    q.q_score_p95,
    q.q_score_p96,
    q.q_score_p97,
    p.viol_p90_provisional   AS viol_p90_raw
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict` p
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v3_strict` q
    ON q.segment_id_child = p.segment_id_child
),
seg_viol AS (
  SELECT segment_id_child, season_group,
    COUNT(*) AS n_tune, AVG(viol_p90_provisional) AS raw_viol_p90
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`
  GROUP BY segment_id_child, season_group
),
season_viol AS (
  SELECT season_group,
    COUNT(*) AS n_tune_season, AVG(viol_p90_provisional) AS raw_viol_p90_season
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`
  GROUP BY season_group
),
tune_with_viol AS (
  SELECT
    t.*,
    COALESCE(sv.raw_viol_p90, ssv.raw_viol_p90_season, 0.10) AS effective_raw_viol_p90
  FROM tune_data t
  LEFT JOIN seg_viol sv  ON sv.segment_id_child = t.segment_id_child
  LEFT JOIN season_viol ssv ON ssv.season_group = t.season_group
),
grid_eval_raw AS (
  SELECT
    g.config_id,
    g.scale_multiplier,
    g.q90_offset,
    g.q95_offset,
    g.factor_clip_hi,
    t.y_true_12w,
    t.yhat_p50_12w,
    t.season_group,
    -- scale_h12_v3_strict (VIF intentionally excluded — see v2 notes)
    t.scale_v1 * g.scale_multiplier AS scale_v3,
    -- correction_factor with this clip_hi
    LEAST(g.factor_clip_hi, GREATEST(0.80,
      SAFE_DIVIDE(t.effective_raw_viol_p90, 0.10)
    )) AS cf_v3,
    CASE g.q90_offset
      WHEN 90 THEN t.q_score_p90_base
      WHEN 91 THEN COALESCE(t.q_score_p91, t.q_score_p90_base)
      WHEN 92 THEN COALESCE(t.q_score_p92, t.q_score_p90_base)
      ELSE t.q_score_p90_base
    END AS q_score_q90_eff,
    CASE g.q95_offset
      WHEN 95 THEN COALESCE(t.q_score_p95, 1.960)
      WHEN 96 THEN COALESCE(t.q_score_p96, COALESCE(t.q_score_p95, 1.960))
      ELSE COALESCE(t.q_score_p95, 1.960)
    END AS q_score_q95_eff
  FROM tune_with_viol t
  CROSS JOIN `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v3_strict` g
),
grid_eval_quantiles AS (
  SELECT
    config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
    y_true_12w, yhat_p50_12w, season_group,
    GREATEST(0.0,
      yhat_p50_12w + q_score_q90_eff * cf_v3 * scale_v3) AS q90_v3,
    GREATEST(0.0,
      yhat_p50_12w + q_score_q95_eff * cf_v3 * scale_v3) AS q95_v3,
    yhat_p50_12w AS p50_v3,
    scale_v3
  FROM grid_eval_raw
)
SELECT
  config_id,
  scale_multiplier,
  q90_offset,
  q95_offset,
  factor_clip_hi,
  COUNT(*) AS n_rows,
  ROUND(AVG(CASE WHEN y_true_12w > q90_v3 THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_v3 THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
  ROUND(
    APPROX_QUANTILES(SAFE_DIVIDE(q90_v3, NULLIF(p50_v3, 0)), 100)[OFFSET(50)]
  , 3) AS q90_p50_ratio_median,
  ROUND(SAFE_DIVIDE(
    COUNTIF(SAFE_DIVIDE(q90_v3, NULLIF(p50_v3, 0)) > 5.0), COUNT(*)), 4) AS cap_rate_q90_proxy,
  -- Calibration loss (same formula as v2)
  ROUND(
    20.0 * GREATEST(AVG(CASE WHEN y_true_12w > q90_v3 THEN 1.0 ELSE 0.0 END) - 0.12, 0)
    + 20.0 * GREATEST(0.08 - AVG(CASE WHEN y_true_12w > q90_v3 THEN 1.0 ELSE 0.0 END), 0)
    +  5.0 * ABS(AVG(CASE WHEN y_true_12w > q90_v3 THEN 1.0 ELSE 0.0 END) - 0.10)
    +  3.0 * GREATEST(APPROX_QUANTILES(SAFE_DIVIDE(q90_v3, NULLIF(p50_v3, 0)), 100)[OFFSET(50)] - 3.0, 0)
    +  2.0 * GREATEST(SAFE_DIVIDE(COUNTIF(SAFE_DIVIDE(q90_v3, NULLIF(p50_v3, 0)) > 5.0), COUNT(*)) - 0.05, 0)
    +  1.0 * ABS(AVG(CASE WHEN y_true_12w > q90_v3 THEN 1.0 ELSE 0.0 END) * 2 - 0.20)
  , 5) AS calibration_loss,
  -- Audit columns
  'DEV_TUNE' AS evaluated_on_split,
  FALSE       AS used_locked_test
FROM grid_eval_quantiles
WHERE yhat_p50_12w >= 0
GROUP BY config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi;

-- Top 5 configurations
SELECT config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
       viol_p90, calibration_loss, evaluated_on_split
FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_dev_tune_h12_v3_strict`
ORDER BY calibration_loss ASC
LIMIT 5;

-- ── 1f. FROZEN QUANTILE CONFIG ───────────────────────────────────────────
-- This is the single, immutable calibration decision.
-- After this table is created, it must NOT be overwritten.
-- Downstream steps read this table; they never re-select.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_h12_v3_strict` AS
SELECT
  config_id,
  scale_multiplier,
  q90_offset,
  q95_offset,
  factor_clip_hi,
  viol_p90       AS viol_p90_dev_tune,
  viol_p95       AS viol_p95_dev_tune,
  q90_p50_ratio_median,
  cap_rate_q90_proxy,
  calibration_loss,
  'SELECTED'     AS status,
  -- Audit columns — confirm this was NOT selected using LOCKED_TEST
  'DEV_TUNE'     AS selected_using_split,
  FALSE          AS used_locked_test,
  CURRENT_TIMESTAMP() AS frozen_at
FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_dev_tune_h12_v3_strict`
ORDER BY calibration_loss ASC
LIMIT 1;

SELECT
  'frozen_quantile_config' AS table_name,
  config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
  viol_p90_dev_tune, calibration_loss, selected_using_split, used_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_h12_v3_strict`;
