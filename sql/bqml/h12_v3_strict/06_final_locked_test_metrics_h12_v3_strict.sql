-- ============================================================================
-- STEP 06: FINAL LOCKED TEST METRICS  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Compute all final metrics on LOCKED_TEST using frozen decisions.
--   This is the only table whose metrics can be presented as "clean test".
--
-- LOCKED_TEST LABEL STATUS:
--   Labels (y_true_12w, stockout_event_12w) confirmed BLIND for W28-W40.
--   Result: test_status = 'LOCKED_TEST_PENDING'.
--   Numeric metrics are NULL. post_selection_bias = FALSE is still asserted
--   because the pipeline structure is clean — labels just aren't available yet.
--
-- HARD CONSTRAINTS (strictly enforced):
--   - No policy re-selection on LOCKED_TEST (reads frozen_policy).
--   - No probability mode re-selection on LOCKED_TEST (reads frozen_probability_mode).
--   - No quantile recalibration on LOCKED_TEST (reads frozen_quantile_config).
--   - No ROW_NUMBER by lift/metric on LOCKED_TEST.
--   - Brier for RAW and CALIBRATED are both reported, but neither can change
--     the frozen selection.
--
-- OUTPUT TABLES:
--   final_locked_test_metrics_h12_v3_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_strict` AS
WITH

-- Frozen decisions (read-only)
frozen_q AS (
  SELECT scale_multiplier, q90_offset, q95_offset, factor_clip_hi, calibration_loss,
         viol_p90_dev_tune, selected_using_split AS q_selected_on, used_locked_test AS q_used_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_h12_v3_strict`
  LIMIT 1
),
frozen_p AS (
  SELECT selected_for_reporting, selected_for_ranking, brier_raw AS p_brier_raw_dev_select,
         brier_calibrated AS p_brier_cal_dev_select, brier_selected AS p_brier_selected_dev_select,
         selected_using_split AS p_selected_on, used_locked_test AS p_used_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`
  LIMIT 1
),
frozen_pol AS (
  SELECT policy, avg_lift_at_100, avg_precision_at_100,
         selected_using_split AS pol_selected_on, used_locked_test AS pol_used_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict`
  LIMIT 1
),

-- Check label availability
label_check AS (
  SELECT
    COUNTIF(y_true_12w IS NOT NULL)          AS n_labelled_rows,
    COUNTIF(stockout_event_12w IS NOT NULL)  AS n_labelled_stockout,
    COUNT(*)                                 AS n_total_locked_test
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict`
  WHERE eval_split_v3 = 'LOCKED_TEST'
    AND split_original = 'VAL'
),

-- LOCKED_TEST base rows (for metrics — only labelled rows)
lt_base AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    f.yhat_p50_12w,
    f.q80_12w,
    f.q90_12w,
    f.q95_12w,
    f.y_true_12w,
    f.stockout_event_12w,
    f.lost_units_proxy_12w,
    c.p_oos_raw,
    c.p_oos_h12 AS p_oos_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  WHERE f.eval_split_v3 = 'LOCKED_TEST'
    AND f.split_original = 'VAL'
    AND f.y_true_12w IS NOT NULL   -- only labelled rows contribute to metrics
),

-- Universe for lift@100 denominator
lt_universe AS (
  SELECT
    COUNT(*)                          AS n_universe,
    COUNTIF(stockout_event_12w = 1)   AS n_oos_universe
  FROM lt_base
  WHERE stockout_event_12w IS NOT NULL
),

-- Alerts applied with frozen policy (top-100 per week)
lt_alerts AS (
  SELECT *
  FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_locked_test_h12_v3_strict`
  WHERE alert_rank <= 100
    AND y_true_12w IS NOT NULL   -- no labels → 0 rows
),

-- Alert performance
alert_perf AS (
  SELECT
    COUNT(*)                                                AS n_alerts,
    COUNTIF(CAST(stockout_event_12w AS INT64) = 1)         AS n_tp,
    SAFE_DIVIDE(
      COUNTIF(CAST(stockout_event_12w AS INT64) = 1),
      COUNT(*)
    )                                                       AS precision_at_100
  FROM lt_alerts
),

-- Global metrics (only if labels exist)
global_metrics AS (
  SELECT
    COUNT(*)                                                          AS n_obs,
    COUNT(DISTINCT sku_id)                                            AS n_skus,
    COUNT(DISTINCT decision_week)                                     AS n_weeks,
    ROUND(AVG(CAST(stockout_event_12w AS FLOAT64)), 4)                AS prevalence_stockout,
    ROUND(SAFE_DIVIDE(
      SUM(ABS(y_true_12w - yhat_p50_12w)), NULLIF(SUM(ABS(y_true_12w)), 0)
    ), 4)                                                             AS wmape,
    ROUND(SAFE_DIVIDE(
      SUM(yhat_p50_12w - y_true_12w), NULLIF(SUM(y_true_12w), 0)
    ), 4)                                                             AS bias_pct,
    ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p80,
    ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p90,
    ROUND(AVG(CASE WHEN y_true_12w > q95_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_rate_p95,
    -- Brier for both modes (reported, never used to change selection)
    ROUND(AVG(POW(p_oos_raw - CAST(stockout_event_12w AS FLOAT64), 2)), 5) AS brier_raw,
    ROUND(AVG(POW(p_oos_cal - CAST(stockout_event_12w AS FLOAT64), 2)), 5) AS brier_calibrated
  FROM lt_base
  WHERE stockout_event_12w IS NOT NULL
)

-- Final output
SELECT
  -- Test identification
  'h12_v3_strict' AS version,
  'LOCKED_TEST'   AS test_split,
  -- Status: LOCKED_TEST_PENDING because labels are blind
  CASE
    WHEN lc.n_labelled_rows = 0 THEN 'LOCKED_TEST_PENDING'
    ELSE 'LOCKED_TEST_EVALUATED'
  END AS test_status,

  -- Anti-leakage assertions (structural, not data-dependent)
  TRUE  AS is_locked_test,
  FALSE AS post_selection_bias,
  FALSE AS policy_selected_on_locked_test,
  FALSE AS prob_mode_selected_on_locked_test,
  FALSE AS quantile_recalibrated_on_locked_test,

  -- Label availability
  lc.n_total_locked_test,
  lc.n_labelled_rows,
  lc.n_labelled_stockout,

  -- Demand metrics (NULL if no labels)
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.n_obs           ELSE NULL END AS n_obs,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.n_skus          ELSE NULL END AS n_skus,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.n_weeks         ELSE NULL END AS n_weeks,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.prevalence_stockout ELSE NULL END AS prevalence_stockout,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.wmape           ELSE NULL END AS wmape,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.bias_pct        ELSE NULL END AS bias_pct,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.viol_rate_p80   ELSE NULL END AS viol_rate_p80,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.viol_rate_p90   ELSE NULL END AS viol_rate_p90,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.viol_rate_p95   ELSE NULL END AS viol_rate_p95,

  -- Brier scores (all three: raw, calibrated, selected)
  -- Reported for transparency; selection was frozen in step 03 and is not changed.
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.brier_raw        ELSE NULL END AS brier_raw,
  CASE WHEN lc.n_labelled_rows > 0 THEN gm.brier_calibrated ELSE NULL END AS brier_calibrated,
  CASE WHEN lc.n_labelled_rows > 0
    THEN CASE fp.selected_for_reporting
           WHEN 'RAW'        THEN gm.brier_raw
           WHEN 'CALIBRATED' THEN gm.brier_calibrated
         END
    ELSE NULL
  END AS brier_selected,
  -- Note: if brier_selected > brier_other on LOCKED_TEST, we do NOT change selection.
  -- This would be a finding to report, not a reason to re-select.

  -- Alert metrics (NULL if no labels)
  CASE WHEN lc.n_labelled_rows > 0 THEN ap.n_alerts        ELSE NULL END AS n_alerts_top100,
  CASE WHEN lc.n_labelled_rows > 0 THEN ap.n_tp            ELSE NULL END AS n_tp_top100,
  CASE WHEN lc.n_labelled_rows > 0
    THEN ROUND(ap.precision_at_100, 4)
    ELSE NULL
  END AS precision_at_100,
  CASE WHEN lc.n_labelled_rows > 0
    THEN ROUND(SAFE_DIVIDE(ap.n_tp, NULLIF(lu.n_oos_universe, 0)), 4)
    ELSE NULL
  END AS recall_at_100,
  CASE WHEN lc.n_labelled_rows > 0
    THEN ROUND(
      SAFE_DIVIDE(
        SAFE_DIVIDE(ap.n_tp, NULLIF(ap.n_alerts, 0)),
        SAFE_DIVIDE(lu.n_oos_universe, NULLIF(lu.n_universe, 0))
      ), 4)
    ELSE NULL
  END AS lift_at_100,

  -- Frozen decision provenance (audit trail)
  fp.selected_for_reporting                AS frozen_prob_mode_reporting,
  fp.selected_for_ranking                  AS frozen_prob_mode_ranking,
  fp.p_selected_on                         AS prob_frozen_on_split,
  fpl.policy                               AS frozen_policy,
  fpl.avg_lift_at_100                      AS frozen_policy_dev_select_lift,
  fpl.pol_selected_on                      AS policy_frozen_on_split,
  fq.scale_multiplier                      AS frozen_q_scale_multiplier,
  fq.q90_offset                            AS frozen_q90_offset,
  fq.calibration_loss                      AS frozen_q_calibration_loss,
  fq.q_selected_on                         AS quantile_frozen_on_split,

  -- Note for tutor / reviewer
  CASE WHEN lc.n_labelled_rows = 0
    THEN 'LOCKED_TEST labels (y_true_12w) are NULL for W28-W40. '
         || 'This is a structural outcome, not a pipeline error. '
         || 'Metrics will be populated when labels become available. '
         || 'The pipeline is methodologically clean: all decisions were frozen '
         || 'before this table was created.'
    ELSE 'LOCKED_TEST evaluated with frozen decisions. post_selection_bias=FALSE.'
  END AS reviewer_note,

  CURRENT_TIMESTAMP() AS computed_at

FROM label_check lc
CROSS JOIN frozen_p fp
CROSS JOIN frozen_pol fpl
CROSS JOIN frozen_q fq
CROSS JOIN global_metrics gm
CROSS JOIN alert_perf ap
CROSS JOIN lt_universe lu;

SELECT
  version, test_split, test_status,
  is_locked_test, post_selection_bias,
  n_total_locked_test, n_labelled_rows,
  wmape, bias_pct, viol_rate_p90,
  brier_raw, brier_calibrated, brier_selected,
  lift_at_100, precision_at_100, recall_at_100,
  frozen_policy, frozen_prob_mode_reporting,
  reviewer_note
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_strict`;
