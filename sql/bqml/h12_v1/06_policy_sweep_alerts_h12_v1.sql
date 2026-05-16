-- ============================================================================
-- STEP 06: POLICY SWEEP + ALERTS TOP-100  (h=12 v1)
-- ============================================================================
-- PURPOSE:
--   Test 5 risk-score policies on VAL_TUNE, select the best by lift@100,
--   then apply it to produce alerts_top100_h12_v1.
--
--   policy_A : p_oos_h12 * GREATEST(q95_12w - yhat_p50_12w, 0)
--   policy_B : p_oos_h12 * q90_12w
--   policy_C : POW(p_oos_h12, gamma) * GREATEST(q95_12w - yhat_p50_12w, 0)
--              gamma in {0.5, 1.0, 1.5}
--   policy_D : p_oos_h12 * lost_units_proxy_12w
--   policy_E : p_oos_h12 * q90_12w * activity_weight
--              activity_weight = LEAST(2.0, GREATEST(0.5, amplitude / avg_amplitude))
--
-- SELECTION CRITERION: highest lift@100 on VAL_TUNE.
--
-- OUTPUT TABLES:
--   policy_sweep_h12_v1
--   policy_best_h12_v1
--   alerts_top100_h12_v1
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 6a. POLICY SWEEP ON VAL_TUNE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_h12_v1` AS

WITH val_tune_forecast AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    f.p_oos_h12,
    f.yhat_p50_12w,
    f.q90_12w,
    f.q95_12w,
    f.amplitude,
    f.lost_units_proxy_12w,
    f.stockout_event_12w,
    f.y_true_12w,
    GREATEST(0.0, f.q95_12w - f.yhat_p50_12w) AS width_p95
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1` f
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_test_split_h12_v1` sp
    ON f.decision_week = sp.decision_week
  WHERE sp.paper_split = 'VAL_TUNE'
    AND f.split = 'VAL'
),

-- Precompute season average amplitude for activity_weight
season_avg_amp AS (
  SELECT season_group, AVG(amplitude) AS avg_amplitude
  FROM val_tune_forecast
  GROUP BY season_group
),

-- All policy scores in one pass
policies AS (
  SELECT
    v.decision_week,
    v.sku_id,
    v.season_group,
    v.stockout_event_12w,
    v.y_true_12w,
    -- policy_A
    v.p_oos_h12 * v.width_p95                            AS score_A,
    -- policy_B
    v.p_oos_h12 * v.q90_12w                              AS score_B,
    -- policy_C (gamma variants)
    POW(v.p_oos_h12, 0.5) * v.width_p95                  AS score_C05,
    POW(v.p_oos_h12, 1.0) * v.width_p95                  AS score_C10,
    POW(v.p_oos_h12, 1.5) * v.width_p95                  AS score_C15,
    -- policy_D
    v.p_oos_h12 * COALESCE(v.lost_units_proxy_12w, 0.0)  AS score_D,
    -- policy_E (activity weight)
    v.p_oos_h12 * v.q90_12w
      * LEAST(2.0, GREATEST(0.5,
          SAFE_DIVIDE(v.amplitude, NULLIF(sa.avg_amplitude, 0))
        ))                                                AS score_E
  FROM val_tune_forecast v
  LEFT JOIN season_avg_amp sa ON sa.season_group = v.season_group
),

-- Rank each policy independently per week -> top-100
ranked_A   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_A   DESC) AS rk FROM policies),
ranked_B   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_B   DESC) AS rk FROM policies),
ranked_C05 AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C05 DESC) AS rk FROM policies),
ranked_C10 AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C10 DESC) AS rk FROM policies),
ranked_C15 AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C15 DESC) AS rk FROM policies),
ranked_D   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_D   DESC) AS rk FROM policies),
ranked_E   AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_E   DESC) AS rk FROM policies),

-- Universe prevalence for lift calculation
prevalence AS (
  SELECT
    season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate
  FROM val_tune_forecast
  GROUP BY season_group
),

-- Policy metrics (precision, recall, lift per policy)
perf AS (
  SELECT 'policy_A'  AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*))       AS precision_at_100,
    COUNT(*) AS n_alerts, COUNTIF(stockout_event_12w = 1) AS n_tp
  FROM ranked_A WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_B'  AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w = 1)
  FROM ranked_B WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_C05' AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w = 1)
  FROM ranked_C05 WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_C10' AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w = 1)
  FROM ranked_C10 WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_C15' AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w = 1)
  FROM ranked_C15 WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_D'  AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w = 1)
  FROM ranked_D WHERE rk <= 100 GROUP BY season_group
  UNION ALL
  SELECT 'policy_E'  AS policy, season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_12w = 1), COUNT(*)),
    COUNT(*), COUNTIF(stockout_event_12w = 1)
  FROM ranked_E WHERE rk <= 100 GROUP BY season_group
)
SELECT
  p.policy,
  p.season_group,
  p.precision_at_100,
  p.n_alerts,
  p.n_tp,
  pr.base_rate,
  SAFE_DIVIDE(p.precision_at_100, NULLIF(pr.base_rate, 0)) AS lift_at_100
FROM perf p
LEFT JOIN prevalence pr USING (season_group)
ORDER BY lift_at_100 DESC, policy, season_group;

-- ---------------------------------------------------------------------------
-- 6b. BEST POLICY (highest average lift across season_groups)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v1` AS
WITH ranked_policies AS (
  SELECT
    policy,
    AVG(lift_at_100) AS avg_lift,
    AVG(precision_at_100) AS avg_precision,
    ROW_NUMBER() OVER (ORDER BY AVG(lift_at_100) DESC) AS rnk
  FROM `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_h12_v1`
  GROUP BY policy
)
SELECT policy, avg_lift, avg_precision, 'SELECTED' AS status
FROM ranked_policies
WHERE rnk = 1;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v1`;

-- ---------------------------------------------------------------------------
-- 6c. ALERTS TOP-100  (VAL, full year, best policy applied)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v1` AS
WITH best_policy AS (
  SELECT policy FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v1` LIMIT 1
),
season_avg_amp AS (
  SELECT season_group, AVG(amplitude) AS avg_amplitude
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1`
  WHERE split = 'VAL'
  GROUP BY season_group
),
scored AS (
  SELECT
    f.*,
    CASE b.policy
      WHEN 'policy_A'  THEN f.p_oos_h12 * GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)
      WHEN 'policy_B'  THEN f.p_oos_h12 * f.q90_12w
      WHEN 'policy_C05' THEN POW(f.p_oos_h12, 0.5) * GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)
      WHEN 'policy_C10' THEN POW(f.p_oos_h12, 1.0) * GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)
      WHEN 'policy_C15' THEN POW(f.p_oos_h12, 1.5) * GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)
      WHEN 'policy_D'  THEN f.p_oos_h12 * COALESCE(f.lost_units_proxy_12w, 0.0)
      WHEN 'policy_E'  THEN
        f.p_oos_h12 * f.q90_12w
          * LEAST(2.0, GREATEST(0.5, SAFE_DIVIDE(f.amplitude, NULLIF(sa.avg_amplitude, 0))))
      ELSE f.p_oos_h12 * f.q90_12w
    END AS risk_score,
    b.policy AS applied_policy,
    -- true label for evaluation
    f.stockout_event_12w AS true_stockout_label,
    CASE WHEN f.y_true_12w = 0 THEN 1 ELSE 0 END AS true_stockout_sales0
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_h12_v1` f
  CROSS JOIN best_policy b
  LEFT JOIN season_avg_amp sa ON sa.season_group = f.season_group
  WHERE f.split = 'VAL'
)
SELECT *
FROM (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY risk_score DESC) AS alert_rank
  FROM scored
)
WHERE alert_rank <= 100
ORDER BY decision_week, alert_rank;

-- Quick summary
SELECT
  applied_policy,
  COUNT(DISTINCT decision_week) AS n_weeks,
  COUNT(*) AS n_alerts,
  ROUND(AVG(CAST(true_stockout_label AS FLOAT64)), 4) AS precision_at_100,
  ROUND(AVG(CAST(true_stockout_sales0 AS FLOAT64)), 4) AS precision_sales0,
  ROUND(AVG(risk_score), 4) AS avg_risk_score
FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v1`
GROUP BY applied_policy;
