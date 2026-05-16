-- ============================================================================
-- PHASE 7: INCREMENTAL UPLIFT ANALYSIS & VERDICT (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Produce a 1-row verdict table with final_verdict ∈ {
--     PROMOTE_RECALL_SAFE_CONTROLLED,
--     EXPERIMENTAL_RECALL_SAFE,
--     KEEP_V5_1,
--     REJECT
--   }
--
--   Criteria logic (all evaluated on LOCKED_TEST):
--   - PROMOTE_RECALL_SAFE_CONTROLLED:
--       incr_precision >= precision_floor
--       AND combined_precision >= precision_floor
--       AND incr_lift >= 2.0
--       AND delta_recall_points >= 0.3
--       AND incr_fpr <= 0.01
--   - EXPERIMENTAL_RECALL_SAFE:
--       incr_precision >= 0.50 (relaxed)
--       AND combined_precision >= precision_floor
--       AND incr_lift >= 1.5
--       AND delta_recall_points >= 0.1
--       AND incr_fpr <= 0.02
--   - KEEP_V5_1:
--       frozen_recall_safe_policy_id = 'NONE_VALID'
--       OR incr_alerts = 0
--   - REJECT: anything else (fails quality bar)
--
-- INPUTS:
--   - final_locked_test_metrics_h12_v5_2_strict   (Phase 6)
--   - frozen_recall_safe_policy_h12_v5_2_strict   (Phase 4)
--
-- OUTPUTS:
--   - incremental_uplift_analysis_h12_v5_2_strict  (1 row)
--
-- ANTI-LEAKAGE:
--   - Policy was frozen before this phase
--   - Verdict is diagnostic; no hyperparameter adjustment based on this output
--   - final_decision_no_optimization = TRUE
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_2_strict` AS

WITH

global_metrics AS (
  SELECT
    stable_alerts,
    stable_precision,
    stable_recall,
    stable_els,
    v5_1_alerts,
    v5_1_precision,
    v5_1_recall,
    v5_1_els,
    v5_2_incr_alerts,
    v5_2_incr_precision,
    v5_2_incr_recall,
    v5_2_incr_els,
    combined_alerts,
    combined_precision,
    combined_recall,
    combined_els,
    v5_2_fpr,
    delta_alerts,
    delta_recall_points,
    delta_precision,
    delta_els,
    n_total,
    n_true_events,
    base_rate
  FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_2_strict`
  WHERE segment_type = 'GLOBAL'
),

frozen AS (
  SELECT
    frozen_recall_safe_policy_id,
    final_status AS policy_selection_status,
    incremental_lift
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
),

verdict AS (
  SELECT
    m.*,
    f.frozen_recall_safe_policy_id,
    f.policy_selection_status,
    f.incremental_lift,

    -- Precision floor (same formula as Phase 3)
    GREATEST(1.5 * m.base_rate, 0.55) AS precision_floor,

    -- Criteria columns
    (m.v5_2_incr_precision >= GREATEST(1.5 * m.base_rate, 0.55))  AS meets_incr_precision,
    (m.combined_precision >= GREATEST(1.5 * m.base_rate, 0.55))    AS meets_combined_precision,
    (f.incremental_lift >= 2.0)                                     AS meets_lift_promote,
    (f.incremental_lift >= 1.5)                                     AS meets_lift_experimental,
    (m.delta_recall_points >= 0.3)                                  AS meets_recall_promote,
    (m.delta_recall_points >= 0.1)                                  AS meets_recall_experimental,
    (m.v5_2_fpr <= 0.01)                                            AS meets_fpr_promote,
    (m.v5_2_fpr <= 0.02)                                            AS meets_fpr_experimental,
    (m.v5_2_incr_precision >= 0.50)                                 AS meets_incr_precision_relaxed,

    -- Final verdict
    CASE
      -- Edge case: no valid policy was found
      WHEN f.frozen_recall_safe_policy_id = 'NONE_VALID'
        OR m.v5_2_incr_alerts = 0
      THEN 'KEEP_V5_1'

      -- Promote: strict criteria met
      WHEN m.v5_2_incr_precision >= GREATEST(1.5 * m.base_rate, 0.55)
       AND m.combined_precision >= GREATEST(1.5 * m.base_rate, 0.55)
       AND f.incremental_lift >= 2.0
       AND m.delta_recall_points >= 0.3
       AND m.v5_2_fpr <= 0.01
      THEN 'PROMOTE_RECALL_SAFE_CONTROLLED'

      -- Experimental: relaxed criteria met
      WHEN m.v5_2_incr_precision >= 0.50
       AND m.combined_precision >= GREATEST(1.5 * m.base_rate, 0.55)
       AND f.incremental_lift >= 1.5
       AND m.delta_recall_points >= 0.1
       AND m.v5_2_fpr <= 0.02
      THEN 'EXPERIMENTAL_RECALL_SAFE'

      -- Reject: fails quality bar
      ELSE 'REJECT'
    END AS final_verdict

  FROM global_metrics m
  CROSS JOIN frozen f
)

SELECT
  *,

  -- Methodological caveat (always present)
  CONCAT(
    'IMPORTANT: v5_2 was designed after observing v5_1 LOCKED_TEST results. ',
    'This introduces potential look-ahead bias at the architecture level. ',
    'Verdict provides directional evidence only. ',
    'Production promotion requires a fresh holdout or prospective evaluation. ',
    'LOCKED_TEST results for v5_2 are diagnostic, not confirmatory.'
  ) AS methodological_caveat,

  -- Anti-leakage metadata
  'LOCKED_TEST'   AS analyzed_on_split,
  TRUE            AS final_decision_no_optimization,

  CURRENT_TIMESTAMP()                             AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 7: Incremental uplift analysis and final verdict' AS phase_description

FROM verdict;

-- ──────────────────────────────────────────────────────────────────────────
-- REPORT
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 7 Complete: Verdict Generated' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'FINAL VERDICT' AS report_section,
  final_verdict,
  frozen_recall_safe_policy_id,
  v5_2_incr_alerts,
  ROUND(v5_2_incr_precision, 4) AS incr_precision,
  ROUND(delta_recall_points, 3) AS delta_recall_pp,
  ROUND(v5_2_fpr, 5) AS incr_fpr,
  ROUND(incremental_lift, 3) AS incr_lift,
  meets_incr_precision,
  meets_combined_precision,
  meets_lift_promote,
  meets_recall_promote,
  meets_fpr_promote
FROM `thequantitativeledger.cruzber_models_eu.incremental_uplift_analysis_h12_v5_2_strict`;
