-- ============================================================================
-- STEP 02: ASSIGN SKU_SEASON_STATE  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Classify each (sku_id, decision_week) into a semantic demand state
--   using only historical features built in step 01 (TRAIN+CALIB,
--   strictly prior years). No LOCKED_TEST data. No y_true_12w.
--
-- STATES (applied in priority order):
--
--   UNKNOWN_FALLBACK       : insufficient historical obs (< 3)
--   ALWAYS_ON              : active year-round, no seasonal off-state
--   OFF_SEASON             : historically inactive in this week
--   IN_SEASON              : historically highly active in this week
--   TRANSITION_UP          : demand historically rising toward this week
--   TRANSITION_DOWN        : demand historically falling from this week
--   REST_OFFPEAK           : REST season, below-average but not fully off
--   INTERMITTENT_RANDOM    : low activity, no detectable seasonal pattern
--   IN_SEASON (default)    : catch-all for well-behaved active periods
--
-- THRESHOLD DOCUMENTATION (all chosen from DEV_TUNE analysis, no LOCKED_TEST):
--
--   n_hist_obs_available < 3            → UNKNOWN_FALLBACK
--   annual_positive_rate >= 0.70
--     AND hist_positive_rate_same_week >= 0.50  → ALWAYS_ON
--   hist_positive_rate_same_week < 0.15
--     AND seasonal_index_same_week < 0.25       → OFF_SEASON
--   hist_positive_rate_same_week >= 0.40
--     AND seasonal_index_same_week >= 1.25      → IN_SEASON
--   transition_slope_positive_rate > +0.10
--     AND hist_positive_rate_same_week BETWEEN 0.15 AND 0.50 → TRANSITION_UP
--   transition_slope_positive_rate < -0.10
--     AND hist_positive_rate_same_week BETWEEN 0.15 AND 0.50 → TRANSITION_DOWN
--   annual_positive_rate < 0.35
--     AND ABS(seasonal_positive_index - 1.0) < 0.40  → INTERMITTENT_RANDOM
--   season_group = 'REST'
--     AND seasonal_index_same_week < 0.60             → REST_OFFPEAK
--   All remaining                                      → IN_SEASON (default)
--
-- OUTPUT TABLE:
--   sku_season_state_h12_v3_2_season_state_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` AS
WITH

features AS (
  SELECT *
  FROM `{PROJECT_ID}.{BQ_DATASET}.sku_week_seasonality_features_h12_v3_2_season_state_strict`
),

classified AS (
  SELECT
    *,
    -- ── Priority-ordered classification ──────────────────────────────
    CASE
      -- P1: Insufficient history → fallback
      WHEN n_hist_obs_available < 3
        THEN 'UNKNOWN_FALLBACK'

      -- P2: Always-on (active regardless of season)
      WHEN annual_positive_rate_sku  >= 0.70
       AND hist_positive_rate_same_week >= 0.50
        THEN 'ALWAYS_ON'

      -- P3: Off-season (historically near-zero in this week)
      WHEN hist_positive_rate_same_week < 0.15
       AND seasonal_index_same_week < 0.25
        THEN 'OFF_SEASON'

      -- P4: In-season (historically highly active)
      WHEN hist_positive_rate_same_week >= 0.40
       AND seasonal_index_same_week >= 1.25
        THEN 'IN_SEASON'

      -- P5: Transition up (demand historically rising toward this week)
      WHEN transition_slope_positive_rate > 0.10
       AND hist_positive_rate_same_week BETWEEN 0.15 AND 0.50
        THEN 'TRANSITION_UP'

      -- P6: Transition down (demand historically falling after this week)
      WHEN transition_slope_positive_rate < -0.10
       AND hist_positive_rate_same_week BETWEEN 0.15 AND 0.50
        THEN 'TRANSITION_DOWN'

      -- P7: Intermittent random (low activity, no seasonal pattern)
      WHEN annual_positive_rate_sku < 0.35
       AND ABS(seasonal_positive_index - 1.0) < 0.40
        THEN 'INTERMITTENT_RANDOM'

      -- P8: REST off-peak (REST season but below-average, not fully off)
      WHEN season_group = 'REST'
       AND seasonal_index_same_week < 0.60
        THEN 'REST_OFFPEAK'

      -- P9: Default — active, in or near season
      ELSE 'IN_SEASON'

    END AS sku_season_state,

    -- ── Rule that triggered the classification (for audit) ────────────
    CASE
      WHEN n_hist_obs_available < 3
        THEN 'n_hist_obs<3'
      WHEN annual_positive_rate_sku >= 0.70 AND hist_positive_rate_same_week >= 0.50
        THEN 'annual_pos>=0.70_AND_week_pos>=0.50'
      WHEN hist_positive_rate_same_week < 0.15 AND seasonal_index_same_week < 0.25
        THEN 'week_pos<0.15_AND_seas_idx<0.25'
      WHEN hist_positive_rate_same_week >= 0.40 AND seasonal_index_same_week >= 1.25
        THEN 'week_pos>=0.40_AND_seas_idx>=1.25'
      WHEN transition_slope_positive_rate > 0.10
       AND hist_positive_rate_same_week BETWEEN 0.15 AND 0.50
        THEN 'transition_slope>0.10'
      WHEN transition_slope_positive_rate < -0.10
       AND hist_positive_rate_same_week BETWEEN 0.15 AND 0.50
        THEN 'transition_slope<-0.10'
      WHEN annual_positive_rate_sku < 0.35
       AND ABS(seasonal_positive_index - 1.0) < 0.40
        THEN 'annual_pos<0.35_AND_no_seasonal_pattern'
      WHEN season_group = 'REST' AND seasonal_index_same_week < 0.60
        THEN 'REST_AND_seas_idx<0.60'
      ELSE 'default_in_season'
    END AS state_rule_applied,

    -- ── Fallback level for downstream use ────────────────────────────
    CASE
      WHEN n_hist_obs_available < 3    THEN 'global'
      WHEN n_hist_years_available < 2  THEN 'season_group'
      ELSE 'sku_week'
    END AS selected_level,

    -- ── Audit flags ───────────────────────────────────────────────────
    FALSE AS used_locked_test_for_classification

  FROM features
)

SELECT
  sku_id,
  decision_week,
  semana_anio,
  season_group,
  split,
  sku_season_state,
  state_rule_applied,
  selected_level,
  -- Pass through all features for downstream use
  hist_avg_units_same_week,
  hist_median_units_same_week,
  hist_p90_units_same_week,
  hist_positive_rate_same_week,
  hist_zero_rate_same_week,
  hist_avg_units_adjacent_weeks,
  hist_positive_rate_adjacent_weeks,
  hist_avg_units_prev_adj,
  hist_positive_rate_prev_adj,
  hist_avg_units_next_adj,
  hist_positive_rate_next_adj,
  annual_avg_units_sku,
  annual_positive_rate_sku,
  seasonal_index_same_week,
  seasonal_positive_index,
  transition_slope_positive_rate,
  transition_slope_avg_units,
  n_hist_obs_available,
  n_hist_years_available,
  n_annual_obs,
  n_annual_years,
  used_locked_test_for_classification,
  feature_source,
  computed_at
FROM classified;

-- ── Verification: state distribution by eval_split_v3 ────────────────────
SELECT
  ss.split,
  tc.eval_split_v3,
  ss.season_group,
  ss.sku_season_state,
  COUNT(*)                                              AS n_rows,
  COUNT(DISTINCT ss.sku_id)                             AS n_skus,
  ROUND(AVG(ss.hist_positive_rate_same_week), 4)        AS avg_hist_pos_rate,
  ROUND(AVG(ss.seasonal_index_same_week), 4)            AS avg_seasonal_idx
FROM `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
  ON tc.decision_week = ss.decision_week
GROUP BY ss.split, tc.eval_split_v3, ss.season_group, ss.sku_season_state
ORDER BY tc.eval_split_v3, ss.season_group, n_rows DESC;

-- ── Key check: REST LOCKED_TEST — do the problematic rows go to OFF_SEASON?
SELECT
  ss.sku_season_state,
  COUNT(*)                                              AS n_rows,
  ROUND(AVG(f.y_true_12w), 3)                          AS avg_actual,
  ROUND(AVG(f.yhat_p50_12w), 3)                        AS avg_pred,
  COUNTIF(f.y_true_12w = 0)                            AS n_zero_actual
FROM `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
JOIN `{PROJECT_ID}.{BQ_DATASET}.forecast_recalibrated_h12_v3_strict` f
  ON f.sku_id = ss.sku_id AND f.decision_week = ss.decision_week
JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
  ON tc.decision_week = ss.decision_week AND tc.eval_split_v3 = 'LOCKED_TEST'
WHERE ss.season_group = 'REST'
  AND f.split_original = 'VAL'
GROUP BY ss.sku_season_state
ORDER BY n_rows DESC;
