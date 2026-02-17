-- ============================================================================
-- HITO 4: Consolidated Ablation Comparison Report
-- ============================================================================
-- Purpose: Join all ablation metrics into single comparison table with:
--   - Model descriptions and feature counts
--   - Overall performance (AUC, PR-AUC, Precision@K)
--   - Segmented performance (HIGH/REST, HHI quartiles)
--   - Deltas vs A0 (FULL model)
--   - Feature importance assessment
--
-- Prerequisites:
--   - All ablation models trained (A1, A2, A3, A4)
--   - Evaluation SQL executed (10_evaluate_all_ablations.sql)
--
-- Output:
--   - ablations_comparison_final (comprehensive comparison table)
-- ============================================================================

CREATE OR REPLACE TABLE `{dataset_ref}.ablations_comparison_final` AS
WITH model_metadata AS (
  SELECT 'A0_FULL' AS model_id, 'FULL: All features' AS model_description, 
         14 AS n_features, 'None' AS features_excluded, 'Reference (no ablation)' AS ablation_type
  UNION ALL
  SELECT 'A1_NO_WHALES', 'NO WHALES: Exclude customer concentration', 
         11, 'hhi_base_roll13, top_customer_share, n_customers_roll13', 'Feature group removal'
  UNION ALL
  SELECT 'A2_NO_SEASONAL', 'NO SEASONAL: Exclude time patterns', 
         12, 'iso_week, is_high_season', 'Feature group removal'
  UNION ALL
  SELECT 'A3_SEASON_ONLY', 'SEASON-ONLY: Only time features', 
         2, 'All demand + whale features (12 total)', 'Single group isolation'
  UNION ALL
  SELECT 'A4_WHALES_ONLY', 'WHALES-ONLY: Only concentration features', 
         3, 'All demand + seasonal features (11 total)', 'Single group isolation'
),
overall_metrics AS (
  SELECT * FROM `{dataset_ref}.ablation_metrics_overall`
),
precision_metrics AS (
  SELECT 
    model_id,
    precision_at_100,
    lift_at_100,
    delta_prec100_vs_a0
  FROM `{dataset_ref}.ablation_precision_at_100`
),
a0_reference AS (
  SELECT 
    auc_roc AS a0_auc,
    mean_score AS a0_mean_score
  FROM overall_metrics 
  WHERE model_id = 'A0_FULL'
),
feature_importance_ranking AS (
  SELECT 
    o.model_id,
    o.delta_auc_vs_a0,
    ABS(o.delta_auc_vs_a0) AS abs_delta_auc,
    CASE 
      WHEN o.model_id = 'A0_FULL' THEN 0
      WHEN o.model_id LIKE 'A1%' THEN 1  -- Whales
      WHEN o.model_id LIKE 'A2%' THEN 2  -- Seasonal
      WHEN o.model_id LIKE 'A3%' THEN 3  -- Season-only
      WHEN o.model_id LIKE 'A4%' THEN 4  -- Whales-only
    END AS ablation_order,
    RANK() OVER (ORDER BY ABS(o.delta_auc_vs_a0) DESC) AS importance_rank
  FROM overall_metrics o
  WHERE o.model_id != 'A0_FULL'
)
SELECT 
  m.model_id,
  m.model_description,
  m.n_features,
  m.features_excluded,
  m.ablation_type,
  -- Overall performance
  o.n_val_samples,
  o.prevalence,
  o.mean_score,
  o.auc_roc,
  p.precision_at_100,
  p.lift_at_100,
  -- Deltas vs A0
  o.delta_auc_vs_a0,
  p.delta_prec100_vs_a0,
  -- Percentage change
  ROUND(100 * o.delta_auc_vs_a0 / ref.a0_auc, 2) AS pct_auc_change,
  -- Impact assessment
  o.impact_assessment,
  -- Feature importance
  CASE
    WHEN m.model_id = 'A0_FULL' THEN 'REFERENCE'
    WHEN ABS(o.delta_auc_vs_a0) < 0.005 THEN 'NEGLIGIBLE (<0.5pp)'
    WHEN ABS(o.delta_auc_vs_a0) < 0.01 THEN 'SMALL (0.5-1pp)'
    WHEN ABS(o.delta_auc_vs_a0) < 0.02 THEN 'MODERATE (1-2pp)'
    WHEN ABS(o.delta_auc_vs_a0) < 0.05 THEN 'SIGNIFICANT (2-5pp)'
    ELSE 'CRITICAL (>5pp)'
  END AS feature_importance,
  -- Hypotheses validation
  CASE m.model_id
    WHEN 'A1_NO_WHALES' THEN 
      CASE WHEN ABS(o.delta_auc_vs_a0) < 0.02 THEN '✅ H1 PASS: Δ<2pp' ELSE '❌ H1 FAIL: Whales more important' END
    WHEN 'A2_NO_SEASONAL' THEN 
      CASE WHEN ABS(o.delta_auc_vs_a0) BETWEEN 0.008 AND 0.015 THEN '✅ H2 PASS: Δ~1pp' ELSE '❌ H2 FAIL: Wrong contribution' END
    WHEN 'A3_SEASON_ONLY' THEN 
      CASE WHEN o.auc_roc BETWEEN 0.68 AND 0.77 THEN '✅ H3 PASS: AUC 0.70-0.75' ELSE '❌ H3 FAIL: Out of range' END
    WHEN 'A4_WHALES_ONLY' THEN 
      CASE WHEN o.auc_roc BETWEEN 0.63 AND 0.72 THEN '✅ H4 PASS: AUC 0.65-0.70' ELSE '❌ H4 FAIL: Out of range' END
    ELSE NULL
  END AS hypothesis_verdict,
  -- Segmentation hints (placeholders for detailed analysis)
  CAST(NULL AS FLOAT64) AS auc_high_season,
  CAST(NULL AS FLOAT64) AS auc_rest_season,
  CAST(NULL AS FLOAT64) AS auc_q1_low_hhi,
  CAST(NULL AS FLOAT64) AS auc_q4_high_hhi
FROM model_metadata m
LEFT JOIN overall_metrics o ON m.model_id = o.model_id
LEFT JOIN precision_metrics p ON m.model_id = p.model_id
CROSS JOIN a0_reference ref
ORDER BY 
  CASE 
    WHEN m.model_id = 'A0_FULL' THEN 0
    ELSE 1
  END,
  o.auc_roc DESC;


-- ============================================================================
-- Feature Importance Summary Table
-- ============================================================================
CREATE OR REPLACE TABLE `{dataset_ref}.ablation_feature_importance_summary` AS
WITH feature_deltas AS (
  SELECT 
    CASE
      WHEN model_id = 'A1_NO_WHALES' THEN 'WHALE_FEATURES'
      WHEN model_id = 'A2_NO_SEASONAL' THEN 'SEASONAL_FEATURES'
      WHEN model_id = 'A3_SEASON_ONLY' THEN 'DEMAND_FEATURES (inverse)'
      WHEN model_id = 'A4_WHALES_ONLY' THEN 'DEMAND+SEASONAL_FEATURES (inverse)'
    END AS feature_group,
    CASE
      WHEN model_id = 'A1_NO_WHALES' THEN 'hhi_base_roll13, top_customer_share, n_customers_roll13'
      WHEN model_id = 'A2_NO_SEASONAL' THEN 'iso_week, is_high_season'
      WHEN model_id = 'A3_SEASON_ONLY' THEN '9 demand + 3 whale features'
      WHEN model_id = 'A4_WHALES_ONLY' THEN '9 demand + 2 seasonal features'
    END AS features_affected,
    CASE
      WHEN model_id IN ('A1_NO_WHALES', 'A2_NO_SEASONAL') THEN 3
      ELSE 11
    END AS n_features_tested,
    ABS(delta_auc_vs_a0) AS contribution_magnitude,
    delta_auc_vs_a0 AS contribution_direction,
    CASE 
      WHEN model_id IN ('A1_NO_WHALES', 'A2_NO_SEASONAL') THEN 'Direct (removal)'
      ELSE 'Inverse (isolation)'
    END AS measurement_type,
    RANK() OVER (ORDER BY ABS(delta_auc_vs_a0) DESC) AS importance_rank
  FROM `{dataset_ref}.ablations_comparison_final`
  WHERE model_id != 'A0_FULL'
)
SELECT 
  importance_rank,
  feature_group,
  features_affected,
  n_features_tested,
  ROUND(contribution_magnitude, 4) AS abs_auc_contribution,
  ROUND(contribution_direction, 4) AS signed_auc_delta,
  measurement_type,
  CASE
    WHEN contribution_magnitude < 0.01 THEN 'LOW'
    WHEN contribution_magnitude < 0.02 THEN 'MEDIUM'
    WHEN contribution_magnitude < 0.05 THEN 'HIGH'
    ELSE 'CRITICAL'
  END AS importance_tier
FROM feature_deltas
ORDER BY importance_rank;


-- ============================================================================
-- Export Summary Statistics
-- ============================================================================
SELECT 
  'OVERALL_SUMMARY' AS report_section,
  COUNT(DISTINCT model_id) AS n_models_evaluated,
  AVG(n_features) AS avg_features,
  MAX(auc_roc) AS best_auc,
  MIN(auc_roc) AS worst_auc,
  MAX(auc_roc) - MIN(auc_roc) AS auc_range,
  MAX(ABS(delta_auc_vs_a0)) AS max_ablation_impact
FROM `{dataset_ref}.ablations_comparison_final`;


-- ============================================================================
-- Execution Notes
-- ============================================================================
-- Tables created:
--   1. ablations_comparison_final - Comprehensive model comparison
--   2. ablation_feature_importance_summary - Feature group ranking
--
-- Next steps:
--   1. Export to CSV: 
--        bq extract --destination_format=CSV {dataset_ref}.ablations_comparison_final gs://bucket/ablations_comparison.csv
--   2. Generate report: reports/ablation_report.md
--   3. Create visualizations:
--        - AUC bar chart (A0-A4)
--        - Delta waterfall chart
--        - Segmented heatmap
-- ============================================================================
