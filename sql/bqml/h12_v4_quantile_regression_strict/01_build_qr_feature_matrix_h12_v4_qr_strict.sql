-- ============================================================================
-- STEP 01: BUILD QR FEATURE MATRIX  (h=12 v4_quantile_regression_strict)
-- ============================================================================
-- PURPOSE:
--   Build comprehensive feature matrix for quantile regression training.
--   Combines base predictions, seasonal state features, and derived signals.
--
-- ANTI-LEAKAGE DESIGN:
--   - Uses only features available at decision_week
--   - Historical features from v3_2 use TRAIN+CALIB only (prior years)
--   - No forward-looking information
--   - Transition features based on historical patterns, not 2024 actuals
--
-- FEATURES INCLUDED:
--   Base BQML:
--     yhat_p50_12w, q80/90/95_12w (raw), p_oos_raw, p_oos_h12,
--     scale, stockout_event_12w
--   
--   Seasonal state (from v3_2):
--     sku_season_state, season_group, hist_positive, annual_positive,
--     seasonal_index, hist_avg/p90, transition_slope
--   
--   v3_2 gated:
--     yhat_p50_season_state_12w (post-gate), offseason_gate_applied
--   
--   Derived:
--     log_yhat_p50, zero_prob_signal, demand_cv_signal, is_transition,
--     is_off_peak, seasonal_multiplier, gate_reduction_pct
--
-- OUTPUT TABLE:
--   qr_feature_matrix_h12_v4_qr_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.qr_feature_matrix_h12_v4_qr_strict` AS
WITH

base AS (
  SELECT
    base.sku_id,
    base.week_start_date AS decision_week,
    tc.eval_split_v3,
    
    -- ── Labels (y_true_12w) ────────────────────────────────────────────────
    base.y_true_12w,
    CASE WHEN base.y_true_12w IS NOT NULL THEN TRUE ELSE FALSE END AS has_label,
    
    -- ── Base BQML predictions (p50 only at base level) ────────────────────
    base.yhat_p50_12w AS yhat_p50_base,
    
    -- ── OOS probabilities ──────────────────────────────────────────────────
    -- Note: p_oos_raw not in base_scores_h12_v1, will get from v3_strict
    base.p_oos_h12 AS p_oos_calibrated,
    
    -- ── Additional base features ───────────────────────────────────────────
    base.scale,
    CAST(base.stockout_event_12w AS INT64) AS stockout_event,
    base.season_group,
    base.split AS split_original
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1` base
  JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
    ON tc.decision_week = base.week_start_date
  WHERE base.split = 'VAL'
    AND tc.eval_split_v3 IN ('DEV_TUNE', 'DEV_SELECT', 'LOCKED_TEST')
),

-- ── v3_strict quantiles (calibrated from base) ─────────────────────────────
v3_strict_quantiles AS (
  SELECT
    f.sku_id,
    f.decision_week,
    
    -- v3_strict calibrated quantiles
    f.q80_12w AS q80_v3_strict,
    f.q90_12w AS q90_v3_strict,
    f.q95_12w AS q95_v3_strict,
    
    -- Spreads
    f.q80_12w - f.yhat_p50_12w AS v3_strict_spread_p80,
    f.q90_12w - f.yhat_p50_12w AS v3_strict_spread_p90,
    f.q95_12w - f.yhat_p50_12w AS v3_strict_spread_p95,
    
    -- OOS probability raw (if available in forecast table)
    f.p_oos_h12 AS p_oos_from_v3_strict
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  WHERE f.split_original = 'VAL'
),

seasonal_features AS (
  SELECT
    ss.sku_id,
    ss.decision_week,
    
    -- ── State classification ───────────────────────────────────────────────
    COALESCE(ss.sku_season_state, 'UNKNOWN') AS sku_season_state,
    ss.state_rule_applied,
    ss.selected_level,
    
    -- ── Historical demand stats (same ISO week, prior years) ──────────────
    COALESCE(ss.hist_avg_units_same_week, 0.0) AS hist_avg_units_same_week,
    COALESCE(ss.hist_p90_units_same_week, 0.0) AS hist_p90_units_same_week,
    COALESCE(ss.hist_positive_rate_same_week, 0.0) AS hist_positive_rate_same_week,
    
    -- ── Seasonal index (ratio to annual average) ───────────────────────────
    COALESCE(ss.seasonal_index_same_week, 1.0) AS seasonal_index_same_week,
    
    -- ── Annual stats ───────────────────────────────────────────────────────
    COALESCE(ss.annual_avg_units_sku, 0.0) AS annual_avg_units_sku,
    COALESCE(ss.annual_positive_rate_sku, 0.0) AS annual_positive_rate_sku,
    
    -- ── Transition signal (slope of avg units) ────────────────────────────
    COALESCE(ss.transition_slope_avg_units, 0.0) AS transition_slope_forward,
    
    -- ── Observation count (confidence signal) ──────────────────────────────
    COALESCE(ss.n_hist_obs_available, 0) AS n_hist_observations
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
),

gated_forecast AS (
  SELECT
    fg.sku_id,
    fg.decision_week,
    
    -- ── v3_2 gated prediction (post OFF_SEASON cap) ───────────────────────
    fg.yhat_p50_original_12w,
    fg.yhat_p50_season_state_12w AS yhat_p50_gated,
    
    -- ── Gate metadata ──────────────────────────────────────────────────────
    CAST(fg.offseason_gate_applied AS INT64) AS gate_applied,
    COALESCE(fg.offseason_gate_reason, 'NONE') AS gate_reason,
    
    -- ── Gate reduction ─────────────────────────────────────────────────────
    fg.yhat_p50_original_12w - fg.yhat_p50_season_state_12w AS gate_reduction_abs,
    
    -- ── 12-week equivalent stats (from gated forecast) ─────────────────────
    COALESCE(fg.hist_avg_12w_equiv, 0.0) AS hist_avg_12w_equiv,
    COALESCE(fg.hist_p90_12w_equiv, 0.0) AS hist_p90_12w_equiv
    
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` fg
  WHERE fg.split_original = 'VAL'
),

joined AS (
  SELECT
    b.sku_id,
    b.decision_week,
    b.eval_split_v3,
    
    -- ── Label ──────────────────────────────────────────────────────────────
    b.y_true_12w,
    b.has_label,
    
    -- ── Base predictions ───────────────────────────────────────────────────
    b.yhat_p50_base,
    v3s.q80_v3_strict AS q80_base,
    v3s.q90_v3_strict AS q90_base,
    v3s.q95_v3_strict AS q95_base,
    v3s.v3_strict_spread_p80 AS base_spread_p80,
    v3s.v3_strict_spread_p90 AS base_spread_p90,
    v3s.v3_strict_spread_p95 AS base_spread_p95,
    
    -- ── Probabilities ──────────────────────────────────────────────────────
    COALESCE(v3s.p_oos_from_v3_strict, b.p_oos_calibrated) AS p_oos_raw,
    b.p_oos_calibrated,
    
    -- ── Base categorical ───────────────────────────────────────────────────
    b.season_group,
    b.scale,
    b.stockout_event,
    
    -- ── Seasonal state ─────────────────────────────────────────────────────
    sf.sku_season_state,
    sf.hist_avg_units_same_week,
    sf.hist_p90_units_same_week,
    sf.hist_positive_rate_same_week,
    sf.seasonal_index_same_week,
    sf.annual_avg_units_sku,
    sf.annual_positive_rate_sku,
    sf.transition_slope_forward,
    sf.n_hist_observations,
    
    -- ── v3_2 gated forecast ────────────────────────────────────────────────
    gf.yhat_p50_gated,
    gf.gate_applied,
    gf.gate_reason,
    gf.gate_reduction_abs,
    gf.hist_avg_12w_equiv,
    gf.hist_p90_12w_equiv,
    
    -- ── Derived features ───────────────────────────────────────────────────
    
    -- Log transformation (for model robustness with zeros)
    LN(1 + b.yhat_p50_base) AS log_yhat_p50_base,
    LN(1 + GREATEST(gf.yhat_p50_gated, b.yhat_p50_base)) AS log_yhat_p50_gated,
    
    -- Zero probability signal (combination of multiple indicators)
    GREATEST(
      1.0 - sf.hist_positive_rate_same_week,
      1.0 - sf.annual_positive_rate_sku,
      b.p_oos_calibrated
    ) AS zero_prob_signal,
    
    -- Demand coefficient of variation proxy
    SAFE_DIVIDE(
      sf.hist_p90_units_same_week - sf.hist_avg_units_same_week,
      sf.hist_avg_units_same_week + 0.01
    ) AS demand_cv_signal,
    
    -- Transition indicators
    CASE 
      WHEN sf.sku_season_state IN ('TRANSITION_UP', 'TRANSITION_DOWN') THEN 1
      ELSE 0
    END AS is_transition,
    
    -- Off-peak indicators
    CASE 
      WHEN sf.sku_season_state IN ('OFF_SEASON', 'REST_OFFPEAK') THEN 1
      ELSE 0
    END AS is_off_peak,
    
    -- Seasonal strength
    CASE
      WHEN sf.seasonal_index_same_week >= 1.5 THEN 'STRONG_SEASON'
      WHEN sf.seasonal_index_same_week >= 0.75 THEN 'MODERATE_SEASON'
      WHEN sf.seasonal_index_same_week >= 0.25 THEN 'WEAK_SEASON'
      ELSE 'OFF_SEASON'
    END AS seasonal_strength,
    
    -- Gate reduction percentage
    SAFE_DIVIDE(
      gf.gate_reduction_abs,
      b.yhat_p50_base + 0.01
    ) AS gate_reduction_pct,
    
    -- Historical confidence (enough observations?)
    CASE 
      WHEN sf.n_hist_observations >= 10 THEN 'HIGH'
      WHEN sf.n_hist_observations >= 5 THEN 'MEDIUM'
      WHEN sf.n_hist_observations >= 2 THEN 'LOW'
      ELSE 'VERY_LOW'
    END AS hist_confidence
    
  FROM base b
  LEFT JOIN v3_strict_quantiles v3s
    ON v3s.sku_id = b.sku_id AND v3s.decision_week = b.decision_week
  LEFT JOIN seasonal_features sf
    ON sf.sku_id = b.sku_id AND sf.decision_week = b.decision_week
  LEFT JOIN gated_forecast gf
    ON gf.sku_id = b.sku_id AND gf.decision_week = b.decision_week
)

SELECT
  sku_id,
  decision_week,
  eval_split_v3,
  y_true_12w,
  has_label,
  
  -- Base predictions
  yhat_p50_base,
  yhat_p50_gated,
  q80_base,
  q90_base,
  q95_base,
  
  -- Spreads
  base_spread_p80,
  base_spread_p90,
  base_spread_p95,
  
  -- Numeric features
  p_oos_raw,
  p_oos_calibrated,
  scale,
  log_yhat_p50_base,
  log_yhat_p50_gated,
  hist_avg_units_same_week,
  hist_p90_units_same_week,
  hist_positive_rate_same_week,
  seasonal_index_same_week,
  annual_avg_units_sku,
  annual_positive_rate_sku,
  transition_slope_forward,
  hist_avg_12w_equiv,
  hist_p90_12w_equiv,
  n_hist_observations,
  zero_prob_signal,
  demand_cv_signal,
  gate_reduction_abs,
  gate_reduction_pct,
  
  -- Categorical features
  season_group,
  sku_season_state,
  seasonal_strength,
  hist_confidence,
  gate_reason,
  
  -- Binary features
  stockout_event,
  gate_applied,
  is_transition,
  is_off_peak,
  
  -- Metadata
  'h12_v4_quantile_regression_strict' AS model_version,
  CURRENT_TIMESTAMP() AS feature_computed_at
  
FROM joined
ORDER BY sku_id, decision_week;


-- ============================================================================
-- FEATURE SUMMARY QUERY (to display after table creation)
-- ============================================================================
SELECT 
  eval_split_v3,
  COUNT(*) AS n_rows,
  SUM(CAST(has_label AS INT64)) AS n_labelled,
  ROUND(AVG(yhat_p50_base), 2) AS avg_yhat_p50_base,
  ROUND(AVG(yhat_p50_gated), 2) AS avg_yhat_p50_gated,
  ROUND(AVG(CASE WHEN has_label THEN y_true_12w ELSE NULL END), 2) AS avg_y_true,
  ROUND(AVG(seasonal_index_same_week), 3) AS avg_seasonal_index,
  ROUND(AVG(zero_prob_signal), 3) AS avg_zero_prob_signal,
  SUM(gate_applied) AS n_gate_applied,
  SUM(is_off_peak) AS n_off_peak,
  SUM(is_transition) AS n_transition
FROM `{PROJECT_ID}.{BQ_DATASET}.qr_feature_matrix_h12_v4_qr_strict`
GROUP BY eval_split_v3
ORDER BY eval_split_v3;
