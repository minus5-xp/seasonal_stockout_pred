-- ============================================================================
-- PHASE 1: BUILD RECALL-SAFE SCORES (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   For each is_recall_safe_candidate row:
--   1. Compute adaptive scoring_segment (season_group::candidate_type if ≥500 rows,
--      else fall back to season_group alone)
--   2. Compute boolean gate flags for the 3 gate sets
--   3. Compute 6 PERCENT_RANK features within eval_split_v3 × scoring_segment
--   4. Compute 3 composite score formulas (F1_BALANCED, F2_RECALL_SAFE, F3_ECONOMIC_RISK)
--
-- INPUTS:
--   - base_scores_h12_v5_2_strict  (Phase 0)
--
-- OUTPUTS:
--   - recall_safe_scored_h12_v5_2_strict  (rows with is_recall_safe_candidate = TRUE)
--
-- ANTI-LEAKAGE:
--   - PERCENT_RANK is partitioned by eval_split_v3; no cross-split contamination
--   - Scores use ONLY pre-existing features; y_true and stockout excluded
--   - Gates and score formulas are fixed; no LOCKED_TEST influence
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.recall_safe_scored_h12_v5_2_strict` AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- Step 1: Filter to recall-safe candidates only
-- ─────────────────────────────────────────────────────────────────────────────
recall_safe_candidates AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`
  WHERE is_recall_safe_candidate = TRUE
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Step 2: Compute adaptive scoring segment
--   Raw segment: season_group::recall_safe_candidate_type
--   If segment has ≥500 rows in the same eval_split_v3, use fine segment
--   Otherwise, fall back to season_group alone
-- ─────────────────────────────────────────────────────────────────────────────
with_segment_size AS (
  SELECT
    *,
    CONCAT(season_group, '::', recall_safe_candidate_type) AS candidate_segment_raw,
    COUNT(*) OVER (
      PARTITION BY eval_split_v3, season_group, recall_safe_candidate_type
    ) AS n_candidate_segment
  FROM recall_safe_candidates
),

with_scoring_segment AS (
  SELECT
    *,
    CASE
      WHEN n_candidate_segment >= 500
      THEN candidate_segment_raw
      ELSE season_group
    END AS scoring_segment
  FROM with_segment_size
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Step 3: Gate flags (boolean columns, one per gate set)
--   Gates are evaluated here; actual filtering happens in Phase 3 per candidate
-- ─────────────────────────────────────────────────────────────────────────────
with_gate_flags AS (
  SELECT
    *,

    -- GATE_C_BASE: current conservative
    (yhat_p50_v3_2_12w >= 1.0
     AND expected_lost_sales_if_oos >= 0.25
     AND p_suspected_oos >= 0.01
     AND p_oos_h12 >= 0.01
    ) AS passes_gate_c_base,

    -- GATE_D_RECALL_SAFE: relaxed thresholds for recall improvement
    (yhat_p50_v3_2_12w >= 0.5
     AND expected_lost_sales_if_oos >= 0.10
     AND p_suspected_oos >= 0.005
     AND p_oos_h12 >= 0.005
     AND p_true_zero_demand < 0.90
    ) AS passes_gate_d_recall_safe,

    -- GATE_E_ECONOMIC: economic risk focus
    (expected_lost_sales_if_oos >= 1.0
     AND yhat_p50_v3_2_12w >= 1.0
     AND p_true_zero_demand < 0.90
    ) AS passes_gate_e_economic

  FROM with_scoring_segment
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Step 4: Percentile ranks within eval_split_v3 × scoring_segment
-- ─────────────────────────────────────────────────────────────────────────────
with_percentile_ranks AS (
  SELECT
    *,

    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, scoring_segment
      ORDER BY p_suspected_oos
    ) AS pr_p_suspected_oos_segment,

    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, scoring_segment
      ORDER BY audit_priority_score
    ) AS pr_audit_priority_segment,

    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, scoring_segment
      ORDER BY expected_lost_sales_if_oos
    ) AS pr_expected_lost_sales_segment,

    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, scoring_segment
      ORDER BY p_oos_h12
    ) AS pr_p_oos_segment,

    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, scoring_segment
      ORDER BY yhat_p50_v3_2_12w
    ) AS pr_yhat_segment,

    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, scoring_segment
      ORDER BY expected_gap_component
    ) AS pr_expected_gap_segment

  FROM with_gate_flags
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Step 5: Score formulas
--   F1_BALANCED:     current v5_1-like weights
--   F2_RECALL_SAFE:  up-weights p_oos_h12 and expected_gap for recall improvement
--   F3_ECONOMIC_RISK: up-weights expected_lost_sales for economic priority
-- ─────────────────────────────────────────────────────────────────────────────
with_scores AS (
  SELECT
    *,

    LEAST(1.0, GREATEST(0.0,
      0.30 * pr_p_suspected_oos_segment
    + 0.25 * pr_audit_priority_segment
    + 0.20 * pr_expected_lost_sales_segment
    + 0.15 * pr_p_oos_segment
    + 0.10 * pr_yhat_segment
    )) AS score_f1_balanced,

    LEAST(1.0, GREATEST(0.0,
      0.20 * pr_p_suspected_oos_segment
    + 0.15 * pr_audit_priority_segment
    + 0.15 * pr_expected_lost_sales_segment
    + 0.30 * pr_p_oos_segment
    + 0.20 * pr_expected_gap_segment
    )) AS score_f2_recall_safe,

    LEAST(1.0, GREATEST(0.0,
      0.20 * pr_p_suspected_oos_segment
    + 0.20 * pr_audit_priority_segment
    + 0.35 * pr_expected_lost_sales_segment
    + 0.15 * pr_yhat_segment
    + 0.10 * pr_p_oos_segment
    )) AS score_f3_economic_risk

  FROM with_percentile_ranks
)

SELECT
  sku_id,
  decision_week,
  eval_split_v3,
  season_group,
  sku_season_state,
  recall_safe_candidate_type,
  scoring_segment,
  candidate_segment_raw,
  n_candidate_segment,

  -- Gate flags
  passes_gate_c_base,
  passes_gate_d_recall_safe,
  passes_gate_e_economic,

  -- Percentile ranks
  pr_p_suspected_oos_segment,
  pr_audit_priority_segment,
  pr_expected_lost_sales_segment,
  pr_p_oos_segment,
  pr_yhat_segment,
  pr_expected_gap_segment,

  -- Score formulas [0,1]
  score_f1_balanced,
  score_f2_recall_safe,
  score_f3_economic_risk,

  -- Original features (for downstream evaluation)
  p_suspected_oos,
  audit_priority_score,
  expected_lost_sales_if_oos,
  p_oos_h12,
  yhat_p50_v3_2_12w,
  p_true_zero_demand,
  zero_run_component,
  expected_gap_component,

  -- Ground truth (evaluation only, NOT used in scoring)
  y_true_12w,
  stockout_event_12w,

  -- Metadata
  CURRENT_TIMESTAMP()                             AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 1: Recall-safe scores with adaptive segmentation' AS phase_description

FROM with_scores;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 1 Complete: Recall-Safe Scores Built' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Score range validation' AS check_name,
  CASE
    WHEN MIN(score_f1_balanced) >= 0 AND MAX(score_f1_balanced) <= 1
     AND MIN(score_f2_recall_safe) >= 0 AND MAX(score_f2_recall_safe) <= 1
     AND MIN(score_f3_economic_risk) >= 0 AND MAX(score_f3_economic_risk) <= 1
    THEN 'PASS'
    ELSE 'FAIL'
  END AS status,
  MIN(score_f1_balanced) AS f1_min, MAX(score_f1_balanced) AS f1_max,
  MIN(score_f2_recall_safe) AS f2_min, MAX(score_f2_recall_safe) AS f2_max,
  MIN(score_f3_economic_risk) AS f3_min, MAX(score_f3_economic_risk) AS f3_max
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_scored_h12_v5_2_strict`;

SELECT
  'Scoring segment distribution (DEV_SELECT)' AS check_name,
  eval_split_v3,
  scoring_segment,
  COUNT(*) AS n_rows,
  COUNTIF(passes_gate_c_base) AS passes_c,
  COUNTIF(passes_gate_d_recall_safe) AS passes_d,
  COUNTIF(passes_gate_e_economic) AS passes_e
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_scored_h12_v5_2_strict`
WHERE eval_split_v3 = 'DEV_SELECT'
GROUP BY eval_split_v3, scoring_segment
ORDER BY scoring_segment;
