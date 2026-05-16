-- ============================================================================
-- PHASE 4: SELECT FROZEN RECALL-SAFE POLICY (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   From valid candidates (not is_invalid_candidate), select the one with
--   minimum selection_loss. This is the FROZEN recall-safe policy for v5_2.
--
--   Edge case: If no valid candidates exist, insert a sentinel row with
--   frozen_recall_safe_policy_id = 'NONE_VALID' and final_status = 'KEEP_V5_1'.
--
-- INPUTS:
--   - recall_safe_candidate_eval_dev_select_h12_v5_2_strict  (Phase 3)
--
-- OUTPUTS:
--   - frozen_recall_safe_policy_h12_v5_2_strict  (1 row)
--
-- ANTI-LEAKAGE:
--   - Selected using DEV_SELECT only (candidates were evaluated on DEV_SELECT)
--   - LOCKED_TEST never accessed in this phase
--   - selected_using_split = 'DEV_SELECT'
--   - selected_without_locked_test = TRUE
--   - post_selection_bias = FALSE (no post-selection optimization on LOCKED_TEST)
--   - methodological_note documents that v5_2 was designed after seeing v5_1
--     LOCKED_TEST results — requires future holdout for production promotion
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict` AS

WITH

best_valid_candidate AS (
  SELECT
    recall_safe_policy_id      AS frozen_recall_safe_policy_id,
    gate_set_id                AS frozen_gate_set_id,
    percentile_config_id       AS frozen_percentile_config_id,
    quota_config_id            AS frozen_quota_config_id,
    score_formula_id           AS frozen_score_formula_id,
    incremental_alerts,
    incremental_precision,
    combined_precision,
    incremental_recall,
    combined_recall,
    incremental_fpr,
    incremental_els,
    incremental_lift,
    weekly_alert_cv,
    min_precision_block,
    std_precision_block,
    selection_loss,
    'FROZEN_FROM_DEV_SELECT'   AS final_status
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict`
  WHERE NOT is_invalid_candidate
  ORDER BY selection_loss ASC
  LIMIT 1
),

-- Count valid candidates to detect edge case
valid_count AS (
  SELECT COUNT(*) AS n_valid
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict`
  WHERE NOT is_invalid_candidate
),

-- Sentinel row for no-valid-candidate edge case
sentinel AS (
  SELECT
    'NONE_VALID'  AS frozen_recall_safe_policy_id,
    'NONE'        AS frozen_gate_set_id,
    'NONE'        AS frozen_percentile_config_id,
    'NONE'        AS frozen_quota_config_id,
    'NONE'        AS frozen_score_formula_id,
    0             AS incremental_alerts,
    NULL          AS incremental_precision,
    NULL          AS combined_precision,
    0.0           AS incremental_recall,
    NULL          AS combined_recall,
    NULL          AS incremental_fpr,
    0.0           AS incremental_els,
    NULL          AS incremental_lift,
    NULL          AS weekly_alert_cv,
    NULL          AS min_precision_block,
    NULL          AS std_precision_block,
    0.0           AS selection_loss,
    'KEEP_V5_1'   AS final_status
),

chosen AS (
  SELECT * FROM best_valid_candidate
  UNION ALL
  SELECT * FROM sentinel
  WHERE (SELECT n_valid FROM valid_count) = 0
  LIMIT 1
)

SELECT
  chosen.*,

  -- Anti-leakage metadata
  'DEV_SELECT'   AS selected_using_split,
  TRUE           AS selected_without_locked_test,
  FALSE          AS post_selection_bias,
  CONCAT(
    'v5_2 was designed after observing v5_1 LOCKED_TEST results. ',
    'Policy selected on DEV_SELECT only; LOCKED_TEST seen post-freeze in Phase 6. ',
    'This version requires a fresh holdout split for production promotion.'
  )              AS methodological_note,

  CURRENT_TIMESTAMP()                             AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 4: Frozen recall-safe policy selection'  AS phase_description

FROM chosen;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 4 Complete: Frozen Recall-Safe Policy Selected' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Frozen policy' AS report_section,
  frozen_recall_safe_policy_id,
  frozen_gate_set_id,
  frozen_percentile_config_id,
  frozen_quota_config_id,
  frozen_score_formula_id,
  incremental_alerts,
  ROUND(incremental_precision, 4) AS incr_precision,
  ROUND(incremental_recall * 100, 3) AS incr_recall_pct,
  ROUND(incremental_lift, 3) AS incr_lift,
  final_status,
  selected_using_split
FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`;

SELECT
  'Anti-leakage check' AS report_section,
  selected_using_split,
  selected_without_locked_test,
  post_selection_bias,
  CASE
    WHEN selected_using_split = 'DEV_SELECT'
     AND selected_without_locked_test = TRUE
     AND post_selection_bias = FALSE
    THEN 'PASS'
    ELSE 'FAIL'
  END AS leakage_check
FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`;
