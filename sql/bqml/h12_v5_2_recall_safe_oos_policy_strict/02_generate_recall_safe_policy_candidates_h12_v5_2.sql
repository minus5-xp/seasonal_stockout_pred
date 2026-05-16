-- ============================================================================
-- PHASE 2: GENERATE RECALL-SAFE POLICY CANDIDATES (h12_v5_2)
-- ============================================================================
-- PURPOSE:
--   Generate 81-row candidate grid (3 gates × 3 percentile configs × 3 quotas
--   × 3 score formulas) using CROSS JOIN of parameter sets.
--
--   Grid dimensions:
--   - 3 gate_sets:        GATE_C_BASE, GATE_D_RECALL_SAFE, GATE_E_ECONOMIC
--   - 3 percentile_configs: P3_CURRENT (0.850/0.870), P4_RECALL (0.800/0.830),
--                           P5_EXPANDED (0.750/0.800)
--   - 3 quota_configs:    Q3_CURRENT (20/30), Q4_RECALL (40/60), Q5_EXPANDED (60/90)
--   - 3 score_formulas:   F1_BALANCED, F2_RECALL_SAFE, F3_ECONOMIC_RISK
--   Total: 3×3×3×3 = 81
--
--   Note: Phase 2 does NOT apply any filters. It only defines the parameter
--   space. Actual evaluation happens in Phase 3 (DEV_SELECT only).
--
-- INPUTS:
--   - recall_safe_scored_h12_v5_2_strict  (Phase 1, for candidate metadata)
--
-- OUTPUTS:
--   - recall_safe_policy_candidates_h12_v5_2_strict  (81 rows)
--
-- ANTI-LEAKAGE:
--   - Parameter grid is fully specified without LOCKED_TEST data
--   - selected_without_locked_test = TRUE by design
--   - post_selection_bias = FALSE (no LOCKED_TEST feedback)
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict` AS

WITH

-- ─────────────────────────────────────────────────────────────────────────────
-- Gate set definitions
-- ─────────────────────────────────────────────────────────────────────────────
gate_sets AS (
  SELECT 'GATE_C_BASE' AS gate_set_id,
    1.0 AS min_yhat, 0.25 AS min_els, 0.01 AS min_p_susp, 0.01 AS min_p_oos,
    NULL AS max_true_zero,
    'passes_gate_c_base' AS gate_column_name
  UNION ALL
  SELECT 'GATE_D_RECALL_SAFE',
    0.5,  0.10, 0.005, 0.005, 0.90, 'passes_gate_d_recall_safe'
  UNION ALL
  SELECT 'GATE_E_ECONOMIC',
    1.0,  1.0,  NULL,  NULL,  0.90, 'passes_gate_e_economic'
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Percentile threshold configurations
--   high_season: applied to HIGH_SEASON segment
--   rest:        applied to all other season_group segments
-- ─────────────────────────────────────────────────────────────────────────────
percentile_configs AS (
  SELECT 'P3_CURRENT'  AS percentile_config_id, 0.870 AS pct_high_season, 0.850 AS pct_rest
  UNION ALL
  SELECT 'P4_RECALL',                            0.830,                   0.800
  UNION ALL
  SELECT 'P5_EXPANDED',                          0.800,                   0.750
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Weekly quota configurations
--   high_season: max alerts per week for HIGH_SEASON segments
--   rest:        max alerts per week for all other segments
-- ─────────────────────────────────────────────────────────────────────────────
quota_configs AS (
  SELECT 'Q3_CURRENT'  AS quota_config_id, 30 AS quota_high_season, 20 AS quota_rest
  UNION ALL
  SELECT 'Q4_RECALL',                      60,                      40
  UNION ALL
  SELECT 'Q5_EXPANDED',                    90,                      60
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Score formula definitions
-- ─────────────────────────────────────────────────────────────────────────────
score_formulas AS (
  SELECT 'F1_BALANCED'     AS score_formula_id, 'score_f1_balanced'     AS score_column_name
  UNION ALL
  SELECT 'F2_RECALL_SAFE',                      'score_f2_recall_safe'
  UNION ALL
  SELECT 'F3_ECONOMIC_RISK',                    'score_f3_economic_risk'
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Build 81-row candidate grid via CROSS JOIN
-- ─────────────────────────────────────────────────────────────────────────────
candidate_grid AS (
  SELECT
    CONCAT(g.gate_set_id, '_', p.percentile_config_id, '_',
           q.quota_config_id, '_', f.score_formula_id) AS recall_safe_policy_id,
    g.gate_set_id,
    g.min_yhat,
    g.min_els,
    g.min_p_susp,
    g.min_p_oos,
    g.max_true_zero,
    g.gate_column_name,
    p.percentile_config_id,
    p.pct_high_season,
    p.pct_rest,
    q.quota_config_id,
    q.quota_high_season,
    q.quota_rest,
    f.score_formula_id,
    f.score_column_name,

    -- Anti-leakage metadata
    TRUE                 AS selected_without_locked_test,
    FALSE                AS post_selection_bias,
    'Phase 2: Candidate grid generation (no LOCKED_TEST data)' AS phase_note
  FROM gate_sets g
  CROSS JOIN percentile_configs p
  CROSS JOIN quota_configs q
  CROSS JOIN score_formulas f
)

SELECT
  *,
  CURRENT_TIMESTAMP()                             AS created_at_utc,
  'h12_v5_2_recall_safe_oos_policy_strict'        AS model_version,
  'Phase 2: 81-candidate policy grid'             AS phase_description
FROM candidate_grid
ORDER BY gate_set_id, percentile_config_id, quota_config_id, score_formula_id;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '══════════════════════════════════════════════════════════════' AS sep;
SELECT 'Phase 2 Complete: Recall-Safe Policy Candidates Generated' AS status;
SELECT '══════════════════════════════════════════════════════════════' AS sep;

SELECT
  'Candidate grid count validation' AS check_name,
  COUNT(*) AS n_candidates,
  CASE WHEN COUNT(*) = 81 THEN 'PASS' ELSE 'FAIL' END AS status
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict`;

SELECT
  'Grid distribution by gate set' AS check_name,
  gate_set_id,
  COUNT(*) AS n
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict`
GROUP BY gate_set_id
ORDER BY gate_set_id;

SELECT
  'Grid distribution by formula' AS check_name,
  score_formula_id,
  COUNT(*) AS n
FROM `thequantitativeledger.cruzber_models_eu.recall_safe_policy_candidates_h12_v5_2_strict`
GROUP BY score_formula_id
ORDER BY score_formula_id;
