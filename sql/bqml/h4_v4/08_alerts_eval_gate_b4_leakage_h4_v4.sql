-- ============================================================================
-- STEP 08: ALERTS EVALUATION + GATE B4 + LEAKAGE CHECK  (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   (a) evaluate_alerts_top100_h4_pooled_v4: pooled precision/lift metrics
--   (b) Gate B4:  lift@100_model > 1.5  AND  ideally improves vs v3
--   (c) Leakage check: 0 rows where (decision_week + 4) != target_week on VAL
--
-- OUTPUT TABLES:
--   eval_alerts_top100_h4_pooled_v4
--   b4_comparison_v3_vs_v4_h4
--   gate_b4_verdict_h4_v4
--   leakage_check_h4_v4
-- ============================================================================

-- ============================================================================
-- 8a. POOLED ALERT EVALUATION
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.eval_alerts_top100_h4_pooled_v4` AS
WITH
pooled AS (
  SELECT
    season_group,
    -- Model-based stockout label
    CAST(true_stockout_label AS INT64)    AS label_model,
    -- Sales=0 label (broader definition)
    CAST(true_stockout_sales0 AS INT64)   AS label_sales0
  FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_v4`
),
global_base AS (
  SELECT
    season_group,
    COUNT(DISTINCT f.decision_week) * 100 AS n_alerts_expected,
    COUNT(*)                              AS n_total_universe,
    COUNTIF(CAST(stockout_event_h4 AS INT64) = 1) AS n_total_stockouts_model,
    COUNTIF(y_true_h4 = 0)               AS n_total_stockouts_sales0
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4` f
  WHERE split = 'VAL'
  GROUP BY season_group
),
alert_perf AS (
  SELECT
    'POOLED' AS period,
    p.season_group,
    COUNT(*)                                      AS n_alerts,
    COUNTIF(p.label_model = 1)                   AS n_tp_model,
    COUNTIF(p.label_model IS NULL)               AS n_null_labels_model,
    SAFE_DIVIDE(COUNTIF(p.label_model = 1), COUNT(*)) AS precision_model,
    COUNTIF(p.label_sales0 = 1)                  AS n_tp_sales0,
    SAFE_DIVIDE(COUNTIF(p.label_sales0 = 1), COUNT(*)) AS precision_sales0
  FROM pooled p
  GROUP BY p.season_group
)
SELECT
  ap.period,
  ap.season_group,
  ap.n_alerts,
  ap.n_tp_model                               AS n_true_positives_in_top100_model,
  ap.n_null_labels_model,
  gb.n_total_stockouts_model,
  SAFE_DIVIDE(gb.n_total_stockouts_model, gb.n_total_universe) AS prevalence_model,
  ap.precision_model                          AS precision_at_100_model,
  SAFE_DIVIDE(ap.n_tp_model, gb.n_total_stockouts_model) AS recall_at_100_model,
  SAFE_DIVIDE(ap.precision_model,
    SAFE_DIVIDE(gb.n_total_stockouts_model, gb.n_total_universe))
                                              AS lift_at_100_model,
  ap.n_tp_sales0                             AS n_true_positives_in_top100_sales0,
  gb.n_total_stockouts_sales0,
  SAFE_DIVIDE(gb.n_total_stockouts_sales0, gb.n_total_universe) AS prevalence_sales0,
  ap.precision_sales0                        AS precision_at_100_sales0,
  SAFE_DIVIDE(ap.n_tp_sales0, gb.n_total_stockouts_sales0)      AS recall_at_100_sales0,
  SAFE_DIVIDE(ap.precision_sales0,
    SAFE_DIVIDE(gb.n_total_stockouts_sales0, gb.n_total_universe))
                                              AS lift_at_100_sales0,
  CASE
    WHEN SAFE_DIVIDE(ap.precision_model,
           SAFE_DIVIDE(gb.n_total_stockouts_model, gb.n_total_universe)) >= 1.5
    THEN 'PASS'
    ELSE 'FAIL'
  END AS gate_b4_lift_check
FROM alert_perf ap
JOIN global_base gb ON ap.season_group = gb.season_group;


-- ============================================================================
-- 8b. COMPARISON v3 vs v4
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.b4_comparison_v3_vs_v4_h4` AS
WITH v3 AS (
  SELECT 'v3_tuned' AS version, season_group,
    precision_at_100_model, recall_at_100_model, lift_at_100_model
  FROM `thequantitativeledger.cruzber_models_eu.eval_alerts_top100_h4_pooled_v3`
  WHERE period = 'POOLED'
),
v4 AS (
  SELECT 'v4' AS version, season_group,
    precision_at_100_model, recall_at_100_model, lift_at_100_model
  FROM `thequantitativeledger.cruzber_models_eu.eval_alerts_top100_h4_pooled_v4`
  WHERE period = 'POOLED'
)
SELECT
  v3.season_group,
  ROUND(v3.precision_at_100_model, 4) AS precision_v3,
  ROUND(v3.recall_at_100_model,    4) AS recall_v3,
  ROUND(v3.lift_at_100_model,      2) AS lift_v3,
  ROUND(v4.precision_at_100_model, 4) AS precision_v4,
  ROUND(v4.recall_at_100_model,    4) AS recall_v4,
  ROUND(v4.lift_at_100_model,      2) AS lift_v4,
  ROUND(v4.precision_at_100_model - v3.precision_at_100_model, 4) AS delta_precision,
  ROUND(v4.lift_at_100_model      - v3.lift_at_100_model,      2) AS delta_lift,
  ROUND(SAFE_DIVIDE(v4.lift_at_100_model - v3.lift_at_100_model, v3.lift_at_100_model) * 100, 2) AS delta_lift_pct,
  CASE
    WHEN v4.lift_at_100_model >= 1.5 AND SAFE_DIVIDE(v4.lift_at_100_model - v3.lift_at_100_model, v3.lift_at_100_model) >= 0
      THEN 'PASS_IMPROVED'
    WHEN v4.lift_at_100_model >= 1.5 AND SAFE_DIVIDE(v4.lift_at_100_model - v3.lift_at_100_model, v3.lift_at_100_model) >= -0.10
      THEN 'CONDITIONAL_PASS'
    WHEN v4.lift_at_100_model >= 1.5
      THEN 'CONDITIONAL_PASS_DEGRADED'
    ELSE 'FAIL'
  END AS gate_b4_verdict
FROM v3
LEFT JOIN v4 USING (season_group)
ORDER BY season_group;


-- ============================================================================
-- 8c. OVERALL GATE B4 VERDICT
-- ============================================================================
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.gate_b4_verdict_h4_v4` AS
WITH verdict_summary AS (
  SELECT
    COUNT(*) AS n_seasons,
    COUNTIF(gate_b4_verdict LIKE 'PASS%')                    AS n_pass,
    COUNTIF(gate_b4_verdict = 'CONDITIONAL_PASS')            AS n_conditional,
    COUNTIF(gate_b4_verdict LIKE '%DEGRADED%')               AS n_degraded,
    COUNTIF(gate_b4_verdict = 'FAIL')                        AS n_fail,
    ROUND(AVG(lift_v4), 2)                                   AS avg_lift_v4,
    ROUND(MIN(lift_v4), 2)                                   AS min_lift_v4,
    ROUND(AVG(delta_lift_pct), 2)                            AS avg_delta_lift_pct_vs_v3
  FROM `thequantitativeledger.cruzber_models_eu.b4_comparison_v3_vs_v4_h4`
)
SELECT
  'v4' AS version,
  *,
  CASE
    WHEN n_fail = 0 AND n_conditional = 0 AND n_degraded = 0 THEN 'PASS'
    WHEN n_fail = 0 THEN 'CONDITIONAL_PASS'
    ELSE 'FAIL'
  END AS gate_b4_overall_verdict
FROM verdict_summary;


-- ============================================================================
-- 8d. LEAKAGE CHECK
-- ============================================================================
-- Rule: target_week MUST equal decision_week + exactly 4 weeks (h=4).
-- Any deviation => data leakage or incorrect join.
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.leakage_check_h4_v4` AS
WITH check_rows AS (
  SELECT
    decision_week,
    target_week,
    DATE_ADD(decision_week, INTERVAL 4 WEEK) AS expected_target_week,
    CASE
      WHEN target_week = DATE_ADD(decision_week, INTERVAL 4 WEEK) THEN 0
      ELSE 1
    END AS is_wrong_horizon
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4`
  WHERE split = 'VAL'
)
SELECT
  COUNT(*)              AS n_rows_checked,
  COUNTIF(is_wrong_horizon = 1) AS n_wrong_horizon,
  CASE
    WHEN COUNTIF(is_wrong_horizon = 1) = 0 THEN 'PASS'
    ELSE 'FAIL'
  END AS status,
  CURRENT_TIMESTAMP()   AS checked_at
FROM check_rows;


-- ============================================================================
-- Final diagnostic display
-- ============================================================================
SELECT 'GATE B4 v4 VERDICT' AS check;
SELECT * FROM `thequantitativeledger.cruzber_models_eu.gate_b4_verdict_h4_v4`;

SELECT 'LEAKAGE CHECK v4' AS check;
SELECT * FROM `thequantitativeledger.cruzber_models_eu.leakage_check_h4_v4`;

SELECT 'v3 vs v4 COMPARISON' AS check;
SELECT * FROM `thequantitativeledger.cruzber_models_eu.b4_comparison_v3_vs_v4_h4`;
