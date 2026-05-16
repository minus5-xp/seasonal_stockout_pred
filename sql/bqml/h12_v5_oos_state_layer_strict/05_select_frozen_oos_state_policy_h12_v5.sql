-- ============================================================================
-- PHASE 5: SELECT FROZEN OOS STATE POLICY (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Select the best performing policy candidate based on minimum selection_loss.
--   Freeze this policy as the production OOS detection system.
--
-- INPUTS:
--   - oos_candidate_evaluation_dev_select_h12_v5_strict
--
-- OUTPUTS:
--   - oos_frozen_policy_h12_v5_strict (1 row)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_frozen_policy_h12_v5_strict` AS
WITH

best_candidate AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.oos_candidate_evaluation_dev_select_h12_v5_strict`
  WHERE NOT exceeds_top_n_constraint
  ORDER BY selection_loss ASC
  LIMIT 1
)

SELECT
  candidate_id AS frozen_candidate_id,
  policy_id AS frozen_policy_id,
  family AS frozen_policy_family,
  precision AS frozen_precision_dev_select,
  recall AS frozen_recall_dev_select,
  f1_score AS frozen_f1_score_dev_select,
  lift AS frozen_lift_dev_select,
  n_flagged_oos AS frozen_n_flagged_oos_dev_select,
  n_true_oos_events AS frozen_n_true_oos_dev_select,
  selection_loss AS frozen_selection_loss,
  total_expected_lost_sales_captured AS frozen_expected_lost_sales_captured,
  precision_high_season AS frozen_precision_high_season,
  recall_high_season AS frozen_recall_high_season,
  lift_high_season AS frozen_lift_high_season,
  precision_off_season AS frozen_precision_off_season,
  recall_off_season AS frozen_recall_off_season,
  lift_off_season AS frozen_lift_off_season,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS frozen_at_utc,
  'DEV_SELECT_holdout_selection' AS selection_method,
  'min_selection_loss' AS selection_criterion,
  TRUE AS is_frozen_for_production,
  'h12_v5_oos_state_layer_strict' AS model_version
  
FROM best_candidate;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 5 Complete: Frozen OOS State Policy Selected' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Show frozen policy details
SELECT
  'Frozen Policy Details' AS check_name,
  frozen_policy_id,
  frozen_policy_family,
  ROUND(frozen_precision_dev_select, 3) AS precision,
  ROUND(frozen_recall_dev_select, 3) AS recall,
  ROUND(frozen_f1_score_dev_select, 3) AS f1_score,
  ROUND(frozen_lift_dev_select, 2) AS lift,
  frozen_n_flagged_oos_dev_select AS n_flagged,
  frozen_n_true_oos_dev_select AS n_true_oos,
  ROUND(frozen_selection_loss, 2) AS selection_loss,
  frozen_at_utc,
  is_frozen_for_production AS frozen
FROM `thequantitativeledger.cruzber_models_eu.oos_frozen_policy_h12_v5_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 6 will apply frozen policy to ALL data' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
