-- ============================================================================
-- STEP 02b: SCORE ALL SPLITS  =>  base_scores_h12_v1
-- ============================================================================
-- PURPOSE:
--   Materialise ML.PREDICT outputs for TRAIN+CALIB+VAL into base_scores_h12_v1.
--   This step ALWAYS runs — even when --skip-training is used — because all
--   downstream steps depend on this table.
--
-- SCALE FORMULA (heteroscedastic, adjusted for 12-week horizon):
--   scale = GREATEST(1.0,
--             roll13_std * SQRT(12.0),      -- weekly std scaled to 12W
--             SQRT(roll13_mean * 12.0 + 1.0) -- Poisson-like variance for counts)
--
-- REQUIRES:
--   enriched_base_h12_v1          (from step 02 or pre-existing)
--   m_oos_h12_v1                  (BQML classifier)
--   m_platt_oos_h12_v1            (Platt calibration)
--   m_demand_h12_v1               (BQML regressor)
-- OUTPUT:
--   base_scores_h12_v1
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` AS

WITH

-- --------------------------------------------------------------------------
-- OOS raw scores
-- --------------------------------------------------------------------------
oos_raw AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_12w_probs)
     WHERE SAFE_CAST(label AS INT64) = 0) AS p0_raw,
    (SELECT prob FROM UNNEST(p.predicted_stockout_event_12w_probs)
     WHERE SAFE_CAST(label AS INT64) = 1) AS p1_raw
  FROM ML.PREDICT(
    MODEL `{PROJECT_ID}.{BQ_DATASET}.m_oos_h12_v1`,
    (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
     WHERE split IN ('TRAIN', 'CALIB', 'VAL'))
  ) p
),

-- Resolve positive-class mapping
pos_map AS (
  SELECT mapping FROM `{PROJECT_ID}.{BQ_DATASET}.oos_prob_mapping_h12_v1` LIMIT 1
),

oos_resolved AS (
  SELECT
    r.sku_id,
    r.week_start_date,
    CASE WHEN m.mapping = 'USE_P1' THEN r.p1_raw ELSE r.p0_raw END AS p_oos_raw
  FROM oos_raw r
  CROSS JOIN pos_map m
),

-- --------------------------------------------------------------------------
-- Platt-calibrated OOS probability
-- --------------------------------------------------------------------------
oos_calibrated AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    (SELECT prob FROM UNNEST(p.predicted_true_label_probs)
     WHERE SAFE_CAST(label AS INT64) = 1) AS p_oos_h12
  FROM ML.PREDICT(
    MODEL `{PROJECT_ID}.{BQ_DATASET}.m_platt_oos_h12_v1`,
    (SELECT sku_id, week_start_date, p_oos_raw
     FROM oos_resolved)
  ) p
),

-- --------------------------------------------------------------------------
-- Demand predictions
-- --------------------------------------------------------------------------
demand_preds AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    GREATEST(0.0, p.predicted_y_true_12w) AS yhat_p50_12w
  FROM ML.PREDICT(
    MODEL `{PROJECT_ID}.{BQ_DATASET}.m_demand_h12_v1`,
    (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1`
     WHERE split IN ('TRAIN', 'CALIB', 'VAL'))
  ) p
)

-- --------------------------------------------------------------------------
-- Final join
-- --------------------------------------------------------------------------
SELECT
  f.sku_id,
  f.week_start_date,
  f.split,
  f.season_group,
  f.amplitude,
  f.roll13_mean,
  f.roll13_std,
  f.roll12_mean,
  f.roll12_std,
  f.cv_13w,
  f.cv_12w,
  f.cv_4w,
  f.demand_decile,
  f.y_true_12w,
  f.y_sales,
  f.stockout_event_12w,
  f.n_stockout_weeks_12w,
  f.lost_units_proxy_12w,
  f.is_train,
  f.target_start_week,
  f.target_end_week,
  f.sale_freq_12w,
  f.zero_share_13w,

  -- calibrated OOS probability
  COALESCE(oc.p_oos_h12, COALESCE(f.p_oos_h12, 0.0)) AS p_oos_h12,

  -- demand forecast (p50)
  COALESCE(d.yhat_p50_12w, 0.0) AS yhat_p50_12w,

  -- heteroscedastic scale adjusted for 12-week aggregation
  GREATEST(
    1.0,
    COALESCE(f.roll13_std, 0.0) * SQRT(12.0),
    SQRT(COALESCE(f.roll13_mean, 0.0) * 12.0 + 1.0)
  ) AS scale

FROM `{PROJECT_ID}.{BQ_DATASET}.enriched_base_h12_v1` f
LEFT JOIN oos_calibrated oc USING (sku_id, week_start_date)
LEFT JOIN demand_preds    d  USING (sku_id, week_start_date)
WHERE f.split IN ('TRAIN', 'CALIB', 'VAL');

-- Sanity check
SELECT
  split,
  COUNT(*)                           AS n_rows,
  ROUND(AVG(p_oos_h12),   4)        AS avg_p_oos,
  ROUND(AVG(yhat_p50_12w),2)        AS avg_yhat_p50,
  ROUND(AVG(scale),        2)        AS avg_scale,
  COUNTIF(p_oos_h12 IS NULL)        AS n_null_p_oos,
  COUNTIF(yhat_p50_12w IS NULL)     AS n_null_yhat
FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
GROUP BY split ORDER BY split;
