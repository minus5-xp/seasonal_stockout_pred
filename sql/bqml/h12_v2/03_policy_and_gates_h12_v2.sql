-- ============================================================================
-- STEP 03: POLICY SWEEP + GATES  (h=12 v2)
-- ============================================================================
-- PURPOSE:
--   Evaluate gates and select best alert policy using exclusively VAL_GATE
--   (iso_week 21-27 of 2024). VAL_TUNE and BLIND are never touched here.
--
-- GATES:
--   B1  leakage_status = PASS              (inherited from h12_v1)
--   B2  scope_vs_R = OK                   (inherited from h12_v1)
--   B3  viol_rate_p90_VAL_GATE ∈ [0.08, 0.12]
--   B3b viol_rate_p95_VAL_GATE ∈ [0.03, 0.08]
--   B3c monotonicity_violations = 0
--   B3d q90_cap_rate <= 0.05
--   B3e median(q90/p50) <= 3.0  (active demand)
--   B4  lift@100_VAL_GATE > 1.5
--   B5  brier_calibrated <= brier_raw
--   B6  WMAPE_VAL_GATE <= WMAPE_h12v1 * 1.10
--   B7  over_under_ratio_q90 <= 3.0
--
-- POLICY SWEEP (5 policies on VAL_GATE):
--   policy_A : p_oos_12w * GREATEST(q90_12w - yhat_p50_12w, 0)
--   policy_B : p_oos_12w * q90_12w
--   policy_C : POW(p_oos_12w, 0.7) * GREATEST(q95_12w - yhat_p50_12w, 0)
--   policy_D : p_oos_12w * COALESCE(lost_units_proxy_12w, GREATEST(q90_12w - yhat_p50_12w, 0))
--   policy_E : p_oos_12w * q90_12w * season_weight (1.25 HIGH_SEASON, 1.0 REST)
--
-- OUTPUT TABLES:
--   gate_metrics_h12_v2
--   policy_sweep_h12_v2
--   policy_best_h12_v2
--   alerts_top100_h12_v2
--   gate_verdict_h12_v2
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 3a. GATE METRICS on VAL_GATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.gate_metrics_h12_v2` AS
WITH

val_gate AS (
  SELECT f.*
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2` f
  WHERE f.eval_split_v2 = 'VAL_GATE'
    AND f.split_original = 'VAL'
),

val_gate_active AS (
  SELECT * FROM val_gate WHERE split_original = 'VAL'
  -- amplitude threshold: use amplitude from base_scores
),

coverage_metrics AS (
  SELECT
    season_group,
    COUNT(*)                                                          AS n_obs,
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
    ROUND(AVG(CASE WHEN q90_12w >= cap_value  THEN 1.0 ELSE 0.0 END), 4) AS q90_cap_rate,
    ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(50)], 3) AS q90_p50_ratio_median,
    -- monotonicity violations (should be 0 after enforcement)
    COUNTIF(q90_12w < q80_12w) AS mono_viol_q90_lt_q80,
    COUNTIF(q95_12w < q90_12w) AS mono_viol_q95_lt_q90,
    -- demand metrics
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)), 0)), 4) AS wmape,
    ROUND(AVG(yhat_p50_12w - y_true_12w) / NULLIF(AVG(y_true_12w), 0), 4) AS bias_pct,
    -- over/under proxy
    ROUND(SAFE_DIVIDE(
      SUM(GREATEST(q90_12w - y_true_12w, 0)),
      NULLIF(SUM(GREATEST(y_true_12w - q90_12w, 0)), 0)
    ), 3) AS over_under_ratio_q90
  FROM val_gate
  WHERE y_true_12w IS NOT NULL
  GROUP BY season_group
),

-- Global aggregates
global_metrics AS (
  SELECT
    'GLOBAL' AS season_group,
    COUNT(*)                                                          AS n_obs,
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
    ROUND(AVG(CASE WHEN q90_12w >= cap_value  THEN 1.0 ELSE 0.0 END), 4) AS q90_cap_rate,
    ROUND(APPROX_QUANTILES(SAFE_DIVIDE(q90_12w, NULLIF(yhat_p50_12w, 0)), 100)[OFFSET(50)], 3) AS q90_p50_ratio_median,
    COUNTIF(q90_12w < q80_12w) AS mono_viol_q90_lt_q80,
    COUNTIF(q95_12w < q90_12w) AS mono_viol_q95_lt_q90,
    ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)), 0)), 4) AS wmape,
    ROUND(AVG(yhat_p50_12w - y_true_12w) / NULLIF(AVG(y_true_12w), 0), 4) AS bias_pct,
    ROUND(SAFE_DIVIDE(
      SUM(GREATEST(q90_12w - y_true_12w, 0)),
      NULLIF(SUM(GREATEST(y_true_12w - q90_12w, 0)), 0)
    ), 3) AS over_under_ratio_q90
  FROM val_gate
  WHERE y_true_12w IS NOT NULL
)

SELECT * FROM coverage_metrics
UNION ALL
SELECT * FROM global_metrics
ORDER BY season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.gate_metrics_h12_v2`;

-- Compare WMAPE v2 vs v1 on VAL_GATE rows
SELECT
  'WMAPE_COMPARISON' AS metric,
  v2.wmape AS wmape_v2,
  v1_ref.wmape_v1_ref,
  ROUND(v2.wmape / NULLIF(v1_ref.wmape_v1_ref, 0), 4) AS ratio_v2_vs_v1
FROM (
  SELECT ROUND(SAFE_DIVIDE(SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)), 0)), 4) AS wmape
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2`
  WHERE eval_split_v2 = 'VAL_GATE' AND y_true_12w IS NOT NULL
) v2
CROSS JOIN (
  SELECT ROUND(SAFE_DIVIDE(SUM(ABS(f.y_true_12w - f.yhat_p50_12w)), NULLIF(SUM(ABS(f.y_true_12w)), 0)), 4) AS wmape_v1_ref
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1` f
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` sp
    ON sp.decision_week = f.decision_week AND sp.eval_split_v2 = 'VAL_GATE'
  WHERE f.split = 'VAL' AND f.y_true_12w IS NOT NULL
) v1_ref;

-- ---------------------------------------------------------------------------
-- 3b. POLICY SWEEP on VAL_GATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_h12_v2` AS
WITH val_gate_scored AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    f.p_oos_h12,
    f.yhat_p50_12w,
    f.q90_12w,
    f.q95_12w,
    f.lost_units_proxy_12w,
    f.stockout_event_12w,
    f.y_true_12w,
    GREATEST(0.0, f.q90_12w - f.yhat_p50_12w) AS width_q90,
    GREATEST(0.0, f.q95_12w - f.yhat_p50_12w) AS width_q95,
    CASE f.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END AS season_weight
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2` f
  WHERE f.eval_split_v2 = 'VAL_GATE'
    AND f.split_original = 'VAL'
    AND f.y_true_12w IS NOT NULL
),
scores AS (
  SELECT *,
    p_oos_h12 * width_q90                                                  AS score_A,
    p_oos_h12 * q90_12w                                                    AS score_B,
    POW(p_oos_h12, 0.7) * width_q95                                        AS score_C,
    p_oos_h12 * COALESCE(NULLIF(lost_units_proxy_12w, 0), width_q90)       AS score_D,
    p_oos_h12 * q90_12w * season_weight                                    AS score_E
  FROM val_gate_scored
),
prevalence AS (
  SELECT season_group, SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)) AS base_rate
  FROM val_gate_scored GROUP BY season_group
),
ranked_A   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_A DESC) AS rk FROM scores),
ranked_B   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_B DESC) AS rk FROM scores),
ranked_C   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C DESC) AS rk FROM scores),
ranked_D   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_D DESC) AS rk FROM scores),
ranked_E   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_E DESC) AS rk FROM scores),
perf AS (
  SELECT 'policy_A' AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)) AS precision_at_100,
    COUNT(*) AS n_alerts, COUNTIF(stockout_event_12w=1) AS n_tp,
    SUM(COALESCE(lost_units_proxy_12w,0)) AS lost_units_captured
  FROM ranked_A WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_B', season_group, SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_B WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_C', season_group, SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_C WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_D', season_group, SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_D WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_E', season_group, SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_E WHERE rk <= 100 GROUP BY season_group
)
SELECT
  p.policy, p.season_group, p.precision_at_100, p.n_alerts, p.n_tp,
  p.lost_units_captured, pr.base_rate,
  SAFE_DIVIDE(p.precision_at_100, NULLIF(pr.base_rate, 0)) AS lift_at_100
FROM perf p LEFT JOIN prevalence pr USING (season_group)
ORDER BY lift_at_100 DESC, policy, season_group;

-- ---------------------------------------------------------------------------
-- 3c. BEST POLICY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v2` AS
WITH agg AS (
  SELECT
    policy,
    AVG(lift_at_100)      AS avg_lift,
    AVG(precision_at_100) AS avg_precision,
    SUM(lost_units_captured) AS total_lost_captured,
    ROW_NUMBER() OVER (ORDER BY AVG(lift_at_100) DESC, AVG(precision_at_100) DESC,
                                SUM(lost_units_captured) DESC) AS rnk
  FROM `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_h12_v2`
  GROUP BY policy
)
SELECT policy, avg_lift, avg_precision, total_lost_captured, 'SELECTED' AS status
FROM agg WHERE rnk = 1;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v2`;

-- ---------------------------------------------------------------------------
-- 3d. ALERTS TOP-100 on VAL (all splits, best policy)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v2` AS
WITH
best AS (SELECT policy FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v2` LIMIT 1),
scored AS (
  SELECT
    f.*,
    CASE b.policy
      WHEN 'policy_A' THEN f.p_oos_h12 * GREATEST(0.0, f.q90_12w - f.yhat_p50_12w)
      WHEN 'policy_B' THEN f.p_oos_h12 * f.q90_12w
      WHEN 'policy_C' THEN POW(f.p_oos_h12, 0.7) * GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)
      WHEN 'policy_D' THEN f.p_oos_h12 * COALESCE(NULLIF(f.lost_units_proxy_12w,0), GREATEST(0.0, f.q90_12w - f.yhat_p50_12w))
      WHEN 'policy_E' THEN f.p_oos_h12 * f.q90_12w * CASE f.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END
      ELSE f.p_oos_h12 * f.q90_12w
    END AS risk_score,
    b.policy AS applied_policy,
    f.stockout_event_12w        AS true_stockout_label,
    CASE WHEN f.y_true_12w = 0 THEN 1 ELSE 0 END AS true_stockout_sales0
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2` f
  CROSS JOIN best b
  WHERE f.split_original = 'VAL'
)
SELECT *,
  ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY risk_score DESC) AS alert_rank
FROM scored
QUALIFY alert_rank <= 100
ORDER BY decision_week, alert_rank;

-- ---------------------------------------------------------------------------
-- 3e. GATE VERDICT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` AS
WITH
gm AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.gate_metrics_h12_v2` WHERE season_group = 'GLOBAL'
),
-- Universe counts on VAL_GATE — read directly from base_scores to avoid
-- CASE WHEN NULL ambiguity in forecast_recalibrated_h12_v2
val_gate_universe AS (
  SELECT
    COUNT(*)                                    AS n_universe,
    COUNTIF(s.stockout_event_12w = 1)           AS n_oos_universe
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` s
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` sp
    ON sp.decision_week = s.week_start_date AND sp.eval_split_v2 = 'VAL_GATE'
  WHERE s.split = 'VAL'
    AND s.y_true_12w IS NOT NULL
),
alerts_gate AS (
  SELECT
    COUNT(*)                                                  AS n_alerts,
    COUNTIF(CAST(true_stockout_label AS INT64) = 1)          AS n_tp
  FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v2`
  WHERE eval_split_v2 = 'VAL_GATE'
),
alerts_perf AS (
  SELECT
    ROUND(SAFE_DIVIDE(ag.n_tp, ag.n_alerts), 4)              AS precision_at_100,
    ROUND(SAFE_DIVIDE(ag.n_tp, vu.n_oos_universe), 4)        AS recall_at_100,
    ROUND(SAFE_DIVIDE(
      SAFE_DIVIDE(ag.n_tp, ag.n_alerts),
      SAFE_DIVIDE(vu.n_oos_universe, vu.n_universe)
    ), 4)                                                     AS lift_at_100
  FROM alerts_gate ag
  CROSS JOIN val_gate_universe vu
),
-- Brier v2 on VAL_GATE: use calibrated scores + base_scores for clean join
brier AS (
  SELECT
    ROUND(AVG(POW(c.p_oos_h12 - CAST(b.stockout_event_12w AS FLOAT64), 2)), 5) AS brier_v2
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = c.sku_id AND b.week_start_date = c.week_start_date
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` sp
    ON sp.decision_week = b.week_start_date AND sp.eval_split_v2 = 'VAL_GATE'
  WHERE b.split = 'VAL'
    AND b.stockout_event_12w IS NOT NULL
),
brier_v1 AS (
  -- score_oos_h12_calibrated_v1 uses 'true_label' (not stockout_event_12w)
  SELECT ROUND(AVG(POW(p_oos_h12 - CAST(true_label AS FLOAT64), 2)), 5) AS brier_raw
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1`
  WHERE split = 'VAL'
),
lk AS (SELECT status AS leakage_status FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_check_h12_v1`),
sc AS (SELECT status AS scope_status FROM `{PROJECT_ID}.{BQ_DATASET}.comparison_scope_h12_vs_R_v11`),
bp AS (SELECT policy AS selected_policy, avg_lift FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v2`),
wmape_v1 AS (
  SELECT ROUND(SAFE_DIVIDE(SUM(ABS(f.y_true_12w - f.yhat_p50_12w)), NULLIF(SUM(ABS(f.y_true_12w)), 0)), 4) AS wmape_v1
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1` f
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` sp
    ON sp.decision_week = f.decision_week AND sp.eval_split_v2 = 'VAL_GATE'
  WHERE f.split = 'VAL' AND f.y_true_12w IS NOT NULL
)

SELECT
  'h12_v2'              AS version,
  bp.selected_policy,

  -- Coverage gates
  ROUND(gm.viol_p90, 4) AS viol_rate_p90_val_gate,
  ROUND(gm.viol_p95, 4) AS viol_rate_p95_val_gate,
  gm.q90_cap_rate,
  gm.q90_p50_ratio_median,
  gm.mono_viol_q90_lt_q80 + gm.mono_viol_q95_lt_q90 AS total_mono_violations,
  gm.over_under_ratio_q90,
  ROUND(gm.wmape, 4)    AS wmape_val_gate,
  ROUND(gm.bias_pct, 4) AS bias_val_gate,

  -- Alert gates
  ROUND(ap.lift_at_100, 4)        AS lift_at_100,
  ROUND(ap.precision_at_100, 4)   AS precision_at_100,
  ROUND(ap.recall_at_100, 4)      AS recall_at_100,

  -- Brier
  ROUND(br.brier_v2, 5)           AS brier_v2,
  ROUND(brv1.brier_raw, 5)        AS brier_v1_raw,
  CASE WHEN br.brier_v2 <= brv1.brier_raw THEN 'PASS' ELSE 'FAIL' END AS b5_brier_gate,

  -- WMAPE comparison
  ROUND(wv1.wmape_v1, 4)          AS wmape_v1_ref,
  ROUND(gm.wmape / NULLIF(wv1.wmape_v1, 0), 4) AS wmape_ratio_v2_v1,

  -- Leakage / scope
  lk.leakage_status,
  sc.scope_status,

  -- Individual gate verdicts
  CASE WHEN lk.leakage_status = 'PASS' THEN 'PASS' ELSE 'FAIL' END AS gate_b1_leakage,
  CASE WHEN sc.scope_status = 'OK' THEN 'PASS' ELSE 'FAIL' END AS gate_b2_scope,
  CASE WHEN gm.viol_p90 BETWEEN 0.08 AND 0.12 THEN 'PASS' ELSE 'FAIL' END AS gate_b3_coverage,
  CASE WHEN gm.viol_p95 BETWEEN 0.03 AND 0.08 THEN 'PASS' ELSE 'CONDITIONAL_PASS' END AS gate_b3b_p95,
  CASE WHEN gm.mono_viol_q90_lt_q80 + gm.mono_viol_q95_lt_q90 = 0 THEN 'PASS' ELSE 'FAIL' END AS gate_b3c_mono,
  CASE WHEN gm.q90_cap_rate <= 0.05 THEN 'PASS' ELSE 'WARN' END AS gate_b3d_cap,
  CASE WHEN gm.q90_p50_ratio_median <= 3.0 THEN 'PASS' ELSE 'WARN' END AS gate_b3e_ratio,
  CASE WHEN ap.lift_at_100 > 1.5 THEN 'PASS' ELSE 'FAIL' END AS gate_b4_lift,
  CASE WHEN br.brier_v2 <= brv1.brier_raw THEN 'PASS' ELSE 'FAIL' END AS gate_b5_brier,
  CASE WHEN gm.wmape <= wv1.wmape_v1 * 1.10 THEN 'PASS' ELSE 'FAIL' END AS gate_b6_wmape,
  CASE WHEN gm.over_under_ratio_q90 <= 3.0 THEN 'PASS' ELSE 'WARN' END AS gate_b7_overstock,

  -- Overall deployment decision
  -- DEPLOY requires B1+B2+B3+B3c+B4 PASS. Others are WARN/CONDITIONAL.
  CASE
    WHEN lk.leakage_status = 'PASS'
     AND sc.scope_status   = 'OK'
     AND gm.viol_p90 BETWEEN 0.08 AND 0.12
     AND (gm.mono_viol_q90_lt_q80 + gm.mono_viol_q95_lt_q90) = 0
     AND ap.lift_at_100 > 1.5
    THEN 'DEPLOY'
    ELSE 'HOLD'
  END AS deployment_decision,

  -- Failed gates (for HOLD diagnosis)
  CONCAT(
    CASE WHEN lk.leakage_status != 'PASS'               THEN 'B1_LEAKAGE ' ELSE '' END,
    CASE WHEN sc.scope_status != 'OK'                    THEN 'B2_SCOPE ' ELSE '' END,
    CASE WHEN NOT (gm.viol_p90 BETWEEN 0.08 AND 0.12)   THEN 'B3_COVERAGE ' ELSE '' END,
    CASE WHEN (gm.mono_viol_q90_lt_q80 + gm.mono_viol_q95_lt_q90) > 0 THEN 'B3C_MONO ' ELSE '' END,
    CASE WHEN ap.lift_at_100 <= 1.5                      THEN 'B4_LIFT ' ELSE '' END,
    CASE WHEN gm.wmape > wv1.wmape_v1 * 1.10             THEN 'B6_WMAPE ' ELSE '' END
  ) AS failed_gates,

  CURRENT_TIMESTAMP() AS run_timestamp

FROM gm, alerts_perf ap, brier br, brier_v1 brv1, lk, sc, bp, wmape_v1 wv1;

SELECT deployment_decision, failed_gates, viol_rate_p90_val_gate, lift_at_100, wmape_val_gate
FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2`;
