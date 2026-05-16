-- ============================================================================
-- PHASE 9: RECALL FRONTIER DIAGNOSTICS (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Read-only analysis of false negatives (FNs) and recall frontier.
--   Diagnoses WHY some true OOS events are still missed, and identifies
--   bottlenecks in the recall-safe candidate funnel.
--
--   Analysis dimensions:
--   1. FN distribution by bucket: missed events categorized by p_suspected_oos,
--      p_true_zero_demand, expected_gap_component
--   2. Candidate funnel analysis (LOCKED_TEST):
--      - passes_gate but not threshold
--      - passes_threshold but not quota
--      - not a recall_safe_candidate (still uncovered)
--   3. Bottleneck identification: which stage blocks the most FNs
--   4. Top unreachable events (highest expected_lost_sales_if_oos but uncovered)
--
--   NOTE: This phase uses LOCKED_TEST for UNDERSTANDING only.
--         Policy selection was already completed in Phase 4. No optimization
--         based on this output is permitted.
--
-- INPUTS:
--   - combined_oos_alerts_h12_v5_2_strict  (Phase 5, all splits)
--   - base_scores_h12_v5_2_strict          (Phase 0)
--   - recall_safe_scored_h12_v5_2_strict   (Phase 1)
--
-- OUTPUTS:
--   - diagnostics_recall_frontier_h12_v5_2_strict
--
-- ANTI-LEAKAGE:
--   - DIAGNOSTIC ONLY: no policy changes derive from this table
--   - LOCKED_TEST accessed post-freeze; final_decision_no_optimization = TRUE
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.diagnostics_recall_frontier_h12_v5_2_strict` AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- Base: LOCKED_TEST events
-- ─────────────────────────────────────────────────────────────────────────────
lt_all AS (
  SELECT
    a.sku_id,
    a.decision_week,
    a.eval_split_v3,
    a.season_group,
    a.sku_season_state,
    a.recall_safe_candidate_type,
    a.is_recall_safe_candidate,
    a.is_stable_core_alert,
    a.is_difficult_state_alert_v5_1,
    a.v5_2_recall_safe_alert,
    a.combined_oos_alert_v5_2,
    a.passes_frozen_gate,
    a.week_score_percentile,
    a.frozen_threshold,
    a.week_rank_all,
    a.frozen_quota,
    a.recall_safe_score,
    b.p_suspected_oos,
    b.p_true_zero_demand,
    b.expected_gap_component,
    b.zero_run_component,
    b.expected_lost_sales_if_oos,
    b.audit_priority_score,
    b.p_oos_h12,
    b.yhat_p50_v3_2_12w,
    b.y_true_12w,
    b.stockout_event_12w
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict` a
  INNER JOIN `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict` b
    ON a.sku_id = b.sku_id
   AND a.decision_week = b.decision_week
  WHERE a.eval_split_v3 = 'LOCKED_TEST'
),

-- ─────────────────────────────────────────────────────────────────────────────
-- FN universe: true OOS events NOT caught by any of the 3 layers
-- ─────────────────────────────────────────────────────────────────────────────
false_negatives AS (
  SELECT
    *,
    -- Funnel stage: why was this event missed?
    CASE
      WHEN is_stable_core_alert OR is_difficult_state_alert_v5_1 OR v5_2_recall_safe_alert
        THEN 'COVERED'  -- already caught (true positive)
      WHEN NOT is_recall_safe_candidate
        THEN 'NOT_CANDIDATE'  -- didn't qualify as recall_safe_candidate in Phase 0
      WHEN NOT COALESCE(passes_frozen_gate, FALSE)
        THEN 'FAILED_GATE'   -- passes candidate but fails frozen gate
      WHEN COALESCE(week_score_percentile, 0) < COALESCE(frozen_threshold, 1)
        THEN 'BELOW_THRESHOLD'  -- passes gate but score below percentile threshold
      WHEN COALESCE(week_rank_all, 9999) > COALESCE(frozen_quota, 0)
        THEN 'QUOTA_EXCEEDED'  -- passes threshold but quota was full
      ELSE 'OTHER_UNCOVERED'
    END AS funnel_stage,

    -- ELS bucket
    CASE
      WHEN expected_lost_sales_if_oos >= 10.0 THEN 'ELS>=10'
      WHEN expected_lost_sales_if_oos >= 5.0  THEN 'ELS_5_10'
      WHEN expected_lost_sales_if_oos >= 1.0  THEN 'ELS_1_5'
      WHEN expected_lost_sales_if_oos >= 0.1  THEN 'ELS_0.1_1'
      ELSE 'ELS<0.1'
    END AS els_bucket,

    -- p_suspected_oos bucket
    CASE
      WHEN p_suspected_oos >= 0.50 THEN 'p_susp>=0.50'
      WHEN p_suspected_oos >= 0.20 THEN 'p_susp_0.20_0.50'
      WHEN p_suspected_oos >= 0.05 THEN 'p_susp_0.05_0.20'
      ELSE 'p_susp<0.05'
    END AS p_susp_bucket,

    -- p_true_zero bucket
    CASE
      WHEN p_true_zero_demand >= 0.90 THEN 'p_zero>=0.90'
      WHEN p_true_zero_demand >= 0.75 THEN 'p_zero_0.75_0.90'
      WHEN p_true_zero_demand >= 0.50 THEN 'p_zero_0.50_0.75'
      ELSE 'p_zero<0.50'
    END AS p_zero_bucket

  FROM lt_all
  WHERE stockout_event_12w = 1  -- true events only
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Summary 1: FN distribution by funnel stage
-- ─────────────────────────────────────────────────────────────────────────────
fn_funnel_summary AS (
  SELECT
    'FN_FUNNEL_STAGE'  AS diagnostic_type,
    funnel_stage       AS category,
    COUNT(*)           AS n_events,
    SUM(expected_lost_sales_if_oos) AS total_els,
    AVG(p_suspected_oos) AS avg_p_susp
  FROM false_negatives
  GROUP BY funnel_stage
),

-- Summary 2: FN distribution by ELS bucket
fn_els_summary AS (
  SELECT
    'FN_ELS_BUCKET'    AS diagnostic_type,
    els_bucket         AS category,
    COUNT(*)           AS n_events,
    SUM(expected_lost_sales_if_oos) AS total_els,
    AVG(p_suspected_oos) AS avg_p_susp
  FROM false_negatives
  WHERE funnel_stage != 'COVERED'
  GROUP BY els_bucket
),

-- Summary 3: FN distribution by p_suspected_oos bucket
fn_psusp_summary AS (
  SELECT
    'FN_P_SUSP_BUCKET' AS diagnostic_type,
    p_susp_bucket      AS category,
    COUNT(*)           AS n_events,
    SUM(expected_lost_sales_if_oos) AS total_els,
    AVG(p_true_zero_demand) AS avg_p_zero
  FROM false_negatives
  WHERE funnel_stage != 'COVERED'
  GROUP BY p_susp_bucket
),

-- Summary 4: FN distribution by candidate type (for uncovered FNs only)
fn_candidate_type_summary AS (
  SELECT
    'FN_CANDIDATE_TYPE' AS diagnostic_type,
    COALESCE(recall_safe_candidate_type, 'NOT_CANDIDATE') AS category,
    COUNT(*)            AS n_events,
    SUM(expected_lost_sales_if_oos) AS total_els,
    AVG(p_suspected_oos) AS avg_p_susp
  FROM false_negatives
  WHERE funnel_stage != 'COVERED'
  GROUP BY recall_safe_candidate_type
),

-- Summary 5: Top 20 unreachable FNs by ELS (highest economic cost still missed)
top_unreachable AS (
  SELECT
    'TOP_UNREACHABLE_FN'  AS diagnostic_type,
    CONCAT(sku_id, '@W', CAST(EXTRACT(ISOWEEK FROM decision_week) AS STRING)) AS category,
    1                     AS n_events,
    expected_lost_sales_if_oos AS total_els,
    p_suspected_oos       AS avg_p_susp
  FROM false_negatives
  WHERE funnel_stage NOT IN ('COVERED')
  ORDER BY expected_lost_sales_if_oos DESC
  LIMIT 20
),

-- Overall recall frontier summary
frontier_overall AS (
  SELECT
    'RECALL_FRONTIER_OVERALL' AS diagnostic_type,
    CONCAT(
      'covered=', CAST(COUNTIF(funnel_stage = 'COVERED') AS STRING),
      ' not_cand=', CAST(COUNTIF(funnel_stage = 'NOT_CANDIDATE') AS STRING),
      ' failed_gate=', CAST(COUNTIF(funnel_stage = 'FAILED_GATE') AS STRING),
      ' below_threshold=', CAST(COUNTIF(funnel_stage = 'BELOW_THRESHOLD') AS STRING),
      ' quota_exceeded=', CAST(COUNTIF(funnel_stage = 'QUOTA_EXCEEDED') AS STRING),
      ' other=', CAST(COUNTIF(funnel_stage = 'OTHER_UNCOVERED') AS STRING)
    ) AS category,
    COUNT(*) AS n_events,
    SUM(expected_lost_sales_if_oos) AS total_els,
    AVG(p_suspected_oos) AS avg_p_susp
  FROM false_negatives
)

-- Combine all diagnostics
SELECT
  *,
  CURRENT_TIMESTAMP()                              AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'         AS model_version,
  'Phase 9: Recall frontier diagnostics (post-freeze read-only)' AS phase_description
FROM (
  SELECT * FROM fn_funnel_summary
  UNION ALL
  SELECT * FROM fn_els_summary
  UNION ALL
  SELECT * FROM fn_psusp_summary
  UNION ALL
  SELECT * FROM fn_candidate_type_summary
  UNION ALL
  SELECT * FROM top_unreachable
  UNION ALL
  SELECT * FROM frontier_overall
)
ORDER BY diagnostic_type, total_els DESC;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 9 Complete: Recall Frontier Diagnostics Generated' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Funnel stage breakdown' AS report_section,
  diagnostic_type,
  category,
  n_events,
  ROUND(total_els, 1) AS total_els
FROM `thequantitativeledger.cruzber_models_eu.diagnostics_recall_frontier_h12_v5_2_strict`
WHERE diagnostic_type IN ('FN_FUNNEL_STAGE', 'RECALL_FRONTIER_OVERALL')
ORDER BY diagnostic_type, n_events DESC;
