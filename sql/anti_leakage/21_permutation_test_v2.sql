-- ============================================================================
-- ANTI-LEAKAGE TEST T2: PERMUTATION TEST (VERSIÓN REAL)
-- ============================================================================
-- Purpose: Shuffle labels to verify performance collapses to random
--   - Uses REAL tables: weekly_features_h4, m_oos_h4
--   - Permutes y_oos_h4 using ROW_NUMBER() + RAND()
--   - Expected: AUC ≈ 0.50, Baseline/Permuted > 1.5x
--
-- Success criteria:
--   0.45 < AUC_permuted < 0.55 (random guessing)
--   AUC_baseline / AUC_permuted > 1.5x
-- ============================================================================

DECLARE TRAIN_START_DATE DATE DEFAULT '2020-01-06';
DECLARE TRAIN_END_DATE DATE DEFAULT '2023-06-30';
DECLARE VAL_START_DATE DATE DEFAULT '2024-01-01';
DECLARE VAL_END_DATE DATE DEFAULT '2024-12-29';

-- ====================
-- Step 1: Permute Labels
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.features_permuted_labels_h4` AS
WITH val_data AS (
  SELECT
    *,
    ROW_NUMBER() OVER (ORDER BY RAND()) AS row_num_shuffle
  FROM `{dataset_ref}.weekly_features_h4`
  WHERE split = 'VAL'
    AND y_oos_h4 IS NOT NULL
    AND ever_sold_flag = 1
),

labels_shuffled AS (
  SELECT
    row_num_shuffle,
    LEAD(y_oos_h4) OVER (ORDER BY RAND()) AS y_oos_h4_permuted
  FROM val_data
)

SELECT
  vd.* EXCEPT(y_oos_h4, row_num_shuffle),
  COALESCE(ls.y_oos_h4_permuted, vd.y_oos_h4) AS y_oos_h4  -- Replace with permuted
FROM val_data vd
LEFT JOIN labels_shuffled ls
  ON vd.row_num_shuffle = ls.row_num_shuffle;

-- Diagnostic
SELECT
  'Permuted Labels Created' AS status,
  COUNT(*) AS total_rows,
  SUM(y_oos_h4) AS n_oos,
  AVG(y_oos_h4) AS prevalence_permuted,
  -- Should be ~same prevalence, but random correlation
  CORR(y_oos_h4, lag_1) AS corr_label_lag1_permuted
FROM `{dataset_ref}.features_permuted_labels_h4`;

-- ====================
-- Step 2: Evaluate BASELINE on Permuted Data
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_baseline_permuted_h4` AS
SELECT *
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
    FROM `{dataset_ref}.features_permuted_labels_h4`
  )
);

SELECT * FROM `{dataset_ref}.eval_baseline_permuted_h4`;

-- ====================
-- Step 3: Get BASELINE AUC (Real Labels)
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.eval_baseline_real_h4` AS
SELECT
  roc_auc AS baseline_auc_real
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
    FROM `{dataset_ref}.weekly_features_h4`
    WHERE split = 'VAL'
      AND y_oos_h4 IS NOT NULL
      AND ever_sold_flag = 1
  )
);

SELECT * FROM `{dataset_ref}.eval_baseline_real_h4`;

-- ====================
-- Step 4: Compare REAL vs PERMUTED
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.comparison_baseline_vs_permuted_h4` AS
WITH metrics AS (
  SELECT
    (SELECT baseline_auc_real FROM `{dataset_ref}.eval_baseline_real_h4` LIMIT 1) AS baseline_auc,
    (SELECT roc_auc FROM `{dataset_ref}.eval_baseline_permuted_h4` LIMIT 1) AS permuted_auc,
    (SELECT precision FROM `{dataset_ref}.eval_baseline_permuted_h4` LIMIT 1) AS permuted_precision
)
SELECT
  baseline_auc,
  permuted_auc,
  baseline_auc / permuted_auc AS auc_ratio,
  permuted_precision,
  CASE
    WHEN permuted_auc BETWEEN 0.45 AND 0.55 AND baseline_auc / permuted_auc > 1.5
    THEN '✅ PASS: Permuted AUC ≈ random (0.50), Baseline >> Permuted'
    WHEN permuted_auc BETWEEN 0.45 AND 0.55
    THEN '⚠️ MARGINAL: Permuted random but ratio < 1.5x'
    WHEN permuted_auc > 0.60
    THEN '❌ FAIL: Permuted AUC > 0.60 (hidden label leakage)'
    ELSE '⚠️ WARNING: Permuted AUC < 0.45 (check data)'
  END AS verdict
FROM metrics;

SELECT * FROM `{dataset_ref}.comparison_baseline_vs_permuted_h4`;

-- ====================
-- Step 5: Temporal Stability Check
-- ====================
CREATE OR REPLACE TABLE `{dataset_ref}.permuted_by_season_h4` AS
WITH predictions_permuted AS (
  SELECT
    is_high_season,
    y_oos_h4 AS actual,
    predicted_y_oos_h4 AS predicted
  FROM ML.PREDICT(
    MODEL `{dataset_ref}.m_oos_h4`,
    (SELECT * FROM `{dataset_ref}.features_permuted_labels_h4`)
  )
)

SELECT
  CASE WHEN is_high_season = 1 THEN 'HIGH_SEASON' ELSE 'REST' END AS season,
  COUNT(*) AS n_samples,
  AVG(actual) AS prevalence,
  SAFE_DIVIDE(
    SUM(CASE WHEN predicted = 1 AND actual = 1 THEN 1 END),
    SUM(CASE WHEN predicted = 1 THEN 1 END)
  ) AS precision_permuted,
  -- Expected: precision ≈ prevalence (random)
  SAFE_DIVIDE(
    SUM(CASE WHEN predicted = 1 AND actual = 1 THEN 1 END),
    SUM(CASE WHEN predicted = 1 THEN 1 END)
  ) - AVG(actual) AS delta_vs_random
FROM predictions_permuted
GROUP BY is_high_season;

SELECT * FROM `{dataset_ref}.permuted_by_season_h4`;

-- ====================
-- SUMMARY
-- ====================
SELECT
  'T2: PERMUTATION TEST' AS test_name,
  baseline_auc,
  permuted_auc,
  auc_ratio,
  verdict,
  CASE
    WHEN permuted_auc BETWEEN 0.45 AND 0.55 
    THEN 'Performance collapses to random → Features legitimately predict labels (no memorization)'
    WHEN permuted_auc > 0.60
    THEN 'Performance persists with random labels → Hidden label proxies detected (LEAK)'
    ELSE 'Check data quality and permutation logic'
  END AS interpretation
FROM `{dataset_ref}.comparison_baseline_vs_permuted_h4`;
