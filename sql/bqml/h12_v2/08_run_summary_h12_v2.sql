-- ============================================================================
-- STEP 08: RUN SUMMARY  (h=12 v2)
-- ============================================================================
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.run_summary_h12_v2` AS
WITH
gv AS (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2`),
cs AS (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_selected_h12_v2`),
rc AS (
  SELECT
    CASE WHEN COUNTIF(row_status='FAIL')=0 THEN 'PASS' ELSE 'FAIL' END AS dirichlet_recon_status
  FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2`
),
bl AS (
  -- Use COALESCE in case blind tables don't exist yet (HOLD scenario)
  SELECT
    COALESCE(MAX(blind_leakage_status), 'NOT_RUN') AS blind_leakage_status,
    COALESCE(SUM(n_rows), 0)                        AS n_blind_national
  FROM (
    SELECT blind_leakage_status, n_rows
    FROM `{PROJECT_ID}.{BQ_DATASET}.blind_leakage_check_h12_v2`
    LIMIT 1
  )
),
bp AS (
  SELECT COUNTIF(forecast_type = 'BLIND_W28_W40_2024') AS n_blind_provincial
  FROM `{PROJECT_ID}.{BQ_DATASET}.blind_forecast_provincial_w28_w40_h12_v2`
)
SELECT
  'h12_v2'               AS version,
  'h12_v1'               AS source_version,
  gv.deployment_decision,
  gv.failed_gates,
  gv.selected_policy,
  -- B3
  gv.viol_rate_p90_val_gate             AS b3_viol_rate_p90_val_gate,
  gv.viol_rate_p95_val_gate             AS b3_viol_rate_p95_val_gate,
  -- B4
  gv.lift_at_100                        AS lift_at_100_val_gate,
  gv.precision_at_100                   AS precision_at_100_val_gate,
  gv.recall_at_100                      AS recall_at_100_val_gate,
  -- Demand
  gv.wmape_val_gate                     AS wmape_12w_val_gate,
  gv.bias_val_gate                      AS bias_12w_val_gate,
  -- OOS
  gv.brier_v2                           AS brier_calibrated,
  gv.brier_v1_raw                       AS brier_raw,
  -- Guardrails
  gv.q90_cap_rate,
  gv.q90_p50_ratio_median,
  gv.over_under_ratio_q90,
  gv.total_mono_violations,
  -- Gates
  gv.gate_b1_leakage,
  gv.gate_b2_scope,
  gv.gate_b3_coverage,
  gv.gate_b4_lift,
  gv.gate_b6_wmape,
  -- Scope / leakage
  gv.leakage_status,
  gv.scope_status                       AS scope_vs_R_status,
  -- Dirichlet
  rc.dirichlet_recon_status             AS dirichlet_reconciliation_status,
  -- Calibration params selected
  cs.scale_multiplier,
  cs.q90_offset,
  cs.q95_offset,
  cs.factor_clip_hi,
  cs.viol_p90_val_tune,
  cs.calibration_loss,
  -- Blind forecast
  CASE WHEN gv.deployment_decision = 'DEPLOY' THEN TRUE ELSE FALSE END AS blind_forecast_generated,
  bl.n_blind_national,
  bp.n_blind_provincial,
  bl.blind_leakage_status,
  -- Timestamp
  gv.run_timestamp,
  CONCAT(
    'B3=', gv.gate_b3_coverage,
    ' | B4=', gv.gate_b4_lift,
    ' | viol_p90=', CAST(ROUND(gv.viol_rate_p90_val_gate,4) AS STRING),
    ' | lift=', CAST(ROUND(gv.lift_at_100,2) AS STRING),
    ' | wmape=', CAST(gv.wmape_val_gate AS STRING),
    ' | dirichlet=', rc.dirichlet_recon_status,
    ' | blind=', CASE WHEN gv.deployment_decision='DEPLOY' THEN 'YES' ELSE 'NO' END
  ) AS summary_line
FROM gv, cs, rc, bl, bp;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.run_summary_h12_v2`;
