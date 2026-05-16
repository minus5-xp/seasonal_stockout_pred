-- ============================================================================
-- STEP 03: REGIME DIAGNOSTICS  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Characterise forecast error and demand behaviour by
--   (eval_split_v3 × season_group × sku_season_state × demand_tier).
--
--   Key questions:
--   1. Is the REST LOCKED_TEST WMAPE=9.94 concentrated in OFF_SEASON?
--   2. What is wmape_y_positive (excludes y=0 from denominator) per state?
--   3. Is zero-demand over-forecasting (avg_pred_when_y_zero) state-specific?
--   4. Do viol_p90/p80 still collapse to 0 for all states or only some?
--
-- WMAPE variants:
--   wmape_all     : SUM(|y-yhat|) / SUM(|y|)  — standard, blows up with zeros
--   wmape_y_pos   : same but only for rows where y_true_12w > 0
--                   — not affected by denominator explosion
--   mae_per_row   : AVG(|y-yhat|) — scale-dependent but robust
--
-- OUTPUT TABLE:
--   season_state_diagnostics_h12_v3_2_season_state_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.season_state_diagnostics_h12_v3_2_season_state_strict` AS
WITH

joined AS (
  SELECT
    f.decision_week,
    f.sku_id,
    tc.eval_split_v3,
    f.season_group,
    ss.sku_season_state,
    -- Demand tier based on y_true_12w (12-week sum)
    CASE
      WHEN f.y_true_12w IS NULL   THEN 'no_label'
      WHEN f.y_true_12w = 0       THEN 'zero'
      WHEN f.y_true_12w < 5       THEN 'low (0<y<5)'
      WHEN f.y_true_12w < 20      THEN 'medium (5<=y<20)'
      ELSE                             'high (y>=20)'
    END AS demand_tier,
    f.y_true_12w,
    f.stockout_event_12w,
    f.yhat_p50_12w,
    f.q80_12w,
    f.q90_12w,
    f.q95_12w,
    -- Brier inputs
    oc.p_oos_raw   AS p_raw,
    oc.p_oos_h12   AS p_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = f.decision_week
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = f.sku_id AND ss.decision_week = f.decision_week
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` oc
    ON oc.sku_id = f.sku_id AND oc.week_start_date = f.decision_week
  WHERE f.split_original = 'VAL'
    AND tc.eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
)

-- ── A. By (eval_split_v3 × season_group × sku_season_state) ─────────────
SELECT
  'by_split_group_state' AS breakdown_level,
  eval_split_v3,
  season_group,
  sku_season_state,
  CAST(NULL AS STRING) AS demand_tier,

  COUNT(*)                                              AS n_rows,
  COUNT(DISTINCT sku_id)                                AS n_skus,
  COUNT(DISTINCT decision_week)                         AS n_weeks,

  -- Demand characterisation
  ROUND(AVG(y_true_12w), 3)                            AS avg_actual,
  ROUND(AVG(yhat_p50_12w), 3)                          AS avg_pred,
  ROUND(SAFE_DIVIDE(
    COUNTIF(y_true_12w = 0), COUNTIF(y_true_12w IS NOT NULL)), 4) AS pct_y_true_zero,
  ROUND(SAFE_DIVIDE(
    COUNTIF(y_true_12w > 0 AND yhat_p50_12w > 0 AND y_true_12w = 0),
    COUNTIF(y_true_12w IS NOT NULL)), 4) AS zero_demand_overforecast_rate,
  ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END), 3) AS avg_pred_when_y_zero,

  -- Error metrics (all rows with labels)
  ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)), 1)       AS abs_error_sum,
  ROUND(SUM(ABS(y_true_12w)), 1)                       AS actual_sum,
  ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)), 3)        AS mae_per_row,
  ROUND(SAFE_DIVIDE(
    SUM(ABS(y_true_12w - yhat_p50_12w)),
    NULLIF(SUM(ABS(y_true_12w)), 0)
  ), 4)                                                  AS wmape_all,
  -- WMAPE on positive-demand rows only (unaffected by zero-denominator explosion)
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
    NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END), 0)
  ), 4)                                                  AS wmape_y_positive,
  ROUND(SAFE_DIVIDE(
    AVG(y_true_12w - yhat_p50_12w),
    NULLIF(AVG(y_true_12w), 0)
  ), 4)                                                  AS bias_pct,

  -- Quantile coverage
  ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p80,
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p95,

  -- Brier scores (where stockout label is available)
  ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
    THEN POW(p_raw - CAST(stockout_event_12w AS FLOAT64), 2) END), 5) AS brier_raw,
  ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
    THEN POW(p_cal - CAST(stockout_event_12w AS FLOAT64), 2) END), 5) AS brier_calibrated

FROM joined
WHERE y_true_12w IS NOT NULL
GROUP BY eval_split_v3, season_group, sku_season_state

UNION ALL

-- ── B. By (eval_split_v3 × sku_season_state) — global across season_groups
SELECT
  'by_split_state'        AS breakdown_level,
  eval_split_v3,
  'ALL'                   AS season_group,
  sku_season_state,
  CAST(NULL AS STRING)    AS demand_tier,
  COUNT(*), COUNT(DISTINCT sku_id), COUNT(DISTINCT decision_week),
  ROUND(AVG(y_true_12w), 3),
  ROUND(AVG(yhat_p50_12w), 3),
  ROUND(SAFE_DIVIDE(COUNTIF(y_true_12w = 0), COUNTIF(y_true_12w IS NOT NULL)), 4),
  ROUND(SAFE_DIVIDE(
    COUNTIF(y_true_12w = 0 AND yhat_p50_12w > 0),
    COUNTIF(y_true_12w IS NOT NULL)), 4),
  ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END), 3),
  ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)), 1),
  ROUND(SUM(ABS(y_true_12w)), 1),
  ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)), 3),
  ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)),0)), 4),
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
    NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END), 0)), 4),
  ROUND(SAFE_DIVIDE(AVG(y_true_12w - yhat_p50_12w), NULLIF(AVG(y_true_12w),0)), 4),
  ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4),
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4),
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4),
  ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
    THEN POW(p_raw - CAST(stockout_event_12w AS FLOAT64), 2) END), 5),
  ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
    THEN POW(p_cal - CAST(stockout_event_12w AS FLOAT64), 2) END), 5)
FROM joined
WHERE y_true_12w IS NOT NULL
GROUP BY eval_split_v3, sku_season_state

UNION ALL

-- ── C. By demand_tier within LOCKED_TEST (for REST specifically)
SELECT
  'by_split_group_tier'   AS breakdown_level,
  eval_split_v3,
  season_group,
  CAST(NULL AS STRING)    AS sku_season_state,
  demand_tier,
  COUNT(*), COUNT(DISTINCT sku_id), COUNT(DISTINCT decision_week),
  ROUND(AVG(y_true_12w), 3),
  ROUND(AVG(yhat_p50_12w), 3),
  ROUND(SAFE_DIVIDE(COUNTIF(y_true_12w = 0), COUNTIF(y_true_12w IS NOT NULL)), 4),
  ROUND(SAFE_DIVIDE(
    COUNTIF(y_true_12w = 0 AND yhat_p50_12w > 0),
    COUNTIF(y_true_12w IS NOT NULL)), 4),
  ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END), 3),
  ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)), 1),
  ROUND(SUM(ABS(y_true_12w)), 1),
  ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)), 3),
  ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)),0)), 4),
  ROUND(SAFE_DIVIDE(
    SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
    NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END), 0)), 4),
  ROUND(SAFE_DIVIDE(AVG(y_true_12w - yhat_p50_12w), NULLIF(AVG(y_true_12w),0)), 4),
  ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4),
  ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4),
  ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4),
  ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
    THEN POW(p_raw - CAST(stockout_event_12w AS FLOAT64), 2) END), 5),
  ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
    THEN POW(p_cal - CAST(stockout_event_12w AS FLOAT64), 2) END), 5)
FROM joined
WHERE y_true_12w IS NOT NULL
GROUP BY eval_split_v3, season_group, demand_tier;

-- ── Key diagnostic query: is REST LOCKED_TEST concentrated in OFF_SEASON? ─
SELECT
  breakdown_level, eval_split_v3, season_group, sku_season_state,
  n_rows, pct_y_true_zero,
  avg_actual, avg_pred, avg_pred_when_y_zero,
  wmape_all, wmape_y_positive, bias_pct,
  viol_rate_p80, viol_rate_p90
FROM `{PROJECT_ID}.{BQ_DATASET}.season_state_diagnostics_h12_v3_2_season_state_strict`
WHERE breakdown_level = 'by_split_group_state'
  AND eval_split_v3 = 'LOCKED_TEST'
  AND season_group  = 'REST'
ORDER BY n_rows DESC;
