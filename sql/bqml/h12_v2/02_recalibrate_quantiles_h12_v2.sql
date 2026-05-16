-- ============================================================================
-- STEP 02: RECALIBRATION GRID  (h=12 v2)
-- ============================================================================
-- PURPOSE:
--   Without retraining models, find the best calibration configuration by
--   evaluating 216 parameter combinations on VAL_TUNE (W01-W20 of 2024).
--   Apply best config to build forecast_recalibrated_h12_v2 for all splits.
--
-- DOES NOT RETRAIN: reads base_scores_h12_v1, residuals_h12_v1,
--   quantile_lookup_h12_v1, quantile_factors_h12_v1.
--
-- GRID (6 × 4 × 3 × 3 = 216 configs):
--   scale_multiplier  ∈ {1.00, 1.03, 1.05, 1.08, 1.10, 1.15}
--   q90_offset        ∈ {90, 91, 92, 93}
--   q95_offset        ∈ {95, 96, 97}
--   factor_clip_hi    ∈ {3.0, 3.5, 4.0}
--
-- KEY FORMULA:
--   scale_h12_v2 = scale_h12_v1 * LEAST(1.5, segment_vif) * scale_multiplier
--   q90_12w_v2 = yhat_p50 + q_score[q90_offset] * cf_clipped * scale_h12_v2
--   correction_factor(clip_hi) = CLIP(viol_rate_p90_provisional / 0.10, 0.80, clip_hi)
--
-- OUTPUT TABLES:
--   val_tune_gate_blind_split_h12_v2
--   segment_vif_h12_v2
--   quantile_lookup_extended_h12_v2
--   viol_rate_provisional_h12_v2
--   calibration_grid_h12_v2
--   calibration_grid_eval_h12_v2
--   calibration_selected_h12_v2
--   forecast_recalibrated_h12_v2
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 2a. NEW TEMPORAL PARTITION
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` AS
SELECT
  week_start_date AS decision_week,
  EXTRACT(ISOYEAR FROM week_start_date)  AS iso_year,
  EXTRACT(ISOWEEK  FROM week_start_date) AS iso_week,
  CASE
    WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
     AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 1  AND 20 THEN 'VAL_TUNE'
    WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
     AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 21 AND 27 THEN 'VAL_GATE'
    WHEN EXTRACT(ISOYEAR FROM week_start_date) = 2024
     AND EXTRACT(ISOWEEK  FROM week_start_date) BETWEEN 28 AND 40 THEN 'BLIND'
    ELSE 'OTHER'
  END AS eval_split_v2
FROM (
  SELECT DISTINCT week_start_date
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split IN ('TRAIN', 'CALIB', 'VAL')
);

SELECT eval_split_v2, COUNT(*) AS n_weeks
FROM `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2`
GROUP BY eval_split_v2 ORDER BY eval_split_v2;

-- ---------------------------------------------------------------------------
-- 2b. SEGMENT VIF (Variance Inflation Factor)
-- Measures ratio of actual residual variance to theoretical scale^2.
-- Computed on CALIB only (no future leakage).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v2` AS
WITH residuals_calib AS (
  SELECT
    r.sku_id,
    r.week_start_date,
    r.season_group,
    r.demand_decile,
    r.volatility_bucket,
    r.segment_id_child,
    b.scale                                           AS scale_v1,
    b.y_true_12w - b.yhat_p50_12w                    AS residual,
    POW(b.scale, 2)                                   AS scale_sq
  FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1` r
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = r.sku_id AND b.week_start_date = r.week_start_date
  WHERE r.score IS NOT NULL  -- active demand only (amplitude >= 10)
),
child_vif AS (
  SELECT
    segment_id_child,
    season_group,
    COUNT(*)              AS n_calib,
    VAR_POP(residual)     AS var_residual,
    AVG(scale_sq)         AS avg_scale_sq
  FROM residuals_calib
  GROUP BY segment_id_child, season_group
),
season_vif AS (
  SELECT
    season_group,
    COUNT(*)              AS n_calib_season,
    VAR_POP(residual)     AS var_residual_season,
    AVG(scale_sq)         AS avg_scale_sq_season
  FROM residuals_calib
  GROUP BY season_group
),
global_vif AS (
  SELECT
    VAR_POP(residual)  AS var_residual_global,
    AVG(scale_sq)      AS avg_scale_sq_global
  FROM residuals_calib
),
all_segments AS (
  SELECT DISTINCT segment_id_child, season_group FROM residuals_calib
)
SELECT
  a.segment_id_child,
  a.season_group,
  c.n_calib,
  -- VIF = sqrt(Var_actual / Var_theoretical)
  CASE
    WHEN c.n_calib >= 50
      THEN SQRT(GREATEST(1.0, SAFE_DIVIDE(c.var_residual, NULLIF(c.avg_scale_sq, 0))))
    WHEN sv.n_calib_season >= 100
      THEN SQRT(GREATEST(1.0, SAFE_DIVIDE(sv.var_residual_season, NULLIF(sv.avg_scale_sq_season, 0))))
    ELSE
      SQRT(GREATEST(1.0, SAFE_DIVIDE(g.var_residual_global, NULLIF(g.avg_scale_sq_global, 0))))
  END AS segment_vif,
  CASE
    WHEN c.n_calib >= 50  THEN 'child'
    WHEN sv.n_calib_season >= 100 THEN 'season'
    ELSE 'global'
  END AS vif_source
FROM all_segments a
LEFT JOIN child_vif  c  USING (segment_id_child, season_group)
LEFT JOIN season_vif sv USING (season_group)
CROSS JOIN global_vif g;

SELECT vif_source, COUNT(*) n, ROUND(AVG(segment_vif),3) avg_vif, ROUND(MAX(segment_vif),3) max_vif
FROM `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v2`
GROUP BY vif_source;

-- ---------------------------------------------------------------------------
-- 2c. EXTENDED QUANTILE LOOKUP
-- Adds score percentiles 91,92,93 and 96,97 to the v1 lookup.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v2` AS
WITH extended AS (
  SELECT
    segment_id_child,
    segment_id_parent,
    season_group,
    demand_decile,
    volatility_bucket,
    n_calib_child,
    fallback_level,
    -- pass-through from original lookup
    q_score_p75,
    q_score_p80,
    q_score_p85,
    q_score_p90,
    q_score_p95,
    q_score_p99,
    -- extended offsets for q90
    APPROX_QUANTILES(score, 100)[OFFSET(91)] AS q_score_p91,
    APPROX_QUANTILES(score, 100)[OFFSET(92)] AS q_score_p92,
    APPROX_QUANTILES(score, 100)[OFFSET(93)] AS q_score_p93,
    -- extended for q95
    APPROX_QUANTILES(score, 100)[OFFSET(96)] AS q_score_p96,
    APPROX_QUANTILES(score, 100)[OFFSET(97)] AS q_score_p97
  FROM `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_h12_v1` ql
  LEFT JOIN (
    SELECT segment_id_child, score
    FROM `{PROJECT_ID}.{BQ_DATASET}.residuals_h12_v1`
    WHERE score IS NOT NULL
  ) r USING (segment_id_child)
  GROUP BY segment_id_child, segment_id_parent, season_group, demand_decile,
           volatility_bucket, n_calib_child, fallback_level,
           q_score_p75, q_score_p80, q_score_p85,
           q_score_p90, q_score_p95, q_score_p99
)
SELECT * FROM extended;

-- ---------------------------------------------------------------------------
-- 2d. PROVISIONAL VIOL RATE (using v1 scale, for computing raw correction_factor)
-- Used to derive correction_factor baseline for different clip_hi values.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_h12_v2` AS
WITH vb_thresh AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1`
),
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
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` tv
    ON s.week_start_date = tv.decision_week AND tv.eval_split_v2 = 'VAL_TUNE'
  LEFT JOIN vb_thresh vbt
    ON vbt.season_group = s.season_group AND vbt.demand_decile = s.demand_decile
  WHERE s.split = 'VAL' AND s.amplitude >= 10.0
),
with_segment AS (
  SELECT
    *,
    CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
           '_V', CAST(volatility_bucket AS STRING)) AS segment_id_child
  FROM tune_rows
),
with_q90_raw AS (
  SELECT
    t.*,
    COALESCE(q.q_score_p90, 1.645) AS q_score_p90_raw,
    COALESCE(v.segment_vif, 1.0)    AS segment_vif
  FROM with_segment t
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v2` q
    ON q.segment_id_child = t.segment_id_child
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v2` v
    ON v.segment_id_child = t.segment_id_child
)
SELECT
  *,
  -- provisional q90 with v1 scale, no correction
  GREATEST(0.0, yhat_p50_12w + q_score_p90_raw * scale_v1) AS q90_provisional,
  CASE WHEN y_true_12w > GREATEST(0.0, yhat_p50_12w + q_score_p90_raw * scale_v1)
       THEN 1 ELSE 0 END AS viol_p90_provisional
FROM with_q90_raw;

-- ---------------------------------------------------------------------------
-- 2e. CALIBRATION GRID (216 configurations)
-- ---------------------------------------------------------------------------
-- Grid v2 revision:
-- VIF REMOVED from scale formula (was over-inflating intervals).
-- scale_h12_v2 = scale_h12_v1 * scale_multiplier ONLY.
-- Lower factor_clip_hi range: [0.8 .. 1.5] to fix over-wide intervals.
-- Calibration loss rebalanced: undercoverage penalised equally to overcoverage.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v2` AS
SELECT
  sm.scale_multiplier,
  q90.q90_offset,
  q95.q95_offset,
  cf.factor_clip_hi,
  ROW_NUMBER() OVER (ORDER BY sm.scale_multiplier, q90.q90_offset, q95.q95_offset, cf.factor_clip_hi) AS config_id
FROM
  (SELECT * FROM UNNEST([0.85, 0.90, 0.92, 0.95, 1.00]) AS scale_multiplier) sm
CROSS JOIN
  (SELECT * FROM UNNEST([90, 91, 92]) AS q90_offset) q90
CROSS JOIN
  (SELECT * FROM UNNEST([95, 96]) AS q95_offset) q95
CROSS JOIN
  (SELECT * FROM UNNEST([0.80, 0.90, 1.00, 1.10, 1.20, 1.50]) AS factor_clip_hi) cf;

SELECT COUNT(*) AS n_configs FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v2`;

-- ---------------------------------------------------------------------------
-- 2f. SEGMENT BASELINE VIOL (raw, pre-clipping) — needed to recompute cf per clip_hi
-- ---------------------------------------------------------------------------
-- For each segment, the raw uncapped correction factor is viol_rate_p90 / 0.10
-- We join this to the grid and apply each clip_hi to get cf(clip_hi).

-- Pre-aggregate per segment on VAL_TUNE
-- (child→season fallback mirrors v1 logic)

-- ---------------------------------------------------------------------------
-- 2g. CALIBRATION GRID EVALUATION — Full cross-join on VAL_TUNE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_h12_v2` AS
WITH

-- Base data: VAL_TUNE rows with all needed features
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
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_h12_v2` p
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v2` q
    ON q.segment_id_child = p.segment_id_child
),

-- Segment-level raw viol_rate (for computing correction_factor)
seg_viol AS (
  SELECT
    segment_id_child,
    season_group,
    COUNT(*)                         AS n_tune,
    AVG(viol_p90_provisional)        AS raw_viol_p90
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_h12_v2`
  GROUP BY segment_id_child, season_group
),
season_viol AS (
  SELECT
    season_group,
    COUNT(*)                         AS n_tune_season,
    AVG(viol_p90_provisional)        AS raw_viol_p90_season
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_h12_v2`
  GROUP BY season_group
),

-- Join tune data with segment viol rates
tune_with_viol AS (
  SELECT
    t.*,
    COALESCE(sv.raw_viol_p90, ssv.raw_viol_p90_season, 0.10) AS effective_raw_viol_p90
  FROM tune_data t
  LEFT JOIN seg_viol sv ON sv.segment_id_child = t.segment_id_child
  LEFT JOIN season_viol ssv ON ssv.season_group = t.season_group
),

-- Full cross-join with grid
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

    -- scale_h12_v2 (VIF removed: was over-inflating intervals)
    t.scale_v1
      * g.scale_multiplier                                    AS scale_h12_v2,

    -- correction_factor for this clip_hi
    LEAST(g.factor_clip_hi, GREATEST(0.80,
      SAFE_DIVIDE(t.effective_raw_viol_p90, 0.10)
    ))                                                        AS cf_v2,

    -- q90 score at the requested offset
    CASE g.q90_offset
      WHEN 90 THEN t.q_score_p90_base
      WHEN 91 THEN COALESCE(t.q_score_p91, t.q_score_p90_base)
      WHEN 92 THEN COALESCE(t.q_score_p92, t.q_score_p90_base)
      WHEN 93 THEN COALESCE(t.q_score_p93, t.q_score_p90_base)
      ELSE t.q_score_p90_base
    END                                                       AS q_score_q90_eff,

    -- q95 score at the requested offset
    CASE g.q95_offset
      WHEN 95 THEN COALESCE(t.q_score_p95, 1.960)
      WHEN 96 THEN COALESCE(t.q_score_p96, COALESCE(t.q_score_p95, 1.960))
      WHEN 97 THEN COALESCE(t.q_score_p97, COALESCE(t.q_score_p95, 1.960))
      ELSE COALESCE(t.q_score_p95, 1.960)
    END                                                       AS q_score_q95_eff

  FROM tune_with_viol t
  CROSS JOIN `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v2` g
),

-- Compute quantiles and violations per row
grid_eval_quantiles AS (
  SELECT
    config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
    y_true_12w, yhat_p50_12w, season_group,

    GREATEST(0.0, yhat_p50_12w
      + q_score_q90_eff * cf_v2 * scale_h12_v2)  AS q90_v2,

    GREATEST(0.0, yhat_p50_12w
      + q_score_q95_eff * cf_v2 * scale_h12_v2)  AS q95_v2,

    yhat_p50_12w                                  AS p50_v2,
    scale_h12_v2
  FROM grid_eval_raw
)

-- Aggregate per config
SELECT
  config_id,
  scale_multiplier,
  q90_offset,
  q95_offset,
  factor_clip_hi,
  COUNT(*) AS n_rows,
  -- violation rates
  ROUND(AVG(CASE WHEN y_true_12w > q90_v2 THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_v2 THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
  -- q90/p50 ratio
  ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q90_v2, NULLIF(p50_v2, 0)), 100)[OFFSET(50)], 3) AS q90_p50_ratio_median,
  -- cap rate proxy (q90 > 3x p50)
  ROUND(SAFE_DIVIDE(
    COUNTIF(SAFE_DIVIDE(q90_v2, NULLIF(p50_v2, 0)) > 5.0), COUNT(*)), 4) AS cap_rate_q90_proxy,
  -- calibration loss (v2 revision: undercoverage penalised equally to overcoverage)
  ROUND(
    20.0 * GREATEST(AVG(CASE WHEN y_true_12w > q90_v2 THEN 1.0 ELSE 0.0 END) - 0.12, 0)
    + 20.0 * GREATEST(0.08 - AVG(CASE WHEN y_true_12w > q90_v2 THEN 1.0 ELSE 0.0 END), 0)
    +  5.0 * ABS(AVG(CASE WHEN y_true_12w > q90_v2 THEN 1.0 ELSE 0.0 END) - 0.10)
    +  3.0 * GREATEST(APPROX_QUANTILES(SAFE_DIVIDE(q90_v2, NULLIF(p50_v2, 0)), 100)[OFFSET(50)] - 3.0, 0)
    +  2.0 * GREATEST(SAFE_DIVIDE(
               COUNTIF(SAFE_DIVIDE(q90_v2, NULLIF(p50_v2, 0)) > 5.0), COUNT(*)) - 0.05, 0)
    +  1.0 * ABS(AVG(CASE WHEN y_true_12w > q90_v2 THEN 1.0 ELSE 0.0 END) * 2 - 0.20)
  , 5) AS calibration_loss
FROM grid_eval_quantiles
WHERE yhat_p50_12w >= 0
GROUP BY config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi;

-- Top 10 configurations (lowest calibration_loss)
SELECT *
FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_h12_v2`
ORDER BY calibration_loss ASC
LIMIT 10;

-- ---------------------------------------------------------------------------
-- 2h. SELECTED CONFIGURATION
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calibration_selected_h12_v2` AS
SELECT
  config_id,
  scale_multiplier,
  q90_offset,
  q95_offset,
  factor_clip_hi,
  viol_p90       AS viol_p90_val_tune,
  viol_p95       AS viol_p95_val_tune,
  q90_p50_ratio_median,
  cap_rate_q90_proxy,
  calibration_loss,
  'SELECTED'     AS status,
  CURRENT_TIMESTAMP() AS selected_at
FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_h12_v2`
ORDER BY calibration_loss ASC
LIMIT 1;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_selected_h12_v2`;

-- ---------------------------------------------------------------------------
-- 2i. FULL RECALIBRATED FORECAST  forecast_recalibrated_h12_v2
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2` AS
WITH

sel AS (
  SELECT scale_multiplier, q90_offset, q95_offset, factor_clip_hi
  FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_selected_h12_v2`
  LIMIT 1
),

vb_thresh AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1`
),

all_rows AS (
  SELECT
    s.*,
    EXTRACT(ISOYEAR FROM s.week_start_date) AS iso_year,
    EXTRACT(ISOWEEK  FROM s.week_start_date) AS iso_week,
    tv.eval_split_v2,
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` s
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` tv
    ON tv.decision_week = s.week_start_date
  LEFT JOIN vb_thresh vbt
    ON vbt.season_group = s.season_group AND vbt.demand_decile = s.demand_decile
  WHERE s.split IN ('TRAIN', 'CALIB', 'VAL')
),

with_segment AS (
  SELECT
    *,
    CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
           '_V', CAST(volatility_bucket AS STRING)) AS segment_id_child
  FROM all_rows
),

with_vif AS (
  SELECT
    w.*,
    COALESCE(v.segment_vif, 1.0) AS segment_vif
  FROM with_segment w
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v2` v
    ON v.segment_id_child = w.segment_id_child
),

with_lookup AS (
  SELECT
    w.*,
    COALESCE(q.q_score_p90, 1.645) AS q_score_p90_base,
    COALESCE(q.q_score_p91, q.q_score_p90, 1.645) AS q_score_p91,
    COALESCE(q.q_score_p92, q.q_score_p90, 1.645) AS q_score_p92,
    COALESCE(q.q_score_p93, q.q_score_p90, 1.645) AS q_score_p93,
    COALESCE(q.q_score_p95, 1.960) AS q_score_p95_base,
    COALESCE(q.q_score_p96, q.q_score_p95, 1.960) AS q_score_p96,
    COALESCE(q.q_score_p97, q.q_score_p95, 1.960) AS q_score_p97,
    COALESCE(q.q_score_p75, 1.036) AS q_score_p75,
    COALESCE(q.q_score_p80, 1.282) AS q_score_p80,
    COALESCE(q.q_score_p85, 1.440) AS q_score_p85,
    COALESCE(q.q_score_p99, 2.576) AS q_score_p99,
    COALESCE(q.n_calib_child, 0)   AS segment_n_calib,
    COALESCE(q.fallback_level, 'global') AS qlookup_fallback
  FROM with_vif w
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v2` q
    ON q.segment_id_child = w.segment_id_child
),

-- Raw correction factor per segment using selected clip_hi
seg_viol_base AS (
  SELECT
    segment_id_child,
    season_group,
    COUNT(*)          AS n_tune_seg,
    AVG(CASE WHEN y_true_12w > GREATEST(0.0, yhat_p50_12w + q_score_p90_raw * scale_v1)
             THEN 1.0 ELSE 0.0 END) AS raw_viol_p90
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_h12_v2`
  GROUP BY segment_id_child, season_group
),
season_viol_base AS (
  SELECT season_group, AVG(viol_p90_provisional) AS raw_viol_p90_season
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_h12_v2`
  GROUP BY season_group
),

with_cf AS (
  SELECT
    w.*,
    COALESCE(sv.raw_viol_p90, ssv.raw_viol_p90_season, 0.10) AS effective_viol,
    LEAST(sel.factor_clip_hi, GREATEST(0.80,
      SAFE_DIVIDE(COALESCE(sv.raw_viol_p90, ssv.raw_viol_p90_season, 0.10), 0.10)
    )) AS cf_v2
  FROM with_lookup w
  LEFT JOIN seg_viol_base sv ON sv.segment_id_child = w.segment_id_child
  LEFT JOIN season_viol_base ssv ON ssv.season_group = w.season_group
  CROSS JOIN sel
),

cap_vals AS (
  SELECT season_group, 2.0 * APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS cap_value
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split IN ('TRAIN', 'CALIB') AND y_true_12w IS NOT NULL
  GROUP BY season_group
),

computed AS (
  SELECT
    w.*,
    -- scale_h12_v2 (VIF removed)
    w.scale * sel.scale_multiplier AS scale_h12_v2,
    -- q90 effective score
    CASE sel.q90_offset
      WHEN 90 THEN w.q_score_p90_base
      WHEN 91 THEN w.q_score_p91
      WHEN 92 THEN w.q_score_p92
      WHEN 93 THEN w.q_score_p93
      ELSE w.q_score_p90_base
    END AS q_score_q90_eff,
    -- q95 effective score
    CASE sel.q95_offset
      WHEN 95 THEN w.q_score_p95_base
      WHEN 96 THEN w.q_score_p96
      WHEN 97 THEN w.q_score_p97
      ELSE w.q_score_p95_base
    END AS q_score_q95_eff,
    sel.q90_offset AS q90_effective_score_percentile,
    sel.q95_offset AS q95_effective_score_percentile,
    sel.scale_multiplier AS sel_scale_multiplier,
    c.cap_value
  FROM with_cf w
  CROSS JOIN sel
  LEFT JOIN cap_vals c ON c.season_group = w.season_group
),

quantiles_raw AS (
  SELECT
    *,
    scale_h12_v2 AS _scale,
    yhat_p50_12w + q_score_p75  * cf_v2 * scale_h12_v2 AS q75_raw,
    yhat_p50_12w + q_score_p80  * cf_v2 * scale_h12_v2 AS q80_raw,
    yhat_p50_12w + q_score_p85  * cf_v2 * scale_h12_v2 AS q85_raw,
    yhat_p50_12w + q_score_q90_eff * cf_v2 * scale_h12_v2 AS q90_raw,
    yhat_p50_12w + q_score_q95_eff * cf_v2 * scale_h12_v2 AS q95_raw,
    yhat_p50_12w + q_score_p99  * cf_v2 * scale_h12_v2 AS q99_raw
  FROM computed
)

SELECT
  week_start_date        AS decision_week,
  iso_year,
  iso_week,
  DATE_ADD(week_start_date, INTERVAL 1  WEEK) AS target_start_week,
  DATE_ADD(week_start_date, INTERVAL 12 WEEK) AS target_end_week,
  sku_id,
  split                  AS split_original,
  COALESCE(eval_split_v2, 'OTHER') AS eval_split_v2,
  season_group,
  demand_decile,
  volatility_bucket,
  segment_id_child,
  p_oos_h12,
  yhat_p50_12w,

  -- Monotone calibrated quantiles (non-negative, capped)
  LEAST(COALESCE(cap_value,1e9), GREATEST(0.0, q75_raw))                          AS q75_12w,
  LEAST(COALESCE(cap_value,1e9), GREATEST(0.0, GREATEST(q75_raw, q80_raw)))       AS q80_12w,
  LEAST(COALESCE(cap_value,1e9), GREATEST(0.0, GREATEST(q80_raw, q85_raw)))       AS q85_12w,
  LEAST(COALESCE(cap_value,1e9), GREATEST(0.0, GREATEST(q85_raw, q90_raw)))       AS q90_12w,
  LEAST(COALESCE(cap_value,1e9), GREATEST(0.0, GREATEST(q90_raw, q95_raw)))       AS q95_12w,
  LEAST(COALESCE(cap_value,1e9), GREATEST(0.0, GREATEST(q95_raw, q99_raw)))       AS q99_12w,

  -- Labels: NULL for BLIND rows (mask future information)
  CASE WHEN COALESCE(eval_split_v2, 'OTHER') = 'BLIND' THEN NULL ELSE y_true_12w          END AS y_true_12w,
  CASE WHEN COALESCE(eval_split_v2, 'OTHER') = 'BLIND' THEN NULL ELSE stockout_event_12w  END AS stockout_event_12w,
  CASE WHEN COALESCE(eval_split_v2, 'OTHER') = 'BLIND' THEN NULL ELSE n_stockout_weeks_12w END AS n_stockout_weeks_12w,
  lost_units_proxy_12w,

  -- Calibration metadata
  scale               AS scale_h12_v1,
  scale_h12_v2,
  sel_scale_multiplier AS scale_multiplier,
  segment_vif,
  q90_effective_score_percentile,
  q95_effective_score_percentile,
  cf_v2               AS correction_factor_v2,
  COALESCE(cap_value, 1e9) AS cap_value,
  CASE WHEN GREATEST(0.0, GREATEST(q85_raw, q90_raw)) >= COALESCE(cap_value, 1e9) THEN 1 ELSE 0 END AS cap_flag_q90,
  segment_n_calib,
  qlookup_fallback,
  'h12_v2' AS version

FROM quantiles_raw
WHERE split IN ('TRAIN', 'CALIB', 'VAL');

-- Sanity check
SELECT eval_split_v2, split_original, COUNT(*) n,
  ROUND(AVG(CASE WHEN y_true_12w IS NULL THEN 1.0 ELSE 0.0 END), 3) AS pct_null_label,
  ROUND(AVG(CASE WHEN q90_12w < q80_12w THEN 1.0 ELSE 0.0 END), 4) AS mono_viol
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2`
GROUP BY eval_split_v2, split_original ORDER BY split_original, eval_split_v2;
