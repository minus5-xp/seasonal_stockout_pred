-- ============================================================================
-- PHASE 5: BUILD COMBINED OOS ALERTS (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Apply the frozen recall-safe policy to ALL splits (DEV_TUNE, DEV_SELECT,
--   LOCKED_TEST). Combine with POLICY_E1 (v5) and GATE_C_P3_Q3 (v5_1) to
--   produce a three-layer additive alert flag.
--
--   Combined logic:
--   combined_oos_alert_v5_2 = is_stable_core_alert
--                             OR is_difficult_state_alert_v5_1
--                             OR v5_2_recall_safe_alert
--
--   Strict no-overlap guaranteed by construction:
--   - v5_2 only fires when NOT stable AND NOT v5_1 alert
--   - alert_source_v5_2 reflects the contributing layer
--
-- INPUTS:
--   - frozen_recall_safe_policy_h12_v5_2_strict      (Phase 4, 1 row)
--   - recall_safe_policy_candidates_h12_v5_2_strict  (Phase 2, for params)
--   - recall_safe_scored_h12_v5_2_strict             (Phase 1, scores, all splits)
--   - base_scores_h12_v5_2_strict                    (Phase 0, all splits, flags)
--
-- OUTPUTS:
--   - combined_oos_alerts_h12_v5_2_strict  (119,857 rows, all splits)
--
-- ANTI-LEAKAGE:
--   - Policy was frozen using DEV_SELECT only (Phase 4)
--   - LOCKED_TEST rows are labelled here using the frozen policy (no new info)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict` AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- Frozen policy parameters
-- ─────────────────────────────────────────────────────────────────────────────
frozen_policy AS (
  SELECT
    frozen_recall_safe_policy_id,
    frozen_gate_set_id,
    frozen_score_formula_id,
    frozen_percentile_config_id,
    frozen_quota_config_id
  FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
  LIMIT 1
),

policy_params AS (
  SELECT
    cand.gate_set_id,
    cand.gate_column_name,
    cand.pct_high_season,
    cand.pct_rest,
    cand.quota_high_season,
    cand.quota_rest,
    cand.score_column_name
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict` cand
  INNER JOIN frozen_policy fp
    ON cand.recall_safe_policy_id = fp.frozen_recall_safe_policy_id

  UNION ALL

  -- Fallback: sentinel NONE_VALID → v5_2 fires 0 alerts (keep v5_1 only).
  -- quota=0 and threshold=1.0 guarantee passes_frozen_gate=FALSE / v5_2_recall_safe_alert=FALSE.
  SELECT
    'NONE'  AS gate_set_id,
    'NONE'  AS gate_column_name,
    1.0     AS pct_high_season,
    1.0     AS pct_rest,
    0       AS quota_high_season,
    0       AS quota_rest,
    'NONE'  AS score_column_name
  FROM frozen_policy
  WHERE frozen_recall_safe_policy_id = 'NONE_VALID'
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Join all data with scored candidates
-- ─────────────────────────────────────────────────────────────────────────────
all_data AS (
  SELECT
    b.sku_id,
    b.decision_week,
    b.week_start_date,
    b.eval_split_v3,
    b.season_group,
    b.sku_season_state,
    b.recall_safe_candidate_type,
    b.is_recall_safe_candidate,

    -- Actuals
    b.y_true_12w,
    b.stockout_event_12w,

    -- Scores
    b.yhat_p50_v3_2_12w,
    b.p_suspected_oos,
    b.expected_lost_sales_if_oos,
    b.audit_priority_score,
    b.p_oos_h12,

    -- Layer flags
    b.is_stable_core_alert,
    b.is_difficult_state_alert_v5_1,
    b.combined_oos_alert_v5_1,
    b.alert_source_v5_1,

    -- v5_2 scores (NULL if not a recall_safe_candidate)
    s.passes_gate_c_base,
    s.passes_gate_d_recall_safe,
    s.passes_gate_e_economic,
    s.score_f1_balanced,
    s.score_f2_recall_safe,
    s.score_f3_economic_risk,
    s.scoring_segment

  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict` b
  LEFT JOIN `thequantitativeledger.cruzber_models_eu.recall_safe_scored_h12_v5_2_strict` s
    ON b.sku_id = s.sku_id
   AND b.decision_week = s.decision_week
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Apply frozen policy gate and score
-- ─────────────────────────────────────────────────────────────────────────────
with_gate_and_score AS (
  SELECT
    a.*,
    p.gate_column_name,
    p.score_column_name,
    p.pct_high_season,
    p.pct_rest,
    p.quota_high_season,
    p.quota_rest,

    -- Resolve active gate
    CASE p.gate_column_name
      WHEN 'passes_gate_c_base'        THEN a.passes_gate_c_base
      WHEN 'passes_gate_d_recall_safe' THEN a.passes_gate_d_recall_safe
      WHEN 'passes_gate_e_economic'    THEN a.passes_gate_e_economic
      ELSE FALSE
    END AS passes_frozen_gate,

    -- Resolve active score
    CASE p.score_column_name
      WHEN 'score_f1_balanced'      THEN a.score_f1_balanced
      WHEN 'score_f2_recall_safe'   THEN a.score_f2_recall_safe
      WHEN 'score_f3_economic_risk' THEN a.score_f3_economic_risk
      ELSE 0.0
    END AS recall_safe_score,

    -- Active threshold
    CASE
      WHEN a.season_group = 'HIGH_SEASON' THEN p.pct_high_season
      ELSE p.pct_rest
    END AS frozen_threshold,

    -- Active quota
    CASE
      WHEN a.season_group = 'HIGH_SEASON' THEN p.quota_high_season
      ELSE p.quota_rest
    END AS frozen_quota

  FROM all_data a
  CROSS JOIN policy_params p
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Apply weekly quota ranking
-- ─────────────────────────────────────────────────────────────────────────────
with_week_rank AS (
  SELECT
    *,
    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, decision_week, season_group
      ORDER BY recall_safe_score
    ) AS week_score_percentile,

    ROW_NUMBER() OVER (
      PARTITION BY eval_split_v3, decision_week, season_group
      ORDER BY recall_safe_score DESC
    ) AS week_rank_all

  FROM with_gate_and_score
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Compute final flags with strict no-overlap
-- ─────────────────────────────────────────────────────────────────────────────
with_v5_2_flag AS (
  SELECT
    *,

    -- v5_2 fires ONLY when not already covered by v5 or v5_1
    (COALESCE(is_stable_core_alert, FALSE) = FALSE
     AND COALESCE(is_difficult_state_alert_v5_1, FALSE) = FALSE
     AND is_recall_safe_candidate = TRUE
     AND passes_frozen_gate = TRUE
     AND week_score_percentile >= frozen_threshold
     AND week_rank_all <= frozen_quota
    ) AS v5_2_recall_safe_alert

  FROM with_week_rank
)

SELECT
  sku_id,
  decision_week,
  week_start_date,
  eval_split_v3,
  season_group,
  sku_season_state,
  recall_safe_candidate_type,
  is_recall_safe_candidate,

  -- Actuals
  y_true_12w,
  stockout_event_12w,

  -- Scores
  yhat_p50_v3_2_12w,
  p_suspected_oos,
  expected_lost_sales_if_oos,
  audit_priority_score,
  p_oos_h12,
  recall_safe_score,
  week_score_percentile,
  passes_frozen_gate,
  frozen_threshold,
  week_rank_all,
  frozen_quota,

  -- Layer flags
  is_stable_core_alert,
  is_difficult_state_alert_v5_1,
  combined_oos_alert_v5_1,
  v5_2_recall_safe_alert,

  -- Combined flag (three-layer union)
  (COALESCE(is_stable_core_alert, FALSE)
   OR COALESCE(is_difficult_state_alert_v5_1, FALSE)
   OR v5_2_recall_safe_alert
  ) AS combined_oos_alert_v5_2,

  -- Alert source (first matching layer)
  CASE
    WHEN COALESCE(is_stable_core_alert, FALSE)           THEN 'STABLE_CORE_POLICY_E1'
    WHEN COALESCE(is_difficult_state_alert_v5_1, FALSE)  THEN 'DIFFICULT_POLICY_V5_1'
    WHEN v5_2_recall_safe_alert                          THEN 'RECALL_SAFE_POLICY_V5_2'
    ELSE 'NONE'
  END AS alert_source_v5_2,

  -- Frozen policy ID for traceability
  (SELECT frozen_recall_safe_policy_id
   FROM `thequantitativeledger.cruzber_models_eu.frozen_recall_safe_policy_h12_v5_2_strict`
   LIMIT 1) AS applied_policy_v5_2,

  CURRENT_TIMESTAMP()                             AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 5: Combined OOS alerts (three-layer)'    AS phase_description

FROM with_v5_2_flag;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 5 Complete: Combined OOS Alerts Built' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Alerts by split and source' AS report_section,
  eval_split_v3,
  alert_source_v5_2,
  COUNT(*) AS n_rows,
  COUNTIF(combined_oos_alert_v5_2) AS n_alerts
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`
GROUP BY eval_split_v3, alert_source_v5_2
ORDER BY eval_split_v3, alert_source_v5_2;

SELECT
  'No-overlap check (critical)' AS report_section,
  COUNTIF(
    CAST(COALESCE(is_stable_core_alert, FALSE) AS INT64)
    + CAST(COALESCE(is_difficult_state_alert_v5_1, FALSE) AS INT64)
    + CAST(v5_2_recall_safe_alert AS INT64) > 1
  ) AS n_overlapping_alerts,
  CASE
    WHEN COUNTIF(
      CAST(COALESCE(is_stable_core_alert, FALSE) AS INT64)
      + CAST(COALESCE(is_difficult_state_alert_v5_1, FALSE) AS INT64)
      + CAST(v5_2_recall_safe_alert AS INT64) > 1
    ) = 0 THEN 'PASS'
    ELSE 'FAIL'
  END AS overlap_check
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_2_strict`;
