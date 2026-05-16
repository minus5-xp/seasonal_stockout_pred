-- ============================================================================
-- STEP 05: QUANTILE RECALIBRATION BY SEASON STATE  (h=12 v3_2_season_state_strict)
-- ============================================================================
-- PURPOSE:
--   Run a grid search of calibration parameters separately for each
--   sku_season_state, using only DEV_TUNE rows. Select the best config
--   per state and store it in frozen_quantile_config_by_season_state.
--
-- KEY DIFFERENCE FROM v3_strict:
--   v3_strict: one global config selected on DEV_TUNE.
--   v3_2: separate config per sku_season_state, with fallback chain:
--     state-specific → season_group → global
--
-- MODIFIED LOSS FUNCTION (vs v3_strict):
--   Adds heavy penalty for viol_p90 = 0 or viol_p80 = 0, which was the
--   pathology observed in LOCKED_TEST. A model with zero violations is
--   over-confident (too-wide intervals), not good — it cannot detect genuine
--   stockout risk.
--
--   loss = 20 * GREATEST(viol_p90 - 0.12, 0)          -- too many violations
--         + 20 * GREATEST(0.08 - viol_p90, 0)          -- too few violations
--         + 50 * CASE WHEN viol_p90 < 0.02 THEN 1      -- COLLAPSE PENALTY
--                      ELSE 0 END
--         +  5 * ABS(viol_p90 - 0.10)                  -- distance from target
--         +  3 * GREATEST(q90_p50_ratio - 3.0, 0)      -- over-wide intervals
--         +  2 * cap_rate_proxy                         -- capped forecasts
--         +  1 * ABS(viol_p80 - 0.20)                  -- p80 calibration
--         + 30 * CASE WHEN viol_p80 < 0.02 THEN 1      -- p80 COLLAPSE PENALTY
--                      ELSE 0 END
--
-- FALLBACK CHAIN (n_obs threshold for state-level selection):
--   - n_obs >= 200 in DEV_TUNE: use state-specific config
--   - 50 <= n_obs < 200:       use season_group config
--   - n_obs < 50:              use global config
--
-- OUTPUT TABLES:
--   calibration_grid_by_state_eval_dev_tune_h12_v3_2_season_state_strict
--   frozen_quantile_config_by_season_state_h12_v3_2_season_state_strict
-- ============================================================================

-- ── 5a. Count DEV_TUNE obs per state (to determine fallback level) ─────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.state_obs_counts_dev_tune_h12_v3_2_season_state_strict` AS
SELECT
  ss.sku_season_state,
  ss.season_group,
  COUNT(*)                  AS n_obs_dev_tune,
  COUNT(DISTINCT ss.sku_id) AS n_skus_dev_tune,
  CASE
    WHEN COUNT(*) >= 200 THEN 'sku_season_state'
    WHEN COUNT(*) >= 50  THEN 'season_group'
    ELSE                      'global'
  END AS selection_level
FROM `{PROJECT_ID}.{BQ_DATASET}.sku_season_state_h12_v3_2_season_state_strict` ss
JOIN `{PROJECT_ID}.{BQ_DATASET}.temporal_contract_h12_v3_strict` tc
  ON tc.decision_week = ss.decision_week AND tc.eval_split_v3 = 'DEV_TUNE'
WHERE ss.split = 'VAL'
GROUP BY ss.sku_season_state, ss.season_group;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.state_obs_counts_dev_tune_h12_v3_2_season_state_strict`
ORDER BY sku_season_state, season_group;

-- ── 5b. Calibration grid evaluation per sku_season_state on DEV_TUNE ──────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_by_state_eval_dev_tune_h12_v3_2_season_state_strict` AS
WITH

-- Reuse frozen quantile lookup and VIF from v3_strict (built on CALIB)
-- Grid: same parameter space as v3_strict
grid AS (
  SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_h12_v3_strict`
),

-- DEV_TUNE rows with season state assigned
dev_tune_base AS (
  SELECT
    f.sku_id,
    f.decision_week,
    f.y_true_12w,
    f.yhat_p50_season_state_12w AS yhat_p50_12w,  -- use gated forecast
    f.scale_v1,
    f.cf_v3,
    f.segment_id_child,
    f.season_group,
    f.sku_season_state,
    -- Extended quantile scores from v3_strict lookup
    q.q_score_p90,
    q.q_score_p91,
    q.q_score_p92,
    q.q_score_p93,
    q.q_score_p95,
    q.q_score_p96,
    q.q_score_p80
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_gated_h12_v3_2_season_state_strict` f
  LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.quantile_lookup_extended_h12_v3_strict` q
    ON q.segment_id_child = f.segment_id_child
  WHERE f.eval_split_v3 = 'DEV_TUNE'
    AND f.split_original = 'VAL'
    AND f.y_true_12w IS NOT NULL
),

-- Segment-level viol rates on DEV_TUNE for correction factor
seg_viol AS (
  SELECT segment_id_child, season_group, sku_season_state,
    AVG(CASE WHEN y_true_12w > GREATEST(0.0,
          yhat_p50_12w + COALESCE(q_score_p90, 1.645) * scale_v1)
        THEN 1.0 ELSE 0.0 END) AS raw_viol_p90
  FROM dev_tune_base
  GROUP BY segment_id_child, season_group, sku_season_state
),

season_viol AS (
  SELECT season_group, sku_season_state,
    AVG(CASE WHEN y_true_12w > GREATEST(0.0,
          yhat_p50_12w + COALESCE(q_score_p90, 1.645) * scale_v1)
        THEN 1.0 ELSE 0.0 END) AS raw_viol_p90_season
  FROM dev_tune_base
  GROUP BY season_group, sku_season_state
),

global_viol AS (
  SELECT AVG(CASE WHEN y_true_12w > GREATEST(0.0,
          yhat_p50_12w + COALESCE(q_score_p90, 1.645) * scale_v1)
      THEN 1.0 ELSE 0.0 END) AS raw_viol_p90_global
  FROM dev_tune_base
),

tune_with_viol AS (
  SELECT t.*,
    COALESCE(sv.raw_viol_p90, ssv.raw_viol_p90_season, g.raw_viol_p90_global, 0.10) AS eff_viol_p90
  FROM dev_tune_base t
  LEFT JOIN seg_viol sv USING (segment_id_child, season_group, sku_season_state)
  LEFT JOIN season_viol ssv USING (season_group, sku_season_state)
  CROSS JOIN global_viol g
),

-- Cross-join grid with DEV_TUNE data, compute quantiles per config
grid_eval_raw AS (
  SELECT
    g.config_id,
    g.scale_multiplier,
    g.q90_offset,
    g.q95_offset,
    g.factor_clip_hi,
    t.y_true_12w,
    t.yhat_p50_12w,
    t.sku_season_state,
    t.season_group,
    -- scale
    t.scale_v1 * g.scale_multiplier AS scale_v3_2,
    -- correction factor
    LEAST(g.factor_clip_hi, GREATEST(0.80,
      SAFE_DIVIDE(t.eff_viol_p90, 0.10)
    )) AS cf_v3_2,
    -- q90 score at offset
    CASE g.q90_offset
      WHEN 90 THEN COALESCE(t.q_score_p90, 1.645)
      WHEN 91 THEN COALESCE(t.q_score_p91, t.q_score_p90, 1.645)
      WHEN 92 THEN COALESCE(t.q_score_p92, t.q_score_p90, 1.645)
      ELSE COALESCE(t.q_score_p90, 1.645)
    END AS q_score_q90_eff,
    CASE g.q95_offset
      WHEN 95 THEN COALESCE(t.q_score_p95, 1.960)
      WHEN 96 THEN COALESCE(t.q_score_p96, t.q_score_p95, 1.960)
      ELSE COALESCE(t.q_score_p95, 1.960)
    END AS q_score_q95_eff,
    COALESCE(t.q_score_p80, 1.282) AS q_score_p80
  FROM tune_with_viol t
  CROSS JOIN grid g
),

grid_eval_quantiles AS (
  SELECT
    config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
    y_true_12w, yhat_p50_12w, sku_season_state, season_group,
    GREATEST(0.0, yhat_p50_12w + q_score_p80     * cf_v3_2 * scale_v3_2) AS q80_v3_2,
    GREATEST(0.0, yhat_p50_12w + q_score_q90_eff * cf_v3_2 * scale_v3_2) AS q90_v3_2,
    GREATEST(0.0, yhat_p50_12w + q_score_q95_eff * cf_v3_2 * scale_v3_2) AS q95_v3_2,
    yhat_p50_12w AS p50_v3_2,
    scale_v3_2
  FROM grid_eval_raw
)

-- Aggregate per (config_id × sku_season_state)
SELECT
  config_id,
  scale_multiplier,
  q90_offset,
  q95_offset,
  factor_clip_hi,
  sku_season_state,
  season_group,
  COUNT(*) AS n_rows,
  ROUND(AVG(CASE WHEN y_true_12w > q80_v3_2 THEN 1.0 ELSE 0.0 END), 4) AS viol_p80,
  ROUND(AVG(CASE WHEN y_true_12w > q90_v3_2 THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
  ROUND(AVG(CASE WHEN y_true_12w > q95_v3_2 THEN 1.0 ELSE 0.0 END), 4) AS viol_p95,
  ROUND(
    APPROX_QUANTILES(SAFE_DIVIDE(q90_v3_2, NULLIF(p50_v3_2, 0)), 100)[OFFSET(50)]
  , 3) AS q90_p50_ratio_median,
  ROUND(SAFE_DIVIDE(
    COUNTIF(SAFE_DIVIDE(q90_v3_2, NULLIF(p50_v3_2, 0)) > 5.0), COUNT(*)), 4) AS cap_rate_proxy,
  -- Modified loss with collapse penalty
  ROUND(
    20.0 * GREATEST(AVG(CASE WHEN y_true_12w > q90_v3_2 THEN 1.0 ELSE 0.0 END) - 0.12, 0)
    + 20.0 * GREATEST(0.08 - AVG(CASE WHEN y_true_12w > q90_v3_2 THEN 1.0 ELSE 0.0 END), 0)
    + 50.0 * CASE WHEN AVG(CASE WHEN y_true_12w > q90_v3_2 THEN 1.0 ELSE 0.0 END) < 0.02
                  THEN 1.0 ELSE 0.0 END
    +  5.0 * ABS(AVG(CASE WHEN y_true_12w > q90_v3_2 THEN 1.0 ELSE 0.0 END) - 0.10)
    +  3.0 * GREATEST(
               APPROX_QUANTILES(SAFE_DIVIDE(q90_v3_2, NULLIF(p50_v3_2,0)),100)[OFFSET(50)] - 3.0, 0)
    +  2.0 * SAFE_DIVIDE(
               COUNTIF(SAFE_DIVIDE(q90_v3_2, NULLIF(p50_v3_2,0)) > 5.0), COUNT(*))
    +  1.0 * ABS(AVG(CASE WHEN y_true_12w > q80_v3_2 THEN 1.0 ELSE 0.0 END) - 0.20)
    + 30.0 * CASE WHEN AVG(CASE WHEN y_true_12w > q80_v3_2 THEN 1.0 ELSE 0.0 END) < 0.02
                  THEN 1.0 ELSE 0.0 END
  , 5) AS calibration_loss,
  'DEV_TUNE' AS evaluated_on_split,
  FALSE      AS used_locked_test
FROM grid_eval_quantiles
WHERE yhat_p50_12w >= 0
GROUP BY config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
         sku_season_state, season_group;

-- ── 5c. FROZEN QUANTILE CONFIG BY STATE ───────────────────────────────────
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_by_season_state_h12_v3_2_season_state_strict` AS
WITH

obs_counts AS (
  SELECT sku_season_state, season_group, n_obs_dev_tune, selection_level
  FROM `{PROJECT_ID}.{BQ_DATASET}.state_obs_counts_dev_tune_h12_v3_2_season_state_strict`
),

-- Best config per state (where n >= 200)
best_per_state AS (
  SELECT
    g.sku_season_state,
    g.season_group,
    g.config_id,
    g.scale_multiplier,
    g.q90_offset,
    g.q95_offset,
    g.factor_clip_hi,
    g.viol_p80,
    g.viol_p90,
    g.viol_p95,
    g.q90_p50_ratio_median,
    g.cap_rate_proxy,
    g.calibration_loss,
    g.n_rows,
    g.evaluated_on_split,
    g.used_locked_test,
    ROW_NUMBER() OVER (
      PARTITION BY g.sku_season_state, g.season_group
      ORDER BY g.calibration_loss ASC
    ) AS rnk
  FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_by_state_eval_dev_tune_h12_v3_2_season_state_strict` g
  JOIN obs_counts o USING (sku_season_state, season_group)
  WHERE o.n_obs_dev_tune >= 200   -- state-specific selection threshold
),

-- Best config globally (fallback)
best_global AS (
  SELECT
    'GLOBAL_FALLBACK' AS sku_season_state,
    'ALL'             AS season_group,
    config_id,
    scale_multiplier,
    q90_offset,
    q95_offset,
    factor_clip_hi,
    AVG(viol_p80) AS viol_p80,
    AVG(viol_p90) AS viol_p90,
    AVG(viol_p95) AS viol_p95,
    AVG(q90_p50_ratio_median) AS q90_p50_ratio_median,
    AVG(cap_rate_proxy) AS cap_rate_proxy,
    AVG(calibration_loss) AS calibration_loss,
    SUM(n_rows) AS n_rows,
    'DEV_TUNE' AS evaluated_on_split,
    FALSE AS used_locked_test,
    ROW_NUMBER() OVER (ORDER BY AVG(calibration_loss) ASC) AS rnk
  FROM `{PROJECT_ID}.{BQ_DATASET}.calibration_grid_by_state_eval_dev_tune_h12_v3_2_season_state_strict`
  GROUP BY config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi
)

-- Combine: state-specific where available, global fallback otherwise
SELECT
  sku_season_state,
  season_group,
  'sku_season_state'        AS selected_level,
  config_id,
  scale_multiplier,
  q90_offset,
  q95_offset,
  CAST(NULL AS FLOAT64)     AS q80_offset,  -- reserved for future
  factor_clip_hi,
  viol_p80                  AS cv_viol_p80,
  viol_p90                  AS cv_viol_p90,
  viol_p95                  AS cv_viol_p95,
  calibration_loss          AS cv_loss,
  n_rows                    AS n_selection_obs,
  evaluated_on_split        AS selected_using_split,
  TRUE                      AS selected_without_locked_test,
  used_locked_test,
  q90_p50_ratio_median,
  cap_rate_proxy,
  CURRENT_TIMESTAMP()       AS frozen_at
FROM best_per_state
WHERE rnk = 1

UNION ALL

-- Global fallback for states with insufficient DEV_TUNE obs
SELECT
  bg.sku_season_state,
  bg.season_group,
  'global_fallback'         AS selected_level,
  bg.config_id,
  bg.scale_multiplier,
  bg.q90_offset,
  bg.q95_offset,
  CAST(NULL AS FLOAT64)     AS q80_offset,
  bg.factor_clip_hi,
  bg.viol_p80               AS cv_viol_p80,
  bg.viol_p90               AS cv_viol_p90,
  bg.viol_p95               AS cv_viol_p95,
  bg.calibration_loss       AS cv_loss,
  bg.n_rows                 AS n_selection_obs,
  bg.evaluated_on_split     AS selected_using_split,
  TRUE                      AS selected_without_locked_test,
  bg.used_locked_test,
  bg.q90_p50_ratio_median,
  bg.cap_rate_proxy,
  CURRENT_TIMESTAMP()       AS frozen_at
FROM best_global bg
WHERE bg.rnk = 1
  -- Only insert fallback for states that didn't get a state-specific config
  AND bg.sku_season_state NOT IN (
    SELECT DISTINCT sku_season_state FROM best_per_state WHERE rnk = 1
  );

SELECT
  sku_season_state, season_group, selected_level,
  scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
  cv_viol_p90, cv_loss, n_selection_obs,
  selected_using_split, selected_without_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.frozen_quantile_config_by_season_state_h12_v3_2_season_state_strict`
ORDER BY sku_season_state;
