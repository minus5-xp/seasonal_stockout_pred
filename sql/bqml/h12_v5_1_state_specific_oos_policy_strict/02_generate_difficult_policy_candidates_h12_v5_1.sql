-- ============================================================================
-- PHASE 2: GENERATE DIFFICULT_POLICY_CANDIDATES (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Create grid of difficult_state_policy candidates by combining:
--   - 3 gate sets (conservative, moderate, exploratory)
--   - 3 percentile thresholds per state (varies by state difficulty)
--   - 3 weekly quota configs per state
--
--   Total: 3 gates × 3 percentiles × 3 quotas = ~81 candidates
--
-- OUTPUTS:
--   - difficult_state_policy_candidates_h12_v5_1_strict (81 rows)
--
-- ANTI-LEAKAGE:
--   - Pure grid definition, no data-dependent selection
--   - Parameters based on domain knowledge, not LOCKED_TEST
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict` AS

WITH

-- Gate sets (3 options)
gate_sets AS (
  SELECT 'GATE_A' AS gate_set_id, 'conservative' AS gate_family,
         5.0 AS min_yhat, 1.0 AS min_els, 0.05 AS min_p_susp, 0.05 AS min_p_oos
  UNION ALL SELECT 'GATE_B', 'moderate',
         3.0, 0.5, 0.03, 0.03
  UNION ALL SELECT 'GATE_C', 'exploratory',
         1.0, 0.25, 0.01, 0.01
),

-- Percentile thresholds per season_group (3 configs)
-- Thresholds are on the COMPOSITE difficult_state_score [0,1].
-- Max achievable composite is ~0.96 (not 1.0) due to combining 5 percentile ranks.
-- Thresholds are set relative to that realistic maximum.
percentile_configs AS (
  -- Config P1: Conservative (top ~2% of composite score)
  SELECT 'P1' AS percentile_config_id, 'conservative' AS percentile_family,
         'HIGH_SEASON' AS season_group, 0.940 AS percentile_threshold
  UNION ALL SELECT 'P1', 'conservative', 'REST', 0.940
  
  -- Config P2: Moderate (top ~5%)
  UNION ALL SELECT 'P2', 'moderate', 'HIGH_SEASON', 0.900
  UNION ALL SELECT 'P2', 'moderate', 'REST', 0.920
  
  -- Config P3: Exploratory (top ~10%)
  UNION ALL SELECT 'P3', 'exploratory', 'HIGH_SEASON', 0.850
  UNION ALL SELECT 'P3', 'exploratory', 'REST', 0.870
),

-- Weekly quota configs per season_group (3 options)
quota_configs AS (
  -- Config Q1: Conservative (fewest alerts per week)
  SELECT 'Q1' AS quota_config_id, 'conservative' AS quota_family,
         'HIGH_SEASON' AS season_group, 5 AS weekly_quota
  UNION ALL SELECT 'Q1', 'conservative', 'REST', 8
  
  -- Config Q2: Moderate
  UNION ALL SELECT 'Q2', 'moderate', 'HIGH_SEASON', 10
  UNION ALL SELECT 'Q2', 'moderate', 'REST', 15
  
  -- Config Q3: Exploratory (most alerts)
  UNION ALL SELECT 'Q3', 'exploratory', 'HIGH_SEASON', 20
  UNION ALL SELECT 'Q3', 'exploratory', 'REST', 30
),

-- Cross product: gate × percentile × quota
candidate_grid AS (
  SELECT
    CONCAT(g.gate_set_id, '_', p.percentile_config_id, '_', q.quota_config_id) AS difficult_policy_id,
    
    -- Gate parameters
    g.gate_set_id,
    g.gate_family,
    g.min_yhat,
    g.min_els,
    g.min_p_susp,
    g.min_p_oos,
    
    -- Percentile parameters (state-specific)
    p.percentile_config_id,
    p.percentile_family,
    
    -- Quota parameters (state-specific)
    q.quota_config_id,
    q.quota_family,
    
    -- Season-group-specific percentile thresholds (pivoted)
    MAX(CASE WHEN p.season_group = 'HIGH_SEASON' THEN p.percentile_threshold END) AS percentile_high_season,
    MAX(CASE WHEN p.season_group = 'REST' THEN p.percentile_threshold END) AS percentile_rest,
    
    -- Season-group-specific weekly quotas (pivoted)
    MAX(CASE WHEN q.season_group = 'HIGH_SEASON' THEN q.weekly_quota END) AS quota_high_season,
    MAX(CASE WHEN q.season_group = 'REST' THEN q.weekly_quota END) AS quota_rest
    
  FROM gate_sets g
  CROSS JOIN (SELECT DISTINCT percentile_config_id, percentile_family FROM percentile_configs) p_configs
  INNER JOIN percentile_configs p ON p_configs.percentile_config_id = p.percentile_config_id
  CROSS JOIN (SELECT DISTINCT quota_config_id, quota_family FROM quota_configs) q_configs
  INNER JOIN quota_configs q ON q_configs.quota_config_id = q.quota_config_id
  
  GROUP BY 
    g.gate_set_id, g.gate_family, g.min_yhat, g.min_els, g.min_p_susp, g.min_p_oos,
    p.percentile_config_id, p.percentile_family,
    q.quota_config_id, q.quota_family
)

SELECT
  difficult_policy_id,
  
  -- Gate parameters
  gate_set_id,
  gate_family,
  min_yhat,
  min_els,
  min_p_susp,
  min_p_oos,
  
  -- Percentile config
  percentile_config_id,
  percentile_family,
  percentile_high_season,
  percentile_rest,
  
  -- Quota config
  quota_config_id,
  quota_family,
  quota_high_season,
  quota_rest,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at_utc,
  TRUE AS selected_without_locked_test,  -- Grid defined without data
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 2: Difficult policy candidate grid' AS phase_description
  
FROM candidate_grid
ORDER BY difficult_policy_id;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 2 Complete: Difficult Policy Candidates Generated' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Candidate count
SELECT
  'Candidate count' AS check_name,
  COUNT(*) AS n_candidates,
  COUNT(DISTINCT difficult_policy_id) AS n_unique_ids,
  CASE 
    WHEN COUNT(*) = 27 AND COUNT(DISTINCT difficult_policy_id) = 27
    THEN '✓ PASS: Expected 27 candidates (3×3×3 with 2 groups)'
    ELSE '✗ WARNING: Unexpected candidate count'
  END AS validation_status
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict`;

-- Candidates by family combination
SELECT
  'Candidates by family combination' AS check_name,
  gate_family,
  percentile_family,
  quota_family,
  COUNT(*) AS n_candidates
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict`
GROUP BY gate_family, percentile_family, quota_family
ORDER BY gate_family, percentile_family, quota_family;

-- Sample candidates (first 5)
SELECT
  'Sample candidates (first 5)' AS check_name,
  difficult_policy_id,
  gate_family,
  percentile_family,
  quota_family,
  percentile_high_season AS p_high,
  quota_high_season AS q_high,
  percentile_rest AS p_rest,
  quota_rest AS q_rest
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict`
ORDER BY difficult_policy_id
LIMIT 5;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 3 will evaluate candidates on DEV_SELECT' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
