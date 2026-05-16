-- ============================================================================
-- PHASE 0: PREPARE v5_2 BASE SCORES (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Join v5 final scores + v5_1 alert flags + v4_2 quantiles (diagnostic only).
--   Add 5 recall_safe_candidate_type categories for the new additive layer.
--
--   v5_2 is ADDITIVE on top of POLICY_E1 (v5) AND GATE_C_P3_Q3 (v5_1).
--   is_recall_safe_candidate excludes rows already covered by either layer.
--
-- INPUTS:
--   - oos_final_scores_h12_v5_strict          (v5 frozen, all splits)
--   - combined_oos_alerts_h12_v5_1_strict      (v5_1 frozen, all splits)
--   - forecast_final_h12_v4_2_strict           (v4_2, LEFT JOIN, diagnostic only)
--
-- OUTPUTS:
--   - base_scores_h12_v5_2_strict              (859,664 rows, all splits)
--
-- ANTI-LEAKAGE:
--   - v5 scores are frozen (POLICY_E1 selected on DEV_SELECT before LOCKED_TEST)
--   - v5_1 alerts are frozen (GATE_C_P3_Q3 selected on DEV_SELECT)
--   - recall_safe_candidate_type uses only features, NOT y_true or stockout
--   - quantile_spread_p90_component is diagnostic only, NOT used in scoring
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict` AS

WITH

v5_scores AS (
  SELECT
    sku_id,
    decision_week,
    week_start_date,
    eval_split_v3,
    season_group,
    sku_season_state,

    -- Actuals (for evaluation only, NEVER used in scoring)
    y_sales,
    y_true_12w,
    stockout_event_12w,

    -- v3_2 forecast
    yhat_p50_v3_2_12w,

    -- v5 component scores [0,1]
    zero_run_component,
    expected_gap_component,
    historical_positive_component,
    season_state_component,
    p_oos_component,
    recent_drop_component,

    -- v5 intermediate scores
    p_suspected_oos_score_raw,
    p_true_zero_demand,

    -- v5 final scores
    p_suspected_oos,
    p_oos_h12,
    expected_lost_sales_if_oos,
    audit_priority_score,

    -- v5 binary flag
    oos_flag AS oos_flag_v5

  FROM `thequantitativeledger.cruzber_models_eu.oos_final_scores_h12_v5_strict`
),

v5_1_flags AS (
  SELECT
    sku_id,
    decision_week,
    is_stable_core_alert,
    is_difficult_state_alert   AS is_difficult_state_alert_v5_1,
    combined_oos_alert         AS combined_oos_alert_v5_1,
    alert_source               AS alert_source_v5_1
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
),

v4_2_quantiles AS (
  SELECT
    sku_id,
    decision_week,
    yhat_p50_v4_2_12w,
    q80_v4_2_12w,
    q90_v4_2_12w,
    q95_v4_2_12w
  FROM `thequantitativeledger.cruzber_models_eu.forecast_final_h12_v4_2_strict`
),

joined AS (
  SELECT
    v5.*,
    v51.is_stable_core_alert,
    v51.is_difficult_state_alert_v5_1,
    v51.combined_oos_alert_v5_1,
    v51.alert_source_v5_1,

    -- v4_2 quantiles (diagnostic only; never used in scoring formulas)
    v42.yhat_p50_v4_2_12w,
    v42.q80_v4_2_12w,
    v42.q90_v4_2_12w,
    v42.q95_v4_2_12w,

    -- Quantile spread: diagnostic only, NOT included in F1/F2/F3
    SAFE_DIVIDE(
      v42.q90_v4_2_12w - v42.yhat_p50_v4_2_12w,
      GREATEST(v42.yhat_p50_v4_2_12w, 1.0)
    ) AS quantile_spread_p90_component

  FROM v5_scores v5
  INNER JOIN v5_1_flags v51
    ON v5.sku_id = v51.sku_id
   AND v5.decision_week = v51.decision_week
  LEFT JOIN v4_2_quantiles v42
    ON v5.sku_id = v42.sku_id
   AND v5.decision_week = v42.decision_week
),

with_candidate_type AS (
  SELECT
    *,

    -- ─────────────────────────────────────────────────────────────────────
    -- Candidate type assignment (priority order: first WHEN that matches wins)
    -- CRITICAL: all types require oos_flag_v5 = 0 AND NOT v5_1 alert
    -- This guarantees no overlap with previous layers by construction.
    -- ─────────────────────────────────────────────────────────────────────
    CASE
      -- Type 1: Core difficult (mirrors v5_1 definition, now excluded from v5_2)
      -- Included for diagnostic completeness; these already have v5_1 coverage
      -- For v5_2 filtering we apply: is_difficult_state_alert_v5_1 = FALSE
      WHEN COALESCE(oos_flag_v5, 0) = 0
       AND NOT COALESCE(is_difficult_state_alert_v5_1, FALSE)
       AND zero_run_component >= 0.15
       AND p_true_zero_demand < 0.75
      THEN 'CORE_DIFFICULT_V5_1_LIKE'

      WHEN COALESCE(oos_flag_v5, 0) = 0
       AND NOT COALESCE(is_difficult_state_alert_v5_1, FALSE)
       AND zero_run_component >= 0.30
       AND p_true_zero_demand < 0.85
       AND p_oos_h12 >= 0.05
      THEN 'LONG_ZERO_RUN_WITH_OOS_PRIOR'

      WHEN COALESCE(oos_flag_v5, 0) = 0
       AND NOT COALESCE(is_difficult_state_alert_v5_1, FALSE)
       AND expected_gap_component >= 0.50
       AND p_true_zero_demand < 0.85
       AND p_oos_h12 >= 0.05
      THEN 'EXPECTED_GAP_WITH_OOS_PRIOR'

      WHEN COALESCE(oos_flag_v5, 0) = 0
       AND NOT COALESCE(is_difficult_state_alert_v5_1, FALSE)
       AND expected_lost_sales_if_oos >= 1.0
       AND p_suspected_oos >= 0.03
       AND p_true_zero_demand < 0.90
      THEN 'ECONOMIC_RISK_NOT_STRUCTURAL_ZERO'

      WHEN COALESCE(oos_flag_v5, 0) = 0
       AND NOT COALESCE(is_difficult_state_alert_v5_1, FALSE)
       AND p_oos_h12 >= 0.10
       AND p_true_zero_demand < 0.90
       AND yhat_p50_v3_2_12w >= 1.0
      THEN 'HIGH_OOS_PRIOR_WITH_DEMAND'

      ELSE 'NOT_RECALL_SAFE_CANDIDATE'
    END AS recall_safe_candidate_type

  FROM joined
),

final AS (
  SELECT
    *,

    -- is_recall_safe_candidate: TRUE iff not covered by v5 or v5_1
    (recall_safe_candidate_type != 'NOT_RECALL_SAFE_CANDIDATE') AS is_recall_safe_candidate,

    CURRENT_TIMESTAMP()                               AS created_at_utc,
    'h12_v5_2_recall_safe_oos_policy_strict'          AS model_version,
    'Phase 0: Base scores for v5_2 additive layer'    AS phase_description

  FROM with_candidate_type
)

SELECT * FROM final;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 0 Complete: v5_2 Base Scores Prepared' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Row count by split' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_rows,
  COUNTIF(is_recall_safe_candidate) AS n_recall_safe_candidates,
  COUNTIF(is_stable_core_alert) AS n_stable_alerts,
  COUNTIF(is_difficult_state_alert_v5_1) AS n_v5_1_alerts
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

SELECT
  'Candidate type distribution (ALL splits)' AS check_name,
  recall_safe_candidate_type,
  COUNT(*) AS n_rows
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`
GROUP BY recall_safe_candidate_type
ORDER BY n_rows DESC;

SELECT
  'No-overlap check (stable AND v5_1 overlap should be 0 for v5_2 scope)' AS check_name,
  COUNTIF(is_recall_safe_candidate AND is_stable_core_alert) AS n_recall_safe_also_stable,
  COUNTIF(is_recall_safe_candidate AND is_difficult_state_alert_v5_1) AS n_recall_safe_also_v5_1,
  CASE
    WHEN COUNTIF(is_recall_safe_candidate AND is_stable_core_alert) = 0
     AND COUNTIF(is_recall_safe_candidate AND is_difficult_state_alert_v5_1) = 0
    THEN 'PASS'
    ELSE 'FAIL'
  END AS overlap_check
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`;
