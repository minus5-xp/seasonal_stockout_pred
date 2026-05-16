-- ============================================================================
-- STEP 02: APPLY FROZEN CALIBRATION TO ALL SPLITS  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Apply frozen_quantile_config_h12_v3_strict (selected in step 01 on
--   DEV_TUNE only) to ALL rows: DEV_TUNE, DEV_SELECT, EMBARGO,
--   LOCKED_TEST, and OTHER (TRAIN/CALIB).
--
--   This produces forecast_recalibrated_h12_v3_strict — the single
--   recalibrated forecast table for v3_strict.
--
-- GUARANTEES:
--   - No calibration parameters are re-estimated here.
--   - frozen_quantile_config is read once (LIMIT 1) and applied uniformly.
--   - y_true_12w and stockout_event_12w are passed through as-is.
--     They will be NULL for LOCKED_TEST rows (confirmed blind).
--   - Labels are NEVER used to compute quantiles or correction factors.
--
-- LEAKAGE CONTROLS:
--   - cap_value: computed on TRAIN+CALIB only (same as v2).
--   - correction_factor baseline: uses viol_rate_provisional computed
--     on DEV_TUNE only (from step 01).
--   - segment_vif: from CALIB rows only (from step 01).
--
-- OUTPUT TABLES:
--   seg_viol_dev_tune_h12_v3_strict   (segment-level baseline viol rates)
--   forecast_recalibrated_h12_v3_strict
-- ============================================================================

-- ── 2a. SEGMENT-LEVEL BASELINE VIOL (DEV_TUNE only) ─────────────────────
-- Pre-aggregate segment-level raw viol_rate and correction factor.
-- This is derived from DEV_TUNE provisional data (step 01).
-- It is stored separately so the full forecast apply step is clean.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.seg_viol_dev_tune_h12_v3_strict` AS
WITH
child_viol AS (
  SELECT segment_id_child, season_group,
    COUNT(*) AS n_tune, AVG(viol_p90_provisional) AS raw_viol_p90
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`
  GROUP BY segment_id_child, season_group
),
season_viol AS (
  SELECT season_group, AVG(viol_p90_provisional) AS raw_viol_p90_season
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`
  GROUP BY season_group
),
global_viol AS (
  SELECT AVG(viol_p90_provisional) AS raw_viol_p90_global
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`
),
all_segments AS (
  SELECT DISTINCT segment_id_child, season_group
  FROM `{PROJECT_ID}.{BQ_DATASET}.viol_rate_provisional_dev_tune_h12_v3_strict`
)
SELECT
  a.segment_id_child,
  a.season_group,
  COALESCE(c.raw_viol_p90, s.raw_viol_p90_season, g.raw_viol_p90_global, 0.10) AS effective_raw_viol_p90,
  CASE
    WHEN c.raw_viol_p90 IS NOT NULL THEN 'child'
    WHEN s.raw_viol_p90_season IS NOT NULL THEN 'season'
    ELSE 'global'
  END AS viol_fallback_level
FROM all_segments a
LEFT JOIN child_viol c  USING (segment_id_child, season_group)
LEFT JOIN season_viol s USING (season_group)
CROSS JOIN global_viol g;

-- ── 2b. FULL RECALIBRATED FORECAST ───────────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` AS
WITH

sel AS (
  SELECT scale_multiplier, q90_offset, q95_offset, factor_clip_hi
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_h12_v3_strict`
  LIMIT 1
),

vb_thresh AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.volatility_bucket_thresholds_h12_v1`
),

-- All rows from base_scores (TRAIN + CALIB + VAL)
all_rows AS (
  SELECT
    s.*,
    EXTRACT(ISOYEAR FROM s.week_start_date) AS iso_year,
    EXTRACT(ISOWEEK  FROM s.week_start_date) AS iso_week,
    tc.eval_split_v3,
    tc.can_tune,
    tc.can_select,
    tc.can_report_final,
    tc.labels_allowed,
    CASE
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v1 THEN 1
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v2 THEN 2
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v3 THEN 3
      WHEN COALESCE(s.cv_13w, 0.0) <= vbt.cv_thresh_v4 THEN 4
      ELSE 5
    END AS volatility_bucket
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` s
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = s.week_start_date
  LEFT JOIN vb_thresh vbt
    ON vbt.season_group = s.season_group AND vbt.demand_decile = s.demand_decile
  WHERE s.split IN ('TRAIN', 'CALIB', 'VAL')
),

with_segment AS (
  SELECT *,
    CONCAT(season_group, '_D', LPAD(CAST(demand_decile AS STRING), 2, '0'),
           '_V', CAST(volatility_bucket AS STRING)) AS segment_id_child
  FROM all_rows
),

with_lookups AS (
  SELECT
    w.*,
    COALESCE(q.q_score_p90,  1.645) AS q_score_p90_base,
    COALESCE(q.q_score_p91,  q.q_score_p90, 1.645) AS q_score_p91,
    COALESCE(q.q_score_p92,  q.q_score_p90, 1.645) AS q_score_p92,
    COALESCE(q.q_score_p93,  q.q_score_p90, 1.645) AS q_score_p93,
    COALESCE(q.q_score_p95,  1.960) AS q_score_p95_base,
    COALESCE(q.q_score_p96,  q.q_score_p95, 1.960) AS q_score_p96,
    COALESCE(q.q_score_p97,  q.q_score_p95, 1.960) AS q_score_p97,
    COALESCE(q.q_score_p75,  1.036) AS q_score_p75,
    COALESCE(q.q_score_p80,  1.282) AS q_score_p80,
    COALESCE(q.q_score_p85,  1.440) AS q_score_p85,
    COALESCE(q.q_score_p99,  2.576) AS q_score_p99,
    COALESCE(v.segment_vif,  1.0)   AS segment_vif
  FROM with_segment w
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v3_strict` q
    ON q.segment_id_child = w.segment_id_child
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.segment_vif_h12_v3_strict` v
    ON v.segment_id_child = w.segment_id_child
),

with_cf AS (
  SELECT
    w.*,
    sv.effective_raw_viol_p90,
    -- correction_factor uses frozen clip_hi (from frozen_quantile_config)
    LEAST(sel.factor_clip_hi, GREATEST(0.80,
      SAFE_DIVIDE(sv.effective_raw_viol_p90, 0.10)
    )) AS cf_v3
  FROM with_lookups w
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.seg_viol_dev_tune_h12_v3_strict` sv
    ON sv.segment_id_child = w.segment_id_child
  CROSS JOIN sel
),

-- cap_value: 2× the 99th percentile of actual demand in TRAIN+CALIB
-- LEAKAGE note: this uses TRAIN+CALIB only, so no leakage.
cap_vals AS (
  SELECT
    season_group,
    2.0 * APPROX_QUANTILES(y_true_12w, 100)[OFFSET(99)] AS cap_value
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split IN ('TRAIN', 'CALIB') AND y_true_12w IS NOT NULL
  GROUP BY season_group
),

computed AS (
  SELECT
    w.*,
    c.cap_value,
    -- scale_h12_v3_strict (VIF intentionally excluded)
    w.scale * sel.scale_multiplier AS scale_h12_v3,
    CASE sel.q90_offset
      WHEN 90 THEN w.q_score_p90_base
      WHEN 91 THEN w.q_score_p91
      WHEN 92 THEN w.q_score_p92
      ELSE w.q_score_p90_base
    END AS q_score_q90_eff,
    CASE sel.q95_offset
      WHEN 95 THEN w.q_score_p95_base
      WHEN 96 THEN w.q_score_p96
      ELSE w.q_score_p95_base
    END AS q_score_q95_eff,
    sel.scale_multiplier AS sel_scale_multiplier,
    sel.q90_offset       AS sel_q90_offset,
    sel.q95_offset       AS sel_q95_offset,
    sel.factor_clip_hi   AS sel_factor_clip_hi
  FROM with_cf w
  CROSS JOIN sel
  LEFT JOIN cap_vals c ON c.season_group = w.season_group
),

quantiles_raw AS (
  SELECT
    *,
    GREATEST(0.0, yhat_p50_12w + q_score_p75  * cf_v3 * scale_h12_v3) AS q75_raw,
    GREATEST(0.0, yhat_p50_12w + q_score_p80  * cf_v3 * scale_h12_v3) AS q80_raw,
    GREATEST(0.0, yhat_p50_12w + q_score_p85  * cf_v3 * scale_h12_v3) AS q85_raw,
    GREATEST(0.0, yhat_p50_12w + q_score_q90_eff * cf_v3 * scale_h12_v3) AS q90_raw,
    GREATEST(0.0, yhat_p50_12w + q_score_q95_eff * cf_v3 * scale_h12_v3) AS q95_raw,
    GREATEST(0.0, yhat_p50_12w + q_score_p99  * cf_v3 * scale_h12_v3) AS q99_raw
  FROM computed
)

SELECT
  -- identity
  week_start_date   AS decision_week,
  iso_year,
  iso_week,
  DATE_ADD(week_start_date, INTERVAL 1  WEEK) AS target_start_week,
  DATE_ADD(week_start_date, INTERVAL 12 WEEK) AS target_end_week,
  sku_id,
  -- temporal contract
  split             AS split_original,
  COALESCE(eval_split_v3, 'OTHER') AS eval_split_v3,
  can_tune,
  can_select,
  can_report_final,
  labels_allowed,
  -- metadata
  season_group,
  demand_decile,
  volatility_bucket,
  segment_id_child,
  amplitude,
  -- probabilities (from v1; v3_strict does not retrain)
  p_oos_h12,
  -- point forecast
  yhat_p50_12w,
  -- recalibrated quantiles (monotonicity enforced)
  GREATEST(0.0, q75_raw)  AS q75_12w,
  GREATEST(0.0, q80_raw)  AS q80_12w,
  GREATEST(0.0,
    GREATEST(q80_raw, q85_raw))  AS q85_12w,
  GREATEST(0.0,
    GREATEST(q80_raw, GREATEST(q85_raw, q90_raw)))  AS q90_12w,
  GREATEST(0.0,
    GREATEST(q80_raw, GREATEST(q85_raw, GREATEST(q90_raw, q95_raw))))  AS q95_12w,
  GREATEST(0.0,
    GREATEST(q80_raw, GREATEST(q85_raw, GREATEST(q90_raw, GREATEST(q95_raw, q99_raw)))))  AS q99_12w,
  cap_value,
  -- scale / calibration params
  scale             AS scale_v1,
  scale_h12_v3,
  cf_v3,
  sel_scale_multiplier,
  sel_q90_offset,
  sel_q95_offset,
  sel_factor_clip_hi,
  -- auxiliary features
  lost_units_proxy_12w,
  -- LABELS: passed through as-is. NULL for LOCKED_TEST (confirmed blind).
  y_true_12w,
  stockout_event_12w,
  n_stockout_weeks_12w
FROM quantiles_raw;

-- ── Verification ─────────────────────────────────────────────────────────
SELECT
  eval_split_v3,
  split_original,
  COUNT(*)                                                     AS n_rows,
  COUNTIF(y_true_12w IS NOT NULL)                              AS n_labelled,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p80
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict`
WHERE y_true_12w IS NOT NULL
GROUP BY eval_split_v3, split_original
ORDER BY eval_split_v3, split_original;

-- Confirm LOCKED_TEST has no labels
SELECT
  'LOCKED_TEST label check' AS check_name,
  CASE
    WHEN COUNTIF(eval_split_v3 = 'LOCKED_TEST' AND y_true_12w IS NOT NULL) = 0
    THEN 'PASS — LOCKED_TEST has no labels (confirmed blind)'
    ELSE CONCAT('WARN — ', CAST(COUNTIF(eval_split_v3 = 'LOCKED_TEST' AND y_true_12w IS NOT NULL) AS STRING),
                ' rows have non-NULL y_true_12w in LOCKED_TEST')
  END AS result
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict`
WHERE split_original = 'VAL';
