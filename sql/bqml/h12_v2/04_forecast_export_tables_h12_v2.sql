-- ============================================================================
-- STEP 04: FORECAST EXPORT TABLES  (h=12 v2)
-- ============================================================================
-- PURPOSE:
--   Produce clean, enriched forecast tables for export to CSV.
--   Attempts to join SKU metadata (sku_name, familia, abc_class, sb_class)
--   from {BASE_SALES_TABLE} via DISTINCT lookup. Columns are NULL if not found.
--
-- OUTPUT TABLES:
--   sku_metadata_h12_v2           (SKU catalog derived from BASE_SALES_TABLE)
--   forecast_national_h12_v2      (all splits, labels masked for BLIND)
--   forecast_alerts_top100_h12_v2 (top-100 alerts per decision_week)
--   forecast_scorecard_h12_v2     (summary scorecard, 1 row)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 4a. SKU METADATA (derived from BASE_SALES_TABLE — adjust columns as needed)
-- ---------------------------------------------------------------------------
-- Source: v_fact_lineas_enriched (columns confirmed: descripcion_articulo,
-- descripcion_familia, codigo_familia, codigo_subfamilia)
-- Note: abc_class / sb_class not present in the enriched view — set to NULL.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_metadata_h12_v2` AS
SELECT DISTINCT
  CAST(codigo_articulo AS STRING)      AS sku_id,
  CAST(descripcion_articulo  AS STRING) AS sku_name,
  CAST(descripcion_subfamilia AS STRING) AS familia,     -- best available family label
  CAST(codigo_subfamilia      AS STRING) AS subfamilia,
  CAST(tipo_abc          AS STRING) AS abc_class,
  CAST(NULL              AS STRING) AS sb_class     -- not in v_fact_lineas_enriched
FROM {BASE_SALES_TABLE}
WHERE fecha_albaran BETWEEN '2021-01-04' AND '2024-12-29';

-- ---------------------------------------------------------------------------
-- 4b. NATIONAL FORECAST TABLE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2` AS
WITH
best_policy AS (SELECT policy AS selected_policy FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v2` LIMIT 1),
scored AS (
  SELECT
    f.*,
    CASE b.selected_policy
      WHEN 'policy_A' THEN f.p_oos_h12 * GREATEST(0.0, f.q90_12w - f.yhat_p50_12w)
      WHEN 'policy_B' THEN f.p_oos_h12 * f.q90_12w
      WHEN 'policy_C' THEN POW(f.p_oos_h12, 0.7) * GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)
      WHEN 'policy_D' THEN f.p_oos_h12 * COALESCE(NULLIF(f.lost_units_proxy_12w,0), GREATEST(0.0,f.q90_12w-f.yhat_p50_12w))
      WHEN 'policy_E' THEN f.p_oos_h12 * f.q90_12w * CASE f.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END
      ELSE f.p_oos_h12 * f.q90_12w
    END AS alert_score,
    b.selected_policy
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2` f
  CROSS JOIN best_policy b
  WHERE f.split_original = 'VAL'
)
SELECT
  s.decision_week,
  s.iso_year,
  s.iso_week,
  s.target_start_week,
  s.target_end_week,
  s.sku_id,
  m.sku_name,
  m.familia,
  m.subfamilia,
  m.abc_class,
  m.sb_class,
  s.season_group,
  s.demand_decile,
  s.volatility_bucket,
  s.eval_split_v2,
  s.p_oos_h12,
  s.alert_score,
  s.selected_policy,
  s.yhat_p50_12w,
  s.q80_12w,
  s.q90_12w,
  s.q95_12w,
  s.q99_12w,
  GREATEST(s.q90_12w - s.yhat_p50_12w, 0.0)  AS expected_buffer_q90,
  GREATEST(s.q95_12w - s.yhat_p50_12w, 0.0)  AS expected_buffer_q95,
  s.lost_units_proxy_12w,
  CASE
    WHEN s.p_oos_h12 >= 0.80 THEN 'CRITICAL'
    WHEN s.p_oos_h12 >= 0.60 THEN 'HIGH'
    WHEN s.p_oos_h12 >= 0.40 THEN 'MEDIUM'
    ELSE 'LOW'
  END AS service_recommendation,
  -- Labels: present for eval rows, NULL for BLIND (masked in forecast_recalibrated)
  s.y_true_12w,
  -- stockout_event_12w is CASE WHEN NULL in recalibrated — cast safely
  CAST(s.stockout_event_12w AS INT64) AS stockout_event_12w,
  CAST(s.n_stockout_weeks_12w AS INT64) AS n_stockout_weeks_12w,
  s.version
FROM scored s
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_metadata_h12_v2` m ON m.sku_id = s.sku_id
ORDER BY s.decision_week, s.alert_score DESC;

-- ---------------------------------------------------------------------------
-- 4c. ALERTS TOP-100 EXPORT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_alerts_top100_h12_v2` AS
SELECT
  a.decision_week,
  a.iso_year,
  a.iso_week,
  a.target_start_week,
  a.target_end_week,
  a.sku_id,
  m.sku_name,
  m.familia,
  m.abc_class,
  m.sb_class,
  a.season_group,
  a.demand_decile,
  a.p_oos_h12,
  a.risk_score AS alert_score,
  a.applied_policy,
  a.alert_rank,
  a.eval_split_v2,
  a.yhat_p50_12w,
  a.q90_12w,
  a.q95_12w,
  GREATEST(a.q90_12w - a.yhat_p50_12w, 0.0) AS expected_buffer_q90,
  a.lost_units_proxy_12w,
  CASE WHEN a.p_oos_h12 >= 0.80 THEN 'CRITICAL'
       WHEN a.p_oos_h12 >= 0.60 THEN 'HIGH'
       WHEN a.p_oos_h12 >= 0.40 THEN 'MEDIUM'
       ELSE 'LOW' END AS service_recommendation,
  a.true_stockout_label,
  a.true_stockout_sales0,
  a.version
FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_top100_h12_v2` a
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_metadata_h12_v2` m ON m.sku_id = a.sku_id
ORDER BY a.decision_week, a.alert_rank;

-- ---------------------------------------------------------------------------
-- 4d. SCORECARD (summary, 1 row per version)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_scorecard_h12_v2` AS
SELECT
  gv.version,
  gv.deployment_decision,
  gv.failed_gates,
  gv.selected_policy,
  -- Coverage
  gv.viol_rate_p90_val_gate,
  gv.viol_rate_p95_val_gate,
  gv.q90_cap_rate,
  gv.q90_p50_ratio_median,
  gv.over_under_ratio_q90,
  gv.total_mono_violations,
  -- Alert
  gv.lift_at_100,
  gv.precision_at_100,
  gv.recall_at_100,
  -- Demand
  gv.wmape_val_gate,
  gv.bias_val_gate,
  -- OOS
  gv.brier_v2,
  gv.brier_v1_raw,
  -- Gate verdicts
  gv.gate_b1_leakage,
  gv.gate_b2_scope,
  gv.gate_b3_coverage,
  gv.gate_b3b_p95,
  gv.gate_b3c_mono,
  gv.gate_b3d_cap,
  gv.gate_b3e_ratio,
  gv.gate_b4_lift,
  gv.gate_b5_brier,
  gv.gate_b6_wmape,
  gv.gate_b7_overstock,
  -- Calibration params
  cs.scale_multiplier         AS recal_scale_multiplier,
  cs.q90_offset               AS recal_q90_offset,
  cs.q95_offset               AS recal_q95_offset,
  cs.factor_clip_hi           AS recal_factor_clip_hi,
  cs.viol_p90_val_tune        AS recal_viol_p90_val_tune,
  cs.calibration_loss         AS recal_calibration_loss,
  gv.run_timestamp
FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2` gv
CROSS JOIN `{PROJECT_ID}.{BQ_DATASET}.calibration_selected_h12_v2` cs;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_scorecard_h12_v2`;
