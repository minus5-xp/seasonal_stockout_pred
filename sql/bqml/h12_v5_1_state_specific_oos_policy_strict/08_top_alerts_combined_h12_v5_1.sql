-- ============================================================================
-- PHASE 8: TOP ALERTS COMBINED (h12_v5_1)
-- ============================================================================
-- PURPOSE:
--   Extract actionable alert lists for LOCKED_TEST, ranked by priority.
--   Generate separate lists for:
--   - Combined (all alerts, stable + difficult)
--   - Stable core only
--   - Difficult state only
--
--   Top K options: 50, 100, 200, 500, 1000
--
-- INPUTS:
--   - combined_oos_alerts_h12_v5_1_strict (Phase 5, LOCKED_TEST)
--
-- OUTPUTS:
--   - top_alerts_combined_h12_v5_1_strict (top-ranked alerts)
--
-- ANTI-LEAKAGE:
--   - Extraction only, no optimization
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict` AS

WITH

locked_test_alerts AS (
  SELECT *
  FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
    AND combined_oos_alert = TRUE
),

-- Rank all combined alerts by priority
ranked_alerts AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      ORDER BY 
        -- Priority: stable alerts first (proven policy), then difficult state
        CASE alert_source
          WHEN 'STABLE_CORE_POLICY_E1' THEN 1
          WHEN 'DIFFICULT_STATE_POLICY' THEN 2
          ELSE 3
        END,
        expected_lost_sales_if_oos DESC,
        audit_priority_score DESC,
        p_suspected_oos DESC
    ) AS global_alert_rank,
    
    -- Rank within alert source
    ROW_NUMBER() OVER (
      PARTITION BY alert_source
      ORDER BY 
        expected_lost_sales_if_oos DESC,
        audit_priority_score DESC,
        p_suspected_oos DESC
    ) AS source_alert_rank
    
  FROM locked_test_alerts
)

SELECT
  sku_id,
  decision_week,
  eval_split_v3,
  sku_season_state,
  season_group,
  
  -- Actuals
  y_true_12w,
  stockout_event_12w,
  
  -- Scores
  yhat_p50_v3_2_12w,
  p_suspected_oos,
  expected_lost_sales_if_oos,
  audit_priority_score,
  difficult_state_score,
  
  -- Alert details
  alert_source,
  is_stable_core_alert,
  is_difficult_state_alert,
  combined_oos_alert,
  
  -- Rankings
  global_alert_rank,
  source_alert_rank,
  
  -- Top-K flags
  global_alert_rank <= 50 AS is_top_50,
  global_alert_rank <= 100 AS is_top_100,
  global_alert_rank <= 200 AS is_top_200,
  global_alert_rank <= 500 AS is_top_500,
  global_alert_rank <= 1000 AS is_top_1000,
  
  -- Metadata
  CURRENT_TIMESTAMP() AS created_at_utc,
  'h12_v5_1_state_specific_oos_policy_strict' AS model_version,
  'Phase 8: Top combined alerts (LOCKED_TEST)' AS phase_description
  
FROM ranked_alerts
ORDER BY global_alert_rank;

-- ──────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ──────────────────────────────────────────────────────────────────────────
SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Phase 8 Complete: Top Alerts Extracted' AS status;
SELECT '════════════════════════════════════════════════════════════════' AS separator;

-- Alert counts by source
SELECT
  'Alert counts by source' AS check_name,
  alert_source,
  COUNT(*) AS n_alerts,
  COUNTIF(stockout_event_12w = 1) AS n_true_oos,
  ROUND(100.0 * COUNTIF(stockout_event_12w = 1) / COUNT(*), 2) AS precision_pct,
  SUM(expected_lost_sales_if_oos) AS total_els_at_risk
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`
GROUP BY alert_source
ORDER BY n_alerts DESC;

-- Top-K precision analysis
SELECT
  'Top-K precision analysis' AS check_name,
  'Top-50' AS top_k_group,
  COUNTIF(is_top_50) AS n_alerts,
  COUNTIF(is_top_50 AND stockout_event_12w = 1) AS n_true_oos,
  ROUND(100.0 * COUNTIF(is_top_50 AND stockout_event_12w = 1) / COUNTIF(is_top_50), 2) AS precision_pct
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`

UNION ALL

SELECT
  'Top-K precision analysis',
  'Top-100',
  COUNTIF(is_top_100),
  COUNTIF(is_top_100 AND stockout_event_12w = 1),
  ROUND(100.0 * COUNTIF(is_top_100 AND stockout_event_12w = 1) / COUNTIF(is_top_100), 2)
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`

UNION ALL

SELECT
  'Top-K precision analysis',
  'Top-200',
  COUNTIF(is_top_200),
  COUNTIF(is_top_200 AND stockout_event_12w = 1),
  ROUND(100.0 * COUNTIF(is_top_200 AND stockout_event_12w = 1) / COUNTIF(is_top_200), 2)
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`

UNION ALL

SELECT
  'Top-K precision analysis',
  'Top-500',
  COUNTIF(is_top_500),
  COUNTIF(is_top_500 AND stockout_event_12w = 1),
  ROUND(100.0 * COUNTIF(is_top_500 AND stockout_event_12w = 1) / COUNTIF(is_top_500), 2)
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`

ORDER BY n_alerts;

-- Top 10 alerts (sample)
SELECT
  'Top 10 alerts (sample)' AS check_name,
  global_alert_rank AS rank,
  alert_source,
  sku_season_state AS state,
  ROUND(p_suspected_oos, 3) AS p_susp,
  ROUND(expected_lost_sales_if_oos, 1) AS els,
  stockout_event_12w AS true_oos
FROM `thequantitativeledger.cruzber_models_eu.top_alerts_combined_h12_v5_1_strict`
WHERE is_top_50
ORDER BY global_alert_rank
LIMIT 10;

SELECT '════════════════════════════════════════════════════════════════' AS separator;
SELECT 'Next: Phase 99 will run comprehensive anti-leakage audit' AS next_step;
SELECT '════════════════════════════════════════════════════════════════' AS separator;
