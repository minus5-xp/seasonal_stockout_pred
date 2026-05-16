-- ============================================================================
-- PHASE 8: COMPARE v3_2, v4_2, v5 (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Create comparison table showing the THREE-LAYER SYSTEM:
--   - v3_2: Point forecast (p50)
--   - v4_2: Quantile overlay (p10, p90, spread)
--   - v5: OOS state detection (p_suspected_oos, oos_flag)
--
-- INPUTS:
--   - oos_final_scores_h12_v5_strict
--   - forecast_final_h12_v4_2_strict (for v4_2 quantiles)
--   - forecast_gated_h12_v3_2_season_state_strict (for v3_2 baseline)
--
-- OUTPUTS:
--   - comparison_v3_v4_v5_h12_strict (consolidated view)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.comparison_v3_v4_v5_h12_strict` AS
WITH

v5_data AS (
  SELECT
    sku_id,
    decision_week,
    week_start_date,
    eval_split_v3,
    season_group,
    sku_season_state,
    y_sales,
    y_true_12w,
    stockout_event_12w,
    yhat_p50_v3_2_12w,
    p_oos_h12,
    frozen_policy_id,
    frozen_policy_family,
    p_suspected_oos,
    oos_flag,
    expected_lost_sales_if_oos,
    audit_priority_score,
    zero_run_length,
    zero_run_component,
    expected_gap_component,
    historical_positive_component,
    season_state_component,
    p_oos_component,
    recent_drop_component
  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

v4_data AS (
  SELECT
    sku_id,
    decision_week,
    q80_v4_2_12w,
    q90_v4_2_12w,
    q95_v4_2_12w,
    spread90_v4_2,
    zero_regime
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
)

SELECT
  v5.sku_id,
  v5.decision_week,
  v5.week_start_date,
  v5.eval_split_v3,
  v5.season_group,
  v5.sku_season_state,
  
  -- Actuals
  v5.y_sales,
  v5.y_true_12w,
  v5.stockout_event_12w,
  
  -- v3_2: Point forecast (p50) - already in v5_data
  v5.yhat_p50_v3_2_12w,
  
  -- v4_2: Quantile overlay
  v4.q80_v4_2_12w,
  v4.q90_v4_2_12w,
  v4.q95_v4_2_12w,
  v4.spread90_v4_2,
  v4.zero_regime,
  
  -- v5: OOS state detection
  v5.p_oos_h12 AS p_oos_legacy,
  v5.p_suspected_oos AS p_suspected_oos_v5,
  v5.oos_flag AS oos_flag_v5,
  v5.expected_lost_sales_if_oos AS expected_lost_sales_v5,
  v5.audit_priority_score AS audit_priority_score_v5,
  v5.zero_run_length,
  v5.frozen_policy_id,
  v5.frozen_policy_family,
  
  -- Component scores (interpretability)
  v5.zero_run_component,
  v5.expected_gap_component,
  v5.historical_positive_component,
  v5.season_state_component,
  v5.p_oos_component,
  v5.recent_drop_component,
  
  -- Metadata
  'h12_v5_oos_state_layer_strict' AS comparison_version,
  CURRENT_TIMESTAMP() AS created_at_utc
  
FROM v5_data v5
LEFT JOIN v4_data v4 USING (sku_id, decision_week)
ORDER BY v5.sku_id, v5.decision_week;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 8 Complete: Comparison Table (v3_2, v4_2, v5) Created' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Comparison summary' AS check_name,
  COUNT(*) AS total_obs,
  COUNT(DISTINCT sku_id) AS n_skus,
  COUNT(DISTINCT decision_week) AS n_weeks,
  
  -- v3_2 coverage
  COUNT(yhat_p50_v3_2_12w) AS n_v3_2,
  
  -- v4_2 coverage
  COUNT(q80_v4_2_12w) AS n_v4_2_q80,
  COUNT(q90_v4_2_12w) AS n_v4_2_q90,
  COUNT(q95_v4_2_12w) AS n_v4_2_q95,
  
  -- v5 coverage
  COUNT(p_suspected_oos_v5) AS n_v5_scores,
  SUM(oos_flag_v5) AS n_v5_flags,
  ROUND(100.0 * SUM(oos_flag_v5) / COUNT(*), 2) AS pct_v5_flagged
  
FROM `thequantitativeledger.cruzber_models_eu.comparison_v3_v4_v5_h12_strict`;

SELECT
  'Three-layer system roles' AS description,
  'v3_2' AS layer,
  'Point forecast (p50)' AS role,
  'WMAPE optimization' AS metric
UNION ALL
SELECT
  'Three-layer system roles',
  'v4_2',
  'Quantile overlay (p10, p90)',
  'Quantile preservation, spread calibration'
UNION ALL
SELECT
  'Three-layer system roles',
  'v5',
  'OOS state detection',
  'Precision@k, Recall@k, Lift@k';

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 99 will run comprehensive leakage audit' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
