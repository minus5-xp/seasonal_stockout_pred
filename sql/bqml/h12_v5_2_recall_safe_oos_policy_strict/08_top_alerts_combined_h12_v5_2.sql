-- ============================================================================
-- PHASE 8: TOP ALERTS COMBINED (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Extract actionable LOCKED_TEST alert lists from the three-layer combined
--   policy (POLICY_E1 + GATE_C_P3_Q3 + recall-safe v5_2).
--
--   Lists extracted:
--   - Top 100 stable alerts by audit_priority_score
--   - Top 100 combined v5_2 alerts by audit_priority_score
--   - Top 500 combined v5_2 alerts
--   - Top 1000 combined v5_2 alerts
--   - v5_2 recall-safe incremental alerts only
--   - Weekly top-20 by precision (combined alerts, highest p_suspected_oos)
--
-- INPUTS:
--   - combined_oos_alerts_h12_v5_2_strict  (Phase 5, LOCKED_TEST split)
--
-- OUTPUTS:
--   - top_alerts_combined_h12_v5_2_strict
--
-- ANTI-LEAKAGE:
--   - Ranking by p_suspected_oos / audit_priority_score (pre-existing features)
--   - No re-scoring on LOCKED_TEST labels
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_2_strict` AS

WITH

lt_alerts AS (
  SELECT
    sku_id,
    decision_week,
    week_start_date,
    eval_split_v3,
    season_group,
    sku_season_state,
    recall_safe_candidate_type,
    alert_source_v5_2,
    is_stable_core_alert,
    is_difficult_state_alert_v5_1,
    v5_2_recall_safe_alert,
    combined_oos_alert_v5_2,
    p_suspected_oos,
    audit_priority_score,
    expected_lost_sales_if_oos,
    p_oos_h12,
    yhat_p50_v3_2_12w,
    recall_safe_score,
    y_true_12w,
    stockout_event_12w,

    -- Global rank by audit priority
    ROW_NUMBER() OVER (
      ORDER BY audit_priority_score DESC, p_suspected_oos DESC
    ) AS global_rank_combined,

    ROW_NUMBER() OVER (
      PARTITION BY CASE WHEN is_stable_core_alert THEN 'stable' ELSE 'other' END
      ORDER BY audit_priority_score DESC
    ) AS layer_rank,

    -- Weekly rank within combined alerts
    ROW_NUMBER() OVER (
      PARTITION BY decision_week
      ORDER BY p_suspected_oos DESC, audit_priority_score DESC
    ) AS weekly_rank

  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
    AND combined_oos_alert_v5_2 = TRUE
),

with_list_flags AS (
  SELECT
    *,
    (is_stable_core_alert AND layer_rank <= 100)         AS in_top100_stable,
    (global_rank_combined <= 100)                        AS in_top100_combined,
    (global_rank_combined <= 500)                        AS in_top500_combined,
    (global_rank_combined <= 1000)                       AS in_top1000_combined,
    (v5_2_recall_safe_alert = TRUE)                      AS in_v5_2_incremental,
    (weekly_rank <= 20)                                  AS in_weekly_top20
  FROM lt_alerts
)

SELECT
  *,
  CURRENT_TIMESTAMP()                             AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 8: Top combined alerts extraction'       AS phase_description

FROM with_list_flags
ORDER BY global_rank_combined;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 8 Complete: Top Alerts Extracted' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Alert list summary' AS report_section,
  COUNTIF(in_top100_stable) AS top100_stable,
  COUNTIF(in_top100_combined) AS top100_combined,
  COUNTIF(in_top500_combined) AS top500_combined,
  COUNTIF(in_top1000_combined) AS top1000_combined,
  COUNTIF(in_v5_2_incremental) AS v5_2_incremental,
  COUNTIF(in_weekly_top20) AS weekly_top20
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_2_strict`;

SELECT
  'v5_2 incremental precision by candidate type' AS report_section,
  recall_safe_candidate_type,
  COUNT(*) AS n_alerts,
  ROUND(
    SAFE_DIVIDE(
      COUNTIF(stockout_event_12w = 1),
      NULLIF(COUNT(*), 0)
    ), 4) AS precision
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_2_strict`
WHERE in_v5_2_incremental
GROUP BY recall_safe_candidate_type
ORDER BY precision DESC;
