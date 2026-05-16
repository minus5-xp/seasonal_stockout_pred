-- ============================================================================
-- PHASE 1: BUILD DIFFICULT_STATE_SCORE (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Compute intra-state percentile ranks for difficult state candidates
--   and create composite difficult_state_score for ranking.
--
--   Key innovation: Percentiles computed WITHIN each state + split,
--   not globally. This allows us to identify anomalous zeros within
--   states where zeros are structurally normal (e.g., OFF_SEASON 87% zeros).
--
-- INPUTS:
--   - base_scores_h12_v5_1_strict (Phase 0 output)
--
-- OUTPUTS:
--   - difficult_state_scored_h12_v5_1_strict (filtered candidates with scores)
--
-- ANTI-LEAKAGE:
--   - Percentiles computed separately per eval_split_v3 (no cross-contamination)
--   - Only difficult_state_candidates processed (is_stable_core_alert = FALSE)
--   - Gates applied BEFORE percentile ranking (no y_true/stockout used)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict` AS

WITH

base_candidates AS (
  SELECT
    -- Identifiers
    sku_id,
    decision_week,
    week_start_date,
    eval_split_v3,
    season_group,
    sku_season_state,
    
    -- Actuals (evaluation only)
    y_sales,
    y_true_12w,
    stockout_event_12w,
    
    -- v3_2 forecast
    yhat_p50_v3_2_12w,
    
    -- v5 scores (frozen)
    p_suspected_oos,
    p_oos_h12,
    expected_lost_sales_if_oos,
    audit_priority_score,
    
    -- v5 flags
    is_stable_core_alert,
    is_difficult_state_candidate
    
  FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
  WHERE is_difficult_state_candidate = TRUE  -- Only difficult states, not already flagged
),

-- Apply gates BEFORE percentile ranking (reduce noise)
-- Define 3 gate sets with state-specific thresholds
gates_applied AS (
  SELECT
    *,
    
    -- GATE_SET_A: Conservative (strictest)
    CASE 
      WHEN yhat_p50_v3_2_12w >= 5.0
       AND expected_lost_sales_if_oos >= 1.0
       AND p_suspected_oos >= 0.05
       AND p_oos_h12 >= 0.05
      THEN TRUE
      ELSE FALSE
    END AS passes_gate_a,
    
    -- GATE_SET_B: Moderate
    CASE 
      WHEN yhat_p50_v3_2_12w >= 3.0
       AND expected_lost_sales_if_oos >= 0.5
       AND p_suspected_oos >= 0.03
       AND p_oos_h12 >= 0.03
      THEN TRUE
      ELSE FALSE
    END AS passes_gate_b,
    
    -- GATE_SET_C: Exploratory (most permissive)
    CASE 
      WHEN yhat_p50_v3_2_12w >= 1.0
       AND expected_lost_sales_if_oos >= 0.25
       AND p_suspected_oos >= 0.01
       AND p_oos_h12 >= 0.01
      THEN TRUE
      ELSE FALSE
    END AS passes_gate_c
    
  FROM base_candidates
),

-- Compute intra-state percentile ranks
-- CRITICAL: PARTITION BY eval_split_v3, season_group
-- This ensures percentiles are computed WITHIN each season group and split
percentile_ranks AS (
  SELECT
    *,
    
    -- Percentile rank of p_suspected_oos within season_group + split
    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, season_group
      ORDER BY p_suspected_oos
    ) AS pr_p_suspected_oos_state,
    
    -- Percentile rank of audit_priority_score within season_group + split
    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, season_group
      ORDER BY audit_priority_score
    ) AS pr_audit_priority_state,
    
    -- Percentile rank of expected_lost_sales_if_oos within season_group + split
    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, season_group
      ORDER BY expected_lost_sales_if_oos
    ) AS pr_expected_lost_sales_state,
    
    -- Percentile rank of p_oos_h12 within season_group + split
    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, season_group
      ORDER BY p_oos_h12
    ) AS pr_p_oos_state,
    
    -- Percentile rank of yhat_p50_v3_2_12w within season_group + split
    PERCENT_RANK() OVER (
      PARTITION BY eval_split_v3, season_group
      ORDER BY yhat_p50_v3_2_12w
    ) AS pr_yhat_p50_state
    
  FROM gates_applied
),

-- Composite difficult_state_score (weighted average of percentile ranks)
composite_score AS (
  SELECT
    *,
    
    -- Composite score formula (all components [0,1], result [0,1])
    0.30 * pr_p_suspected_oos_state
  + 0.25 * pr_audit_priority_state
  + 0.20 * pr_expected_lost_sales_state
  + 0.15 * pr_p_oos_state
  + 0.10 * pr_yhat_p50_state AS difficult_state_score
    
  FROM percentile_ranks
)

SELECT
  -- Identifiers
  sku_id,
  decision_week,
  week_start_date,
  eval_split_v3,
  season_group,
  sku_season_state,
  
  -- Actuals (evaluation only)
  y_sales,
  y_true_12w,
  stockout_event_12w,
  
  -- Base scores
  yhat_p50_v3_2_12w,
  p_suspected_oos,
  p_oos_h12,
  expected_lost_sales_if_oos,
  audit_priority_score,
  
  -- Gates
  passes_gate_a,
  passes_gate_b,
  passes_gate_c,
  
  -- Percentile ranks (intra-state)
  pr_p_suspected_oos_state,
  pr_audit_priority_state,
  pr_expected_lost_sales_state,
  pr_p_oos_state,
  pr_yhat_p50_state,
  
  -- Composite score (PRIMARY RANKING METRIC for difficult states)
  difficult_state_score,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at_utc,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 1: Difficult state scores with intra-state percentile ranking' AS phase_description
  
FROM composite_score;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 1 Complete: Difficult State Scores Computed' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Row count and score distribution
SELECT
  'Row count and score bounds' AS check_name,
  COUNT(*) AS n_candidates,
  ROUND(MIN(difficult_state_score), 4) AS min_score,
  ROUND(MAX(difficult_state_score), 4) AS max_score,
  ROUND(AVG(difficult_state_score), 4) AS avg_score,
  CASE 
    WHEN MIN(difficult_state_score) >= 0.0 AND MAX(difficult_state_score) <= 1.0
    THEN '✓ PASS: Scores bounded [0,1]'
    ELSE '✗ FAIL: Scores out of bounds'
  END AS validation_status
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict`;

-- Gate passage rates by state
SELECT
  'Gate passage rates' AS check_name,
  season_group,
  COUNT(*) AS n_total,
  COUNTIF(passes_gate_a) AS n_pass_gate_a,
  COUNTIF(passes_gate_b) AS n_pass_gate_b,
  COUNTIF(passes_gate_c) AS n_pass_gate_c,
  ROUND(100.0 * COUNTIF(passes_gate_a) / COUNT(*), 1) AS pct_pass_a,
  ROUND(100.0 * COUNTIF(passes_gate_b) / COUNT(*), 1) AS pct_pass_b,
  ROUND(100.0 * COUNTIF(passes_gate_c) / COUNT(*), 1) AS pct_pass_c
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict`
GROUP BY season_group
ORDER BY COUNT(*) DESC;

-- Percentile rank distribution (should be uniform [0,1] within each season_group)
SELECT
  'Percentile rank distribution by season_group' AS check_name,
  season_group,
  eval_split_v3,
  COUNT(*) AS n_obs,
  ROUND(AVG(pr_p_suspected_oos_state), 3) AS avg_pr_p_suspected,
  ROUND(AVG(pr_audit_priority_state), 3) AS avg_pr_audit,
  ROUND(AVG(pr_expected_lost_sales_state), 3) AS avg_pr_els,
  ROUND(AVG(difficult_state_score), 3) AS avg_composite_score
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict`
GROUP BY season_group, eval_split_v3
ORDER BY season_group, eval_split_v3;

-- Top 10 difficult state candidates (highest composite score)
SELECT
  'Top 10 difficult state candidates (DEV_SELECT preview)' AS check_name,
  sku_id,
  decision_week,
  season_group,
  sku_season_state,
  ROUND(difficult_state_score, 4) AS score,
  ROUND(p_suspected_oos, 4) AS p_susp,
  ROUND(expected_lost_sales_if_oos, 2) AS els,
  y_sales,
  y_true_12w
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict`
WHERE eval_split_v3 = 'DEV_SELECT'
ORDER BY difficult_state_score DESC
LIMIT 10;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 2 will generate difficult_policy_candidates grid' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
