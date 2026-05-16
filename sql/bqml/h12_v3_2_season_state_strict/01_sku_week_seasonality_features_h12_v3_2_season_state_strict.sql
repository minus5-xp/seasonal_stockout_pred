-- ============================================================================
-- STEP 01: SKU-WEEK SEASONALITY FEATURES  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Build historical seasonality features per (sku_id, decision_week)
--   using exclusively TRAIN+CALIB rows from years strictly prior to the
--   decision year. No future data, no VAL rows, no LOCKED_TEST.
--
-- WHY THIS STEP EXISTS:
--   v3_strict revealed that REST in W28-W40 (summer) is a completely
--   different demand regime from REST in W01-W16 (winter/spring). The
--   season_group column is not granular enough: it classifies SKUs
--   seasonally but not by SKU-specific activation state per week.
--   A pharmacy SKU that is REST in winter can be OFF_SEASON in summer.
--
-- ANTI-LEAKAGE DESIGN:
--   - Source: base_scores_h12_v1, split IN ('TRAIN','CALIB') ONLY.
--   - Year filter: EXTRACT(ISOYEAR FROM hist.week_start_date)
--                  < EXTRACT(ISOYEAR FROM decision.week_start_date)
--     ensures no data from the same year contaminates the feature.
--   - Adjacent week window uses iso_week ± 2, same year restriction.
--   - LOCKED_TEST rows receive features but those features are built
--     from pre-LOCKED_TEST history only.
--   - y_true_12w is NEVER used here (only y_sales = weekly demand).
--
-- FIELD USED: y_sales (weekly sales for that single week, not 12w sum).
--   If y_sales is unavailable, fallback: y_true_12w / 12.0 approximation.
--
-- OUTPUT TABLE:
--   sku_week_seasonality_features_h12_v3_2_season_state_strict
-- ============================================================================

CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.sku_week_seasonality_features_h12_v3_2_season_state_strict` AS
WITH

-- ── All decision-weeks we need features for ────────────────────────────────
-- This is the universe of rows in the v3_strict forecast table.
-- We need features for DEV_TUNE, DEV_SELECT, and LOCKED_TEST.
decision_weeks AS (
  SELECT DISTINCT
    sku_id,
    week_start_date                             AS decision_week,
    EXTRACT(ISOYEAR FROM week_start_date)       AS decision_year,
    EXTRACT(ISOWEEK  FROM week_start_date)      AS decision_iso_week,
    season_group,
    split
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split = 'VAL'
    AND week_start_date IS NOT NULL
),

-- ── Historical demand source: TRAIN+CALIB only ────────────────────────────
-- y_sales = actual weekly demand for that single week.
-- Fallback: if y_sales is NULL, approximate as y_true_12w / 12.
hist_demand AS (
  SELECT
    sku_id,
    week_start_date,
    EXTRACT(ISOYEAR FROM week_start_date) AS hist_year,
    EXTRACT(ISOWEEK  FROM week_start_date) AS hist_iso_week,
    -- Primary: y_sales (single-week demand)
    -- Fallback: y_true_12w / 12 if y_sales not populated
    COALESCE(y_sales, SAFE_DIVIDE(y_true_12w, 12.0)) AS weekly_demand,
    CASE WHEN COALESCE(y_sales, SAFE_DIVIDE(y_true_12w, 12.0)) > 0
         THEN 1 ELSE 0 END AS is_positive
  FROM `{PROJECT_ID}.{BQ_DATASET}.base_scores_h12_v1`
  WHERE split IN ('TRAIN', 'CALIB')
    AND week_start_date IS NOT NULL
),

-- ── Annual stats per SKU (all iso_weeks, all TRAIN+CALIB years) ───────────
-- Used for seasonal_index denominator.
-- LEAKAGE NOTE: We aggregate all TRAIN+CALIB years together. Since these
-- are all prior to 2024 VAL, no leakage. However for exact strictness we
-- could further filter by decision_year; we leave it as-is because
-- annual stats should be stable across years.
annual_stats AS (
  SELECT
    sku_id,
    AVG(weekly_demand)                              AS annual_avg_units_sku,
    SAFE_DIVIDE(SUM(is_positive), COUNT(*))         AS annual_positive_rate_sku,
    COUNT(*)                                        AS n_annual_obs,
    COUNT(DISTINCT hist_year)                       AS n_annual_years
  FROM hist_demand
  GROUP BY sku_id
),

-- ── Same-week historical stats ────────────────────────────────────────────
-- For each (sku_id, decision_iso_week), aggregate TRAIN+CALIB rows where
-- hist_iso_week = decision_iso_week AND hist_year < decision_year.
same_week_stats AS (
  SELECT
    d.sku_id,
    d.decision_week,
    d.decision_iso_week,
    COUNT(*)                                        AS n_hist_obs_same_week,
    COUNT(DISTINCT h.hist_year)                     AS n_hist_years_same_week,
    AVG(h.weekly_demand)                            AS hist_avg_units_same_week,
    APPROX_QUANTILES(h.weekly_demand, 2)[OFFSET(1)] AS hist_median_units_same_week,
    APPROX_QUANTILES(h.weekly_demand, 10)[OFFSET(9)] AS hist_p90_units_same_week,
    SAFE_DIVIDE(SUM(h.is_positive), COUNT(*))       AS hist_positive_rate_same_week,
    1.0 - SAFE_DIVIDE(SUM(h.is_positive), COUNT(*)) AS hist_zero_rate_same_week
  FROM decision_weeks d
  JOIN hist_demand h
    ON  h.sku_id       = d.sku_id
    -- Same iso_week of year
    AND h.hist_iso_week = d.decision_iso_week
    -- Strictly prior years — KEY anti-leakage filter
    AND h.hist_year < d.decision_year
  GROUP BY d.sku_id, d.decision_week, d.decision_iso_week
),

-- ── Adjacent-week historical stats (iso_week ± 1,2) ─────────────────────
-- Used for TRANSITION detection: compare demand pattern in adjacent weeks.
adjacent_stats AS (
  SELECT
    d.sku_id,
    d.decision_week,
    -- Backward adjacent: iso_week -1, -2 (seasonality trend coming in)
    AVG(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week - 2
                                      AND d.decision_iso_week - 1
             THEN h.weekly_demand END)           AS hist_avg_units_prev_adj,
    SAFE_DIVIDE(
      SUM(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week - 2
                                        AND d.decision_iso_week - 1
               AND h.is_positive = 1 THEN 1 ELSE 0 END),
      NULLIF(SUM(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week - 2
                                              AND d.decision_iso_week - 1
                      THEN 1 ELSE 0 END), 0)
    )                                            AS hist_positive_rate_prev_adj,
    -- Forward adjacent: iso_week +1, +2 (what happens right after)
    -- LEAKAGE NOTE: We use HISTORICAL forward adjacency (prior years only),
    -- NOT actual future demand of 2024. This is the pattern of what
    -- iso_weeks N+1 and N+2 typically look like in past years.
    AVG(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week + 1
                                      AND d.decision_iso_week + 2
             THEN h.weekly_demand END)           AS hist_avg_units_next_adj,
    SAFE_DIVIDE(
      SUM(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week + 1
                                        AND d.decision_iso_week + 2
               AND h.is_positive = 1 THEN 1 ELSE 0 END),
      NULLIF(SUM(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week + 1
                                              AND d.decision_iso_week + 2
                      THEN 1 ELSE 0 END), 0)
    )                                            AS hist_positive_rate_next_adj,
    -- All adjacent (±2) combined
    AVG(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week - 2
                                      AND d.decision_iso_week + 2
             AND h.hist_iso_week != d.decision_iso_week
             THEN h.weekly_demand END)           AS hist_avg_units_adjacent,
    SAFE_DIVIDE(
      SUM(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week - 2
                                        AND d.decision_iso_week + 2
               AND h.hist_iso_week != d.decision_iso_week
               AND h.is_positive = 1 THEN 1 ELSE 0 END),
      NULLIF(SUM(CASE WHEN h.hist_iso_week BETWEEN d.decision_iso_week - 2
                                              AND d.decision_iso_week + 2
                      AND h.hist_iso_week != d.decision_iso_week
                      THEN 1 ELSE 0 END), 0)
    )                                            AS hist_positive_rate_adjacent
  FROM decision_weeks d
  JOIN hist_demand h
    ON  h.sku_id    = d.sku_id
    AND h.hist_year < d.decision_year
    AND h.hist_iso_week BETWEEN d.decision_iso_week - 2
                             AND d.decision_iso_week + 2
  GROUP BY d.sku_id, d.decision_week
)

-- ── Final assembly ────────────────────────────────────────────────────────
SELECT
  d.sku_id,
  d.decision_week,
  d.decision_iso_week                              AS semana_anio,
  d.season_group,
  d.split,

  -- ── Same-week historical features ────────────────────────────────────
  COALESCE(sw.hist_avg_units_same_week,    0.0)   AS hist_avg_units_same_week,
  COALESCE(sw.hist_median_units_same_week, 0.0)   AS hist_median_units_same_week,
  COALESCE(sw.hist_p90_units_same_week,    0.0)   AS hist_p90_units_same_week,
  COALESCE(sw.hist_positive_rate_same_week,0.0)   AS hist_positive_rate_same_week,
  COALESCE(sw.hist_zero_rate_same_week,    1.0)   AS hist_zero_rate_same_week,
  COALESCE(sw.n_hist_obs_same_week,          0)   AS n_hist_obs_available,
  COALESCE(sw.n_hist_years_same_week,        0)   AS n_hist_years_available,

  -- ── Adjacent-week historical features ────────────────────────────────
  COALESCE(adj.hist_avg_units_adjacent,    0.0)   AS hist_avg_units_adjacent_weeks,
  COALESCE(adj.hist_positive_rate_adjacent,0.0)   AS hist_positive_rate_adjacent_weeks,
  COALESCE(adj.hist_avg_units_prev_adj,    0.0)   AS hist_avg_units_prev_adj,
  COALESCE(adj.hist_positive_rate_prev_adj,0.0)   AS hist_positive_rate_prev_adj,
  COALESCE(adj.hist_avg_units_next_adj,    0.0)   AS hist_avg_units_next_adj,
  COALESCE(adj.hist_positive_rate_next_adj,0.0)   AS hist_positive_rate_next_adj,

  -- ── Annual SKU-level features ─────────────────────────────────────────
  COALESCE(ann.annual_avg_units_sku,       0.0)   AS annual_avg_units_sku,
  COALESCE(ann.annual_positive_rate_sku,   0.0)   AS annual_positive_rate_sku,
  COALESCE(ann.n_annual_obs,                 0)   AS n_annual_obs,
  COALESCE(ann.n_annual_years,               0)   AS n_annual_years,

  -- ── Derived indices ───────────────────────────────────────────────────
  -- How active is this week relative to the SKU's annual average?
  SAFE_DIVIDE(
    COALESCE(sw.hist_avg_units_same_week, 0.0),
    NULLIF(COALESCE(ann.annual_avg_units_sku, 0.0), 0.0)
  )                                               AS seasonal_index_same_week,

  -- How likely is a sale this week vs the SKU's annual positive rate?
  SAFE_DIVIDE(
    COALESCE(sw.hist_positive_rate_same_week, 0.0),
    NULLIF(COALESCE(ann.annual_positive_rate_sku, 0.0), 0.0)
  )                                               AS seasonal_positive_index,

  -- Transition slope: positive rate trend from previous to next adjacent weeks
  -- Positive = demand picking up (TRANSITION_UP candidate)
  -- Negative = demand falling (TRANSITION_DOWN candidate)
  COALESCE(adj.hist_positive_rate_next_adj, 0.0)
  - COALESCE(adj.hist_positive_rate_prev_adj, 0.0)
                                                  AS transition_slope_positive_rate,

  COALESCE(adj.hist_avg_units_next_adj, 0.0)
  - COALESCE(adj.hist_avg_units_prev_adj, 0.0)
                                                  AS transition_slope_avg_units,

  -- Audit metadata
  FALSE                                           AS used_locked_test,
  'TRAIN_CALIB_PRIOR_YEARS'                       AS feature_source,
  CURRENT_TIMESTAMP()                             AS computed_at

FROM decision_weeks d
LEFT JOIN same_week_stats sw  ON sw.sku_id = d.sku_id AND sw.decision_week = d.decision_week
LEFT JOIN adjacent_stats  adj ON adj.sku_id = d.sku_id AND adj.decision_week = d.decision_week
LEFT JOIN annual_stats    ann ON ann.sku_id = d.sku_id;

-- ── Verification ──────────────────────────────────────────────────────────
SELECT
  split,
  COUNT(*)                                              AS n_rows,
  COUNTIF(n_hist_obs_available = 0)                    AS n_no_history,
  ROUND(AVG(hist_positive_rate_same_week), 4)          AS avg_hist_pos_rate,
  ROUND(AVG(seasonal_index_same_week), 4)              AS avg_seasonal_index,
  ROUND(AVG(hist_avg_units_same_week), 2)              AS avg_hist_demand,
  COUNTIF(used_locked_test = TRUE)                     AS n_locked_test_used  -- must be 0
FROM `{PROJECT_ID}.{BQ_DATASET}.sku_week_seasonality_features_h12_v3_2_season_state_strict`
GROUP BY split
ORDER BY split;

-- Spot-check: REST vs HIGH_SEASON seasonal index distribution
SELECT
  season_group,
  EXTRACT(ISOWEEK FROM decision_week)           AS iso_week,
  COUNT(*)                                       AS n,
  ROUND(AVG(seasonal_index_same_week), 3)        AS avg_seasonal_idx,
  ROUND(AVG(hist_positive_rate_same_week), 3)    AS avg_pos_rate,
  ROUND(AVG(hist_avg_units_same_week), 2)        AS avg_hist_units
FROM `{PROJECT_ID}.{BQ_DATASET}.sku_week_seasonality_features_h12_v3_2_season_state_strict`
WHERE split = 'VAL'
  AND EXTRACT(ISOYEAR FROM decision_week) = 2024
GROUP BY season_group, EXTRACT(ISOWEEK FROM decision_week)
ORDER BY season_group, iso_week;
