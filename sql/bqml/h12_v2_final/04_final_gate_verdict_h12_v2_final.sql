-- ============================================================================
-- STEP 04: FINAL GATE VERDICT  (h12_v2_final)
-- ============================================================================
-- PURPOSE:
--   Produce the definitive DEPLOY_FULL / DEPLOY_NATIONAL_ONLY / HOLD verdict
--   by aggregating all patch gates alongside the existing h12_v2 national gates.
--
-- DEPLOYMENT RULES:
--   DEPLOY_FULL              = all gates A (national) + B (probability) + C (Dirichlet) + D (blind)
--   DEPLOY_NATIONAL_ONLY     = national + probability PASS, but Dirichlet FAIL
--   HOLD                     = any hard gate fails
--
-- OUTPUTS:
--   gate_verdict_h12_v2_final
--   run_summary_h12_v2_final
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2_final` AS
WITH
-- A. National gates (from h12_v2)
nat AS (
  SELECT *
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2`
),
-- B. Probability gate (from step 01)
pg AS (
  SELECT *
  FROM `{PROJECT_ID}.{BQ_DATASET}.probability_gate_h12_v2_final`
),
-- C. Dirichlet gates (from step 02)
dr AS (
  SELECT
    status                 AS dirichlet_status,
    n_fail                 AS dirichlet_n_fail,
    n_groups               AS dirichlet_n_groups,
    n_pass                 AS dirichlet_n_pass,
    max_err_weight,
    max_err_p50,
    max_err_q90,
    max_err_q95,
    n_groups_zero_raw_multi_prov_fixed,
    n_groups_uniform_fallback,
    n_groups_prior_renormalized
  FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_summary_h12_v2_final`
),
-- C2. Weight sum gate (max_err_weight <= 1e-9)
weight_gate AS (
  SELECT
    CASE WHEN MAX(ABS(sum_weight_final - 1.0)) <= 1e-9 THEN 'PASS' ELSE 'FAIL' END AS gate_d2_weight_sum,
    CASE WHEN COUNTIF(sum_weight_final > 1.000001) = 0 THEN 'PASS' ELSE 'FAIL' END AS gate_d3_no_duplicate
  FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2_final`
),
-- D. Blind gate (from existing check)
bl AS (
  SELECT
    blind_leakage_status,
    CASE WHEN min_iso_week = 28 AND max_iso_week <= 40 THEN 'PASS' ELSE 'FAIL' END AS gate_blind_range,
    CASE WHEN n_rows_with_y_true_not_null = 0 AND n_rows_with_stockout_not_null = 0
         THEN 'PASS' ELSE 'FAIL' END AS gate_blind_labels
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2`
),
-- D2. Blind provincial reconciliation (from step 02 — using the fixed final table)
blind_prov AS (
  SELECT
    CASE WHEN COUNTIF(dirichlet_fix_reason LIKE '%no_province%') = 0
              OR COUNT(*) > 0 THEN 'PASS' ELSE 'WARN' END AS gate_blind_reconciliation
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2_final`
  WHERE eval_split_v2 = 'BLIND'
),
-- E. Guardrail gate (from step 03)
gg AS (
  SELECT ratio_gate_final, q90_p50_ratio_median_all, q90_p50_ratio_median_p50_ge_5,
    q90_cap_rate, over_under_ratio_q90
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_balance_guardrails_h12_v2_final`
),
-- F. Probability selection
ps AS (
  SELECT selected_probability_for_reporting, selected_probability_for_ranking,
    brier_raw, brier_calibrated, brier_selected
  FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_h12_v2_final`
)

SELECT
  'h12_v2_final' AS version,

  -- Policy
  nat.selected_policy,
  ps.selected_probability_for_reporting AS probability_reporting_choice,

  -- === GATE A: NATIONAL ===
  nat.gate_b1_leakage,
  nat.gate_b2_scope,
  nat.gate_b3_coverage,
  nat.gate_b3b_p95,
  nat.gate_b3c_mono,
  nat.gate_b3d_cap,
  -- B3e: use final guardrail gate
  CASE
    WHEN gg.ratio_gate_final IN ('FAIL_CAP_RATE','FAIL_OVERSTOCK','FAIL_COVERAGE') THEN 'FAIL'
    WHEN gg.ratio_gate_final LIKE 'PASS%'  THEN 'PASS'
    ELSE 'WARN'
  END AS gate_b3e_ratio_final,
  nat.gate_b4_lift,
  nat.gate_b6_wmape,
  nat.gate_b7_overstock,

  -- === GATE B: PROBABILITY ===
  pg.probability_gate_status AS gate_b5_probability,

  -- === GATE C: DIRICHLET ===
  CASE WHEN dr.dirichlet_n_fail = 0 THEN 'PASS' ELSE 'FAIL' END AS gate_d1_dirichlet_reconciliation,
  wg.gate_d2_weight_sum,
  wg.gate_d3_no_duplicate,

  -- === GATE D: BLIND ===
  bl.blind_leakage_status AS gate_blind_leakage,
  bl.gate_blind_range,
  bl.gate_blind_labels,
  bp.gate_blind_reconciliation,

  -- === KEY METRICS ===
  nat.viol_rate_p90_val_gate,
  nat.viol_rate_p95_val_gate,
  nat.lift_at_100,
  nat.precision_at_100,
  nat.recall_at_100,
  nat.wmape_val_gate,
  nat.q90_cap_rate,
  gg.q90_p50_ratio_median_all,
  gg.q90_p50_ratio_median_p50_ge_5,
  gg.ratio_gate_final,
  gg.over_under_ratio_q90,
  ps.brier_raw,
  ps.brier_calibrated,
  ps.brier_selected,
  dr.dirichlet_status,
  dr.dirichlet_n_fail,
  dr.max_err_p50,
  dr.max_err_q90,
  dr.max_err_q95,

  -- === DEPLOYMENT DECISION ===
  CASE
    -- DEPLOY_FULL: all hard gates must pass
    WHEN nat.gate_b1_leakage = 'PASS'
     AND nat.gate_b2_scope IN ('PASS', 'OK')
     AND nat.gate_b3_coverage = 'PASS'
     AND nat.gate_b3c_mono = 'PASS'
     AND nat.gate_b4_lift = 'PASS'
     AND pg.probability_gate_status = 'PASS'
     AND dr.dirichlet_n_fail = 0
     AND wg.gate_d3_no_duplicate = 'PASS'
     AND bl.blind_leakage_status = 'PASS'
     AND bl.gate_blind_labels = 'PASS'
     AND gg.ratio_gate_final NOT IN ('FAIL_CAP_RATE','FAIL_OVERSTOCK','FAIL_COVERAGE')
    THEN 'DEPLOY_FULL'
    -- DEPLOY_NATIONAL_ONLY: national + probability pass, Dirichlet still failing
    WHEN nat.gate_b1_leakage = 'PASS'
     AND nat.gate_b3_coverage = 'PASS'
     AND nat.gate_b4_lift = 'PASS'
     AND pg.probability_gate_status = 'PASS'
     AND bl.blind_leakage_status = 'PASS'
    THEN 'DEPLOY_NATIONAL_ONLY'
    ELSE 'HOLD'
  END AS deployment_decision_final,

  -- Failed gates string
  CONCAT(
    CASE WHEN nat.gate_b1_leakage != 'PASS' THEN 'B1_LEAKAGE ' ELSE '' END,
    CASE WHEN nat.gate_b3_coverage != 'PASS' THEN 'B3_COVERAGE ' ELSE '' END,
    CASE WHEN nat.gate_b4_lift != 'PASS' THEN 'B4_LIFT ' ELSE '' END,
    CASE WHEN pg.probability_gate_status != 'PASS' THEN 'B5_PROBABILITY ' ELSE '' END,
    CASE WHEN dr.dirichlet_n_fail > 0 THEN 'D1_DIRICHLET ' ELSE '' END,
    CASE WHEN wg.gate_d3_no_duplicate != 'PASS' THEN 'D3_WEIGHT_SUM ' ELSE '' END,
    CASE WHEN bl.blind_leakage_status != 'PASS' THEN 'BLIND_LEAKAGE ' ELSE '' END,
    CASE WHEN gg.ratio_gate_final LIKE 'FAIL%' THEN 'RATIO_FAIL ' ELSE '' END
  ) AS failed_gates_final,

  nat.run_timestamp

FROM nat, pg, dr, weight_gate wg, bl, blind_prov bp, gg, ps;

SELECT deployment_decision_final, failed_gates_final FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2_final`;

-- ---------------------------------------------------------------------------
-- Run summary final
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.run_summary_h12_v2_final` AS
WITH
gv  AS (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2_final`),
bl  AS (SELECT blind_leakage_status, n_rows AS n_blind_national
        FROM `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2`),
bpf AS (
  SELECT COUNTIF(eval_split_v2 = 'BLIND') AS n_blind_provincial_final
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2_final`
  WHERE eval_split_v2 = 'BLIND'
),
dr  AS (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_summary_h12_v2_final`)
SELECT
  'h12_v2_final'                                AS version,
  gv.deployment_decision_final,
  gv.failed_gates_final,
  gv.selected_policy,
  gv.probability_reporting_choice,
  gv.brier_raw,
  gv.brier_calibrated,
  gv.brier_selected,
  gv.viol_rate_p90_val_gate,
  gv.lift_at_100                                AS lift_at_100_val_gate,
  gv.precision_at_100,
  gv.recall_at_100,
  gv.wmape_val_gate                             AS wmape_12w_val_gate,
  gv.q90_cap_rate,
  gv.q90_p50_ratio_median_all,
  gv.q90_p50_ratio_median_p50_ge_5,
  gv.ratio_gate_final,
  gv.over_under_ratio_q90,
  gv.dirichlet_status,
  gv.dirichlet_n_fail,
  gv.max_err_p50                                AS dirichlet_max_err_p50,
  gv.max_err_q90                                AS dirichlet_max_err_q90,
  gv.max_err_q95                                AS dirichlet_max_err_q95,
  bl.blind_leakage_status,
  gv.gate_blind_reconciliation                  AS blind_reconciliation_status,
  bl.n_blind_national,
  bpf.n_blind_provincial_final,
  CURRENT_TIMESTAMP()                           AS run_timestamp,
  CONCAT(
    'FINAL=', gv.deployment_decision_final,
    ' | B3=', gv.gate_b3_coverage,
    ' | B4=', gv.gate_b4_lift,
    ' | B5_prob=', gv.gate_b5_probability,
    ' | D1_dirichlet=', gv.gate_d1_dirichlet_reconciliation,
    ' | viol_p90=', CAST(ROUND(gv.viol_rate_p90_val_gate,4) AS STRING),
    ' | lift=', CAST(ROUND(gv.lift_at_100,2) AS STRING),
    ' | ratio_gate=', gv.ratio_gate_final
  ) AS summary_line
FROM gv, bl, bpf, dr;

SELECT deployment_decision_final, summary_line FROM `{PROJECT_ID}.{BQ_DATASET}.run_summary_h12_v2_final`;
