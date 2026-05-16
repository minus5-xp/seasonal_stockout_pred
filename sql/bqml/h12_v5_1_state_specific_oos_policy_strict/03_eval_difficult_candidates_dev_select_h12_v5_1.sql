-- ============================================================================
-- PHASE 3: EVALUATE DIFFICULT_POLICY_CANDIDATES ON DEV_SELECT (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Evaluate all 81 difficult_policy_candidates on DEV_SELECT holdout.
--   Compute incremental and combined metrics vs stable_core_policy (POLICY_E1).
--   Calculate selection_loss for policy selection in Phase 4.
--
-- INPUTS:
--   - difficult_state_scored_h12_v5_1_strict (Phase 1)
--   - difficult_state_policy_candidates_h12_v5_1_strict (Phase 2)
--   - base_scores_h12_v5_1_strict (Phase 0, for stable alerts)
--
-- OUTPUTS:
--   - difficult_state_candidate_eval_dev_select_h12_v5_1_strict (81 rows)
--
-- ANTI-LEAKAGE:
--   - Only DEV_SELECT split used for evaluation
--   - LOCKED_TEST never accessed
--   - y_true_12w and stockout_event_12w used ONLY for evaluation metrics
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict` AS

WITH

-- DEV_SELECT data with scores
dev_select_data AS (
  SELECT
    base.sku_id,
    base.decision_week,
    base.sku_season_state,
    base.season_group,
    
    -- Actuals (for evaluation)
    base.y_true_12w,
    base.stockout_event_12w,
    
    -- v5 stable scores
    base.p_suspected_oos,
    base.expected_lost_sales_if_oos,
    base.audit_priority_score,
    
    -- v5_1 difficult state score
    scored.difficult_state_score,
    
    -- Gates
    scored.passes_gate_a,
    scored.passes_gate_b,
    scored.passes_gate_c,
    
    -- Stable core alert (frozen POLICY_E1)
    base.is_stable_core_alert,
    base.is_difficult_state_candidate
    
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` base
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict` scored
    ON base.sku_id = scored.sku_id
   AND base.decision_week = scored.decision_week
  WHERE base.eval_split_v3 = 'DEV_SELECT'
),

-- Baseline metrics (stable_core_policy only, POLICY_E1)
stable_baseline AS (
  SELECT
    COUNT(*) AS n_obs_total,
    COUNTIF(stockout_event_12w = 1) AS n_true_oos_total,
    COUNTIF(is_stable_core_alert) AS n_stable_alerts,
    COUNTIF(is_stable_core_alert AND stockout_event_12w = 1) AS n_stable_tp,
    COUNTIF(is_stable_core_alert AND COALESCE(stockout_event_12w, 0) = 0) AS n_stable_fp,
    
    -- Stable metrics
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(is_stable_core_alert)
    ) AS stable_precision,
    
    SAFE_DIVIDE(
      COUNTIF(is_stable_core_alert AND stockout_event_12w = 1),
      COUNTIF(stockout_event_12w = 1)
    ) AS stable_recall,
    
    SAFE_DIVIDE(1.0 * COUNTIF(stockout_event_12w = 1), COUNT(*)) AS base_rate
    
  FROM dev_select_data
),

-- For each candidate, apply policy and compute flags
candidate_applications AS (
  SELECT
    cand.difficult_policy_id,
    cand.gate_set_id,
    cand.percentile_config_id,
    cand.quota_config_id,
    
    data.sku_id,
    data.decision_week,
    data.sku_season_state,
    data.season_group,
    data.stockout_event_12w,
    data.expected_lost_sales_if_oos,
    data.is_stable_core_alert,
    data.is_difficult_state_candidate,
    data.difficult_state_score,
    
    -- Apply gate filter
    CASE cand.gate_set_id
      WHEN 'GATE_A' THEN data.passes_gate_a
      WHEN 'GATE_B' THEN data.passes_gate_b
      WHEN 'GATE_C' THEN data.passes_gate_c
    END AS passes_gate,
    
    -- Get season-group-specific percentile threshold
    CASE data.season_group
      WHEN 'HIGH_SEASON' THEN cand.percentile_high_season
      WHEN 'REST' THEN cand.percentile_rest
    END AS state_percentile_threshold,
    
    -- Get season-group-specific weekly quota
    CASE data.season_group
      WHEN 'HIGH_SEASON' THEN cand.quota_high_season
      WHEN 'REST' THEN cand.quota_rest
    END AS state_weekly_quota
    
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict` cand
  CROSS JOIN dev_select_data data
  WHERE data.is_difficult_state_candidate = TRUE  -- Only apply to difficult states
),

-- Rank within state+week and apply quota
ranked_candidates AS (
  SELECT
    *,
    
    -- Rank within season_group + week by difficult_state_score
    ROW_NUMBER() OVER (
      PARTITION BY difficult_policy_id, decision_week, season_group
      ORDER BY difficult_state_score DESC, expected_lost_sales_if_oos DESC
    ) AS rank_within_state_week,
    
    -- Flag: passes all criteria (gate + percentile + quota)
    CASE 
      WHEN passes_gate
       AND difficult_state_score >= state_percentile_threshold
      THEN TRUE
      ELSE FALSE
    END AS meets_criteria_before_quota
    
  FROM candidate_applications
),

-- Apply quota (top-N per state per week)
flagged_candidates AS (
  SELECT
    *,
    
    -- Final flag: meets criteria AND within quota
    CASE 
      WHEN meets_criteria_before_quota
       AND rank_within_state_week <= state_weekly_quota
      THEN TRUE
      ELSE FALSE
    END AS is_difficult_state_alert
    
  FROM ranked_candidates
),

-- Compute weekly alert counts per policy for stability metrics
weekly_alert_counts AS (
  SELECT
    difficult_policy_id,
    decision_week,
    COUNTIF(is_difficult_state_alert) AS alerts_this_week
  FROM flagged_candidates
  GROUP BY difficult_policy_id, decision_week
),

-- Compute stability metrics per policy
weekly_stability_metrics AS (
  SELECT
    difficult_policy_id,
    STDDEV(alerts_this_week) AS weekly_alerts_std
  FROM weekly_alert_counts
  GROUP BY difficult_policy_id
),

-- Aggregate metrics per candidate
candidate_metrics AS (
  SELECT
    fc.difficult_policy_id,
    ANY_VALUE(fc.gate_set_id) AS gate_set_id,
    ANY_VALUE(fc.percentile_config_id) AS percentile_config_id,
    ANY_VALUE(fc.quota_config_id) AS quota_config_id,
    
    -- Incremental alerts (difficult state alerts not in stable)
    COUNTIF(fc.is_difficult_state_alert) AS incremental_alerts,
    COUNTIF(fc.is_difficult_state_alert AND fc.stockout_event_12w = 1) AS incremental_true_positives,
    COUNTIF(fc.is_difficult_state_alert AND COALESCE(fc.stockout_event_12w, 0) = 0) AS incremental_false_positives,
    SUM(CASE WHEN fc.is_difficult_state_alert AND fc.stockout_event_12w = 1
             THEN fc.expected_lost_sales_if_oos ELSE 0 END) AS incremental_expected_lost_sales,
    
    -- By season_group
    COUNTIF(fc.is_difficult_state_alert AND fc.season_group = 'HIGH_SEASON') AS alerts_high_season,
    COUNTIF(fc.is_difficult_state_alert AND fc.season_group = 'REST') AS alerts_rest,
    
    COUNTIF(fc.is_difficult_state_alert AND fc.stockout_event_12w = 1 AND fc.season_group = 'HIGH_SEASON') AS tp_high_season,
    COUNTIF(fc.is_difficult_state_alert AND fc.stockout_event_12w = 1 AND fc.season_group = 'REST') AS tp_rest,
    
    -- Stability metrics (weekly variation)
    wsm.weekly_alerts_std
    
  FROM flagged_candidates fc
  LEFT JOIN weekly_stability_metrics wsm
    ON fc.difficult_policy_id = wsm.difficult_policy_id
  GROUP BY fc.difficult_policy_id, wsm.weekly_alerts_std
),

-- Combine with stable baseline and compute final metrics
final_evaluation AS (
  SELECT
    m.*,
    b.n_obs_total,
    b.n_true_oos_total,
    b.n_stable_alerts,
    b.n_stable_tp,
    b.stable_precision,
    b.stable_recall,
    b.base_rate,
    
    -- Incremental metrics
    SAFE_DIVIDE(m.incremental_true_positives, m.incremental_alerts) AS incremental_precision,
    SAFE_DIVIDE(m.incremental_true_positives, b.n_true_oos_total) AS incremental_recall,
    SAFE_DIVIDE(
      SAFE_DIVIDE(m.incremental_true_positives, m.incremental_alerts),
      b.base_rate
    ) AS incremental_lift,
    SAFE_DIVIDE(m.incremental_false_positives, b.n_obs_total - b.n_true_oos_total) AS incremental_fpr,
    
    -- Combined metrics (stable + difficult, no duplicates since difficult excludes stable)
    b.n_stable_alerts + m.incremental_alerts AS combined_alerts,
    b.n_stable_tp + m.incremental_true_positives AS combined_true_positives,
    b.n_stable_fp + m.incremental_false_positives AS combined_false_positives,
    
    SAFE_DIVIDE(
      b.n_stable_tp + m.incremental_true_positives,
      b.n_stable_alerts + m.incremental_alerts
    ) AS combined_precision,
    
    SAFE_DIVIDE(
      b.n_stable_tp + m.incremental_true_positives,
      b.n_true_oos_total
    ) AS combined_recall,
    
    SAFE_DIVIDE(
      SAFE_DIVIDE(b.n_stable_tp + m.incremental_true_positives, b.n_stable_alerts + m.incremental_alerts),
      b.base_rate
    ) AS combined_lift
    
  FROM candidate_metrics m
  CROSS JOIN stable_baseline b
)

SELECT
  difficult_policy_id,
  gate_set_id,
  percentile_config_id,
  quota_config_id,
  
  -- Data context
  n_obs_total,
  n_true_oos_total,
  base_rate,
  
  -- Stable baseline (POLICY_E1)
  n_stable_alerts,
  n_stable_tp,
  stable_precision,
  stable_recall,
  
  -- Incremental (difficult state policy only)
  incremental_alerts,
  incremental_true_positives,
  incremental_false_positives,
  incremental_precision,
  incremental_recall,
  incremental_lift,
  incremental_fpr,
  incremental_expected_lost_sales,
  
  -- Combined (stable + difficult)
  combined_alerts,
  combined_true_positives,
  combined_false_positives,
  combined_precision,
  combined_recall,
  combined_lift,
  
  -- By season_group
  alerts_high_season,
  alerts_rest,
  tp_high_season,
  tp_rest,
  
  -- Stability
  weekly_alerts_std,
  
  -- Penalties for selection_loss
  -- Use n_obs_total as reference (not n_stable_alerts) to avoid penalising
  -- any policy that finds more alerts than the tiny stable baseline
  CASE 
    WHEN incremental_alerts > 0.10 * n_obs_total THEN 2.0
    WHEN incremental_alerts > 0.05 * n_obs_total THEN 1.0
    ELSE 0.0
  END AS alert_volume_penalty,
  
  CASE 
    WHEN incremental_precision < base_rate THEN 5.0
    WHEN incremental_precision < 1.2 * base_rate THEN 2.0
    ELSE 0.0
  END AS low_precision_penalty,
  
  CASE 
    WHEN weekly_alerts_std > 5.0 THEN 1.5
    WHEN weekly_alerts_std > 3.0 THEN 0.5
    ELSE 0.0
  END AS instability_penalty,
  
  -- SELECTION_LOSS (minimize to select best policy)
  (2.0 - COALESCE(incremental_lift, 0.0))
  - 1.5 * (COALESCE(incremental_expected_lost_sales, 0.0) / 1000.0)
  - 1.0 * COALESCE(incremental_recall, 0.0)
  + 1.0 * COALESCE(incremental_fpr, 0.0) * 100.0
  + CASE 
      WHEN incremental_alerts > 0.10 * n_obs_total THEN 2.0
      WHEN incremental_alerts > 0.05 * n_obs_total THEN 1.0
      ELSE 0.0
    END
  + CASE 
      WHEN incremental_precision < base_rate THEN 5.0
      WHEN incremental_precision < 1.2 * base_rate THEN 2.0
      ELSE 0.0
    END
  + CASE 
      WHEN weekly_alerts_std > 5.0 THEN 1.5
      WHEN weekly_alerts_std > 3.0 THEN 0.5
      ELSE 0.0
    END AS selection_loss,
  
  -- Filters (invalid candidates)
  CASE 
    WHEN incremental_alerts = 0 THEN TRUE
    WHEN incremental_precision < base_rate THEN TRUE
    WHEN incremental_lift <= 1.0 THEN TRUE
    ELSE FALSE
  END AS is_invalid_candidate,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS evaluated_at_utc,
  'DEV_SELECT' AS evaluated_on_split,
  TRUE AS selected_without_locked_test,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version
  
FROM final_evaluation
ORDER BY selection_loss ASC;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 3 Complete: Candidates Evaluated on DEV_SELECT' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Candidate count
SELECT
  'Evaluation summary' AS check_name,
  COUNT(*) AS n_candidates_evaluated,
  COUNTIF(is_invalid_candidate) AS n_invalid,
  COUNTIF(NOT is_invalid_candidate) AS n_valid,
  MIN(selection_loss) AS min_loss,
  MAX(selection_loss) AS max_loss
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`;

-- Top 5 candidates (lowest selection_loss)
SELECT
  'Top 5 candidates (lowest selection_loss)' AS check_name,
  difficult_policy_id,
  ROUND(incremental_precision, 3) AS incr_prec,
  ROUND(incremental_recall, 3) AS incr_rec,
  ROUND(incremental_lift, 2) AS incr_lift,
  incremental_alerts AS incr_alerts,
  ROUND(combined_precision, 3) AS comb_prec,
  ROUND(combined_recall, 3) AS comb_rec,
  ROUND(selection_loss, 2) AS loss,
  is_invalid_candidate AS invalid
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
ORDER BY selection_loss ASC
LIMIT 5;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 4 will select frozen policy (min selection_loss, valid only)' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
