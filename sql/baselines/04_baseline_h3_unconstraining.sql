-- =====================================================
-- BASELINE H3: UNCONSTRAINING (OPTIONAL - FUTURE WORK)
-- =====================================================
-- Purpose: Detect censored demand and reconstruct latent demand
--          Following Kourentzes et al. "Demand forecasting under lost sales"
--
-- Steps:
--   1. Identify OOS periods (y_sales = 0 due to stockout, not lack of demand)
--   2. Reconstruct latent demand using rolling average or historical patterns
--   3. Evaluate improvement in forecast accuracy (MAE/RMSE)
--
-- Note: This baseline is OPTIONAL for paper submission
--       Include only if quantile/demand layer is part of final paper
--       Otherwise document as "future work" in Limitations
--
-- Expected: MAE improvement 10-30% for SKUs with frequent OOS
-- =====================================================

-- Step 1: Identify censored observations (OOS cases)
CREATE OR REPLACE TABLE `{dataset_ref}.censored_demand_detection` AS
SELECT
  sku_id,
  week_start_date,
  y_sales AS observed_sales,
  y_oos_h4,
  
  -- Classify observation as censored if OOS and zero sales
  CASE 
    WHEN y_oos_h4 = 1 AND y_sales = 0 THEN 1  -- Censored (OOS)
    ELSE 0  -- Not censored (regular demand or no demand)
  END AS is_censored,
  
  -- Features for reconstruction
  lag_1,
  lag_2,
  lag_4,
  roll4_mean,
  roll13_mean,
  
  split
FROM `{dataset_ref}.weekly_features_h4`
WHERE split IN ('TRAIN', 'VAL');

-- Step 2: Reconstruct latent demand for censored observations
CREATE OR REPLACE TABLE `{dataset_ref}.unconstrained_demand_h3` AS
WITH reconstruction AS (
  SELECT
    sku_id,
    week_start_date,
    observed_sales,
    y_oos_h4,
    is_censored,
    
    -- Reconstruct latent demand using rolling average (simple method)
    CASE
      WHEN is_censored = 1 THEN
        -- Use rolling average of non-zero historical sales
        CASE
          WHEN roll4_mean > 0 THEN roll4_mean
          WHEN roll13_mean > 0 THEN roll13_mean
          WHEN lag_1 > 0 THEN lag_1
          WHEN lag_2 > 0 THEN lag_2
          ELSE 1.0  -- Fallback: minimum demand assumption
        END
      ELSE observed_sales  -- Keep original if not censored
    END AS unconstrained_demand,
    
    roll4_mean,
    roll13_mean,
    split
    
  FROM `{dataset_ref}.censored_demand_detection`
)
SELECT * FROM reconstruction;

-- Step 3: Calculate MAE/RMSE improvement (requires actual h=4 sales for validation)
-- Note: This step assumes we have "true" demand at h=4 (y_sales_h4)
--       If y_sales_h4 is also censored, this evaluation is limited

CREATE OR REPLACE TABLE `{dataset_ref}.eval_h3_unconstraining` AS
WITH forecast_comparison AS (
  SELECT
    sku_id,
    week_start_date,
    y_sales_h4 AS actual_sales_h4,
    
    -- Naive forecast: use rolling average directly
    roll4_mean AS forecast_constrained,
    
    -- Unconstrained forecast: adjust for detected OOS
    CASE
      WHEN is_censored = 1 THEN unconstrained_demand
      ELSE roll4_mean
    END AS forecast_unconstrained,
    
    is_censored
    
  FROM `{dataset_ref}.unconstrained_demand_h3`
  WHERE split = 'VAL'
    AND y_sales_h4 IS NOT NULL  -- Only evaluate where we have actual h=4 sales
),
metrics AS (
  SELECT
    -- Overall metrics
    COUNT(*) AS n_samples,
    SUM(is_censored) AS n_censored,
    
    -- MAE/RMSE for constrained forecast
    AVG(ABS(actual_sales_h4 - forecast_constrained)) AS mae_constrained,
    SQRT(AVG(POW(actual_sales_h4 - forecast_constrained, 2))) AS rmse_constrained,
    
    -- MAE/RMSE for unconstrained forecast
    AVG(ABS(actual_sales_h4 - forecast_unconstrained)) AS mae_unconstrained,
    SQRT(AVG(POW(actual_sales_h4 - forecast_unconstrained, 2))) AS rmse_unconstrained
    
  FROM forecast_comparison
),
improvement AS (
  SELECT
    *,
    -- Calculate improvement percentage
    SAFE_DIVIDE(mae_constrained - mae_unconstrained, mae_constrained) * 100 AS mae_improvement_pct,
    SAFE_DIVIDE(rmse_constrained - rmse_unconstrained, rmse_constrained) * 100 AS rmse_improvement_pct
  FROM metrics
)
SELECT
  n_samples,
  n_censored,
  ROUND(SAFE_DIVIDE(n_censored, n_samples) * 100, 2) AS censoring_rate_pct,
  
  ROUND(mae_constrained, 2) AS mae_constrained,
  ROUND(mae_unconstrained, 2) AS mae_unconstrained,
  ROUND(mae_improvement_pct, 2) AS mae_improvement_pct,
  
  ROUND(rmse_constrained, 2) AS rmse_constrained,
  ROUND(rmse_unconstrained, 2) AS rmse_unconstrained,
  ROUND(rmse_improvement_pct, 2) AS rmse_improvement_pct,
  
  CASE
    WHEN mae_improvement_pct >= 20 THEN '✅ Strong unconstraining benefit'
    WHEN mae_improvement_pct >= 10 THEN '✅ Moderate unconstraining benefit'
    WHEN mae_improvement_pct >= 5 THEN '⚠️ Weak unconstraining benefit'
    WHEN mae_improvement_pct >= 0 THEN '⚠️ Marginal benefit'
    ELSE '❌ No benefit (worse performance)'
  END AS verdict
  
FROM improvement;

-- Step 4: SKU-level analysis (which SKUs benefit most)
CREATE OR REPLACE TABLE `{dataset_ref}.unconstraining_by_sku_h3` AS
WITH sku_metrics AS (
  SELECT
    uc.sku_id,
    COUNT(*) AS n_periods,
    SUM(uc.is_censored) AS n_censored_periods,
    SAFE_DIVIDE(SUM(uc.is_censored), COUNT(*)) AS censoring_rate,
    
    -- MAE comparison
    AVG(ABS(y_sales_h4 - roll4_mean)) AS mae_constrained,
    AVG(ABS(y_sales_h4 - unconstrained_demand)) AS mae_unconstrained,
    
    -- Improvement
    SAFE_DIVIDE(
      AVG(ABS(y_sales_h4 - roll4_mean)) - AVG(ABS(y_sales_h4 - unconstrained_demand)),
      AVG(ABS(y_sales_h4 - roll4_mean))
    ) * 100 AS mae_improvement_pct
    
  FROM `{dataset_ref}.unconstrained_demand_h3` uc
  INNER JOIN `{dataset_ref}.weekly_features_h4` wf
    ON uc.sku_id = wf.sku_id 
    AND uc.week_start_date = wf.week_start_date
  WHERE uc.split = 'VAL'
    AND wf.y_sales_h4 IS NOT NULL
  GROUP BY uc.sku_id
  HAVING n_censored_periods > 0  -- Only SKUs with some censoring
)
SELECT
  sku_id,
  n_periods,
  n_censored_periods,
  ROUND(censoring_rate * 100, 2) AS censoring_rate_pct,
  ROUND(mae_constrained, 2) AS mae_constrained,
  ROUND(mae_unconstrained, 2) AS mae_unconstrained,
  ROUND(mae_improvement_pct, 2) AS mae_improvement_pct,
  
  CASE
    WHEN mae_improvement_pct >= 30 THEN '✅ High benefit SKU'
    WHEN mae_improvement_pct >= 15 THEN '✅ Medium benefit SKU'
    WHEN mae_improvement_pct >= 5 THEN '⚠️ Low benefit SKU'
    ELSE '❌ No benefit SKU'
  END AS sku_verdict
  
FROM sku_metrics
ORDER BY mae_improvement_pct DESC
LIMIT 100;

-- Final summary output
SELECT 
  'H3_Unconstraining' AS baseline_name,
  'Censored demand reconstruction (Kourentzes-inspired)' AS description,
  mae_constrained,
  mae_unconstrained,
  mae_improvement_pct,
  censoring_rate_pct,
  verdict,
  '⚠️ OPTIONAL: Include in paper ONLY if quantile layer is part of final submission' AS note
FROM `{dataset_ref}.eval_h3_unconstraining`;
