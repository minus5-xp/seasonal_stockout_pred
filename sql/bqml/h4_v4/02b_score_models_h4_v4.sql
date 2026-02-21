-- ============================================================================
-- STEP 02b: SCORE ALL SPLITS  => base_scores_h4_v4
-- ============================================================================
-- PURPOSE:
--   Materialize ML.PREDICT outputs for TRAIN+CALIB+VAL into base_scores_h4_v4.
--   This step always runs, even when --skip-training is used, because all
--   downstream steps (residuals, calibration, forecast) depend on this table.
--
-- REQUIRES:
--   enriched_base_h4_v4  (built in step 02 / 02-PRE)
--   m_oos_h4_v4          (BQML classifier — built in step 02a)
--   m_demand_h4_v4       (BQML regressor  — built in step 02a)
-- OUTPUT:
--   base_scores_h4_v4    : predictions for TRAIN + CALIB + VAL splits
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4` AS

WITH
-- --------- OOS classifier scores -------------------------------------------
oos_preds AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    (SELECT prob FROM UNNEST(p.predicted_y_oos_h4_probs)
     WHERE SAFE_CAST(label AS INT64) = 1) AS p_oos_raw
  FROM ML.PREDICT(
    MODEL `thequantitativeledger.cruzber_models_eu.m_oos_h4_v4`,
    (
      SELECT * FROM `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4`
      WHERE split IN ('TRAIN', 'CALIB', 'VAL')
    )
  ) p
),

-- --------- Demand regressor scores -----------------------------------------
demand_preds AS (
  SELECT
    p.sku_id,
    p.week_start_date,
    GREATEST(0.0, p.predicted_y_true_h4) AS yhat_p50_raw
  FROM ML.PREDICT(
    MODEL `thequantitativeledger.cruzber_models_eu.m_demand_h4_v4`,
    (
      SELECT * FROM `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4`
      WHERE split IN ('TRAIN', 'CALIB', 'VAL')
    )
  ) p
)

SELECT
  f.sku_id,
  f.week_start_date,
  f.split,
  f.season_group,
  f.amplitude,
  f.roll13_mean,
  f.roll13_std,
  f.cv_13w,
  f.hhi_base_roll13,
  f.demand_decile,
  f.y_true_h4,
  f.y_oos_h4,
  f.stockout_event_h4,
  f.is_high_season,
  f.zero_share_13w,
  f.last_nonzero_lag,
  f.mean_interarrival_13w,

  -- OOS probability from model (or fall back to train_with_poos_h4 value)
  COALESCE(o.p_oos_raw, f.p_oos_h4, 0.0)  AS p_oos_h4,

  -- Demand predictions
  COALESCE(d.yhat_p50_raw, 0.0)            AS yhat_p50_h4,

  -- Scale (heteroscedastic, same formula as v2)
  GREATEST(
    1.0,
    COALESCE(f.roll13_std, 0.0),
    SQRT(COALESCE(f.roll13_mean, 0.0) + 1.0)
  )                                         AS scale

FROM `thequantitativeledger.cruzber_models_eu.enriched_base_h4_v4` f
LEFT JOIN oos_preds   o USING (sku_id, week_start_date)
LEFT JOIN demand_preds d USING (sku_id, week_start_date)
WHERE f.split IN ('TRAIN', 'CALIB', 'VAL');

-- Quick sanity check
SELECT split, COUNT(*) n, ROUND(AVG(p_oos_h4),4) avg_p_oos, ROUND(AVG(yhat_p50_h4),4) avg_yhat
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h4_v4`
GROUP BY split ORDER BY split;
