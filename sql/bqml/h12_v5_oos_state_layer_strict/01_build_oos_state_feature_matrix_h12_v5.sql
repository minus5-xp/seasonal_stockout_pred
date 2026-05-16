-- ============================================================================
-- PHASE 1: BUILD OOS STATE FEATURE MATRIX (h12_v5)
-- ============================================================================
-- PURPOSE:
--   Engineer features for OOS state detection:
--   - Zero run lengths (consecutive zeros before decision_week)
--   - Recent statistics (4w, 8w, 12w rolling windows from PAST only)
--   - Expected demand gap (forecast vs recent sales)
--   - Historical zero/positive rates
--   - Segment flags
--
-- CRITICAL: All features use only data BEFORE decision_week (no future leakage)
--
-- INPUTS:
--   - oos_state_inputs_h12_v5_strict
--
-- OUTPUTS:
--   - oos_state_feature_matrix_h12_v5_strict
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict` AS
WITH

base_with_lag AS (
  SELECT
    *,
    LAG(y_sales, 1) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag1,
    LAG(y_sales, 2) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag2,
    LAG(y_sales, 3) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag3,
    LAG(y_sales, 4) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag4,
    LAG(y_sales, 5) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag5,
    LAG(y_sales, 6) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag6,
    LAG(y_sales, 7) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag7,
    LAG(y_sales, 8) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag8,
    LAG(y_sales, 9) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag9,
    LAG(y_sales, 10) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag10,
    LAG(y_sales, 11) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag11,
    LAG(y_sales, 12) OVER (PARTITION BY sku_id ORDER BY decision_week) AS y_sales_lag12
  FROM `thequantitativeledger.cruzber_models_eu.oos_state_inputs_h12_v5_strict`
),

zero_runs AS (
  SELECT
    sku_id,
    decision_week,
    -- Zero run length: count consecutive zeros before decision_week
    CASE
      WHEN y_sales_lag1 IS NULL THEN 0
      WHEN y_sales_lag1 > 0 THEN 0
      WHEN y_sales_lag2 IS NULL OR y_sales_lag2 > 0 THEN 1
      WHEN y_sales_lag3 IS NULL OR y_sales_lag3 > 0 THEN 2
      WHEN y_sales_lag4 IS NULL OR y_sales_lag4 > 0 THEN 3
      WHEN y_sales_lag5 IS NULL OR y_sales_lag5 > 0 THEN 4
      WHEN y_sales_lag6 IS NULL OR y_sales_lag6 > 0 THEN 5
      WHEN y_sales_lag7 IS NULL OR y_sales_lag7 > 0 THEN 6
      WHEN y_sales_lag8 IS NULL OR y_sales_lag8 > 0 THEN 7
      WHEN y_sales_lag9 IS NULL OR y_sales_lag9 > 0 THEN 8
      WHEN y_sales_lag10 IS NULL OR y_sales_lag10 > 0 THEN 9
      WHEN y_sales_lag11 IS NULL OR y_sales_lag11 > 0 THEN 10
      WHEN y_sales_lag12 IS NULL OR y_sales_lag12 > 0 THEN 11
      ELSE 12
    END AS zero_run_length
  FROM base_with_lag
),

recent_stats AS (
  SELECT
    sku_id,
    decision_week,
    -- 4-week window
    CASE WHEN y_sales_lag1 = 0 OR y_sales_lag2 = 0 OR y_sales_lag3 = 0 OR y_sales_lag4 = 0 THEN 1.0 ELSE 0.0 END AS recent_zero_rate_4w_approx,
    COALESCE((y_sales_lag1 + y_sales_lag2 + y_sales_lag3 + y_sales_lag4) / 4.0, 0.0) AS recent_mean_sales_4w,
    GREATEST(COALESCE(y_sales_lag1, 0), COALESCE(y_sales_lag2, 0), COALESCE(y_sales_lag3, 0), COALESCE(y_sales_lag4, 0)) AS recent_max_sales_4w,
    -- 8-week window
    COALESCE((
      IF(y_sales_lag1 = 0, 1.0, 0.0) + 
      IF(y_sales_lag2 = 0, 1.0, 0.0) + 
      IF(y_sales_lag3 = 0, 1.0, 0.0) + 
      IF(y_sales_lag4 = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag5, 0) = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag6, 0) = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag7, 0) = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag8, 0) = 0, 1.0, 0.0)
    ) / 8.0, 0.0) AS recent_zero_rate_8w,
    COALESCE((
      COALESCE(y_sales_lag1, 0) + COALESCE(y_sales_lag2, 0) + COALESCE(y_sales_lag3, 0) + COALESCE(y_sales_lag4, 0) +
      COALESCE(y_sales_lag5, 0) + COALESCE(y_sales_lag6, 0) + COALESCE(y_sales_lag7, 0) + COALESCE(y_sales_lag8, 0)
    ) / 8.0, 0.0) AS recent_mean_sales_8w,
    -- 12-week window
    COALESCE((
      IF(y_sales_lag1 = 0, 1.0, 0.0) + IF(y_sales_lag2 = 0, 1.0, 0.0) + IF(y_sales_lag3 = 0, 1.0, 0.0) + IF(y_sales_lag4 = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag5, 0) = 0, 1.0, 0.0) + IF(COALESCE(y_sales_lag6, 0) = 0, 1.0, 0.0) + 
      IF(COALESCE(y_sales_lag7, 0) = 0, 1.0, 0.0) + IF(COALESCE(y_sales_lag8, 0) = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag9, 0) = 0, 1.0, 0.0) + IF(COALESCE(y_sales_lag10, 0) = 0, 1.0, 0.0) +
      IF(COALESCE(y_sales_lag11, 0) = 0, 1.0, 0.0) + IF(COALESCE(y_sales_lag12, 0) = 0, 1.0, 0.0)
    ) / 12.0, 0.0) AS recent_zero_rate_12w,
    COALESCE((
      COALESCE(y_sales_lag1, 0) + COALESCE(y_sales_lag2, 0) + COALESCE(y_sales_lag3, 0) + COALESCE(y_sales_lag4, 0) +
      COALESCE(y_sales_lag5, 0) + COALESCE(y_sales_lag6, 0) + COALESCE(y_sales_lag7, 0) + COALESCE(y_sales_lag8, 0) +
      COALESCE(y_sales_lag9, 0) + COALESCE(y_sales_lag10, 0) + COALESCE(y_sales_lag11, 0) + COALESCE(y_sales_lag12, 0)
    ) / 12.0, 0.0) AS recent_mean_sales_12w,
    GREATEST(
      COALESCE(y_sales_lag1, 0), COALESCE(y_sales_lag2, 0), COALESCE(y_sales_lag3, 0), COALESCE(y_sales_lag4, 0),
      COALESCE(y_sales_lag5, 0), COALESCE(y_sales_lag6, 0), COALESCE(y_sales_lag7, 0), COALESCE(y_sales_lag8, 0),
      COALESCE(y_sales_lag9, 0), COALESCE(y_sales_lag10, 0), COALESCE(y_sales_lag11, 0), COALESCE(y_sales_lag12, 0)
    ) AS recent_max_sales_12w,
    -- Positive weeks count
    (
      IF(COALESCE(y_sales_lag1, 0) > 0, 1, 0) + IF(COALESCE(y_sales_lag2, 0) > 0, 1, 0) + 
      IF(COALESCE(y_sales_lag3, 0) > 0, 1, 0) + IF(COALESCE(y_sales_lag4, 0) > 0, 1, 0) +
      IF(COALESCE(y_sales_lag5, 0) > 0, 1, 0) + IF(COALESCE(y_sales_lag6, 0) > 0, 1, 0) +
      IF(COALESCE(y_sales_lag7, 0) > 0, 1, 0) + IF(COALESCE(y_sales_lag8, 0) > 0, 1, 0) +
      IF(COALESCE(y_sales_lag9, 0) > 0, 1, 0) + IF(COALESCE(y_sales_lag10, 0) > 0, 1, 0) +
      IF(COALESCE(y_sales_lag11, 0) > 0, 1, 0) + IF(COALESCE(y_sales_lag12, 0) > 0, 1, 0)
    ) AS recent_positive_weeks_12w,
    -- Weeks since last positive sale
    CASE
      WHEN COALESCE(y_sales_lag1, 0) > 0 THEN 0
      WHEN COALESCE(y_sales_lag2, 0) > 0 THEN 1
      WHEN COALESCE(y_sales_lag3, 0) > 0 THEN 2
      WHEN COALESCE(y_sales_lag4, 0) > 0 THEN 3
      WHEN COALESCE(y_sales_lag5, 0) > 0 THEN 4
      WHEN COALESCE(y_sales_lag6, 0) > 0 THEN 5
      WHEN COALESCE(y_sales_lag7, 0) > 0 THEN 6
      WHEN COALESCE(y_sales_lag8, 0) > 0 THEN 7
      WHEN COALESCE(y_sales_lag9, 0) > 0 THEN 8
      WHEN COALESCE(y_sales_lag10, 0) > 0 THEN 9
      WHEN COALESCE(y_sales_lag11, 0) > 0 THEN 10
      WHEN COALESCE(y_sales_lag12, 0) > 0 THEN 11
      ELSE 12
    END AS weeks_since_last_positive_sale
  FROM base_with_lag
),

final_features AS (
  SELECT
    inp.*,
    zr.zero_run_length,
    LEAST(zr.zero_run_length, 12) AS zero_run_length_capped,
    CASE
      WHEN zr.zero_run_length = 0 THEN '0'
      WHEN zr.zero_run_length = 1 THEN '1'
      WHEN zr.zero_run_length BETWEEN 2 AND 3 THEN '2-3'
      WHEN zr.zero_run_length BETWEEN 4 AND 7 THEN '4-7'
      ELSE '8+'
    END AS zero_run_bucket,
    
    -- Recent stats
    rs.recent_zero_rate_4w_approx AS recent_zero_rate_4w,
    rs.recent_zero_rate_8w,
    rs.recent_zero_rate_12w,
    rs.recent_mean_sales_4w,
    rs.recent_mean_sales_8w,
    rs.recent_mean_sales_12w,
    rs.recent_max_sales_4w,
    rs.recent_max_sales_12w,
    rs.recent_positive_weeks_12w,
    rs.weeks_since_last_positive_sale,
    
    -- Historical positive/zero rates
    COALESCE(inp.hist_positive_rate_same_week, 0.5) AS historical_positive_rate_same_week,
    COALESCE(inp.hist_zero_rate_same_week, 0.5) AS historical_zero_rate_same_week,
    COALESCE(inp.hist_avg_units_same_week, 0.0) AS same_week_expected_units,
    
    -- Expected demand gap
    GREATEST(inp.yhat_p50_v3_2_12w - rs.recent_mean_sales_4w, 0.0) AS expected_demand_gap,
    SAFE_DIVIDE(
      GREATEST(inp.yhat_p50_v3_2_12w - rs.recent_mean_sales_4w, 0.0),
      GREATEST(inp.yhat_p50_v3_2_12w, 1.0)
    ) AS normalized_expected_demand_gap,
    
    -- Positive demand prior
    GREATEST(
      COALESCE(inp.hist_positive_rate_same_week, 0.0),
      COALESCE(inp.annual_positive_rate_sku, 0.0)
    ) AS positive_demand_prior,
    
    -- Zero regime flag
    CASE
      WHEN COALESCE(inp.hist_positive_rate_same_week, 1.0) <= 0.20 THEN 'EXTREME_ZERO'
      WHEN COALESCE(inp.hist_positive_rate_same_week, 1.0) <= 0.35 THEN 'HIGH_ZERO'
      WHEN COALESCE(inp.hist_positive_rate_same_week, 1.0) <= 0.50 THEN 'MODERATE_ZERO'
      ELSE 'LOW_ZERO'
    END AS zero_regime_flag,
    
    -- Segment flags
    inp.season_group = 'REST' AS is_rest,
    inp.season_group = 'HIGH_SEASON' AS is_high_season,
    inp.sku_season_state = 'OFF_SEASON' AS is_off_season,
    inp.sku_season_state = 'ALWAYS_ON' AS is_always_on,
    inp.sku_season_state = 'TRANSITION_UP' AS is_transition_up,
    inp.sku_season_state = 'TRANSITION_DOWN' AS is_transition_down,
    inp.sku_season_state = 'IN_SEASON' AS is_in_season,
    inp.sku_season_state = 'INTERMITTENT_RANDOM' AS is_intermittent_random,
    inp.sku_season_state = 'REST_OFFPEAK' AS is_rest_offpeak
    
  FROM `thequantitativeledger.cruzber_models_eu.oos_state_inputs_h12_v5_strict` inp
  JOIN zero_runs zr
    ON inp.sku_id = zr.sku_id AND inp.decision_week = zr.decision_week
  JOIN recent_stats rs
    ON inp.sku_id = rs.sku_id AND inp.decision_week = rs.decision_week
)

SELECT * FROM final_features;

-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 1 Complete: OOS State Feature Matrix Built' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Validation
SELECT
  'Feature matrix summary' AS check_name,
  eval_split_v3,
  COUNT(*) AS n_obs,
  ROUND(AVG(zero_run_length), 2) AS avg_zero_run,
  ROUND(AVG(recent_zero_rate_12w), 3) AS avg_recent_zero_rate,
  ROUND(AVG(historical_zero_rate_same_week), 3) AS avg_hist_zero_rate,
  ROUND(AVG(expected_demand_gap), 2) AS avg_demand_gap,
  ROUND(AVG(CAST(stockout_event_12w AS FLOAT64)), 3) AS stockout_rate
FROM `thequantitativeledger.cruzber_models_eu.oos_state_feature_matrix_h12_v5_strict`
GROUP BY eval_split_v3
ORDER BY 
  CASE eval_split_v3
    WHEN 'DEV_TUNE' THEN 1
    WHEN 'DEV_SELECT' THEN 2
    WHEN 'EMBARGO' THEN 3
    WHEN 'LOCKED_TEST' THEN 4
    ELSE 5
  END;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 2 will generate OOS policy candidates' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
