-- ============================================================================
-- PHASE 5: BUILD COMBINED OOS ALERTS (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Apply frozen difficult_state_policy to ALL splits (DEV_TUNE, DEV_SELECT, LOCKED_TEST).
--   Combine with stable_core_policy (POLICY_E1) to produce final unified alerts.
--
--   Combined logic: alert = stable_core_alert OR difficult_state_alert
--
-- INPUTS:
--   - frozen_difficult_state_policy_h12_v5_1_strict (Phase 4, 1 row)
--   - base_scores_h12_v5_1_strict (Phase 0, all splits)
--   - difficult_state_scored_h12_v5_1_strict (Phase 1, all splits)
--   - difficult_state_policy_candidates_h12_v5_1_strict (Phase 2, for policy params)
--
-- OUTPUTS:
--   - combined_oos_alerts_h12_v5_1_strict (119,857 rows, all splits)
--
-- ANTI-LEAKAGE:
--   - Policy was frozen using DEV_SELECT only
--   - Now applying to LOCKED_TEST with no feedback loop
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict` AS

WITH

-- Get frozen policy params
frozen_policy AS (
  SELECT
    frozen_difficult_policy_id,
    frozen_gate_set_id,
    frozen_percentile_config_id,
    frozen_quota_config_id
  FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
  LIMIT 1
),

-- Get policy parameters from candidate table
policy_params AS (
  SELECT
    cand.gate_set_id,
    cand.min_yhat,
    cand.min_els,
    cand.min_p_susp,
    cand.min_p_oos,
    cand.percentile_high_season,
    cand.percentile_rest,
    cand.quota_high_season,
    cand.quota_rest
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict` cand
  INNER JOIN frozen_policy fp
    ON cand.difficult_policy_id = fp.frozen_difficult_policy_id
),

-- All data with scores
all_data AS (
  SELECT
    base.sku_id,
    base.decision_week,
    base.eval_split_v3,
    base.sku_season_state,
    base.season_group,
    
    -- Actuals
    base.y_true_12w,
    base.stockout_event_12w,
    
    -- v5 scores
    base.yhat_p50_v3_2_12w,
    base.p_suspected_oos,
    base.expected_lost_sales_if_oos,
    base.audit_priority_score,
    base.p_oos_h12,
    
    -- v5_1 difficult state score
    scored.difficult_state_score,
    
    -- Flags
    base.is_stable_core_alert,
    base.is_difficult_state_candidate
    
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` base
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict` scored
    ON base.sku_id = scored.sku_id
   AND base.decision_week = scored.decision_week
),

-- Apply frozen policy to all data
policy_application AS (
  SELECT
    data.*,
    params.min_yhat,
    params.min_els,
    params.min_p_susp,
    params.min_p_oos,
    
    -- Season-group-specific params
    CASE data.season_group
      WHEN 'HIGH_SEASON' THEN params.percentile_high_season
      WHEN 'REST' THEN params.percentile_rest
    END AS state_percentile_threshold,
    
    CASE data.season_group
      WHEN 'HIGH_SEASON' THEN params.quota_high_season
      WHEN 'REST' THEN params.quota_rest
    END AS state_weekly_quota,
    
    -- Gate check
    CASE params.gate_set_id
      WHEN 'GATE_A' THEN 
        data.yhat_p50_v3_2_12w >= 5.0 
        AND data.expected_lost_sales_if_oos >= 1.0 
        AND data.p_suspected_oos >= 0.05
        AND data.p_oos_h12 >= 0.05
      WHEN 'GATE_B' THEN 
        data.yhat_p50_v3_2_12w >= 3.0 
        AND data.expected_lost_sales_if_oos >= 0.5 
        AND data.p_suspected_oos >= 0.03
        AND data.p_oos_h12 >= 0.03
      WHEN 'GATE_C' THEN 
        data.yhat_p50_v3_2_12w >= 1.0 
        AND data.expected_lost_sales_if_oos >= 0.25 
        AND data.p_suspected_oos >= 0.01
        AND data.p_oos_h12 >= 0.01
    END AS passes_gate
    
  FROM all_data data
  CROSS JOIN policy_params params
  WHERE data.is_difficult_state_candidate = TRUE
),

-- Rank and apply quota
ranked_policy AS (
  SELECT
    *,
    
    -- Rank within eval_split + season_group + week
    ROW_NUMBER() OVER (
      PARTITION BY eval_split_v3, decision_week, season_group
      ORDER BY difficult_state_score DESC, expected_lost_sales_if_oos DESC
    ) AS rank_within_state_week,
    
    -- Meets criteria before quota
    CASE 
      WHEN passes_gate
       AND difficult_state_score >= state_percentile_threshold
      THEN TRUE
      ELSE FALSE
    END AS meets_criteria_before_quota
    
  FROM policy_application
),

-- Flag difficult state alerts
flagged_policy AS (
  SELECT
    *,
    
    -- Final difficult state alert
    CASE 
      WHEN meets_criteria_before_quota
       AND rank_within_state_week <= state_weekly_quota
      THEN TRUE
      ELSE FALSE
    END AS is_difficult_state_alert
    
  FROM ranked_policy
),

-- Merge back with all data (including non-candidates)
final_alerts AS (
  SELECT
    all_data.sku_id,
    all_data.decision_week,
    all_data.eval_split_v3,
    all_data.sku_season_state,
    all_data.season_group,
    
    -- Actuals
    all_data.y_true_12w,
    all_data.stockout_event_12w,
    
    -- Scores
    all_data.yhat_p50_v3_2_12w,
    all_data.p_suspected_oos,
    all_data.expected_lost_sales_if_oos,
    all_data.audit_priority_score,
    all_data.difficult_state_score,
    
    -- Alert flags
    all_data.is_stable_core_alert,
    COALESCE(flagged.is_difficult_state_alert, FALSE) AS is_difficult_state_alert,
    
    -- Combined alert (OR logic, no overlap by construction)
    all_data.is_stable_core_alert OR COALESCE(flagged.is_difficult_state_alert, FALSE) AS combined_oos_alert,
    
    -- Alert source
    CASE 
      WHEN all_data.is_stable_core_alert THEN 'STABLE_CORE_POLICY_E1'
      WHEN COALESCE(flagged.is_difficult_state_alert, FALSE) THEN 'DIFFICULT_STATE_POLICY'
      ELSE 'NONE'
    END AS alert_source,
    
    -- Rank (if applicable)
    flagged.rank_within_state_week,
    
    -- Metadata
    CURRENT_TIMESTAMP() AS created_at_utc,
    'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
    'Phase 5: Combined alerts (stable + difficult)' AS phase_description
    
  FROM all_data
  LEFT JOIN flagged_policy flagged
    ON all_data.sku_id = flagged.sku_id
   AND all_data.decision_week = flagged.decision_week
)

SELECT * FROM final_alerts
ORDER BY eval_split_v3, decision_week, sku_id;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 5 Complete: Combined OOS Alerts Built' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Row counts by split
SELECT
  'Row counts by split' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  COUNTIF(combined_oos_alert) AS n_combined_alerts,
  COUNTIF(is_stable_core_alert) AS n_stable_alerts,
  COUNTIF(is_difficult_state_alert) AS n_difficult_alerts,
  ROUND(100.0 * COUNTIF(combined_oos_alert) / COUNT(*), 2) AS pct_combined_alerts
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;

-- Alert source distribution
SELECT
  'Alert source distribution' AS check_name,
  alert_source,
  COUNT(*) AS n_alerts,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total_alerts
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
WHERE combined_oos_alert
GROUP BY alert_source
ORDER BY n_alerts DESC;

-- Overlap check (should be 0 by construction)
SELECT
  'Overlap check (should be 0)' AS check_name,
  COUNTIF(is_stable_core_alert AND is_difficult_state_alert) AS n_overlap_alerts,
  CASE 
    WHEN COUNTIF(is_stable_core_alert AND is_difficult_state_alert) = 0
    THEN '✓ PASS: No overlap between stable and difficult alerts'
    ELSE '✗ FAIL: Overlap detected (logic error)'
  END AS validation_status
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 6 will compute final metrics on LOCKED_TEST' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
