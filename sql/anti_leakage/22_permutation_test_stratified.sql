-- ============================================================================
-- ANTI-LEAKAGE T2 STRATIFIED: PERMUTATION TEST WITH TEMPORAL STRATIFICATION
-- ============================================================================
-- Purpose: Robust permutation test with stratification by week
--   - Permute labels WITHIN each week (preserves temporal distribution)
--   - Use FARM_FINGERPRINT for deterministic shuffling with seed
--   - Single seed execution (caller will run multiple seeds)
--
-- Expected: AUC_permuted ≈ 0.50 ± 0.03 (95% CI from 30 seeds)
--
-- Parameters:
--   {seed}: Integer seed for reproducible permutation (0-29)
-- ============================================================================

DECLARE SEED INT64 DEFAULT {seed};
DECLARE VAL_START_DATE DATE DEFAULT '2024-01-01';
DECLARE VAL_END_DATE DATE DEFAULT '2024-12-29';

-- ====================
-- Step 1: Stratified Permutation (by week)
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.features_permuted_stratified_seed{seed}` AS
WITH val_data AS (
  SELECT
    *,
    -- Assign row number WITHIN each week for stratified shuffle
    ROW_NUMBER() OVER (
      PARTITION BY week_start_date 
      ORDER BY FARM_FINGERPRINT(CONCAT(CAST(sku_id AS STRING), CAST(SEED AS STRING)))
    ) AS row_num_within_week,
    COUNT(*) OVER (PARTITION BY week_start_date) AS n_rows_week
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE split = 'VAL'
    AND y_oos_h4 IS NOT NULL
    AND ever_sold_flag = 1
),

labels_shuffled AS (
  -- Circular shift: row i gets label from row (i + 1) mod n_rows_week
  SELECT
    week_start_date,
    row_num_within_week,
    y_oos_h4 AS original_label,
    LEAD(y_oos_h4, 1) OVER (
      PARTITION BY week_start_date 
      ORDER BY row_num_within_week
    ) AS y_oos_h4_permuted
  FROM val_data
),

-- Handle last row per week (circular: wrap to first row)
labels_complete AS (
  SELECT
    ls.week_start_date,
    ls.row_num_within_week,
    COALESCE(
      ls.y_oos_h4_permuted,
      FIRST_VALUE(ls.original_label) OVER (
        PARTITION BY ls.week_start_date 
        ORDER BY ls.row_num_within_week
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      )
    ) AS y_oos_h4_permuted
  FROM labels_shuffled ls
)

SELECT
  vd.* EXCEPT(y_oos_h4, row_num_within_week, n_rows_week),
  lc.y_oos_h4_permuted AS y_oos_h4
FROM val_data vd
JOIN labels_complete lc
  ON vd.week_start_date = lc.week_start_date
  AND vd.row_num_within_week = lc.row_num_within_week;

-- Diagnostic
SELECT
  SEED AS seed_used,
  COUNT(*) AS total_rows,
  SUM(y_oos_h4) AS n_oos_permuted,
  AVG(y_oos_h4) AS prevalence_permuted,
  -- Check: prevalence should match original
  (SELECT AVG(y_oos_h4) FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'VAL') AS prevalence_original,
  ABS(AVG(y_oos_h4) - (SELECT AVG(y_oos_h4) FROM `{dataset_ref}.weekly_features_h4` WHERE split = 'VAL')) AS prevalence_delta
FROM `{dataset_ref}.features_permuted_stratified_seed{seed}`;


-- ====================
-- Step 2: Evaluate Baseline Model on Permuted Labels
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_permuted_stratified_seed{seed}` AS
SELECT
  SEED AS seed_used,
  *
FROM ML.EVALUATE(
  MODEL `{dataset_ref}.m_oos_h4`,
  (
    SELECT
      y_oos_h4,
      lag_1, lag_2, lag_4,
      roll4_mean, roll13_mean, roll13_std,
      iso_week, is_high_season,
      hhi_base_roll13, n_customers_roll13, top_customer_share,
      amplitude, cv_roll13, n_days_nonzero
    FROM `{dataset_ref}.features_permuted_stratified_seed{seed}`
  )
);

-- ====================
-- Step 3: Store Results (for aggregation across seeds)
-- ====================
CREATE TABLE IF NOT EXISTS `{dataset_ref}.anti_leakage_permutation_runs` (
  seed INT64,
  execution_timestamp TIMESTAMP,
  n_samples INT64,
  prevalence_permuted FLOAT64,
  roc_auc FLOAT64,
  log_loss FLOAT64,
  precision FLOAT64,
  recall FLOAT64,
  f1_score FLOAT64,
  accuracy FLOAT64
);

INSERT INTO `{dataset_ref}.anti_leakage_permutation_runs`
SELECT
  SEED AS seed,
  CURRENT_TIMESTAMP() AS execution_timestamp,
  (SELECT COUNT(*) FROM `{dataset_ref}.features_permuted_stratified_seed{seed}`) AS n_samples,
  (SELECT AVG(y_oos_h4) FROM `{dataset_ref}.features_permuted_stratified_seed{seed}`) AS prevalence_permuted,
  roc_auc,
  log_loss,
  precision,
  recall,
  f1_score,
  accuracy
FROM `{dataset_ref}.eval_permuted_stratified_seed{seed}`;

-- ====================
-- Step 4: Cleanup (optional - comment out to keep temp tables)
-- ====================
-- DROP TABLE IF EXISTS `{dataset_ref}.features_permuted_stratified_seed{seed}`;
-- DROP TABLE IF EXISTS `{dataset_ref}.eval_permuted_stratified_seed{seed}`;

-- ====================
-- Step 5: Query Result
-- ====================
SELECT
  seed,
  n_samples,
  prevalence_permuted,
  roc_auc,
  log_loss,
  precision,
  recall,
  CASE
    WHEN roc_auc BETWEEN 0.47 AND 0.53 THEN '✅ Random (within tolerance)'
    WHEN roc_auc BETWEEN 0.45 AND 0.55 THEN '⚠️ Near-random (acceptable)'
    ELSE '❌ Not random'
  END AS verdict
FROM `{dataset_ref}.anti_leakage_permutation_runs`
WHERE seed = SEED
ORDER BY execution_timestamp DESC
LIMIT 1;
