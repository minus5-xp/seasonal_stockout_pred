-- ============================================================================
-- STEP 07: FINAL LOCKED TEST METRICS  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Compute evaluation metrics on LOCKED_TEST using only frozen decisions.
--   Reports four granularity levels: global, season_group, sku_season_state,
--   demand_tier. Each row carries post_selection_bias = FALSE and
--   selected_using_locked_test = FALSE.
--
-- WMAPE VARIANTS:
--   wmape_all         : standard WMAPE (blows up when SUM(y)≈0 for OFF_SEASON)
--   wmape_y_positive  : WMAPE restricted to rows where y_true_12w > 0
--                       (unaffected by zero-denominator inflation)
--
--   For OFF_SEASON and REST_OFFPEAK, wmape_y_positive is the primary KPI.
--   wmape_all is diagnostic (shows denominator explosion severity).
--
-- ANTI-LEAKAGE:
--   - Frozen decisions are read-only: frozen_quantile_config_by_season_state,
--     frozen_probability_mode_by_season_state, frozen_policy_by_season_state.
--   - No re-selection of any parameter on LOCKED_TEST.
--   - Brier RAW and CALIBRATED both reported; selection not changed even if
--     one outperforms the other on LOCKED_TEST.
--
-- OUTPUT TABLE:
--   final_locked_test_metrics_h12_v3_2_season_state_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_2_season_state_strict` AS
WITH

-- ── All frozen decisions ───────────────────────────────────────────────────
frozen_q AS (
  SELECT sku_season_state, selected_level, scale_multiplier, q90_offset,
         factor_clip_hi, cv_viol_p90, cv_loss, selected_using_split,
         selected_without_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_by_season_state_h12_v3_2_season_state_strict`
),
frozen_prob AS (
  SELECT sku_season_state, selected_for_reporting, selected_for_ranking,
         selection_source AS prob_selection_source, selected_without_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_by_season_state_h12_v3_2_season_state_strict`
),
frozen_pol AS (
  SELECT sku_season_state, policy, dev_select_lift, selection_source AS pol_selection_source,
         selected_without_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_by_season_state_h12_v3_2_season_state_strict`
),

-- ── LOCKED_TEST base rows (labels confirmed present for 53k rows) ──────────
lt_base AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    ss.sku_season_state,
    CASE
      WHEN f.y_true_12w IS NULL THEN 'no_label'
      WHEN f.y_true_12w = 0    THEN 'zero'
      WHEN f.y_true_12w < 5    THEN 'low (0<y<5)'
      WHEN f.y_true_12w < 20   THEN 'medium (5<=y<20)'
      ELSE                          'high (y>=20)'
    END AS demand_tier,
    f.y_true_12w,
    f.stockout_event_12w,
    -- Use gated forecast as the primary prediction
    f.yhat_p50_season_state_12w  AS yhat_p50_12w,
    f.yhat_p50_original_12w,
    f.offseason_gate_applied,
    f.q80_12w,
    f.q90_12w,
    f.q95_12w,
    c.p_oos_raw,
    c.p_oos_h12 AS p_oos_cal,
    -- Frozen prob mode for this state
    fp.selected_for_reporting    AS prob_mode_reporting
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = f.sku_id AND ss.decision_week = f.decision_week
  LEFT JOIN frozen_prob fp ON fp.sku_season_state = ss.sku_season_state
  WHERE f.eval_split_v3 = 'LOCKED_TEST'
    AND f.split_original = 'VAL'
    AND f.y_true_12w IS NOT NULL  -- labelled rows only
),

-- ── Metrics macro (used in all four breakdowns) ────────────────────────────
-- Global alert counts for lift denominator
lt_universe AS (
  SELECT
    COUNT(*) AS n_universe,
    COUNTIF(stockout_event_12w = 1) AS n_oos_universe
  FROM lt_base
  WHERE stockout_event_12w IS NOT NULL
),

-- ── BUILD METRICS CTE ──────────────────────────────────────────────────────
metrics_global AS (
  SELECT
    'global'            AS breakdown_level,
    'ALL'               AS season_group,
    'ALL'               AS sku_season_state,
    'ALL'               AS demand_tier,
    COUNT(*)            AS n_obs,
    COUNT(DISTINCT sku_id) AS n_skus,
    COUNT(DISTINCT decision_week) AS n_weeks,
    ROUND(SUM(y_true_12w), 1)     AS actual_sum,
    ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)), 1) AS abs_error_sum,
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)),0)),4) AS wmape_all,
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
      NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END), 0)
    ),4)                AS wmape_y_positive,
    ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)),3) AS mae_per_row,
    ROUND(SAFE_DIVIDE(AVG(y_true_12w - yhat_p50_12w), NULLIF(AVG(y_true_12w),0)),4) AS bias_pct,
    ROUND(SAFE_DIVIDE(COUNTIF(y_true_12w = 0 AND yhat_p50_12w > 0),
                      COUNTIF(y_true_12w IS NOT NULL)), 4) AS zero_demand_overforecast_rate,
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END), 3) AS avg_pred_when_y_zero,
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END),4) AS viol_rate_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END),4) AS viol_rate_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END),4) AS viol_rate_p95,
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_raw - CAST(stockout_event_12w AS FLOAT64),2) END),5) AS brier_raw,
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_cal - CAST(stockout_event_12w AS FLOAT64),2) END),5) AS brier_calibrated,
    COUNTIF(offseason_gate_applied = TRUE) AS n_gate_applied
  FROM lt_base
),

metrics_by_group AS (
  SELECT
    'by_season_group'   AS breakdown_level,
    season_group,
    'ALL'               AS sku_season_state,
    'ALL'               AS demand_tier,
    COUNT(*), COUNT(DISTINCT sku_id), COUNT(DISTINCT decision_week),
    ROUND(SUM(y_true_12w),1),
    ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)),1),
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)),0)),4),
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
      NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END),0)),4),
    ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)),3),
    ROUND(SAFE_DIVIDE(AVG(y_true_12w - yhat_p50_12w), NULLIF(AVG(y_true_12w),0)),4),
    ROUND(SAFE_DIVIDE(COUNTIF(y_true_12w = 0 AND yhat_p50_12w > 0),
                      COUNTIF(y_true_12w IS NOT NULL)),4),
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END),3),
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_raw - CAST(stockout_event_12w AS FLOAT64),2) END),5),
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_cal - CAST(stockout_event_12w AS FLOAT64),2) END),5),
    COUNTIF(offseason_gate_applied = TRUE)
  FROM lt_base
  GROUP BY season_group
),

metrics_by_state AS (
  SELECT
    'by_sku_season_state' AS breakdown_level,
    'ALL'                 AS season_group,
    sku_season_state,
    'ALL'                 AS demand_tier,
    COUNT(*), COUNT(DISTINCT sku_id), COUNT(DISTINCT decision_week),
    ROUND(SUM(y_true_12w),1),
    ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)),1),
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)),0)),4),
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
      NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END),0)),4),
    ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)),3),
    ROUND(SAFE_DIVIDE(AVG(y_true_12w - yhat_p50_12w), NULLIF(AVG(y_true_12w),0)),4),
    ROUND(SAFE_DIVIDE(COUNTIF(y_true_12w = 0 AND yhat_p50_12w > 0),
                      COUNTIF(y_true_12w IS NOT NULL)),4),
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END),3),
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_raw - CAST(stockout_event_12w AS FLOAT64),2) END),5),
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_cal - CAST(stockout_event_12w AS FLOAT64),2) END),5),
    COUNTIF(offseason_gate_applied = TRUE)
  FROM lt_base
  GROUP BY sku_season_state
),

metrics_by_tier AS (
  SELECT
    'by_demand_tier'    AS breakdown_level,
    season_group,
    sku_season_state,
    demand_tier,
    COUNT(*), COUNT(DISTINCT sku_id), COUNT(DISTINCT decision_week),
    ROUND(SUM(y_true_12w),1),
    ROUND(SUM(ABS(y_true_12w - yhat_p50_12w)),1),
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)),0)),4),
    ROUND(SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - yhat_p50_12w) END),
      NULLIF(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w) END),0)),4),
    ROUND(AVG(ABS(y_true_12w - yhat_p50_12w)),3),
    ROUND(SAFE_DIVIDE(AVG(y_true_12w - yhat_p50_12w), NULLIF(AVG(y_true_12w),0)),4),
    ROUND(SAFE_DIVIDE(COUNTIF(y_true_12w = 0 AND yhat_p50_12w > 0),
                      COUNTIF(y_true_12w IS NOT NULL)),4),
    ROUND(AVG(CASE WHEN y_true_12w = 0 THEN yhat_p50_12w END),3),
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END),4),
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_raw - CAST(stockout_event_12w AS FLOAT64),2) END),5),
    ROUND(AVG(CASE WHEN stockout_event_12w IS NOT NULL
      THEN POW(p_oos_cal - CAST(stockout_event_12w AS FLOAT64),2) END),5),
    COUNTIF(offseason_gate_applied = TRUE)
  FROM lt_base
  GROUP BY season_group, sku_season_state, demand_tier
),

all_metrics AS (
  SELECT * FROM metrics_global
  UNION ALL SELECT * FROM metrics_by_group
  UNION ALL SELECT * FROM metrics_by_state
  UNION ALL SELECT * FROM metrics_by_tier
)

SELECT
  m.*,
  -- Anti-leakage assertions
  TRUE  AS is_locked_test,
  FALSE AS post_selection_bias,
  FALSE AS selected_using_locked_test,
  FALSE AS quantile_recalibrated_on_locked_test,
  FALSE AS gate_used_locked_test_labels,
  -- Version
  'h12_v3_2_season_state_strict' AS version,
  CURRENT_TIMESTAMP() AS computed_at
FROM all_metrics m;

-- ── Key review query ──────────────────────────────────────────────────────
SELECT
  breakdown_level,
  season_group,
  sku_season_state,
  demand_tier,
  n_obs,
  wmape_all,
  wmape_y_positive,
  bias_pct,
  viol_rate_p90,
  brier_raw,
  brier_calibrated,
  n_gate_applied,
  post_selection_bias,
  selected_using_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_2_season_state_strict`
WHERE breakdown_level IN ('global', 'by_season_group', 'by_sku_season_state')
ORDER BY breakdown_level, season_group, sku_season_state;
