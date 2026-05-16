-- ============================================================================
-- STEP 04: POLICY SWEEP — DEV_SELECT ONLY  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Evaluate all 5 alert policies (A/B/C/D/E) using exclusively DEV_SELECT
--   (W09-W16 of 2024). The winning policy is stored in
--   frozen_policy_h12_v3_strict.
--
-- POST-SELECTION BIAS FIX:
--   In h12_v2, policy_sweep_h12_v2 evaluated policies on VAL_GATE (W21-W27),
--   selected the best policy from that same split, and then gate metrics were
--   reported on VAL_GATE → post-selection bias.
--   v3_strict: selection uses DEV_SELECT (W09-W16). LOCKED_TEST never
--   participates in policy selection.
--
-- POLICY DEFINITIONS (same as v2):
--   policy_A : p_oos_12w * GREATEST(q90 - p50, 0)
--   policy_B : p_oos_12w * q90
--   policy_C : POW(p_oos_12w, 0.7) * GREATEST(q95 - p50, 0)
--   policy_D : p_oos_12w * COALESCE(lost_units_proxy, GREATEST(q90 - p50, 0))
--   policy_E : p_oos_12w * q90 * season_weight (1.25 HIGH_SEASON, 1.0 REST)
--
-- PROBABILITY USED: frozen_probability_mode.selected_for_ranking
--   (selected on DEV_SELECT in step 03).
--
-- OUTPUT TABLES:
--   policy_sweep_dev_select_h12_v3_strict
--   frozen_policy_h12_v3_strict   ← FROZEN DECISION
-- ============================================================================

-- ── 4a. POLICY SWEEP on DEV_SELECT ───────────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_dev_select_h12_v3_strict` AS
WITH

-- Frozen probability selection
prob_mode AS (
  SELECT selected_for_ranking AS prob_mode
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`
  LIMIT 1
),

dev_select_scored AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    -- Use frozen probability mode for ranking
    CASE pm.prob_mode
      WHEN 'RAW'        THEN c.p_oos_raw
      WHEN 'CALIBRATED' THEN c.p_oos_h12
      ELSE c.p_oos_h12
    END                                                  AS p_oos_rank,
    f.yhat_p50_12w,
    f.q90_12w,
    f.q95_12w,
    f.lost_units_proxy_12w,
    f.stockout_event_12w,
    f.y_true_12w,
    GREATEST(0.0, f.q90_12w - f.yhat_p50_12w)           AS width_q90,
    GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)           AS width_q95,
    CASE f.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END AS season_weight,
    pm.prob_mode                                         AS applied_prob_mode
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  CROSS JOIN prob_mode pm
  WHERE f.eval_split_v3 = 'DEV_SELECT'          -- DEV_SELECT only
    AND f.split_original = 'VAL'
    AND f.stockout_event_12w IS NOT NULL         -- labelled rows only
    AND f.y_true_12w IS NOT NULL
),

scores AS (
  SELECT *,
    p_oos_rank * width_q90                                           AS score_A,
    p_oos_rank * q90_12w                                             AS score_B,
    POW(p_oos_rank, 0.7) * width_q95                                 AS score_C,
    p_oos_rank * COALESCE(NULLIF(lost_units_proxy_12w, 0), width_q90) AS score_D,
    p_oos_rank * q90_12w * season_weight                             AS score_E
  FROM dev_select_scored
),

prevalence AS (
  SELECT season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate
  FROM dev_select_scored
  GROUP BY season_group
),

ranked_A AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_A DESC) AS rk FROM scores),
ranked_B AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_B DESC) AS rk FROM scores),
ranked_C AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C DESC) AS rk FROM scores),
ranked_D AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_D DESC) AS rk FROM scores),
ranked_E AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_E DESC) AS rk FROM scores),

perf AS (
  SELECT 'policy_A' AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)) AS precision_at_100,
    COUNT(*) AS n_alerts, COUNTIF(stockout_event_12w=1) AS n_tp,
    SUM(COALESCE(lost_units_proxy_12w, 0)) AS lost_units_captured
  FROM ranked_A WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_B', season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_B WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_C', season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_C WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_D', season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_D WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_E', season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w=1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w=1), SUM(COALESCE(lost_units_proxy_12w,0))
  FROM ranked_E WHERE rk <= 100 GROUP BY season_group
)

SELECT
  p.policy,
  p.season_group,
  ROUND(p.precision_at_100, 4)                              AS precision_at_100,
  p.n_alerts,
  p.n_tp,
  ROUND(p.lost_units_captured, 1)                           AS lost_units_captured,
  ROUND(pr.base_rate, 4)                                    AS base_rate,
  ROUND(SAFE_DIVIDE(p.precision_at_100, NULLIF(pr.base_rate, 0)), 4) AS lift_at_100,
  -- Audit
  'DEV_SELECT' AS evaluated_on_split,
  FALSE        AS used_locked_test
FROM perf p
LEFT JOIN prevalence pr USING (season_group)
ORDER BY lift_at_100 DESC, policy, season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_dev_select_h12_v3_strict`
ORDER BY lift_at_100 DESC LIMIT 20;

-- ── 4b. FROZEN POLICY ────────────────────────────────────────────────────
-- Aggregate across season_groups; select winner by avg_lift_at_100.
-- Single-row table. Never re-selected on LOCKED_TEST.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict` AS
WITH agg AS (
  SELECT
    policy,
    ROUND(AVG(lift_at_100), 4)      AS avg_lift_at_100,
    ROUND(AVG(precision_at_100), 4) AS avg_precision_at_100,
    SUM(lost_units_captured)        AS total_lost_units_captured,
    ROW_NUMBER() OVER (
      ORDER BY AVG(lift_at_100) DESC,
               AVG(precision_at_100) DESC,
               SUM(lost_units_captured) DESC
    ) AS rnk
  FROM `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_dev_select_h12_v3_strict`
  GROUP BY policy
)
SELECT
  policy,
  avg_lift_at_100,
  avg_precision_at_100,
  total_lost_units_captured,
  'SELECTED' AS status,
  -- Audit
  'DEV_SELECT'  AS selected_using_split,
  FALSE         AS used_locked_test,
  CURRENT_TIMESTAMP() AS frozen_at,
  CONCAT(
    'Policy=', policy,
    ', avg_lift=', CAST(avg_lift_at_100 AS STRING),
    ' | Selected on DEV_SELECT (W09-W16) — NOT on LOCKED_TEST'
  ) AS notes
FROM agg
WHERE rnk = 1;

SELECT
  'frozen_policy' AS table_name,
  policy, avg_lift_at_100, avg_precision_at_100,
  selected_using_split, used_locked_test, frozen_at
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict`;
