-- ============================================================================
-- PHASE 4: SELECT AND FREEZE BEST OVERLAY POLICY (h12_v4_2)
-- ============================================================================
-- PURPOSE:
--   Select the overlay candidate with lowest composite loss on DEV_SELECT.
--   Freeze the configuration to prevent post-selection optimization.
--
-- INPUTS:
--   - overlay_candidate_scores_dev_select_h12_v4_2_strict
--
-- OUTPUTS:
--   - frozen_overlay_policy_h12_v4_2_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict` AS
SELECT
  *,
  'DEV_SELECT' AS selected_using_split,
  TRUE AS selected_without_locked_test,
  FALSE AS post_selection_bias,
  CURRENT_TIMESTAMP() AS frozen_at
FROM `thequantitativeledger.cruzber_models_eu.overlay_candidate_scores_dev_select_h12_v4_2_strict`
WHERE composite_loss = (
  SELECT MIN(composite_loss)
  FROM `thequantitativeledger.cruzber_models_eu.overlay_candidate_scores_dev_select_h12_v4_2_strict`
  WHERE monotonicity_violation_rate = 0  -- Hard constraint
)
LIMIT 1;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 4 Complete: Overlay Policy Frozen' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Show frozen policy
SELECT
  candidate_id,
  method,
  cap_strategy,
  min_n_segment,
  ROUND(composite_loss, 4) AS loss,
  ROUND(wmape_ypos, 4) AS wmape,
  ROUND(viol_p80, 3) AS p80,
  ROUND(viol_p90, 3) AS p90,
  ROUND(viol_p95, 3) AS p95,
  ROUND(avg_spread_p50_p90, 2) AS spread90,
  ROUND(monotonicity_violation_rate, 4) AS mono_viol,
  selected_using_split,
  selected_without_locked_test
FROM `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'CRITICAL: p50 is frozen from v3_2. Only quantile spreads are configured.' AS note;
SELECT 'Next: Phase 5 will build final forecast table with frozen policy' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
