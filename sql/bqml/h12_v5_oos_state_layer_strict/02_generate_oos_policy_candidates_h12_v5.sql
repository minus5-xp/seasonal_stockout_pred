-- ============================================================================
-- PHASE 2: GENERATE OOS POLICY CANDIDATES (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Define candidate OOS detection policies with different weight combinations
--   and thresholds. These will be scored on DEV_TUNE in Phase 3.
--
-- OUTPUTS:
--   - oos_policy_candidates_h12_v5_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_policy_candidates_h12_v5_strict` AS

WITH policy_grid AS (
  -- Policy Family A: Zero-run heavy
  SELECT 'POLICY_A1' AS policy_id, 0.40 AS w1, 0.20 AS w2, 0.15 AS w3, 0.10 AS w4, 0.10 AS w5, 0.05 AS w6, 'zero_run_heavy' AS family
  UNION ALL SELECT 'POLICY_A2', 0.35, 0.25, 0.15, 0.10, 0.10, 0.05, 'zero_run_heavy'
  
  -- Policy Family B: Expected-gap heavy
  UNION ALL SELECT 'POLICY_B1', 0.15, 0.40, 0.20, 0.10, 0.10, 0.05, 'expected_gap_heavy'
  UNION ALL SELECT 'POLICY_B2', 0.20, 0.35, 0.20, 0.10, 0.10, 0.05, 'expected_gap_heavy'
  
  -- Policy Family C: Historical-positive heavy
  UNION ALL SELECT 'POLICY_C1', 0.15, 0.20, 0.35, 0.15, 0.10, 0.05, 'historical_positive_heavy'
  UNION ALL SELECT 'POLICY_C2', 0.15, 0.20, 0.30, 0.20, 0.10, 0.05, 'historical_positive_heavy'
  
  -- Policy Family D: Balanced
  UNION ALL SELECT 'POLICY_D1', 0.25, 0.25, 0.20, 0.15, 0.10, 0.05, 'balanced'
  UNION ALL SELECT 'POLICY_D2', 0.20, 0.20, 0.20, 0.20, 0.15, 0.05, 'balanced'
  
  -- Policy Family E: Conservative (requires longer zero run)
  UNION ALL SELECT 'POLICY_E1', 0.45, 0.20, 0.15, 0.10, 0.05, 0.05, 'conservative'
  UNION ALL SELECT 'POLICY_E2', 0.50, 0.15, 0.15, 0.10, 0.05, 0.05, 'conservative'
),

thresholds AS (
  SELECT 0.30 AS p_suspected_oos_threshold, 'threshold_30' AS threshold_label
  UNION ALL SELECT 0.40, 'threshold_40'
  UNION ALL SELECT 0.50, 'threshold_50'
  UNION ALL SELECT 0.60, 'threshold_60'
),

top_n_policies AS (
  SELECT 50 AS top_n, 'global' AS scope, 'top50_global' AS top_n_label
  UNION ALL SELECT 100, 'global', 'top100_global'
  UNION ALL SELECT 200, 'global', 'top200_global'
  UNION ALL SELECT 20, 'season_group', 'top20_by_season'
  UNION ALL SELECT 50, 'season_group', 'top50_by_season'
),

candidates AS (
  SELECT
    CONCAT(pg.policy_id, '_', t.threshold_label, '_', tn.top_n_label) AS candidate_id,
    pg.policy_id,
    pg.family,
    pg.w1,
    pg.w2,
    pg.w3,
    pg.w4,
    pg.w5,
    pg.w6,
    t.p_suspected_oos_threshold,
    t.threshold_label,
    tn.top_n,
    tn.scope AS ranking_scope,
    tn.top_n_label,
    CURRENT_TIMESTAMP() AS created_at
  FROM policy_grid pg
  CROSS JOIN thresholds t
  CROSS JOIN top_n_policies tn
)

SELECT * FROM candidates;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 2 Complete: OOS Policy Candidates Generated' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

SELECT
  'Candidate summary' AS check_name,
  family,
  COUNT(*) AS n_candidates
FROM `thequantitativeledger.cruzber_models_eu.oos_policy_candidates_h12_v5_strict`
GROUP BY family
ORDER BY n_candidates DESC;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT CONCAT('Total candidates: ', CAST(COUNT(*) AS STRING)) AS total
FROM `thequantitativeledger.cruzber_models_eu.oos_policy_candidates_h12_v5_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 3 will score candidates on DEV_TUNE' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
