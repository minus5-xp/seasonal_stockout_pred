-- ============================================================================
-- STEP 04: OFF-SEASON FORECAST GATE  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Apply a conservative cap to yhat_p50_12w for SKUs in OFF_SEASON and
--   REST_OFFPEAK states. The cap is derived entirely from historical demand
--   (TRAIN+CALIB) for the same iso_week in prior years — never from LOCKED_TEST.
--
-- GATE LOGIC:
--
--   OFF_SEASON:
--     cap = COALESCE(
--             hist_p90_units_same_week * 12,  -- scale to 12-week equivalent
--             annual_avg_units_sku * 12 * 0.25,
--             yhat_p50_12w                    -- no cap if no history
--           )
--     yhat_p50_season_state_12w = LEAST(yhat_p50_original_12w, cap)
--     Floor = GREATEST(gated, hist_avg_units_same_week * 12 * 0.3)
--       Prevents over-suppression when p90 is very low but avg>0.
--
--   REST_OFFPEAK:
--     cap = hist_p90_units_same_week * 12 * 1.5  (softer cap)
--     yhat_p50_season_state_12w = LEAST(yhat_p50_original_12w, cap)
--
--   All other states: yhat_p50_season_state_12w = yhat_p50_original_12w
--
-- NOTE on scale: hist_p90_units_same_week is a weekly stat (single week).
--   yhat_p50_12w is a 12-week sum. We multiply weekly stats × 12 to convert.
--   This is approximate (ignores week-to-week variation within the window)
--   but conservative and auditable.
--
-- ANTI-LEAKAGE:
--   - cap computation uses only hist_p90_units_same_week and
--     annual_avg_units_sku, both from step 01 (TRAIN+CALIB, prior years).
--   - y_true_12w of LOCKED_TEST is NOT read here.
--   - Gate thresholds are not calibrated on LOCKED_TEST.
--
-- OUTPUT TABLE:
--   forecast_gated_h12_v3_2_season_state_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` AS
WITH

base AS (
  SELECT
    f.decision_week,
    f.sku_id,
    f.iso_year,
    f.iso_week,
    f.target_start_week,
    f.target_end_week,
    f.split_original,
    f.eval_split_v3,
    f.can_tune,
    f.can_select,
    f.can_report_final,
    f.labels_allowed,
    f.season_group,
    f.demand_decile,
    f.volatility_bucket,
    f.segment_id_child,
    f.amplitude,
    f.p_oos_h12,
    -- Original forecast (from v3_strict recalibrated)
    f.yhat_p50_12w          AS yhat_p50_original_12w,
    f.q80_12w,
    f.q90_12w,
    f.q95_12w,
    f.q75_12w,
    f.q85_12w,
    f.q99_12w,
    f.cap_value,
    f.scale_v1,
    f.scale_h12_v3,
    f.cf_v3,
    f.sel_scale_multiplier,
    f.sel_q90_offset,
    f.sel_q95_offset,
    f.sel_factor_clip_hi,
    f.lost_units_proxy_12w,
    -- Labels passed through as-is
    f.y_true_12w,
    f.stockout_event_12w,
    f.n_stockout_weeks_12w,
    -- Season state features (from step 02)
    ss.sku_season_state,
    ss.state_rule_applied,
    ss.selected_level,
    -- Historical demand features (12-week equivalent for gate computation)
    ss.hist_p90_units_same_week  * 12.0  AS hist_p90_12w_equiv,
    ss.hist_avg_units_same_week  * 12.0  AS hist_avg_12w_equiv,
    ss.annual_avg_units_sku      * 12.0  AS annual_avg_12w_equiv,
    ss.hist_positive_rate_same_week,
    ss.seasonal_index_same_week,
    ss.n_hist_obs_available
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
    ON ss.sku_id = f.sku_id AND ss.decision_week = f.decision_week
),

gated AS (
  SELECT
    *,
    -- ── Compute cap per state ──────────────────────────────────────────
    CASE sku_season_state
      WHEN 'OFF_SEASON' THEN
        COALESCE(
          NULLIF(hist_p90_12w_equiv, 0.0),          -- primary: p90 of same week
          annual_avg_12w_equiv * 0.25,               -- fallback: 25% of annual avg
          yhat_p50_original_12w                      -- no cap
        )
      WHEN 'REST_OFFPEAK' THEN
        COALESCE(
          NULLIF(hist_p90_12w_equiv * 1.5, 0.0),    -- softer cap for REST_OFFPEAK
          annual_avg_12w_equiv * 0.50,
          yhat_p50_original_12w
        )
      ELSE NULL  -- no cap for other states
    END AS gate_cap_raw,

    -- ── Gate reason ───────────────────────────────────────────────────
    CASE sku_season_state
      WHEN 'OFF_SEASON' THEN
        CASE
          WHEN hist_p90_12w_equiv > 0 THEN 'off_season_hist_p90_cap'
          WHEN annual_avg_12w_equiv > 0 THEN 'off_season_annual_fallback_cap'
          ELSE 'no_cap_no_history'
        END
      WHEN 'REST_OFFPEAK' THEN
        CASE
          WHEN hist_p90_12w_equiv > 0 THEN 'rest_offpeak_hist_p90x1.5_cap'
          WHEN annual_avg_12w_equiv > 0 THEN 'rest_offpeak_annual_fallback_cap'
          ELSE 'no_cap_no_history'
        END
      ELSE 'no_gate'
    END AS offseason_gate_reason

  FROM base
),

final AS (
  SELECT
    *,
    -- ── Apply gate ────────────────────────────────────────────────────
    CASE
      WHEN sku_season_state IN ('OFF_SEASON', 'REST_OFFPEAK')
       AND gate_cap_raw IS NOT NULL
       AND gate_cap_raw < yhat_p50_original_12w
      THEN
        -- Apply cap but floor at 30% of historical avg to avoid
        -- over-suppression of genuinely low-demand SKUs
        GREATEST(
          LEAST(yhat_p50_original_12w, gate_cap_raw),
          GREATEST(0.0, hist_avg_12w_equiv * 0.30)
        )
      ELSE
        yhat_p50_original_12w
    END AS yhat_p50_season_state_12w,

    CASE
      WHEN sku_season_state IN ('OFF_SEASON', 'REST_OFFPEAK')
       AND gate_cap_raw IS NOT NULL
       AND gate_cap_raw < yhat_p50_original_12w
      THEN TRUE
      ELSE FALSE
    END AS offseason_gate_applied

  FROM gated
)

SELECT
  decision_week,
  sku_id,
  iso_year,
  iso_week,
  target_start_week,
  target_end_week,
  split_original,
  eval_split_v3,
  can_tune,
  can_select,
  can_report_final,
  labels_allowed,
  season_group,
  demand_decile,
  volatility_bucket,
  segment_id_child,
  amplitude,
  p_oos_h12,
  -- Both versions of forecast
  yhat_p50_original_12w,
  yhat_p50_season_state_12w,
  -- Gate metadata
  offseason_gate_applied,
  offseason_gate_reason,
  gate_cap_raw,
  sku_season_state,
  state_rule_applied,
  selected_level,
  -- Quantiles (from v3_strict; recalibrated per state in step 05)
  q75_12w,
  q80_12w,
  q85_12w,
  q90_12w,
  q95_12w,
  q99_12w,
  cap_value,
  scale_v1,
  scale_h12_v3,
  cf_v3,
  sel_scale_multiplier,
  sel_q90_offset,
  sel_q95_offset,
  sel_factor_clip_hi,
  lost_units_proxy_12w,
  -- Season state features (kept for audit)
  hist_p90_12w_equiv,
  hist_avg_12w_equiv,
  annual_avg_12w_equiv,
  hist_positive_rate_same_week,
  seasonal_index_same_week,
  n_hist_obs_available,
  -- Labels (NULL for LOCKED_TEST; never used in gate computation)
  y_true_12w,
  stockout_event_12w,
  n_stockout_weeks_12w,
  -- Audit
  FALSE AS gate_used_locked_test_labels
FROM final;

-- ── Gate impact summary ───────────────────────────────────────────────────
SELECT
  eval_split_v3,
  season_group,
  sku_season_state,
  offseason_gate_applied,
  offseason_gate_reason,
  COUNT(*)                                          AS n_rows,
  ROUND(AVG(yhat_p50_original_12w), 2)              AS avg_pred_original,
  ROUND(AVG(yhat_p50_season_state_12w), 2)          AS avg_pred_gated,
  ROUND(AVG(yhat_p50_original_12w - yhat_p50_season_state_12w), 2) AS avg_reduction,
  ROUND(AVG(CASE WHEN y_true_12w IS NOT NULL
    THEN ABS(y_true_12w - yhat_p50_season_state_12w) END), 3)      AS mae_gated,
  ROUND(AVG(CASE WHEN y_true_12w IS NOT NULL
    THEN ABS(y_true_12w - yhat_p50_original_12w) END), 3)          AS mae_original
FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict`
GROUP BY eval_split_v3, season_group, sku_season_state,
         offseason_gate_applied, offseason_gate_reason
ORDER BY eval_split_v3, n_rows DESC;
