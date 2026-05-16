-- ============================================================================
-- PHASE 5: SELECT FROZEN EFFICIENT POLICY (h12_v4_1)
-- ============================================================================
-- PURPOSE:
--   Evaluate all A×B candidates on DEV_SELECT using composite loss function.
--   Select the best candidate and freeze it for LOCKED_TEST evaluation.
--
--   Loss Function:
--     loss = 2.0×WMAPE_all + 2.0×WMAPE_ypos + 1.0×zero_overf 
--          + 0.5×|bias| + 0.8×coverage_penalty 
--          + 1.0×rest_penalty + 1.0×highseason_degradation 
--          + 10.0×monotonicity_penalty + 0.5×stability_score
--
--   Relaxed targets (given dataset difficulty):
--     viol_p80: [0.10, 0.25] (ideal 0.20)
--     viol_p90: [0.04, 0.15] (ideal 0.10)
--     viol_p95: [0.01, 0.08] (ideal 0.05)
--
-- INPUTS:
--   - conformal_quantile_candidates_h12_v4_1_strict
--
-- OUTPUTS:
--   - frozen_efficient_policy_h12_v4_1_strict (single row with winning candidate)
--
-- ANTI-LEAKAGE:
--   - Selection uses only DEV_SELECT data
--   - LOCKED_TEST not used
--   - Frozen flags: selected_using_split='DEV_SELECT', 
--                   selected_without_locked_test=TRUE, 
--                   post_selection_bias=FALSE
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- Step 1: Compute comprehensive metrics on DEV_SELECT for all A×B candidates
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_full_metrics_dev_select_h12_v4_1` AS
WITH

-- B1 candidates
metrics_B1 AS (
  SELECT
    'B1_ABS_RESIDUAL' AS spread_method,
    point_candidate,
    CONCAT(point_candidate, '_', 'B1_ABS_RESIDUAL') AS full_candidate_id,
    -- Global metrics
    'GLOBAL' AS segment,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B1 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B1 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B1 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B1 < p50 OR q_p90_B1 < q_p80_B1 OR q_p95_B1 < q_p90_B1 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_SELECT'
  GROUP BY point_candidate
  
  UNION ALL
  
  -- HIGH_SEASON metrics
  SELECT
    'B1_ABS_RESIDUAL' AS spread_method,
    point_candidate,
    CONCAT(point_candidate, '_', 'B1_ABS_RESIDUAL') AS full_candidate_id,
    'HIGH_SEASON' AS segment,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B1 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B1 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B1 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B1 < p50 OR q_p90_B1 < q_p80_B1 OR q_p95_B1 < q_p90_B1 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'HIGH_SEASON'
  GROUP BY point_candidate
  
  UNION ALL
  
  -- REST metrics
  SELECT
    'B1_ABS_RESIDUAL' AS spread_method,
    point_candidate,
    CONCAT(point_candidate, '_', 'B1_ABS_RESIDUAL') AS full_candidate_id,
    'REST' AS segment,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(
      SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END),
      SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)
    ) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B1 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B1 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B1 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B1 < p50 OR q_p90_B1 < q_p80_B1 OR q_p95_B1 < q_p90_B1 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'REST'
  GROUP BY point_candidate
),

-- Repeat for B2, B3, B4 (similar structure)
metrics_B2 AS (
  SELECT
    'B2_LOG_RESIDUAL' AS spread_method,
    point_candidate,
    CONCAT(point_candidate, '_', 'B2_LOG_RESIDUAL') AS full_candidate_id,
    'GLOBAL' AS segment,
    COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B2 THEN 1.0 ELSE 0.0 END) AS viol_p80,
    AVG(CASE WHEN y_true_12w > q_p90_B2 THEN 1.0 ELSE 0.0 END) AS viol_p90,
    AVG(CASE WHEN y_true_12w > q_p95_B2 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B2 < p50 OR q_p90_B2 < q_p80_B2 OR q_p95_B2 < q_p90_B2 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_SELECT'
  GROUP BY point_candidate
  UNION ALL
  SELECT
    'B2_LOG_RESIDUAL' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B2_LOG_RESIDUAL') AS full_candidate_id,
    'HIGH_SEASON' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B2 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B2 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B2 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B2 < p50 OR q_p90_B2 < q_p80_B2 OR q_p95_B2 < q_p90_B2 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'HIGH_SEASON'
  GROUP BY point_candidate
  UNION ALL
  SELECT
    'B2_LOG_RESIDUAL' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B2_LOG_RESIDUAL') AS full_candidate_id,
    'REST' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B2 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B2 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B2 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B2 < p50 OR q_p90_B2 < q_p80_B2 OR q_p95_B2 < q_p90_B2 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict`
  WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'REST'
  GROUP BY point_candidate
),

metrics_B3 AS (
  SELECT 'B3_HYBRID_ADAPTIVE' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B3_HYBRID_ADAPTIVE') AS full_candidate_id, 'GLOBAL' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias,
    AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B3 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B3 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B3 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B3 < p50 OR q_p90_B3 < q_p80_B3 OR q_p95_B3 < q_p90_B3 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` WHERE eval_split_v3 = 'DEV_SELECT' GROUP BY point_candidate
  UNION ALL
  SELECT 'B3_HYBRID_ADAPTIVE' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B3_HYBRID_ADAPTIVE') AS full_candidate_id, 'HIGH_SEASON' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias, AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B3 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B3 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B3 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B3 < p50 OR q_p90_B3 < q_p80_B3 OR q_p95_B3 < q_p90_B3 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'HIGH_SEASON' GROUP BY point_candidate
  UNION ALL
  SELECT 'B3_HYBRID_ADAPTIVE' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B3_HYBRID_ADAPTIVE') AS full_candidate_id, 'REST' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias, AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B3 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B3 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B3 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B3 < p50 OR q_p90_B3 < q_p80_B3 OR q_p95_B3 < q_p90_B3 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'REST' GROUP BY point_candidate
),

metrics_B4 AS (
  SELECT 'B4_CONFORMAL_CALIBRATED' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B4_CONFORMAL_CALIBRATED') AS full_candidate_id, 'GLOBAL' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias, AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B4 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B4 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B4 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B4 < p50 OR q_p90_B4 < q_p80_B4 OR q_p95_B4 < q_p90_B4 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` WHERE eval_split_v3 = 'DEV_SELECT' GROUP BY point_candidate
  UNION ALL
  SELECT 'B4_CONFORMAL_CALIBRATED' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B4_CONFORMAL_CALIBRATED') AS full_candidate_id, 'HIGH_SEASON' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias, AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B4 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B4 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B4 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B4 < p50 OR q_p90_B4 < q_p80_B4 OR q_p95_B4 < q_p90_B4 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'HIGH_SEASON' GROUP BY point_candidate
  UNION ALL
  SELECT 'B4_CONFORMAL_CALIBRATED' AS spread_method, point_candidate, CONCAT(point_candidate, '_', 'B4_CONFORMAL_CALIBRATED') AS full_candidate_id, 'REST' AS segment, COUNT(*) AS n_obs,
    SAFE_DIVIDE(SUM(ABS(y_true_12w - p50)), SUM(y_true_12w)) AS wmape_all,
    SAFE_DIVIDE(SUM(CASE WHEN y_true_12w > 0 THEN ABS(y_true_12w - p50) END), SUM(CASE WHEN y_true_12w > 0 THEN y_true_12w END)) AS wmape_ypos,
    SAFE_DIVIDE((SUM(p50) - SUM(y_true_12w)), SUM(y_true_12w)) AS bias, AVG(CASE WHEN y_true_12w = 0 AND p50 > 0 THEN 1.0 ELSE 0.0 END) AS zero_overf,
    AVG(CASE WHEN y_true_12w > q_p80_B4 THEN 1.0 ELSE 0.0 END) AS viol_p80, AVG(CASE WHEN y_true_12w > q_p90_B4 THEN 1.0 ELSE 0.0 END) AS viol_p90, AVG(CASE WHEN y_true_12w > q_p95_B4 THEN 1.0 ELSE 0.0 END) AS viol_p95,
    AVG(CASE WHEN q_p80_B4 < p50 OR q_p90_B4 < q_p80_B4 OR q_p95_B4 < q_p90_B4 THEN 1.0 ELSE 0.0 END) AS monotonicity_viol
  FROM `thequantitativeledger.cruzber_models_eu.conformal_quantile_candidates_h12_v4_1_strict` WHERE eval_split_v3 = 'DEV_SELECT' AND season_group = 'REST' GROUP BY point_candidate
)

SELECT * FROM metrics_B1
UNION ALL SELECT * FROM metrics_B2
UNION ALL SELECT * FROM metrics_B3
UNION ALL SELECT * FROM metrics_B4;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 2: Compute composite loss and select best candidate
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu._temp_loss_computation_h12_v4_1` AS
WITH

pivoted AS (
  SELECT
    full_candidate_id,
    spread_method,
    point_candidate,
    MAX(CASE WHEN segment = 'GLOBAL' THEN wmape_all END) AS wmape_all_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN wmape_ypos END) AS wmape_ypos_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN bias END) AS bias_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN zero_overf END) AS zero_overf_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN viol_p80 END) AS viol_p80_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN viol_p90 END) AS viol_p90_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN viol_p95 END) AS viol_p95_global,
    MAX(CASE WHEN segment = 'GLOBAL' THEN monotonicity_viol END) AS monotonicity_viol_global,
    MAX(CASE WHEN segment = 'REST' THEN wmape_ypos END) AS wmape_ypos_rest,
    MAX(CASE WHEN segment = 'HIGH_SEASON' THEN wmape_ypos END) AS wmape_ypos_high
  FROM `thequantitativeledger.cruzber_models_eu._temp_full_metrics_dev_select_h12_v4_1`
  GROUP BY full_candidate_id, spread_method, point_candidate
),

loss_components AS (
  SELECT
    *,
    -- Coverage penalty (distance from relaxed targets)
    (CASE WHEN viol_p80_global < 0.10 THEN (0.10 - viol_p80_global) * 5.0
          WHEN viol_p80_global > 0.25 THEN (viol_p80_global - 0.25) * 2.0
          ELSE 0.0 END
     + CASE WHEN viol_p90_global < 0.04 THEN (0.04 - viol_p90_global) * 8.0
            WHEN viol_p90_global > 0.15 THEN (viol_p90_global - 0.15) * 3.0
            ELSE 0.0 END
     + CASE WHEN viol_p95_global < 0.01 THEN (0.01 - viol_p95_global) * 10.0
            WHEN viol_p95_global > 0.08 THEN (viol_p95_global - 0.08) * 4.0
            ELSE 0.0 END
    ) AS coverage_penalty,
    -- REST penalty (if worse than v3_2)
    CASE WHEN wmape_ypos_rest > (4.761 * 1.05) THEN (wmape_ypos_rest - 4.761) * 2.0
         ELSE 0.0 END AS rest_penalty,
    -- HIGH degradation penalty
    CASE WHEN wmape_ypos_high > (0.624 * 1.10) THEN (wmape_ypos_high - 0.624) * 3.0
         ELSE 0.0 END AS highseason_penalty,
    -- Monotonicity penalty
    monotonicity_viol_global * 10.0 AS monotonicity_penalty,
    -- Stability score (placeholder, would need weekly variance)
    0.0 AS stability_score
  FROM pivoted
),

final_loss AS (
  SELECT
    *,
    (2.0 * wmape_all_global
     + 2.0 * wmape_ypos_global
     + 1.0 * zero_overf_global
     + 0.5 * ABS(bias_global)
     + 0.8 * coverage_penalty
     + 1.0 * rest_penalty
     + 1.0 * highseason_penalty
     + monotonicity_penalty
     + 0.5 * stability_score
    ) AS composite_loss
  FROM loss_components
)

SELECT * FROM final_loss
ORDER BY composite_loss ASC;

-- ──────────────────────────────────────────────────────────────────────────
-- Step 3: Freeze best candidate
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.frozen_efficient_policy_h12_v4_1_strict` AS
SELECT
  full_candidate_id AS frozen_candidate_id,
  spread_method,
  point_candidate,
  wmape_all_global,
  wmape_ypos_global,
  wmape_ypos_rest,
  wmape_ypos_high,
  bias_global,
  zero_overf_global,
  viol_p80_global,
  viol_p90_global,
  viol_p95_global,
  monotonicity_viol_global,
  coverage_penalty,
  rest_penalty,
  highseason_penalty,
  monotonicity_penalty,
  composite_loss,
  -- Anti-leakage flags
  'DEV_SELECT' AS selected_using_split,
  TRUE AS selected_without_locked_test,
  FALSE AS post_selection_bias,
  CURRENT_TIMESTAMP() AS created_at
FROM `thequantitativeledger.cruzber_models_eu._temp_loss_computation_h12_v4_1`
ORDER BY composite_loss ASC
LIMIT 1;

-- Cleanup
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_full_metrics_dev_select_h12_v4_1`;
DROP TABLE IF EXISTS `thequantitativeledger.cruzber_models_eu._temp_loss_computation_h12_v4_1`;

-- ──────────────────────────────────────────────────────────────────────────
-- Validation: Display frozen policy
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 5 Complete: Frozen Policy Selected' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

SELECT
  frozen_candidate_id,
  ROUND(composite_loss, 4) AS loss,
  ROUND(wmape_ypos_global, 4) AS wmape_ypos,
  ROUND(viol_p90_global, 4) AS viol_p90,
  ROUND(zero_overf_global, 4) AS zero_overf,
  selected_using_split,
  selected_without_locked_test
FROM `thequantitativeledger.cruzber_models_eu.frozen_efficient_policy_h12_v4_1_strict`;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 6 will evaluate frozen policy on LOCKED_TEST (one-time use)' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
