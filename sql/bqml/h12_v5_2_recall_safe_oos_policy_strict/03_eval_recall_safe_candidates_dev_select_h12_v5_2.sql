-- ============================================================================
-- PHASE 3: EVALUATE RECALL-SAFE CANDIDATES ON DEV_SELECT (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   For each of 81 policy candidates, evaluate incremental metrics vs the
--   frozen v5_1 combined policy using DEV_SELECT data ONLY.
--
--   Evaluation logic per candidate:
--   1. Apply gate (boolean gate column must be TRUE)
--   2. Select score formula column
--   3. Compute season_group-based percentile threshold
--   4. Apply weekly quota (ROW_NUMBER within candidate × week × season_group)
--   5. Compute precision, recall, FPR, ELS vs stable + v5_1 baselines
--   6. Block stability: split weeks NTILE(2); compute min/std precision per block
--   7. Weekly alert volume CV
--   8. Apply validity filters and compute selection_loss
--
-- INPUTS:
--   - recall_safe_policy_candidates_h12_v5_2_strict  (Phase 2, 81 rows)
--   - recall_safe_scored_h12_v5_2_strict             (Phase 1, all splits)
--   - combined_oos_alerts_h12_v5_1_strict            (v5_1 frozen, for baselines)
--   - base_scores_h12_v5_2_strict                    (Phase 0, for y_true reference)
--
-- OUTPUTS:
--   - recall_safe_candidate_eval_dev_select_h12_v5_2_strict  (up to 81 rows)
--
-- ANTI-LEAKAGE:
--   - Evaluation restricted to DEV_SELECT (eval_split_v3 = 'DEV_SELECT')
--   - LOCKED_TEST never touched in this phase
--   - y_true_12w / stockout_event_12w used only as ground truth labels for
--     precision/recall computation (not as model features)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict` AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- DEV_SELECT universe for evaluation
-- ─────────────────────────────────────────────────────────────────────────────
dev_select_base AS (
  SELECT
    b.sku_id,
    b.decision_week,
    b.eval_split_v3,
    b.season_group,
    b.y_true_12w,
    b.stockout_event_12w,
    b.is_stable_core_alert,
    b.is_difficult_state_alert_v5_1,
    b.combined_oos_alert_v5_1,
    b.is_recall_safe_candidate,
    b.recall_safe_candidate_type
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict` b
  WHERE b.eval_split_v3 = 'DEV_SELECT'
),

-- Recall-safe scores on DEV_SELECT
dev_select_scored AS (
  SELECT
    s.sku_id,
    s.decision_week,
    s.season_group,
    s.recall_safe_candidate_type,
    s.scoring_segment,
    s.passes_gate_c_base,
    s.passes_gate_d_recall_safe,
    s.passes_gate_e_economic,
    s.score_f1_balanced,
    s.score_f2_recall_safe,
    s.score_f3_economic_risk
  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_scored_h12_v5_2_strict` s
  WHERE s.eval_split_v3 = 'DEV_SELECT'
),

-- Joined DEV_SELECT dataset
dev_select_joined AS (
  SELECT
    b.*,
    s.passes_gate_c_base,
    s.passes_gate_d_recall_safe,
    s.passes_gate_e_economic,
    s.score_f1_balanced,
    s.score_f2_recall_safe,
    s.score_f3_economic_risk,
    s.scoring_segment
  FROM dev_select_base b
  LEFT JOIN dev_select_scored s
    ON b.sku_id = s.sku_id
   AND b.decision_week = s.decision_week
),

-- DEV_SELECT universe stats (for recall denominator and base rate)
dev_select_universe AS (
  SELECT
    COUNT(*) AS n_total,
    COUNTIF(stockout_event_12w = 1) AS n_true_positives_universe,
    COUNTIF(combined_oos_alert_v5_1 = TRUE) AS n_v5_1_alerts,
    SAFE_DIVIDE(
      COUNTIF(stockout_event_12w = 1 AND combined_oos_alert_v5_1 = TRUE),
      NULLIF(COUNTIF(combined_oos_alert_v5_1 = TRUE), 0)
    ) AS base_precision_v5_1,
    SAFE_DIVIDE(
      COUNTIF(stockout_event_12w = 1 AND combined_oos_alert_v5_1 = TRUE),
      NULLIF(COUNTIF(stockout_event_12w = 1), 0)
    ) AS base_recall_v5_1,
    SAFE_DIVIDE(
      COUNTIF(stockout_event_12w = 1),
      COUNT(*)
    ) AS base_rate
  FROM dev_select_joined
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-candidate evaluation using CROSS JOIN + conditional aggregation
-- ─────────────────────────────────────────────────────────────────────────────
candidate_rows AS (
  SELECT
    c.recall_safe_policy_id,
    c.gate_set_id,
    c.gate_column_name,
    c.percentile_config_id,
    c.pct_high_season,
    c.pct_rest,
    c.quota_config_id,
    c.quota_high_season,
    c.quota_rest,
    c.score_formula_id,
    c.score_column_name,

    d.sku_id,
    d.decision_week,
    d.season_group,
    d.y_true_12w,
    d.stockout_event_12w,
    d.is_stable_core_alert,
    d.is_difficult_state_alert_v5_1,
    d.combined_oos_alert_v5_1,
    d.is_recall_safe_candidate,
    d.passes_gate_c_base,
    d.passes_gate_d_recall_safe,
    d.passes_gate_e_economic,
    d.score_f1_balanced,
    d.score_f2_recall_safe,
    d.score_f3_economic_risk,
    d.scoring_segment

  FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict` c
  CROSS JOIN dev_select_joined d
  WHERE d.is_recall_safe_candidate = TRUE
),

-- Resolve which gate column and score column to use per candidate
with_gate_and_score AS (
  SELECT
    *,
    -- Select gate
    CASE gate_column_name
      WHEN 'passes_gate_c_base'        THEN passes_gate_c_base
      WHEN 'passes_gate_d_recall_safe' THEN passes_gate_d_recall_safe
      WHEN 'passes_gate_e_economic'    THEN passes_gate_e_economic
      ELSE FALSE
    END AS passes_active_gate,

    -- Select score
    CASE score_column_name
      WHEN 'score_f1_balanced'     THEN score_f1_balanced
      WHEN 'score_f2_recall_safe'  THEN score_f2_recall_safe
      WHEN 'score_f3_economic_risk' THEN score_f3_economic_risk
      ELSE 0.0
    END AS active_score,

    -- Season group threshold
    CASE
      WHEN season_group = 'HIGH_SEASON' THEN pct_high_season
      ELSE pct_rest
    END AS active_threshold,

    -- Season group quota
    CASE
      WHEN season_group = 'HIGH_SEASON' THEN quota_high_season
      ELSE quota_rest
    END AS active_quota

  FROM candidate_rows
),

-- Compute weekly percentile thresholds and ranking
with_week_rank AS (
  SELECT
    *,
    PERCENT_RANK() OVER (
      PARTITION BY recall_safe_policy_id, decision_week, season_group
      ORDER BY active_score
    ) AS week_score_percentile,

    ROW_NUMBER() OVER (
      PARTITION BY recall_safe_policy_id, decision_week, season_group
      ORDER BY active_score DESC
    ) AS week_rank

  FROM with_gate_and_score
),

-- Determine v5_2 alert for this candidate
with_v5_2_alert AS (
  SELECT
    *,
    (passes_active_gate = TRUE
     AND week_score_percentile >= active_threshold
     AND week_rank <= active_quota
    ) AS v5_2_recall_safe_alert,

    -- Combined with v5_1
    (combined_oos_alert_v5_1 = TRUE
     OR (passes_active_gate = TRUE
         AND week_score_percentile >= active_threshold
         AND week_rank <= active_quota)
    ) AS combined_oos_alert_v5_2

  FROM with_week_rank
),

-- Weekly aggregates for block stability and CV
weekly_agg AS (
  SELECT
    recall_safe_policy_id,
    decision_week,
    COUNTIF(v5_2_recall_safe_alert) AS weekly_incr_alerts,
    COUNTIF(combined_oos_alert_v5_2) AS weekly_combined_alerts,
    SAFE_DIVIDE(
      COUNTIF(combined_oos_alert_v5_2 AND stockout_event_12w = 1),
      NULLIF(COUNTIF(combined_oos_alert_v5_2), 0)
    ) AS weekly_combined_precision,

    -- Block assignment for stability
    NTILE(2) OVER (
      PARTITION BY recall_safe_policy_id
      ORDER BY decision_week
    ) AS temporal_block

  FROM with_v5_2_alert
  GROUP BY recall_safe_policy_id, decision_week
),

-- Per-block precision stats
block_stats AS (
  SELECT
    recall_safe_policy_id,
    MIN(weekly_combined_precision) AS min_precision_block,
    STDDEV(weekly_combined_precision) AS std_precision_block,
    MIN(CASE WHEN temporal_block = 1 THEN weekly_combined_precision END) AS min_precision_block_1,
    MIN(CASE WHEN temporal_block = 2 THEN weekly_combined_precision END) AS min_precision_block_2
  FROM weekly_agg
  GROUP BY recall_safe_policy_id
),

-- Alert volume coefficient of variation
weekly_cv AS (
  SELECT
    recall_safe_policy_id,
    SAFE_DIVIDE(
      STDDEV(weekly_incr_alerts),
      NULLIF(AVG(weekly_incr_alerts), 0)
    ) AS weekly_alert_cv
  FROM weekly_agg
  GROUP BY recall_safe_policy_id
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Final aggregation per candidate
-- ─────────────────────────────────────────────────────────────────────────────
candidate_metrics AS (
  SELECT
    a.recall_safe_policy_id,
    a.gate_set_id,
    a.percentile_config_id,
    a.quota_config_id,
    a.score_formula_id,

    -- Volume
    COUNTIF(a.v5_2_recall_safe_alert) AS incremental_alerts,
    COUNTIF(a.combined_oos_alert_v5_1) AS v5_1_alerts,
    COUNTIF(a.combined_oos_alert_v5_2) AS combined_alerts_v5_2,

    -- Incremental precision / recall / FPR
    SAFE_DIVIDE(
      COUNTIF(a.v5_2_recall_safe_alert AND a.stockout_event_12w = 1),
      NULLIF(COUNTIF(a.v5_2_recall_safe_alert), 0)
    ) AS incremental_precision,

    SAFE_DIVIDE(
      COUNTIF(a.combined_oos_alert_v5_2 AND a.stockout_event_12w = 1),
      NULLIF(COUNTIF(a.combined_oos_alert_v5_2), 0)
    ) AS combined_precision,

    -- Recall (denominator = all positives in universe, not just recall-safe candidates)
    -- NOTE: stockout_event_12w used here as label only (not as feature)
    SAFE_DIVIDE(
      COUNTIF(a.v5_2_recall_safe_alert AND a.stockout_event_12w = 1),
      NULLIF((SELECT n_true_positives_universe FROM dev_select_universe), 0)
    ) AS incremental_recall,

    SAFE_DIVIDE(
      COUNTIF(a.combined_oos_alert_v5_2 AND a.stockout_event_12w = 1),
      NULLIF((SELECT n_true_positives_universe FROM dev_select_universe), 0)
    ) AS combined_recall,

    -- FPR (false positive rate on non-events)
    SAFE_DIVIDE(
      COUNTIF(a.v5_2_recall_safe_alert AND a.stockout_event_12w = 0),
      NULLIF(COUNTIF(a.stockout_event_12w = 0), 0)
    ) AS incremental_fpr,

    -- ELS
    SUM(CASE WHEN a.v5_2_recall_safe_alert AND a.stockout_event_12w = 1
             THEN a.y_true_12w ELSE 0 END) AS incremental_els,

    -- Incremental lift vs v5_1 precision baseline
    SAFE_DIVIDE(
      SAFE_DIVIDE(
        COUNTIF(a.v5_2_recall_safe_alert AND a.stockout_event_12w = 1),
        NULLIF(COUNTIF(a.v5_2_recall_safe_alert), 0)
      ),
      NULLIF((SELECT base_precision_v5_1 FROM dev_select_universe), 0)
    ) AS incremental_lift,

    -- Evaluation metadata
    'DEV_SELECT'    AS evaluated_on_split,
    TRUE            AS selected_without_locked_test,
    FALSE           AS post_selection_bias

  FROM with_v5_2_alert a
  GROUP BY
    a.recall_safe_policy_id, a.gate_set_id, a.percentile_config_id,
    a.quota_config_id, a.score_formula_id
),

-- Join block and CV stats
with_stability AS (
  SELECT
    m.*,
    bs.min_precision_block,
    bs.std_precision_block,
    bs.min_precision_block_1,
    bs.min_precision_block_2,
    wc.weekly_alert_cv
  FROM candidate_metrics m
  LEFT JOIN block_stats bs USING (recall_safe_policy_id)
  LEFT JOIN weekly_cv wc USING (recall_safe_policy_id)
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Validity and selection_loss computation
-- ─────────────────────────────────────────────────────────────────────────────
with_validity AS (
  SELECT
    s.*,
    u.base_rate,
    u.base_precision_v5_1,
    u.base_recall_v5_1,

    -- Precision floor: max of (1.5 × base_rate, 0.55)
    GREATEST(1.5 * u.base_rate, 0.55) AS precision_floor,

    -- Block instability: difference between worst block and overall
    ABS(COALESCE(min_precision_block_1, 0) - COALESCE(min_precision_block_2, 0)) AS block_instability_delta

  FROM with_stability s
  CROSS JOIN dev_select_universe u
),

with_penalties AS (
  SELECT
    *,

    -- Invalid candidate flags
    (incremental_alerts = 0
     OR incremental_precision < precision_floor
     OR combined_precision < precision_floor
     OR incremental_lift < 1.5
     OR incremental_fpr > 0.02
     OR weekly_alert_cv > 1.25
     OR COALESCE(min_precision_block, 0) < GREATEST(1.25 * base_rate, 0.50)
    ) AS is_invalid_candidate,

    -- Precision floor penalty
    CASE
      WHEN incremental_precision < precision_floor THEN 10.0
      WHEN combined_precision < precision_floor    THEN 5.0
      ELSE 0.0
    END AS precision_floor_penalty,

    -- Alert volume penalty
    CASE
      WHEN combined_alerts_v5_2 > 0
       AND SAFE_DIVIDE(combined_alerts_v5_2, (
           SELECT n_total FROM dev_select_universe
         )) > 0.03                               THEN 2.0
      WHEN combined_alerts_v5_2 > 0
       AND SAFE_DIVIDE(combined_alerts_v5_2, (
           SELECT n_total FROM dev_select_universe
         )) > 0.015                              THEN 0.5
      ELSE 0.0
    END AS alert_volume_penalty,

    -- Instability penalty: based on block precision difference
    block_instability_delta AS instability_penalty

  FROM with_validity
),

final AS (
  SELECT
    *,

    -- Selection loss (minimize = best candidate)
    -- Negative terms: recall, lift, ELS (we want MORE of these)
    -- Positive terms: FPR, instability, precision floor, volume (we want LESS)
    (
      -4.0 * COALESCE(incremental_recall, 0)
    - 2.0 * COALESCE(incremental_lift, 0)
    - 1.0 * COALESCE(incremental_els, 0) / 1000.0
    + 2.0 * COALESCE(incremental_fpr, 0)
    + 1.5 * COALESCE(instability_penalty, 0)
    + 2.0 * precision_floor_penalty
    + 1.0 * alert_volume_penalty
    ) AS selection_loss,

    CURRENT_TIMESTAMP()                           AS created_at_utc,
    'h12_v5_2_recall_safe_oos_policy_strict'      AS model_version,
    'Phase 3: Candidate evaluation on DEV_SELECT' AS phase_description

  FROM with_penalties
)

SELECT * FROM final;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 3 Complete: Recall-Safe Candidate Evaluation Done' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Candidate evaluation summary' AS report_section,
  COUNT(*) AS n_evaluated,
  COUNTIF(NOT is_invalid_candidate) AS n_valid_candidates,
  COUNTIF(is_invalid_candidate) AS n_invalid_candidates,
  MIN(CASE WHEN NOT is_invalid_candidate THEN selection_loss END) AS best_selection_loss,
  CASE
    WHEN COUNTIF(NOT is_invalid_candidate) > 0 THEN 'PASS'
    ELSE 'WARNING - No valid candidates found'
  END AS status
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict`;

SELECT
  'Top 5 valid candidates by selection_loss' AS report_section,
  recall_safe_policy_id,
  incremental_alerts,
  incremental_precision,
  combined_precision,
  incremental_recall,
  incremental_fpr,
  incremental_lift,
  selection_loss
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_candidate_eval_dev_select_h12_v5_2_strict`
WHERE NOT is_invalid_candidate
ORDER BY selection_loss ASC
LIMIT 5;
