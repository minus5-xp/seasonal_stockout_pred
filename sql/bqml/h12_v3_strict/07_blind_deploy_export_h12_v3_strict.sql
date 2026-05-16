-- ============================================================================
-- STEP 07: BLIND DEPLOY EXPORT  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Export LOCKED_TEST rows (W28-W40) with frozen decisions applied.
--   Labels are always NULL in the output (confirmed blind).
--   This is the deployment-ready forecast for weeks without ground truth.
--
-- ANTI-LEAKAGE GUARANTEES:
--   - y_true_12w        = NULL (always masked)
--   - stockout_event_12w = NULL (always masked)
--   - n_stockout_weeks_12w = NULL (always masked)
--   - Alert ranking uses frozen_policy (selected on DEV_SELECT).
--   - Probability used is frozen_probability_mode (selected on DEV_SELECT).
--   - No labels used to compute risk_score.
--   - labels_included = FALSE.
--
-- OUTPUT TABLES:
--   blind_deploy_export_h12_v3_strict
--   blind_deploy_leakage_check_h12_v3_strict
-- ============================================================================

-- ── 7a. BLIND DEPLOY EXPORT ───────────────────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_deploy_export_h12_v3_strict` AS
WITH
frozen_pol AS (
  SELECT policy AS selected_policy
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict`
  LIMIT 1
),
frozen_prob AS (
  SELECT selected_for_reporting AS prob_mode_reporting,
         selected_for_ranking   AS prob_mode_ranking
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`
  LIMIT 1
)
SELECT
  a.decision_week,
  a.iso_year,
  a.iso_week,
  a.target_start_week,
  a.target_end_week,
  a.sku_id,
  a.season_group,
  a.eval_split_v3,
  a.selected_policy,
  a.applied_prob_mode,
  -- Probabilities
  CASE fp.prob_mode_reporting
    WHEN 'RAW'        THEN c.p_oos_raw
    WHEN 'CALIBRATED' THEN c.p_oos_h12
    ELSE c.p_oos_h12
  END                                               AS p_oos_report,
  a.p_oos_rank                                      AS p_oos_rank,
  -- Quantile forecasts
  f.yhat_p50_12w,
  f.q80_12w,
  f.q90_12w,
  f.q95_12w,
  -- Risk score
  a.risk_score,
  a.alert_rank,
  -- LABELS ALWAYS NULL
  CAST(NULL AS FLOAT64)  AS y_true_12w,
  CAST(NULL AS INT64)    AS stockout_event_12w,
  CAST(NULL AS INT64)    AS n_stockout_weeks_12w,
  -- Metadata
  FALSE                  AS labels_included,
  TRUE                   AS is_locked_test,
  FALSE                  AS labels_used_in_scoring,
  fp.prob_mode_reporting,
  fp.prob_mode_ranking,
  'LOCKED_TEST_PENDING'  AS test_label_status,
  CURRENT_TIMESTAMP()    AS export_at
FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_locked_test_h12_v3_strict` a
JOIN `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  ON f.sku_id = a.sku_id AND f.decision_week = a.decision_week
JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
  ON c.sku_id = a.sku_id AND c.week_start_date = a.decision_week
CROSS JOIN frozen_prob fp
ORDER BY decision_week, alert_rank;

-- ── 7b. LEAKAGE CHECK ────────────────────────────────────────────────────
-- Verify that no labels were included in the blind export.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.blind_deploy_leakage_check_h12_v3_strict` AS
SELECT
  'blind_deploy_label_check'    AS check_name,
  COUNT(*)                      AS n_rows,
  COUNTIF(y_true_12w IS NOT NULL)      AS n_y_true_not_null,
  COUNTIF(stockout_event_12w IS NOT NULL) AS n_stockout_not_null,
  COUNTIF(labels_included = TRUE)      AS n_labels_included_true,
  CASE
    WHEN COUNTIF(y_true_12w IS NOT NULL) = 0
     AND COUNTIF(stockout_event_12w IS NOT NULL) = 0
     AND COUNTIF(labels_included = TRUE) = 0
    THEN 'PASS'
    ELSE 'FAIL — labels found in blind export'
  END AS verdict
FROM `{PROJECT_ID}.{BQ_DATASET}.blind_deploy_export_h12_v3_strict`;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.blind_deploy_leakage_check_h12_v3_strict`;

-- ── Summary ───────────────────────────────────────────────────────────────
SELECT
  decision_week,
  COUNT(DISTINCT sku_id)  AS n_skus,
  COUNTIF(alert_rank <= 100) AS n_top100_alerts,
  ROUND(AVG(p_oos_rank), 4)  AS avg_risk_prob,
  ROUND(MAX(risk_score), 3)  AS max_risk_score
FROM `{PROJECT_ID}.{BQ_DATASET}.blind_deploy_export_h12_v3_strict`
GROUP BY decision_week
ORDER BY decision_week;
