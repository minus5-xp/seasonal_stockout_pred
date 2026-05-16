-- ============================================================================
-- STEP 03: PROBABILITY MODE SELECTION — DEV_SELECT ONLY  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Compare p_oos_raw vs p_oos_h12 (Platt-calibrated) using Brier score,
--   log-loss, and rank correlation — exclusively on DEV_SELECT (W09-W16).
--
--   The winning probability is frozen in frozen_probability_mode_h12_v3_strict.
--   This decision is NEVER revisited on LOCKED_TEST.
--
-- POST-SELECTION BIAS FIX:
--   In h12_v2_final, probability_brier_comparison_h12_v2_final was computed
--   on VAL_GATE (W21-W27), and the selection was used to report metrics on
--   that same split → post-selection bias.
--   v3_strict: selection is made on DEV_SELECT (W09-W16), reported on nothing
--   until LOCKED_TEST where the decision is read-only.
--
-- OUTPUT TABLES:
--   probability_selection_dev_select_h12_v3_strict
--   probability_calibration_deciles_dev_select_h12_v3_strict
--   frozen_probability_mode_h12_v3_strict   ← FROZEN DECISION
-- ============================================================================

-- ── 3a. BRIER + CALIBRATION COMPARISON on DEV_SELECT ─────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_selection_dev_select_h12_v3_strict` AS
WITH dev_select_probs AS (
  SELECT
    c.sku_id,
    c.week_start_date,
    c.p_oos_raw,
    c.p_oos_h12                              AS p_oos_cal,
    CAST(b.stockout_event_12w AS FLOAT64)    AS actual_label
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = c.sku_id AND b.week_start_date = c.week_start_date
  -- DEV_SELECT filter (not VAL_GATE)
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = c.week_start_date
   AND tc.eval_split_v3 = 'DEV_SELECT'
  WHERE c.split = 'VAL'
    AND b.stockout_event_12w IS NOT NULL
    AND c.p_oos_raw IS NOT NULL
    AND c.p_oos_h12 IS NOT NULL
)
SELECT
  COUNT(*)                                                            AS n_rows,
  ROUND(AVG(CAST(actual_label AS FLOAT64)), 4)                       AS prevalence,
  -- Brier scores
  ROUND(AVG(POW(p_oos_raw - actual_label, 2)), 5)                    AS brier_raw,
  ROUND(AVG(POW(p_oos_cal - actual_label, 2)), 5)                    AS brier_calibrated,
  -- Mean predictions
  ROUND(AVG(p_oos_raw), 4)                                           AS mean_p_raw,
  ROUND(AVG(p_oos_cal), 4)                                           AS mean_p_cal,
  -- Log-loss (clipped to avoid log(0))
  ROUND(-AVG(
    actual_label * LN(GREATEST(p_oos_raw, 1e-7))
    + (1 - actual_label) * LN(GREATEST(1 - p_oos_raw, 1e-7))
  ), 5)                                                              AS logloss_raw,
  ROUND(-AVG(
    actual_label * LN(GREATEST(p_oos_cal, 1e-7))
    + (1 - actual_label) * LN(GREATEST(1 - p_oos_cal, 1e-7))
  ), 5)                                                              AS logloss_calibrated,
  -- Rank correlation with actual
  ROUND(CORR(p_oos_raw, actual_label), 4)                            AS corr_raw_vs_label,
  ROUND(CORR(p_oos_cal, actual_label), 4)                            AS corr_cal_vs_label,
  -- Selection rule:
  --   CALIBRATED wins if brier_cal <= brier_raw * 1.01 (1% tolerance)
  CASE
    WHEN AVG(POW(p_oos_cal - actual_label, 2))
         <= AVG(POW(p_oos_raw - actual_label, 2)) * 1.01
    THEN 'CALIBRATED'
    ELSE 'RAW'
  END                                                                AS selected_for_reporting,
  -- Ranking selection: whichever correlates more with actual
  CASE
    WHEN CORR(p_oos_cal, actual_label) >= CORR(p_oos_raw, actual_label)
    THEN 'CALIBRATED'
    ELSE 'RAW'
  END                                                                AS selected_for_ranking,
  -- Audit
  'DEV_SELECT' AS evaluated_on_split,
  FALSE        AS used_locked_test
FROM dev_select_probs;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_dev_select_h12_v3_strict`;

-- ── 3b. CALIBRATION DECILES on DEV_SELECT ────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_calibration_deciles_dev_select_h12_v3_strict` AS
WITH dev_select_probs AS (
  SELECT
    c.p_oos_raw,
    c.p_oos_h12 AS p_oos_cal,
    CAST(b.stockout_event_12w AS FLOAT64) AS actual_label,
    NTILE(10) OVER (ORDER BY c.p_oos_raw) AS decile_raw,
    NTILE(10) OVER (ORDER BY c.p_oos_h12) AS decile_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = c.sku_id AND b.week_start_date = c.week_start_date
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = c.week_start_date
   AND tc.eval_split_v3 = 'DEV_SELECT'
  WHERE c.split = 'VAL' AND b.stockout_event_12w IS NOT NULL
)
SELECT
  decile_raw AS decile,
  ROUND(AVG(p_oos_raw), 4)    AS avg_pred_raw,
  ROUND(AVG(p_oos_cal), 4)    AS avg_pred_cal,
  ROUND(AVG(actual_label), 4) AS avg_actual,
  COUNT(*)                     AS n
FROM dev_select_probs
GROUP BY decile_raw
ORDER BY decile_raw;

-- ── 3c. FROZEN PROBABILITY MODE ──────────────────────────────────────────
-- Single-row table. Never re-selected on LOCKED_TEST.
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict` AS
SELECT
  brier_raw,
  brier_calibrated,
  selected_for_reporting,
  selected_for_ranking,
  corr_raw_vs_label,
  corr_cal_vs_label,
  logloss_raw,
  logloss_calibrated,
  -- Brier of selected mode
  CASE selected_for_reporting
    WHEN 'RAW'        THEN brier_raw
    WHEN 'CALIBRATED' THEN brier_calibrated
  END                          AS brier_selected,
  -- Status
  CASE
    WHEN brier_raw IS NULL THEN 'UNKNOWN'
    WHEN CASE selected_for_reporting
           WHEN 'RAW'        THEN brier_raw
           WHEN 'CALIBRATED' THEN brier_calibrated
         END <= brier_raw * 1.01 THEN 'PASS'
    ELSE 'FAIL'
  END                          AS brier_gate_status,
  -- Audit
  'DEV_SELECT'  AS selected_using_split,
  FALSE         AS used_locked_test,
  CURRENT_TIMESTAMP() AS frozen_at,
  CONCAT(
    'Reporting=', selected_for_reporting,
    ', Ranking=', selected_for_ranking,
    ', brier_raw=', CAST(ROUND(brier_raw,5) AS STRING),
    ', brier_cal=', CAST(ROUND(brier_calibrated,5) AS STRING),
    ' | Selected on DEV_SELECT (W09-W16) — NOT on LOCKED_TEST'
  ) AS notes
FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_dev_select_h12_v3_strict`;

SELECT
  'frozen_probability_mode' AS table_name,
  selected_for_reporting, selected_for_ranking,
  brier_raw, brier_calibrated, brier_selected,
  brier_gate_status, selected_using_split, used_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`;
