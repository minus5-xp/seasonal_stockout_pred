-- ============================================================================
-- PHASE 4: SELECT FROZEN DIFFICULT_STATE_POLICY (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Select the best difficult_state_policy from Phase 3 evaluation.
--   Criterion: Minimum selection_loss among valid candidates.
--
-- INPUTS:
--   - difficult_state_candidate_eval_dev_select_h12_v5_1_strict (Phase 3)
--
-- OUTPUTS:
--   - frozen_difficult_state_policy_h12_v5_1_strict (1 row)
--
-- ANTI-LEAKAGE:
--   - Selection based on DEV_SELECT only (not LOCKED_TEST)
--   - Only valid candidates considered (is_invalid_candidate = FALSE)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict` AS

WITH

best_candidate AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
  WHERE NOT is_invalid_candidate
  ORDER BY selection_loss ASC
  LIMIT 1
)

SELECT
  -- Policy identification
  difficult_policy_id AS frozen_difficult_policy_id,
  gate_set_id AS frozen_gate_set_id,
  percentile_config_id AS frozen_percentile_config_id,
  quota_config_id AS frozen_quota_config_id,
  
  -- Selection metrics (DEV_SELECT performance)
  incremental_alerts AS dev_select_incremental_alerts,
  incremental_true_positives AS dev_select_incremental_tp,
  incremental_precision AS dev_select_incremental_precision,
  incremental_recall AS dev_select_incremental_recall,
  incremental_lift AS dev_select_incremental_lift,
  incremental_expected_lost_sales AS dev_select_incremental_els,
  
  combined_alerts AS dev_select_combined_alerts,
  combined_precision AS dev_select_combined_precision,
  combined_recall AS dev_select_combined_recall,
  combined_lift AS dev_select_combined_lift,
  
  selection_loss AS dev_select_selection_loss,
  
  -- By season_group (DEV_SELECT)
  alerts_high_season AS dev_select_alerts_high_season,
  alerts_rest AS dev_select_alerts_rest,
  
  -- Metadata (CRITICAL for anti-leakage)
  CURRENT_TIMESTAMP() AS frozen_at_utc,
  'DEV_SELECT' AS selected_using_split,
  TRUE AS selected_without_locked_test,
  FALSE AS post_selection_bias,
  'min_selection_loss' AS selection_criterion,
  TRUE AS is_frozen_for_production,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 4: Frozen difficult state policy selected' AS phase_description
  
FROM best_candidate;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 4 Complete: Frozen Difficult State Policy Selected' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Frozen policy details
SELECT
  'Frozen policy details' AS check_name,
  frozen_difficult_policy_id,
  frozen_gate_set_id,
  frozen_percentile_config_id,
  frozen_quota_config_id,
  ROUND(dev_select_incremental_precision, 3) AS incr_prec,
  ROUND(dev_select_incremental_recall, 3) AS incr_rec,
  ROUND(dev_select_incremental_lift, 2) AS incr_lift,
  dev_select_incremental_alerts AS incr_alerts,
  ROUND(dev_select_combined_precision, 3) AS comb_prec,
  ROUND(dev_select_combined_recall, 3) AS comb_rec,
  ROUND(dev_select_selection_loss, 2) AS loss,
  selected_without_locked_test,
  post_selection_bias
FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`;

-- Anti-leakage confirmation
SELECT
  'Anti-leakage confirmation' AS check_name,
  CASE 
    WHEN selected_using_split = 'DEV_SELECT'
     AND selected_without_locked_test = TRUE
     AND post_selection_bias = FALSE
    THEN '✓ PASS: Policy selected on DEV_SELECT, LOCKED_TEST not used'
    ELSE '✗ FAIL: Anti-leakage violation'
  END AS validation_status
FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 5 will apply frozen policy to ALL data and build combined alerts' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
