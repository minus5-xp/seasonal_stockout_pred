-- ============================================================================
-- STEP 05: APPLY FROZEN DECISIONS TO LOCKED_TEST  (h=12 v3_strict)
-- ============================================================================
-- PURPOSE:
--   Apply frozen_policy and frozen_probability_mode to LOCKED_TEST rows.
--   Produce alert rankings for LOCKED_TEST.
--
--   Since LOCKED_TEST labels are confirmed blind (y_true_12w = NULL),
--   this step produces rankings only — not metric evaluation.
--   Metric evaluation happens in step 06.
--
-- HARD CONSTRAINTS (anti-leakage):
--   - No ROW_NUMBER re-scoring by metric on LOCKED_TEST.
--   - No policy re-selection on LOCKED_TEST.
--   - No probability re-selection on LOCKED_TEST.
--   - The applied_policy comes exclusively from frozen_policy_h12_v3_strict.
--   - The applied_prob_mode comes from frozen_probability_mode_h12_v3_strict.
--
-- OUTPUT TABLES:
--   alerts_locked_test_h12_v3_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.alerts_locked_test_h12_v3_strict` AS
WITH

-- Read frozen decisions (read-only)
frozen_policy AS (
  SELECT policy AS selected_policy, avg_lift_at_100, avg_precision_at_100
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_policy_h12_v3_strict`
  LIMIT 1
),
frozen_prob AS (
  SELECT selected_for_ranking AS prob_mode
  FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_probability_mode_h12_v3_strict`
  LIMIT 1
),

-- LOCKED_TEST rows
locked_test_rows AS (
  SELECT
    f.decision_week,
    f.iso_year,
    f.iso_week,
    f.target_start_week,
    f.target_end_week,
    f.sku_id,
    f.season_group,
    f.eval_split_v3,
    f.yhat_p50_12w,
    f.q90_12w,
    f.q95_12w,
    f.lost_units_proxy_12w,
    -- Labels: confirmed NULL for LOCKED_TEST
    f.y_true_12w,
    f.stockout_event_12w,
    -- Apply frozen probability mode
    CASE fp.prob_mode
      WHEN 'RAW'        THEN c.p_oos_raw
      WHEN 'CALIBRATED' THEN c.p_oos_h12
      ELSE c.p_oos_h12
    END                                                  AS p_oos_rank,
    fp.prob_mode                                         AS applied_prob_mode,
    GREATEST(0.0, f.q90_12w - f.yhat_p50_12w)           AS width_q90,
    GREATEST(0.0, f.q95_12w - f.yhat_p50_12w)           AS width_q95,
    CASE f.season_group WHEN 'HIGH_SEASON' THEN 1.25 ELSE 1.0 END AS season_weight
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  JOIN `{PROJECT_ID}.{BQ_DATASET}.score_oos_h12_calibrated_v1` c
    ON c.sku_id = f.sku_id AND c.week_start_date = f.decision_week
  CROSS JOIN frozen_prob fp
  WHERE f.eval_split_v3 = 'LOCKED_TEST'
    AND f.split_original = 'VAL'
),

-- Compute alert scores using frozen policy
scored AS (
  SELECT
    t.*,
    fp.selected_policy,
    fp.avg_lift_at_100  AS frozen_policy_dev_select_lift,
    fp.avg_precision_at_100 AS frozen_policy_dev_select_precision,
    -- Score per frozen policy
    CASE fp.selected_policy
      WHEN 'policy_A' THEN p_oos_rank * width_q90
      WHEN 'policy_B' THEN p_oos_rank * q90_12w
      WHEN 'policy_C' THEN POW(p_oos_rank, 0.7) * width_q95
      WHEN 'policy_D' THEN p_oos_rank * COALESCE(NULLIF(lost_units_proxy_12w, 0), width_q90)
      WHEN 'policy_E' THEN p_oos_rank * q90_12w * season_weight
      ELSE p_oos_rank * q90_12w   -- fallback: policy_B
    END AS risk_score
  FROM locked_test_rows t
  CROSS JOIN frozen_policy fp
)

SELECT
  *,
  ROW_NUMBER() OVER (PARTITION BY decision_week ORDER BY risk_score DESC) AS alert_rank,
  -- Audit flags
  TRUE  AS is_locked_test,
  FALSE AS labels_used_in_scoring,   -- scoring uses only forecasts, not labels
  FALSE AS policy_selected_here,     -- policy was frozen in step 04
  FALSE AS prob_mode_selected_here   -- prob_mode was frozen in step 03
FROM scored
ORDER BY decision_week, alert_rank;

-- ── Verification ─────────────────────────────────────────────────────────
SELECT
  eval_split_v3,
  selected_policy,
  applied_prob_mode,
  COUNT(*)                    AS n_rows,
  COUNT(DISTINCT sku_id)      AS n_skus,
  COUNT(DISTINCT decision_week) AS n_weeks,
  COUNTIF(alert_rank <= 100)  AS n_top100_alerts,
  COUNTIF(y_true_12w IS NOT NULL) AS n_labelled   -- expect 0 for LOCKED_TEST
FROM `{PROJECT_ID}.{BQ_DATASET}.alerts_locked_test_h12_v3_strict`
GROUP BY eval_split_v3, selected_policy, applied_prob_mode;
