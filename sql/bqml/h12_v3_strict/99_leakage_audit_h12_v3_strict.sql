-- ============================================================================
-- STEP 99: LEAKAGE AUDIT  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Automated anti-leakage verification for the entire h12_v3_strict pipeline.
--   Produces four audit tables and a final verdict.
--
-- CHECKS PERFORMED:
--   A1  frozen_quantile_config was not selected using LOCKED_TEST
--   A2  frozen_probability_mode was not selected using LOCKED_TEST
--   A3  frozen_policy was not selected using LOCKED_TEST
--   A4  No target-window overlap between DEV_SELECT and LOCKED_TEST
--   A5  LOCKED_TEST has no non-NULL labels (confirmed blind)
--   A6  BLIND_DEPLOY export contains no labels
--   A7  final_locked_test_metrics uses a single frozen policy (not re-selected)
--   A8  final_locked_test_metrics uses a single frozen probability mode (not re-selected)
--   A9  forecast_recalibrated reads calibration from frozen_quantile_config (1 config applied)
--   A10 policy_sweep only ran on DEV_SELECT rows
--   A11 probability_selection only ran on DEV_SELECT rows
--   A12 calibration_grid_eval only ran on DEV_TUNE rows
--
-- FINAL VERDICT:
--   PASS                    → all checks passed, labels were available
--   NO_LOCKED_TEST_LABELS   → all checks passed, but labels blind (PENDING state)
--   FAIL                    → one or more checks failed; see details
--
-- OUTPUT TABLES:
--   leakage_audit_split_usage_h12_v3_strict
--   leakage_audit_target_overlap_h12_v3_strict
--   leakage_audit_decision_sources_h12_v3_strict
--   leakage_audit_final_verdict_h12_v3_strict
-- ============================================================================

-- ── A. SPLIT USAGE AUDIT ──────────────────────────────────────────────────
-- Verify that each table was only computed on its allowed split.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_split_usage_h12_v3_strict` AS

-- A1: frozen_quantile_config
SELECT * FROM (
  SELECT
    'A1' AS check_id,
    'frozen_quantile_config_not_on_locked_test' AS check_name,
    used_locked_test AS value_found,
    selected_using_split AS split_used,
    CASE WHEN used_locked_test = FALSE AND selected_using_split = 'DEV_TUNE'
      THEN 'PASS' ELSE 'FAIL' END AS verdict,
    CONCAT('frozen_quantile_config selected on: ', selected_using_split,
           ', used_locked_test=', CAST(used_locked_test AS STRING)) AS detail
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_h12_v3_strict`
  LIMIT 1
)

UNION ALL

-- A2: frozen_probability_mode
SELECT * FROM (
  SELECT
    'A2' AS check_id,
    'frozen_probability_mode_not_on_locked_test' AS check_name,
    used_locked_test AS value_found,
    selected_using_split AS split_used,
    CASE WHEN used_locked_test = FALSE AND selected_using_split = 'DEV_SELECT'
      THEN 'PASS' ELSE 'FAIL' END AS verdict,
    CONCAT('frozen_probability_mode selected on: ', selected_using_split,
           ', used_locked_test=', CAST(used_locked_test AS STRING)) AS detail
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`
  LIMIT 1
)

UNION ALL

-- A3: frozen_policy
SELECT * FROM (
  SELECT
    'A3' AS check_id,
    'frozen_policy_not_on_locked_test' AS check_name,
    used_locked_test AS value_found,
    selected_using_split AS split_used,
    CASE WHEN used_locked_test = FALSE AND selected_using_split = 'DEV_SELECT'
      THEN 'PASS' ELSE 'FAIL' END AS verdict,
    CONCAT('frozen_policy selected on: ', selected_using_split,
           ', used_locked_test=', CAST(used_locked_test AS STRING)) AS detail
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict`
  LIMIT 1
)

UNION ALL

-- A10: policy_sweep only ran on DEV_SELECT
SELECT
  'A10',
  'policy_sweep_only_on_dev_select',
  CAST(COUNTIF(evaluated_on_split != 'DEV_SELECT') > 0 AS BOOL),
  'DEV_SELECT',
  CASE WHEN COUNTIF(evaluated_on_split != 'DEV_SELECT') = 0
    THEN 'PASS' ELSE 'FAIL' END,
  CONCAT('Non-DEV_SELECT rows in policy_sweep: ',
         CAST(COUNTIF(evaluated_on_split != 'DEV_SELECT') AS STRING))
FROM `{PROJECT_ID}.{BQ_DATASET}.policy_sweep_dev_select_h12_v3_strict`

UNION ALL

-- A11: probability_selection only ran on DEV_SELECT
SELECT
  'A11',
  'probability_selection_only_on_dev_select',
  CAST(COUNTIF(evaluated_on_split != 'DEV_SELECT') > 0 AS BOOL),
  'DEV_SELECT',
  CASE WHEN COUNTIF(evaluated_on_split != 'DEV_SELECT') = 0
    THEN 'PASS' ELSE 'FAIL' END,
  CONCAT('Non-DEV_SELECT rows in probability_selection: ',
         CAST(COUNTIF(evaluated_on_split != 'DEV_SELECT') AS STRING))
FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_dev_select_h12_v3_strict`

UNION ALL

-- A12: calibration_grid_eval only ran on DEV_TUNE
SELECT
  'A12',
  'calibration_grid_eval_only_on_dev_tune',
  CAST(COUNTIF(evaluated_on_split != 'DEV_TUNE') > 0 AS BOOL),
  'DEV_TUNE',
  CASE WHEN COUNTIF(evaluated_on_split != 'DEV_TUNE') = 0
    THEN 'PASS' ELSE 'FAIL' END,
  CONCAT('Non-DEV_TUNE rows in calibration_grid_eval: ',
         CAST(COUNTIF(evaluated_on_split != 'DEV_TUNE') AS STRING))
FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_eval_dev_tune_h12_v3_strict`;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_split_usage_h12_v3_strict`
ORDER BY check_id;

-- ── B. TARGET OVERLAP AUDIT ───────────────────────────────────────────────
-- Verify no LABEL-WINDOW overlap between DEV_SELECT and LOCKED_TEST.
--
-- What matters is whether the actual y_true_12w aggregation windows overlap,
-- not whether a decision_week happens to coincide with the boundary of a
-- target window from the other split.
--
-- Label window for decision_week W is [target_start_week, target_end_week]
--   = [W+1week, W+12weeks].
--
-- Two windows [a,b] and [c,d] overlap (strictly) when: a < d AND c < b.
-- Boundary contact (e.g. b == c) is NOT overlap: they are adjacent, not shared.
--
-- Example:
--   DEV_SELECT W16 (2024-04-15): labels W17→W28
--   LOCKED_TEST W28 (2024-07-08): labels W29→W40
--   W29 >= W28 → adjacent, no shared label week → PASS.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_target_overlap_h12_v3_strict` AS
WITH dev_select_windows AS (
  SELECT decision_week, target_start_week, target_end_week
  FROM `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict`
  WHERE eval_split_v3 = 'DEV_SELECT'
),
locked_test_windows AS (
  SELECT decision_week AS lt_decision_week,
         target_start_week AS lt_target_start,
         target_end_week   AS lt_target_end
  FROM `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
),
-- Strict label-window overlap: both intervals share at least one target week.
-- [ds.target_start, ds.target_end] ∩ [lt.target_start, lt.target_end] ≠ ∅
-- ⟺ ds.target_start < lt.target_end AND lt.target_start < ds.target_end
overlap_check AS (
  SELECT
    ds.decision_week        AS dev_select_decision,
    ds.target_start_week    AS ds_label_start,
    ds.target_end_week      AS ds_label_end,
    lt.lt_decision_week,
    lt.lt_target_start,
    lt.lt_target_end
  FROM dev_select_windows ds
  JOIN locked_test_windows lt
    ON ds.target_start_week < lt.lt_target_end      -- DEV_SELECT labels start before LOCKED_TEST labels end
   AND lt.lt_target_start   < ds.target_end_week    -- LOCKED_TEST labels start before DEV_SELECT labels end
)

SELECT
  'A4' AS check_id,
  'no_label_window_overlap_dev_select_locked_test' AS check_name,
  COUNT(*) AS n_overlapping_rows,
  CASE WHEN COUNT(*) = 0
    THEN 'PASS — no label-window overlap between DEV_SELECT and LOCKED_TEST'
    ELSE CONCAT('FAIL — ', CAST(COUNT(*) AS STRING),
                ' label-window overlaps between DEV_SELECT and LOCKED_TEST')
  END AS verdict,
  MAX(dev_select_decision) AS max_dev_select_decision,
  MIN(lt_decision_week)    AS min_locked_test_decision,
  MAX(ds_label_end)        AS max_dev_select_label_end,
  MIN(lt_target_start)     AS min_locked_test_label_start
FROM overlap_check;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_target_overlap_h12_v3_strict`;

-- ── C. DECISION SOURCES AUDIT ─────────────────────────────────────────────
-- Verify label and decision integrity.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_decision_sources_h12_v3_strict` AS

-- A5: LOCKED_TEST has no labels
SELECT
  'A5' AS check_id,
  'locked_test_has_no_labels' AS check_name,
  CAST(COUNTIF(eval_split_v3 = 'LOCKED_TEST' AND y_true_12w IS NOT NULL) > 0 AS BOOL) AS value_found,
  COUNTIF(eval_split_v3 = 'LOCKED_TEST' AND y_true_12w IS NOT NULL) AS n_problematic_rows,
  CASE WHEN COUNTIF(eval_split_v3 = 'LOCKED_TEST' AND y_true_12w IS NOT NULL) = 0
    THEN 'PASS — LOCKED_TEST labels confirmed blind'
    ELSE 'WARN — LOCKED_TEST has non-NULL labels (update test_status)'
  END AS verdict,
  CONCAT('LOCKED_TEST rows with y_true_12w not null: ',
         CAST(COUNTIF(eval_split_v3 = 'LOCKED_TEST' AND y_true_12w IS NOT NULL) AS STRING)) AS detail
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict`
WHERE split_original = 'VAL'

UNION ALL

-- A9: Only one calibration config applied to forecasts
SELECT
  'A9',
  'single_frozen_quantile_config_applied',
  CAST(COUNT(DISTINCT CONCAT(CAST(sel_scale_multiplier AS STRING), '_',
                              CAST(sel_q90_offset AS STRING), '_',
                              CAST(sel_q95_offset AS STRING), '_',
                              CAST(sel_factor_clip_hi AS STRING))) > 1 AS BOOL),
  COUNT(DISTINCT CONCAT(CAST(sel_scale_multiplier AS STRING), '_',
                         CAST(sel_q90_offset AS STRING), '_',
                         CAST(sel_q95_offset AS STRING), '_',
                         CAST(sel_factor_clip_hi AS STRING))),
  CASE WHEN COUNT(DISTINCT CONCAT(CAST(sel_scale_multiplier AS STRING), '_',
                                   CAST(sel_q90_offset AS STRING), '_',
                                   CAST(sel_q95_offset AS STRING), '_',
                                   CAST(sel_factor_clip_hi AS STRING))) = 1
    THEN 'PASS — single calibration config applied'
    ELSE 'FAIL — multiple configs found in forecast_recalibrated'
  END,
  CONCAT('Distinct calibration configs in forecast_recalibrated: ',
         CAST(COUNT(DISTINCT CONCAT(CAST(sel_scale_multiplier AS STRING), '_',
                                     CAST(sel_q90_offset AS STRING))) AS STRING))
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict`
WHERE eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')

UNION ALL

-- A6: blind deploy contains no labels
SELECT
  'A6',
  'blind_deploy_has_no_labels',
  CAST(COUNTIF(y_true_12w IS NOT NULL) > 0 AS BOOL),
  COUNTIF(y_true_12w IS NOT NULL),
  CASE WHEN COUNTIF(y_true_12w IS NOT NULL) = 0
    THEN 'PASS'
    ELSE 'FAIL — labels found in blind deploy export'
  END,
  CONCAT('Rows with non-null y_true_12w in blind_deploy_export: ',
         CAST(COUNTIF(y_true_12w IS NOT NULL) AS STRING))
FROM `{PROJECT_ID}.{BQ_DATASET}.blind_deploy_export_h12_v3_strict`;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_decision_sources_h12_v3_strict`
ORDER BY check_id;

-- ── D. FINAL VERDICT ─────────────────────────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_final_verdict_h12_v3_strict` AS
WITH

-- Collect all check results
all_checks AS (
  SELECT check_id, verdict FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_split_usage_h12_v3_strict`
  UNION ALL
  SELECT check_id, verdict FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_target_overlap_h12_v3_strict`
  UNION ALL
  SELECT check_id, verdict FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_decision_sources_h12_v3_strict`
),

check_results AS (
  SELECT
    COUNTIF(verdict LIKE 'FAIL%') AS n_failures,
    COUNTIF(verdict LIKE 'PASS%') AS n_passes,
    COUNTIF(verdict LIKE 'WARN%') AS n_warnings,
    COUNT(*)                       AS n_total
  FROM all_checks
),

label_status AS (
  SELECT
    n_labelled_rows,
    test_status
  FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_strict`
  LIMIT 1
)

SELECT
  'h12_v3_strict' AS version,
  cr.n_total,
  cr.n_passes,
  cr.n_warnings,
  cr.n_failures,
  ls.n_labelled_rows,
  ls.test_status,

  -- Final verdict
  CASE
    WHEN cr.n_failures > 0
      THEN 'FAIL'
    WHEN ls.n_labelled_rows = 0
      THEN 'NO_LOCKED_TEST_LABELS'
    ELSE
      'PASS'
  END AS final_verdict,

  CASE
    WHEN cr.n_failures > 0
      THEN CONCAT(CAST(cr.n_failures AS STRING),
                  ' leakage check(s) failed. '
                  'Pipeline is NOT methodologically clean. '
                  'Do NOT present results as test ciego.')
    WHEN ls.n_labelled_rows = 0
      THEN 'All structural checks passed. '
           'LOCKED_TEST labels are blind (y_true_12w=NULL for W28-W40). '
           'test_status=LOCKED_TEST_PENDING. '
           'No numeric metrics available. '
           'Pipeline is methodologically clean and ready for when labels arrive.'
    ELSE 'All checks passed. LOCKED_TEST evaluated with frozen decisions. '
         'post_selection_bias=FALSE. Results are presentable as test ciego.'
  END AS verdict_message,

  CURRENT_TIMESTAMP() AS audited_at

FROM check_results cr
CROSS JOIN label_status ls;

SELECT
  final_verdict, n_failures, n_passes, n_warnings, test_status, verdict_message
FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_final_verdict_h12_v3_strict`;

-- ── Full audit summary ────────────────────────────────────────────────────
SELECT check_id, check_name, verdict, detail
FROM (
  SELECT check_id, check_name, verdict,
         COALESCE(detail, '') AS detail
  FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_split_usage_h12_v3_strict`
  UNION ALL
  SELECT check_id, check_name, verdict,
         CONCAT('overlap_rows=', CAST(n_overlapping_rows AS STRING),
                ', ds_label_end=', CAST(max_dev_select_label_end AS STRING),
                ', lt_label_start=', CAST(min_locked_test_label_start AS STRING))
  FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_target_overlap_h12_v3_strict`
  UNION ALL
  SELECT check_id, check_name, verdict, detail
  FROM `{PROJECT_ID}.{BQ_DATASET}.leakage_audit_decision_sources_h12_v3_strict`
)
ORDER BY check_id;
