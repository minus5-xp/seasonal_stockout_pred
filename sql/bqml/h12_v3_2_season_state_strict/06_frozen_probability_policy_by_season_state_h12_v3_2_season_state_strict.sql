-- ============================================================================
-- STEP 06: FROZEN PROBABILITY MODE AND POLICY BY STATE  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Select probability mode (RAW vs CALIBRATED) and alert policy
--   (A/B/C/D/E) per sku_season_state, using only DEV_SELECT.
--
--   Inherits global decisions from v3_strict when state-level n < 500
--   in DEV_SELECT (too small to reliably distinguish RAW vs CAL per state).
--
-- ANTI-LEAKAGE:
--   - All selections use eval_split_v3 = 'DEV_SELECT' only.
--   - LOCKED_TEST never used for selection.
--   - Fallback to v3_strict global decisions is explicit and auditable.
--
-- OUTPUT TABLES:
--   frozen_probability_mode_by_season_state_h12_v3_2_season_state_strict
--   frozen_policy_by_season_state_h12_v3_2_season_state_strict
-- ============================================================================

-- ── 6a. STATE-LEVEL BRIER COMPARISON ON DEV_SELECT ────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_selection_by_state_dev_select_h12_v3_2_season_state_strict` AS
WITH

dev_select_probs AS (
  SELECT
    f.sku_id,
    f.decision_week,
    f.season_group,
    ss.sku_season_state,
    c.p_oos_raw,
    c.p_oos_h12                           AS p_oos_cal,
    CAST(b.stockout_event_12w AS FLOAT64) AS actual_label
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = f.sku_id AND b.week_start_date = f.decision_week
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = f.sku_id AND ss.decision_week = f.decision_week
  WHERE f.eval_split_v3 = 'DEV_SELECT'
    AND f.split_original = 'VAL'
    AND b.stockout_event_12w IS NOT NULL
    AND c.p_oos_raw IS NOT NULL
    AND c.p_oos_h12 IS NOT NULL
)

SELECT
  sku_season_state,
  COUNT(*)                                                     AS n_rows,
  ROUND(AVG(CAST(actual_label AS FLOAT64)), 4)                 AS prevalence,
  ROUND(AVG(POW(p_oos_raw - actual_label, 2)), 5)              AS brier_raw,
  ROUND(AVG(POW(p_oos_cal - actual_label, 2)), 5)              AS brier_calibrated,
  ROUND(CORR(p_oos_raw, actual_label), 4)                      AS corr_raw,
  ROUND(CORR(p_oos_cal, actual_label), 4)                      AS corr_cal,
  CASE
    WHEN AVG(POW(p_oos_cal - actual_label, 2))
         <= AVG(POW(p_oos_raw - actual_label, 2)) * 1.01
    THEN 'CALIBRATED'
    ELSE 'RAW'
  END                                                          AS selected_for_reporting,
  CASE
    WHEN CORR(p_oos_cal, actual_label) >= CORR(p_oos_raw, actual_label)
    THEN 'CALIBRATED'
    ELSE 'RAW'
  END                                                          AS selected_for_ranking,
  'DEV_SELECT'                                                 AS evaluated_on_split,
  FALSE                                                        AS used_locked_test
FROM dev_select_probs
GROUP BY sku_season_state;

-- ── 6b. FROZEN PROBABILITY MODE BY STATE ──────────────────────────────────
-- Threshold: if n_rows >= 500, use state-specific selection.
-- Otherwise: inherit from v3_strict global (CALIBRATED, selected DEV_SELECT).
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_by_season_state_h12_v3_2_season_state_strict` AS
WITH

global_fallback AS (
  SELECT
    selected_for_reporting AS global_reporting,
    selected_for_ranking   AS global_ranking
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`
  LIMIT 1
)

SELECT
  s.sku_season_state,
  s.n_rows                                          AS n_selection_obs,
  -- Use state-specific if n >= 500, else global fallback
  CASE WHEN s.n_rows >= 500
    THEN s.selected_for_reporting
    ELSE g.global_reporting
  END                                               AS selected_for_reporting,
  CASE WHEN s.n_rows >= 500
    THEN s.selected_for_ranking
    ELSE g.global_ranking
  END                                               AS selected_for_ranking,
  CASE WHEN s.n_rows >= 500
    THEN 'DEV_SELECT_state_specific'
    ELSE 'DEV_SELECT_global_fallback'
  END                                               AS selection_source,
  s.brier_raw                                       AS brier_raw_dev_select,
  s.brier_calibrated                                AS brier_cal_dev_select,
  s.corr_raw,
  s.corr_cal,
  s.evaluated_on_split,
  TRUE                                              AS selected_without_locked_test,
  s.used_locked_test,
  CURRENT_TIMESTAMP()                               AS frozen_at
FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_by_state_dev_select_h12_v3_2_season_state_strict` s
CROSS JOIN global_fallback g;

SELECT sku_season_state, selected_for_reporting, selected_for_ranking,
       selection_source, n_selection_obs, selected_without_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_by_season_state_h12_v3_2_season_state_strict`
ORDER BY sku_season_state;

-- ── 6c. POLICY SWEEP BY STATE ON DEV_SELECT ───────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_by_state_dev_select_h12_v3_2_season_state_strict` AS
WITH

prob_modes AS (
  SELECT sku_season_state, selected_for_ranking AS prob_mode
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_by_season_state_h12_v3_2_season_state_strict`
),

dev_select_scored AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    ss.sku_season_state,
    CASE pm.prob_mode
      WHEN 'RAW'        THEN c.p_oos_raw
      WHEN 'CALIBRATED' THEN c.p_oos_h12
      ELSE c.p_oos_h12
    END                                                AS p_oos_rank,
    f.yhat_p50_season_state_12w                        AS yhat_p50_12w,
    f.q90_12w,
    f.q95_12w,
    f.lost_units_proxy_12w,
    b.stockout_event_12w,
    b.y_true_12w,
    GREATEST(0.0, f.q90_12w - f.yhat_p50_season_state_12w) AS width_q90,
    GREATEST(0.0, f.q95_12w - f.yhat_p50_season_state_12w) AS width_q95,
    CASE f.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END AS season_weight
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = f.sku_id AND b.week_start_date = f.decision_week
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = f.sku_id AND ss.decision_week = f.decision_week
  JOIN prob_modes pm ON pm.sku_season_state = ss.sku_season_state
  WHERE f.eval_split_v3 = 'DEV_SELECT'
    AND f.split_original = 'VAL'
    AND b.stockout_event_12w IS NOT NULL
    AND b.y_true_12w IS NOT NULL
),

scores AS (
  SELECT *,
    p_oos_rank * width_q90                                          AS score_A,
    p_oos_rank * q90_12w                                            AS score_B,
    POW(p_oos_rank, 0.7) * width_q95                                AS score_C,
    p_oos_rank * COALESCE(NULLIF(lost_units_proxy_12w, 0), width_q90) AS score_D,
    p_oos_rank * q90_12w * season_weight                            AS score_E
  FROM dev_select_scored
),

prevalence AS (
  SELECT sku_season_state,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate
  FROM dev_select_scored GROUP BY sku_season_state
),

ranked_A AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY sku_season_state, decision_week ORDER BY score_A DESC) AS rk FROM scores),
ranked_B AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY sku_season_state, decision_week ORDER BY score_B DESC) AS rk FROM scores),
ranked_C AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY sku_season_state, decision_week ORDER BY score_C DESC) AS rk FROM scores),
ranked_D AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY sku_season_state, decision_week ORDER BY score_D DESC) AS rk FROM scores),
ranked_E AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY sku_season_state, decision_week ORDER BY score_E DESC) AS rk FROM scores),

perf AS (
  SELECT 'policy_A' AS policy, sku_season_state,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)) AS precision_at_100,
    COUNT(*) AS n_alerts, COUNTIF(stockout_event_12w=1) AS n_tp,
    SUM(COALESCE(lost_units_proxy_12w,0)) AS lost_units_captured
  FROM ranked_A WHERE rk <= 100 GROUP BY sku_season_state
  UNION ALL
  SELECT 'policy_B', sku_season_state,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_B WHERE rk <= 100 GROUP BY sku_season_state
  UNION ALL
  SELECT 'policy_C', sku_season_state,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_C WHERE rk <= 100 GROUP BY sku_season_state
  UNION ALL
  SELECT 'policy_D', sku_season_state,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_D WHERE rk <= 100 GROUP BY sku_season_state
  UNION ALL
  SELECT 'policy_E', sku_season_state,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_E WHERE rk <= 100 GROUP BY sku_season_state
)

SELECT
  p.policy,
  p.sku_season_state,
  ROUND(p.precision_at_100, 4)                                   AS precision_at_100,
  p.n_alerts, p.n_tp,
  ROUND(p.lost_units_captured, 1)                                AS lost_units_captured,
  ROUND(pr.base_rate, 4)                                         AS base_rate,
  ROUND(SAFE_DIVIDE(p.precision_at_100, NULLIF(pr.base_rate,0)),4) AS lift_at_100,
  'DEV_SELECT'                                                   AS evaluated_on_split,
  FALSE                                                          AS used_locked_test
FROM perf p
LEFT JOIN prevalence pr USING (sku_season_state)
ORDER BY lift_at_100 DESC, policy, sku_season_state;

-- ── 6d. FROZEN POLICY BY STATE ─────────────────────────────────────────────
-- Threshold: state-specific if n_alerts >= 10, else global fallback.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_by_season_state_h12_v3_2_season_state_strict` AS
WITH

global_policy AS (
  SELECT policy AS global_policy
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict`
  LIMIT 1
),

best_per_state AS (
  SELECT
    sku_season_state,
    policy,
    lift_at_100,
    precision_at_100,
    n_alerts,
    n_tp,
    evaluated_on_split,
    used_locked_test,
    ROW_NUMBER() OVER (
      PARTITION BY sku_season_state
      ORDER BY lift_at_100 DESC, precision_at_100 DESC
    ) AS rnk
  FROM `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_by_state_dev_select_h12_v3_2_season_state_strict`
)

SELECT
  b.sku_season_state,
  CASE WHEN b.n_alerts >= 10 THEN b.policy ELSE g.global_policy END AS policy,
  CASE WHEN b.n_alerts >= 10 THEN b.lift_at_100 ELSE NULL END       AS dev_select_lift,
  CASE WHEN b.n_alerts >= 10 THEN b.precision_at_100 ELSE NULL END   AS dev_select_precision,
  b.n_alerts                                                          AS n_selection_alerts,
  CASE WHEN b.n_alerts >= 10
    THEN 'DEV_SELECT_state_specific'
    ELSE 'DEV_SELECT_global_fallback'
  END                                                                 AS selection_source,
  b.evaluated_on_split,
  TRUE                                                                AS selected_without_locked_test,
  b.used_locked_test,
  CURRENT_TIMESTAMP()                                                 AS frozen_at
FROM best_per_state b
CROSS JOIN global_policy g
WHERE b.rnk = 1;

SELECT sku_season_state, policy, dev_select_lift, selection_source, selected_without_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_by_season_state_h12_v3_2_season_state_strict`
ORDER BY sku_season_state;
