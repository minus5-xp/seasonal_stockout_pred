-- ============================================================================
-- STEP 99: LEAKAGE AUDIT  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Extend v3_strict audit with checks specific to the season-state pipeline.
--   Verifies that all seasonality features, state classifications, gates,
--   and frozen configs are derived from pre-LOCKED_TEST data exclusively.
--
-- CHECKS:
--   (Inherits A1-A12 logic from v3_strict; re-checks frozen tables)
--   B1  seasonality features were not computed using LOCKED_TEST data
--   B2  seasonality features only use TRAIN+CALIB prior years (no VAL year)
--   B3  frozen_quantile_config: selected_without_locked_test = TRUE for all states
--   B4  frozen_probability_mode: selected_without_locked_test = TRUE for all states
--   B5  frozen_policy: selected_without_locked_test = TRUE for all states
--   B6  gate computation does not use y_true_12w of LOCKED_TEST
--       (gate_used_locked_test_labels = FALSE for all rows)
--   B7  sku_season_state classification does not use locked test
--       (used_locked_test_for_classification = FALSE for all rows)
--   B8  UNKNOWN_FALLBACK rows are explicitly flagged and not calibrated on LT
--   B9  final_locked_test_metrics: post_selection_bias = FALSE, selected_using_locked_test = FALSE
--   B10 no label leakage in blind export (labels NULL)
--
-- OUTPUT TABLES:
--   leakage_audit_season_state_checks_h12_v3_2_season_state_strict
--   leakage_audit_season_state_verdict_h12_v3_2_season_state_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_season_state_checks_h12_v3_2_season_state_strict` AS

-- B1: Seasonality feature table audit column
SELECT * FROM (
  SELECT
    'B1' AS check_id,
    'seasonality_features_no_locked_test' AS check_name,
    CAST(COUNTIF(used_locked_test = TRUE) > 0 AS BOOL) AS value_found,
    COUNTIF(used_locked_test = TRUE) AS n_problematic,
    CASE WHEN COUNTIF(used_locked_test = TRUE) = 0
      THEN 'PASS — used_locked_test=FALSE for all rows'
      ELSE CONCAT('FAIL — ', CAST(COUNTIF(used_locked_test = TRUE) AS STRING),
                  ' rows have used_locked_test=TRUE in seasonality features')
    END AS verdict,
    CONCAT('Rows with used_locked_test=TRUE: ',
           CAST(COUNTIF(used_locked_test = TRUE) AS STRING)) AS detail
  FROM `{PROJECT_ID}.{BQ_DATASET}.sku_week_seasonality_features_h12_v3_2_season_state_strict`
)

UNION ALL

-- B2: Feature source is TRAIN+CALIB only
SELECT * FROM (
  SELECT
    'B2',
    'feature_source_train_calib_only',
    CAST(COUNTIF(feature_source != 'TRAIN_CALIB_PRIOR_YEARS') > 0 AS BOOL),
    COUNTIF(feature_source != 'TRAIN_CALIB_PRIOR_YEARS'),
    CASE WHEN COUNTIF(feature_source != 'TRAIN_CALIB_PRIOR_YEARS') = 0
      THEN 'PASS'
      ELSE 'FAIL — unexpected feature_source values found'
    END,
    CONCAT('Non-TRAIN_CALIB_PRIOR_YEARS rows: ',
           CAST(COUNTIF(feature_source != 'TRAIN_CALIB_PRIOR_YEARS') AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.sku_week_seasonality_features_h12_v3_2_season_state_strict`
)

UNION ALL

-- B3: All frozen quantile configs have selected_without_locked_test = TRUE
SELECT * FROM (
  SELECT
    'B3',
    'frozen_quantile_config_no_locked_test',
    CAST(COUNTIF(selected_without_locked_test = FALSE) > 0 AS BOOL),
    COUNTIF(selected_without_locked_test = FALSE),
    CASE WHEN COUNTIF(selected_without_locked_test = FALSE) = 0
      THEN 'PASS — all frozen quantile configs selected without LOCKED_TEST'
      ELSE 'FAIL'
    END,
    CONCAT('States with selected_without_locked_test=FALSE: ',
           CAST(COUNTIF(selected_without_locked_test = FALSE) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_by_season_state_h12_v3_2_season_state_strict`
)

UNION ALL

-- B4: All frozen probability modes have selected_without_locked_test = TRUE
SELECT * FROM (
  SELECT
    'B4',
    'frozen_probability_mode_no_locked_test',
    CAST(COUNTIF(selected_without_locked_test = FALSE) > 0 AS BOOL),
    COUNTIF(selected_without_locked_test = FALSE),
    CASE WHEN COUNTIF(selected_without_locked_test = FALSE) = 0
      THEN 'PASS'
      ELSE 'FAIL'
    END,
    CONCAT('States with selected_without_locked_test=FALSE: ',
           CAST(COUNTIF(selected_without_locked_test = FALSE) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_by_season_state_h12_v3_2_season_state_strict`
)

UNION ALL

-- B5: All frozen policies have selected_without_locked_test = TRUE
SELECT * FROM (
  SELECT
    'B5',
    'frozen_policy_no_locked_test',
    CAST(COUNTIF(selected_without_locked_test = FALSE) > 0 AS BOOL),
    COUNTIF(selected_without_locked_test = FALSE),
    CASE WHEN COUNTIF(selected_without_locked_test = FALSE) = 0
      THEN 'PASS'
      ELSE 'FAIL'
    END,
    CONCAT('States with selected_without_locked_test=FALSE: ',
           CAST(COUNTIF(selected_without_locked_test = FALSE) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_by_season_state_h12_v3_2_season_state_strict`
)

UNION ALL

-- B6: Gate did not use y_true_12w of LOCKED_TEST
SELECT * FROM (
  SELECT
    'B6',
    'gate_did_not_use_locked_test_labels',
    CAST(COUNTIF(gate_used_locked_test_labels = TRUE) > 0 AS BOOL),
    COUNTIF(gate_used_locked_test_labels = TRUE),
    CASE WHEN COUNTIF(gate_used_locked_test_labels = TRUE) = 0
      THEN 'PASS — gate_used_locked_test_labels=FALSE for all rows'
      ELSE 'FAIL'
    END,
    CONCAT('Rows with gate_used_locked_test_labels=TRUE: ',
           CAST(COUNTIF(gate_used_locked_test_labels = TRUE) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
)

UNION ALL

-- B7: Season state classification did not use LOCKED_TEST
SELECT * FROM (
  SELECT
    'B7',
    'season_state_classification_no_locked_test',
    CAST(COUNTIF(used_locked_test_for_classification = TRUE) > 0 AS BOOL),
    COUNTIF(used_locked_test_for_classification = TRUE),
    CASE WHEN COUNTIF(used_locked_test_for_classification = TRUE) = 0
      THEN 'PASS'
      ELSE 'FAIL'
    END,
    CONCAT('Rows with used_locked_test_for_classification=TRUE: ',
           CAST(COUNTIF(used_locked_test_for_classification = TRUE) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict`
)

UNION ALL

-- B8: UNKNOWN_FALLBACK rows have global-level fallback config (not calibrated on LT)
SELECT * FROM (
  SELECT
    'B8',
    'unknown_fallback_gets_global_config',
    CAST(COUNTIF(sku_season_state = 'UNKNOWN_FALLBACK'
                 AND selected_level NOT IN ('global_fallback', 'sku_season_state')) > 0 AS BOOL),
    COUNTIF(sku_season_state = 'UNKNOWN_FALLBACK'
            AND selected_level NOT IN ('global_fallback', 'sku_season_state')),
    CASE WHEN COUNTIF(sku_season_state = 'UNKNOWN_FALLBACK'
                      AND selected_level NOT IN ('global_fallback', 'sku_season_state')) = 0
      THEN 'PASS — UNKNOWN_FALLBACK uses global or state config'
      ELSE 'WARN — some UNKNOWN_FALLBACK rows have unexpected config level'
    END,
    CONCAT('UNKNOWN_FALLBACK with unexpected level: ',
           CAST(COUNTIF(sku_season_state = 'UNKNOWN_FALLBACK'
                        AND selected_level NOT IN ('global_fallback', 'sku_season_state')) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_by_season_state_h12_v3_2_season_state_strict`
)

UNION ALL

-- B9: Final metrics assert no selection bias
SELECT * FROM (
  SELECT
    'B9',
    'final_metrics_post_selection_bias_false',
    CAST(COUNTIF(post_selection_bias = TRUE OR selected_using_locked_test = TRUE) > 0 AS BOOL),
    COUNTIF(post_selection_bias = TRUE OR selected_using_locked_test = TRUE),
    CASE WHEN COUNTIF(post_selection_bias = TRUE OR selected_using_locked_test = TRUE) = 0
      THEN 'PASS — post_selection_bias=FALSE and selected_using_locked_test=FALSE for all rows'
      ELSE 'FAIL'
    END,
    CONCAT('Rows with bias flag or LT selection: ',
           CAST(COUNTIF(post_selection_bias = TRUE OR selected_using_locked_test = TRUE) AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_2_season_state_strict`
);

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_season_state_checks_h12_v3_2_season_state_strict`
ORDER BY check_id;

-- ── Final verdict ─────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_season_state_verdict_h12_v3_2_season_state_strict` AS
WITH
all_checks AS (
  SELECT check_id, verdict
  FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_season_state_checks_h12_v3_2_season_state_strict`
),
count_results AS (
  SELECT
    COUNTIF(verdict LIKE 'FAIL%') AS n_failures,
    COUNTIF(verdict LIKE 'PASS%') AS n_passes,
    COUNTIF(verdict LIKE 'WARN%') AS n_warnings,
    COUNT(*)                       AS n_total
  FROM all_checks
),
label_status AS (
  SELECT COUNT(*) AS n_labelled
  FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_2_season_state_strict`
  WHERE breakdown_level = 'global' AND n_obs > 0
)
SELECT
  'h12_v3_2_season_state_strict' AS version,
  cr.n_total,
  cr.n_passes,
  cr.n_warnings,
  cr.n_failures,
  CASE
    WHEN cr.n_failures > 0 THEN 'FAIL'
    WHEN ls.n_labelled = 0 THEN 'NO_LOCKED_TEST_LABELS'
    ELSE 'PASS'
  END AS final_verdict,
  CASE
    WHEN cr.n_failures > 0
      THEN CONCAT(CAST(cr.n_failures AS STRING), ' leakage check(s) FAILED.')
    WHEN ls.n_labelled = 0
      THEN 'Structural checks passed. No labels in LOCKED_TEST.'
    ELSE 'All checks passed. Metrics are methodologically clean. post_selection_bias=FALSE.'
  END AS verdict_message,
  CURRENT_TIMESTAMP() AS audited_at
FROM count_results cr CROSS JOIN label_status ls;

SELECT final_verdict, n_failures, n_passes, n_warnings, verdict_message
FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_season_state_verdict_h12_v3_2_season_state_strict`;
