-- ============================================================================
-- STEP 06: POLICY SWEEP + ALERTS TOP-100  (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   Test three risk-score policies on VAL_TUNE, select the best by lift@100,
--   then apply it to produce the final alert list alerts_top100_h4_v4.
--
--   policy_A (v3 baseline): risk = p_oos * (q95 - p50)
--   policy_B (lost-sales):  risk = p_oos * q90
--   policy_C (gamma comp.): risk = p_oos^gamma * (q95 - p50) ; gamma in {0.5, 1.0, 1.5}
--
-- OUTPUT TABLES:
--   policy_sweep_h4_v4          : lift@100 per policy on VAL_TUNE
--   alerts_top100_h4_v4         : Top-100 weekly alerts using best policy
-- ============================================================================

-- ============================================================================
-- 6a. POLICY SWEEP ON VAL_TUNE
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.policy_sweep_h4_v4` AS

WITH val_tune_forecast AS (
  -- Use forecast_h4_v4 rows from VAL_TUNE weeks only
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    f.p_oos_h4,
    f.yhat_p50_h4,
    f.q90_h4,
    f.q95_h4,
    f.amplitude,
    f.stockout_event_h4,
    f.y_true_h4,
    -- convenience
    GREATEST(0.0, f.q95_h4 - f.yhat_p50_h4) AS width_p95
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4` f
  INNER JOIN `thequantitativeledger.cruzber_models_eu.val_tune_test_split_h4_v4` sp
    ON f.decision_week = sp.decision_week
  WHERE sp.paper_split = 'VAL_TUNE'
),

-- Compute all policy scores in one pass
policies AS (
  SELECT
    decision_week,
    sku_id,
    season_group,
    stockout_event_h4,
    -- policy_A
    p_oos_h4 * width_p95
      AS score_A,
    -- policy_B
    p_oos_h4 * q90_h4
      AS score_B,
    -- policy_C_05
    POW(p_oos_h4, 0.5) * width_p95
      AS score_C05,
    -- policy_C_10  (== policy_A with gamma=1)
    POW(p_oos_h4, 1.0) * width_p95
      AS score_C10,
    -- policy_C_15
    POW(p_oos_h4, 1.5) * width_p95
      AS score_C15
  FROM val_tune_forecast
),

-- Rank each policy independently and take top-100 per week
ranked_A AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_A   DESC) AS rk FROM policies
),
ranked_B AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_B   DESC) AS rk FROM policies
),
ranked_C05 AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C05 DESC) AS rk FROM policies
),
ranked_C10 AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C10 DESC) AS rk FROM policies
),
ranked_C15 AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY score_C15 DESC) AS rk FROM policies
),

-- Prevalence (needed for lift = precision / prevalence)
prevalence AS (
  SELECT
    season_group,
    SAFE_DIVIDE(COUNTIF(stockout_event_h4 = 1), COUNT(*)) AS prev
  FROM policies
  GROUP BY season_group
),

-- Precision per policy
perf_A AS (
  SELECT 'policy_A' AS policy, season_group,
    COUNT(*) AS n_alerts,
    COUNTIF(stockout_event_h4 = 1) AS n_tp,
    SAFE_DIVIDE(COUNTIF(stockout_event_h4 = 1), COUNT(*)) AS precision_at_100
  FROM ranked_A WHERE rk <= 100 GROUP BY season_group
),
perf_B AS (
  SELECT 'policy_B' AS policy, season_group,
    COUNT(*) AS n_alerts,
    COUNTIF(stockout_event_h4 = 1) AS n_tp,
    SAFE_DIVIDE(COUNTIF(stockout_event_h4 = 1), COUNT(*)) AS precision_at_100
  FROM ranked_B WHERE rk <= 100 GROUP BY season_group
),
perf_C05 AS (
  SELECT 'policy_C_gamma0.5' AS policy, season_group,
    COUNT(*) AS n_alerts,
    COUNTIF(stockout_event_h4 = 1) AS n_tp,
    SAFE_DIVIDE(COUNTIF(stockout_event_h4 = 1), COUNT(*)) AS precision_at_100
  FROM ranked_C05 WHERE rk <= 100 GROUP BY season_group
),
perf_C10 AS (
  SELECT 'policy_C_gamma1.0' AS policy, season_group,
    COUNT(*) AS n_alerts,
    COUNTIF(stockout_event_h4 = 1) AS n_tp,
    SAFE_DIVIDE(COUNTIF(stockout_event_h4 = 1), COUNT(*)) AS precision_at_100
  FROM ranked_C10 WHERE rk <= 100 GROUP BY season_group
),
perf_C15 AS (
  SELECT 'policy_C_gamma1.5' AS policy, season_group,
    COUNT(*) AS n_alerts,
    COUNTIF(stockout_event_h4 = 1) AS n_tp,
    SAFE_DIVIDE(COUNTIF(stockout_event_h4 = 1), COUNT(*)) AS precision_at_100
  FROM ranked_C15 WHERE rk <= 100 GROUP BY season_group
),

all_perfs AS (
  SELECT * FROM perf_A
  UNION ALL SELECT * FROM perf_B
  UNION ALL SELECT * FROM perf_C05
  UNION ALL SELECT * FROM perf_C10
  UNION ALL SELECT * FROM perf_C15
)

SELECT
  ap.policy,
  ap.season_group,
  ap.n_alerts,
  ap.n_tp,
  ap.precision_at_100,
  pr.prev AS prevalence,
  SAFE_DIVIDE(ap.precision_at_100, pr.prev) AS lift_at_100,
  -- window-rank for easy selection of best
  RANK() OVER (ORDER BY SAFE_DIVIDE(ap.precision_at_100, pr.prev) DESC) AS lift_rank_overall
FROM all_perfs ap
JOIN prevalence pr ON ap.season_group = pr.season_group
ORDER BY ap.season_group, lift_rank_overall;


-- ============================================================================
-- 6b. SELECT BEST POLICY (highest avg lift across seasons)
-- Helper view — materialised for auditing
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.policy_best_h4_v4` AS
WITH policy_lifts AS (
  SELECT
    policy,
    AVG(lift_at_100) AS avg_lift
  FROM `thequantitativeledger.cruzber_models_eu.policy_sweep_h4_v4`
  GROUP BY policy
)
SELECT policy, ROUND(avg_lift, 4) AS avg_lift,
  RANK() OVER (ORDER BY avg_lift DESC) AS policy_rank
FROM policy_lifts
ORDER BY policy_rank;


-- ============================================================================
-- 6c. ALERTS TOP-100  (best policy applied to full VAL)
-- ============================================================================
-- Note: best_policy is read dynamically using a scalar subquery.
-- If policy_best is 'policy_B', risk = p_oos * q90; etc.
-- We compute all 5 scores and pick the winner via CASE.
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_v4` AS

WITH best_policy AS (
  SELECT policy FROM `thequantitativeledger.cruzber_models_eu.policy_best_h4_v4`
  WHERE policy_rank = 1
  LIMIT 1
),

base AS (
  SELECT
    f.decision_week,
    f.target_week,
    f.sku_id,
    f.p_oos_h4,
    f.yhat_p50_h4,
    f.q90_h4,
    f.q95_h4,
    f.q99_h4,
    f.y_true_h4,
    f.stockout_event_h4,
    f.season_group,
    f.segment_id_child,
    f.amplitude,
    GREATEST(0.0, f.q95_h4 - f.yhat_p50_h4) AS uncertainty_width_p95,
    -- all policy scores
    f.p_oos_h4 * GREATEST(0.0, f.q95_h4 - f.yhat_p50_h4)          AS score_A,
    f.p_oos_h4 * f.q90_h4                                           AS score_B,
    POW(f.p_oos_h4, 0.5) * GREATEST(0.0, f.q95_h4 - f.yhat_p50_h4) AS score_C05,
    f.p_oos_h4          * GREATEST(0.0, f.q95_h4 - f.yhat_p50_h4) AS score_C10,
    POW(f.p_oos_h4, 1.5) * GREATEST(0.0, f.q95_h4 - f.yhat_p50_h4) AS score_C15
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4` f
  WHERE f.split = 'VAL'
),

-- Risk score = score of the winning policy
with_risk AS (
  SELECT
    b.*,
    bp.policy AS applied_policy,
    CASE bp.policy
      WHEN 'policy_A'         THEN b.score_A
      WHEN 'policy_B'         THEN b.score_B
      WHEN 'policy_C_gamma0.5' THEN b.score_C05
      WHEN 'policy_C_gamma1.0' THEN b.score_C10
      WHEN 'policy_C_gamma1.5' THEN b.score_C15
      ELSE b.score_A   -- safe default
    END AS risk_score
  FROM base b
  CROSS JOIN best_policy bp
),

ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY decision_week
      ORDER BY risk_score DESC, p_oos_h4 DESC, amplitude DESC
    ) AS rank_in_week
  FROM with_risk
)

SELECT
  decision_week,
  target_week,
  rank_in_week,
  sku_id,
  p_oos_h4,
  yhat_p50_h4,
  q90_h4,
  q95_h4,
  q99_h4,
  uncertainty_width_p95,
  risk_score,
  applied_policy,
  y_true_h4,
  CAST(stockout_event_h4 AS INT64) AS true_stockout_label,
  CASE WHEN y_true_h4 = 0 THEN 1 ELSE 0 END AS true_stockout_sales0,
  season_group,
  segment_id_child,
  amplitude
FROM ranked
WHERE rank_in_week <= 100
ORDER BY decision_week, rank_in_week;

-- Summary
SELECT applied_policy, COUNT(DISTINCT decision_week) n_weeks, COUNT(*) n_alerts
FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_v4`
GROUP BY applied_policy;
