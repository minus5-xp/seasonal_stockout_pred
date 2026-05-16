-- ============================================================================
-- STEP 01: FIX PROBABILITY + BRIER SELECTION  (h12_v2_final)
-- ============================================================================
-- PURPOSE:
--   brier_v2(Platt calibrated) = 0.0805 > brier_raw = 0.06685 → Platt WORSENS.
--   Select the better probability for reporting without breaking ranking.
--
--   p_oos_12w_rank   = probability maximising lift@100 (keep current Platt if better)
--   p_oos_12w_report = probability minimising Brier on VAL_GATE (select raw vs cal)
--   p_oos_12w_deploy = p_oos_12w_report (used in displayed forecast)
--
-- INPUTS (read-only):
--   score_oos_h12_calibrated_v1  : p_oos_raw, p_oos_h12 (Platt), true_label, split
--   base_scores_h12_v1           : stockout_event_12w, week_start_date, split
--   val_tune_gate_blind_split_h12_v2 : eval_split_v2
--   forecast_recalibrated_h12_v2 : full forecast table
--   alerts_top100_h12_v2         : current alert ranking
--
-- OUTPUTS:
--   probability_brier_comparison_h12_v2_final
--   probability_selection_h12_v2_final
--   probability_calibration_deciles_h12_v2_final
--   forecast_national_h12_v2_final
--   probability_gate_h12_v2_final
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1a. BRIER COMPARISON ON VAL_GATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_brier_comparison_h12_v2_final` AS
WITH val_gate_probs AS (
  SELECT
    c.sku_id,
    c.week_start_date,
    c.p_oos_raw,
    c.p_oos_h12       AS p_oos_cal,
    CAST(b.stockout_event_12w AS FLOAT64) AS actual_label
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = c.sku_id AND b.week_start_date = c.week_start_date
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` sp
    ON sp.decision_week = c.week_start_date AND sp.eval_split_v2 = 'VAL_GATE'
  WHERE c.split = 'VAL'
    AND b.stockout_event_12w IS NOT NULL
    AND c.p_oos_raw IS NOT NULL
)
SELECT
  COUNT(*)                                                AS n_rows,
  -- Brier scores
  ROUND(AVG(POW(p_oos_raw - actual_label, 2)), 5)       AS brier_raw,
  ROUND(AVG(POW(p_oos_cal - actual_label, 2)), 5)       AS brier_calibrated,
  -- Mean predictions
  ROUND(AVG(p_oos_raw), 4)                               AS mean_p_raw,
  ROUND(AVG(p_oos_cal), 4)                               AS mean_p_cal,
  ROUND(AVG(actual_label), 4)                            AS prevalence,
  -- Log-loss proxies (clipped to avoid log(0))
  ROUND(-AVG(
    actual_label * LN(GREATEST(p_oos_raw, 1e-7))
    + (1 - actual_label) * LN(GREATEST(1 - p_oos_raw, 1e-7))
  ), 5)                                                  AS logloss_raw,
  ROUND(-AVG(
    actual_label * LN(GREATEST(p_oos_cal, 1e-7))
    + (1 - actual_label) * LN(GREATEST(1 - p_oos_cal, 1e-7))
  ), 5)                                                  AS logloss_calibrated,
  -- Selection
  CASE
    WHEN AVG(POW(p_oos_cal - actual_label, 2))
         <= AVG(POW(p_oos_raw - actual_label, 2)) * 1.01
    THEN 'CALIBRATED'
    ELSE 'RAW'
  END                                                    AS selected_probability_for_reporting,
  -- Ranking comparison: which gives higher precision@100?
  -- (approximate: use correlation with actual as proxy)
  ROUND(CORR(p_oos_raw, actual_label), 4)                AS corr_raw_vs_label,
  ROUND(CORR(p_oos_cal, actual_label), 4)                AS corr_cal_vs_label
FROM val_gate_probs;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.probability_brier_comparison_h12_v2_final`;

-- ---------------------------------------------------------------------------
-- 1b. CALIBRATION DECILES (both raw and calibrated on VAL_GATE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_calibration_deciles_h12_v2_final` AS
WITH val_gate_probs AS (
  SELECT
    c.p_oos_raw,
    c.p_oos_h12 AS p_oos_cal,
    CAST(b.stockout_event_12w AS FLOAT64) AS actual_label,
    NTILE(10) OVER (ORDER BY c.p_oos_raw) AS decile_raw,
    NTILE(10) OVER (ORDER BY c.p_oos_h12) AS decile_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = c.sku_id AND b.week_start_date = c.week_start_date
  INNER JOIN `{PROJECT_ID}.{BQ_DATASET}.val_tune_gate_blind_split_h12_v2` sp
    ON sp.decision_week = c.week_start_date AND sp.eval_split_v2 = 'VAL_GATE'
  WHERE c.split = 'VAL' AND b.stockout_event_12w IS NOT NULL
)
SELECT
  decile_raw AS decile,
  ROUND(AVG(p_oos_raw), 4)     AS avg_pred_raw,
  ROUND(AVG(p_oos_cal), 4)     AS avg_pred_cal,
  ROUND(AVG(actual_label), 4)  AS avg_actual,
  COUNT(*)                      AS n
FROM val_gate_probs
GROUP BY decile_raw
ORDER BY decile_raw;

-- ---------------------------------------------------------------------------
-- 1c. PROBABILITY SELECTION TABLE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_selection_h12_v2_final` AS
WITH brier AS (
  SELECT
    brier_raw,
    brier_calibrated,
    selected_probability_for_reporting,
    corr_raw_vs_label,
    corr_cal_vs_label,
    -- Ranking: pick whichever correlates more with actual
    CASE
      WHEN corr_cal_vs_label >= corr_raw_vs_label THEN 'CALIBRATED'
      ELSE 'RAW'
    END AS selected_probability_for_ranking
  FROM `{PROJECT_ID}.{BQ_DATASET}.probability_brier_comparison_h12_v2_final`
)
SELECT
  brier_raw,
  brier_calibrated,
  selected_probability_for_reporting,
  selected_probability_for_ranking,
  CASE selected_probability_for_reporting
    WHEN 'RAW'        THEN brier_raw
    WHEN 'CALIBRATED' THEN brier_calibrated
  END AS brier_selected,
  CASE
    WHEN brier_raw IS NULL THEN 'UNKNOWN_RAW_NOT_AVAILABLE'
    WHEN CASE selected_probability_for_reporting
           WHEN 'RAW'        THEN brier_raw
           WHEN 'CALIBRATED' THEN brier_calibrated
         END <= brier_raw * 1.01 THEN 'PASS'
    ELSE 'FAIL'
  END AS brier_gate_status,
  CONCAT(
    'Reporting=', selected_probability_for_reporting,
    ', Ranking=', selected_probability_for_ranking,
    ', brier_raw=', CAST(ROUND(brier_raw,5) AS STRING),
    ', brier_cal=', CAST(ROUND(brier_calibrated,5) AS STRING)
  ) AS notes
FROM brier;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_h12_v2_final`;

-- ---------------------------------------------------------------------------
-- 1d. RANKING COMPARISON (lift@100 raw vs calibrated on VAL_GATE)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_ranking_comparison_h12_v2_final` AS
WITH
sel AS (
  SELECT policy AS selected_policy FROM `{PROJECT_ID}.{BQ_DATASET}.policy_best_h12_v2` LIMIT 1
),
val_gate_scores AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.season_group,
    -- raw and calibrated probabilities
    c.p_oos_raw,
    c.p_oos_h12 AS p_oos_cal,
    f.q90_12w,
    f.q95_12w,
    f.yhat_p50_12w,
    f.lost_units_proxy_12w,
    CAST(b.stockout_event_12w AS INT64) AS actual_label
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v2` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  JOIN `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` b
    ON b.sku_id = f.sku_id AND b.week_start_date = f.decision_week
  WHERE f.eval_split_v2 = 'VAL_GATE'
    AND f.split_original = 'VAL'
    AND b.stockout_event_12w IS NOT NULL
),
prevalence AS (
  SELECT SAFE_DIVIDE(COUNTIF(actual_label=1), COUNT(*)) AS base_rate
  FROM val_gate_scores
),
-- Rank by raw probability (policy_B equivalent)
raw_ranked AS (
  SELECT *,
    p_oos_raw * q90_12w AS score_raw,
    ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY p_oos_raw * q90_12w DESC) AS rk_raw
  FROM val_gate_scores
),
-- Rank by calibrated probability (current)
cal_ranked AS (
  SELECT *,
    p_oos_cal * q90_12w AS score_cal,
    ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY p_oos_cal * q90_12w DESC) AS rk_cal
  FROM val_gate_scores
)
SELECT
  'raw'   AS prob_source,
  ROUND(SAFE_DIVIDE(COUNTIF(actual_label=1), COUNT(*)), 4)  AS precision_at_100,
  SAFE_DIVIDE(
    SAFE_DIVIDE(COUNTIF(actual_label=1), COUNT(*)),
    (SELECT base_rate FROM prevalence)
  )                                                          AS lift_at_100,
  COUNT(*)                                                   AS n_alerts
FROM raw_ranked WHERE rk_raw <= 100
UNION ALL
SELECT
  'calibrated' AS prob_source,
  ROUND(SAFE_DIVIDE(COUNTIF(actual_label=1), COUNT(*)), 4),
  SAFE_DIVIDE(
    SAFE_DIVIDE(COUNTIF(actual_label=1), COUNT(*)),
    (SELECT base_rate FROM prevalence)
  ),
  COUNT(*)
FROM cal_ranked WHERE rk_cal <= 100;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.probability_ranking_comparison_h12_v2_final`;

-- ---------------------------------------------------------------------------
-- 1e. CREATE forecast_national_h12_v2_final
-- Adds p_oos_12w_rank / report / deploy to national forecast.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2_final` AS
WITH
prob_sel AS (
  SELECT
    selected_probability_for_reporting,
    selected_probability_for_ranking
  FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_h12_v2_final`
  LIMIT 1
),
-- Join raw probability to forecast
with_raw AS (
  SELECT
    f.*,
    COALESCE(c.p_oos_raw, f.p_oos_h12) AS p_oos_raw_avail
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
)
SELECT
  r.decision_week,
  r.iso_year,
  r.iso_week,
  r.target_start_week,
  r.target_end_week,
  r.sku_id,
  r.sku_name,
  r.familia,
  r.subfamilia,
  r.abc_class,
  r.sb_class,
  r.season_group,
  r.demand_decile,
  r.volatility_bucket,
  r.eval_split_v2,

  -- Three probability columns
  CASE ps.selected_probability_for_ranking
    WHEN 'RAW'        THEN r.p_oos_raw_avail
    ELSE r.p_oos_h12
  END AS p_oos_12w_rank,

  CASE ps.selected_probability_for_reporting
    WHEN 'RAW'        THEN r.p_oos_raw_avail
    ELSE r.p_oos_h12
  END AS p_oos_12w_report,

  -- deploy = report (for display)
  CASE ps.selected_probability_for_reporting
    WHEN 'RAW'        THEN r.p_oos_raw_avail
    ELSE r.p_oos_h12
  END AS p_oos_12w_deploy,

  ps.selected_probability_for_reporting AS probability_reporting_choice,

  -- Recalculate alert_score using rank probability
  CASE r.selected_policy
    WHEN 'policy_A' THEN
      CASE ps.selected_probability_for_ranking WHEN 'RAW' THEN r.p_oos_raw_avail ELSE r.p_oos_h12 END
      * GREATEST(0.0, r.q90_12w - r.yhat_p50_12w)
    WHEN 'policy_B' THEN
      CASE ps.selected_probability_for_ranking WHEN 'RAW' THEN r.p_oos_raw_avail ELSE r.p_oos_h12 END
      * r.q90_12w
    WHEN 'policy_C' THEN
      POW(CASE ps.selected_probability_for_ranking WHEN 'RAW' THEN r.p_oos_raw_avail ELSE r.p_oos_h12 END, 0.7)
      * GREATEST(0.0, r.q95_12w - r.yhat_p50_12w)
    WHEN 'policy_D' THEN
      CASE ps.selected_probability_for_ranking WHEN 'RAW' THEN r.p_oos_raw_avail ELSE r.p_oos_h12 END
      * COALESCE(NULLIF(r.lost_units_proxy_12w, 0), GREATEST(0.0, r.q90_12w - r.yhat_p50_12w))
    WHEN 'policy_E' THEN
      CASE ps.selected_probability_for_ranking WHEN 'RAW' THEN r.p_oos_raw_avail ELSE r.p_oos_h12 END
      * r.q90_12w
      * CASE r.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END
    ELSE
      CASE ps.selected_probability_for_ranking WHEN 'RAW' THEN r.p_oos_raw_avail ELSE r.p_oos_h12 END
      * r.q90_12w
  END AS alert_score_final,

  r.selected_policy,
  r.yhat_p50_12w,
  r.q80_12w,
  r.q90_12w,
  r.q95_12w,
  r.q99_12w,
  r.expected_buffer_q90,
  r.expected_buffer_q95,
  r.lost_units_proxy_12w,
  r.service_recommendation,
  r.y_true_12w,
  r.stockout_event_12w,
  r.n_stockout_weeks_12w,
  'h12_v2_final' AS version

FROM with_raw r
CROSS JOIN prob_sel ps;

-- Quick sanity
SELECT
  eval_split_v2,
  COUNT(*) n,
  ROUND(AVG(p_oos_12w_report), 4) avg_p_report,
  ROUND(AVG(p_oos_12w_rank), 4) avg_p_rank,
  probability_reporting_choice
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2_final`
GROUP BY eval_split_v2, probability_reporting_choice
ORDER BY eval_split_v2;

-- ---------------------------------------------------------------------------
-- 1f. PROBABILITY GATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.probability_gate_h12_v2_final` AS
WITH
ps AS (SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.probability_selection_h12_v2_final`),
rank_comp AS (
  SELECT
    MAX(CASE WHEN prob_source = 'raw'        THEN lift_at_100 END) AS lift_raw,
    MAX(CASE WHEN prob_source = 'calibrated' THEN lift_at_100 END) AS lift_cal,
    MAX(CASE WHEN prob_source = 'raw'        THEN precision_at_100 END) AS prec_raw,
    MAX(CASE WHEN prob_source = 'calibrated' THEN precision_at_100 END) AS prec_cal
  FROM `{PROJECT_ID}.{BQ_DATASET}.probability_ranking_comparison_h12_v2_final`
),
h12v2_prec AS (
  SELECT precision_at_100 AS prec_v2
  FROM `{PROJECT_ID}.{BQ_DATASET}.gate_verdict_h12_v2`
)
SELECT
  ps.brier_raw,
  ps.brier_calibrated,
  ps.brier_selected,
  ps.brier_gate_status,
  ps.selected_probability_for_reporting,
  ps.selected_probability_for_ranking,
  rc.lift_raw,
  rc.lift_cal,
  -- Final lift uses the selected ranking probability
  CASE ps.selected_probability_for_ranking
    WHEN 'RAW'        THEN rc.lift_raw
    ELSE rc.lift_cal
  END AS lift_at_100_final,
  -- Final precision
  CASE ps.selected_probability_for_ranking
    WHEN 'RAW'        THEN rc.prec_raw
    ELSE rc.prec_cal
  END AS precision_at_100_final,
  -- Gate: PASS if brier ok AND lift >= 1.5 AND precision not drops >10%
  CASE
    WHEN ps.brier_gate_status NOT IN ('PASS') THEN 'FAIL_BRIER'
    WHEN CASE ps.selected_probability_for_ranking
           WHEN 'RAW' THEN rc.lift_raw ELSE rc.lift_cal END < 1.5 THEN 'FAIL_LIFT'
    WHEN CASE ps.selected_probability_for_ranking
           WHEN 'RAW' THEN rc.prec_raw ELSE rc.prec_cal END
         < hp.prec_v2 * 0.90 THEN 'FAIL_PRECISION_DROP'
    ELSE 'PASS'
  END AS probability_gate_status
FROM ps, rank_comp rc, h12v2_prec hp;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.probability_gate_h12_v2_final`;
