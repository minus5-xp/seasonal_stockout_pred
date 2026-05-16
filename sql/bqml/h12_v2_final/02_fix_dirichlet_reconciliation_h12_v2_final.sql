-- ============================================================================
-- STEP 02: FIX DIRICHLET RECONCILIATION  (h12_v2_final)
-- ============================================================================
-- PURPOSE:
--   Fix the zero-raw-weight bug where COALESCE(NULL, 1.0) assigns 1.0 to each
--   province when sum_raw=0, causing SUM(weight) > 1 and provincial forecast > national.
--
-- NORMALISATION RULES:
--   A. sum_raw > 0  → weight = raw / SUM(raw)
--   B. sum_raw = 0, N > 1, sum_prior > 0 → prior / SUM(prior)
--   C. sum_raw = 0, N > 1, sum_prior = 0 → uniform 1/N
--   D. sum_raw = 0, N = 1              → 1.0
--   E. no province match               → 'NACIONAL', weight = 1.0
--
-- FORECAST PROVINCIAL = national_final × dirichlet_weight_final
--   (national_final from forecast_national_h12_v2_final, not original h12_v2)
--
-- OUTPUTS:
--   dirichlet_weights_fixed_h12_v2_final         (corrected weights per SKU×week×province)
--   forecast_provincial_dirichlet_h12_v2_final   (reconciled provincial forecast)
--   dirichlet_reconciliation_check_h12_v2_final
--   dirichlet_reconciliation_summary_h12_v2_final
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 2a. COMPUTE CORRECTED DIRICHLET WEIGHTS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.dirichlet_weights_fixed_h12_v2_final` AS
WITH

-- Raw data from allocation base
alloc AS (
  SELECT
    decision_week,
    sku_id,
    provincia,
    COALESCE(dirichlet_weight_raw, 0.0)       AS raw_weight,
    COALESCE(prior_prov, 0.0)                 AS prior_weight,
    prior_level_used
  FROM `{PROJECT_ID}.{BQ_DATASET}.provincial_allocation_base_h12_v2`
),

-- Per SKU×week: sum of raw and prior weights, province count
agg AS (
  SELECT
    decision_week,
    sku_id,
    SUM(raw_weight)               AS sum_raw,
    SUM(prior_weight)             AS sum_prior,
    COUNT(DISTINCT provincia)     AS n_provincias
  FROM alloc
  GROUP BY decision_week, sku_id
),

-- Join and apply normalisation rules
normalised AS (
  SELECT
    a.decision_week,
    a.sku_id,
    a.provincia,
    a.raw_weight,
    a.prior_weight,
    a.prior_level_used,
    ag.sum_raw,
    ag.sum_prior,
    ag.n_provincias,

    -- Rule selection
    CASE
      WHEN ag.sum_raw > 0           THEN 'A_raw_normalised'
      WHEN ag.n_provincias > 1
           AND ag.sum_prior > 0     THEN 'B_prior_normalised'
      WHEN ag.n_provincias > 1
           AND ag.sum_prior <= 0    THEN 'C_uniform'
      WHEN ag.n_provincias = 1      THEN 'D_single_province'
      ELSE                               'E_no_province'
    END AS dirichlet_fix_reason,

    -- Final weight (never NULL, always sums to 1 per SKU×week)
    CASE
      WHEN ag.sum_raw > 0
        THEN SAFE_DIVIDE(a.raw_weight, ag.sum_raw)
      WHEN ag.n_provincias > 1 AND ag.sum_prior > 0
        THEN SAFE_DIVIDE(a.prior_weight, ag.sum_prior)
      WHEN ag.n_provincias > 1 AND ag.sum_prior <= 0
        THEN SAFE_DIVIDE(1.0, ag.n_provincias)
      ELSE 1.0
    END AS dirichlet_weight_final,

    -- Prior level label for audit
    CASE
      WHEN ag.sum_raw > 0           THEN a.prior_level_used
      WHEN ag.n_provincias > 1
           AND ag.sum_prior > 0     THEN CONCAT(a.prior_level_used, '_renormalized_zero_raw')
      WHEN ag.n_provincias > 1
           AND ag.sum_prior <= 0    THEN 'uniform_fallback_zero_raw_weight'
      ELSE                               'single_province_zero_raw_weight'
    END AS prior_level_used_final

  FROM alloc a
  JOIN agg ag USING (decision_week, sku_id)
)

SELECT * FROM normalised;

-- Sanity: weight sums should all be 1.0 ± 1e-9
SELECT
  CASE
    WHEN MAX(ABS(sum_check - 1.0)) <= 1e-9 THEN 'PASS'
    ELSE 'FAIL'
  END AS weight_sum_check,
  MAX(ABS(sum_check - 1.0)) AS max_err_weight,
  COUNT(*) AS n_groups
FROM (
  SELECT decision_week, sku_id, SUM(dirichlet_weight_final) AS sum_check
  FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_weights_fixed_h12_v2_final`
  GROUP BY decision_week, sku_id
);

-- ---------------------------------------------------------------------------
-- 2b. PROVINCIAL FORECAST FINAL
-- Uses forecast_national_h12_v2_final as source of truth.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2_final` AS
WITH

-- National final forecast (from step 01)
national AS (
  SELECT
    decision_week,
    iso_year,
    iso_week,
    target_start_week,
    target_end_week,
    sku_id,
    sku_name,
    familia,
    abc_class,
    sb_class,
    season_group,
    eval_split_v2,
    p_oos_12w_rank,
    p_oos_12w_report,
    p_oos_12w_deploy,
    probability_reporting_choice,
    alert_score_final,
    selected_policy,
    yhat_p50_12w   AS yhat_p50_12w_national,
    q80_12w        AS q80_12w_national,
    q90_12w        AS q90_12w_national,
    q95_12w        AS q95_12w_national,
    q99_12w        AS q99_12w_national,
    expected_buffer_q90 AS expected_buffer_q90_national,
    expected_buffer_q95 AS expected_buffer_q95_national,
    lost_units_proxy_12w AS lost_units_proxy_12w_national,
    y_true_12w,
    stockout_event_12w,
    version
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2_final`
),

-- Corrected weights
weights AS (
  SELECT *
  FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_weights_fixed_h12_v2_final`
),

-- Original weights for audit trail
orig AS (
  SELECT
    decision_week,
    sku_id,
    provincia,
    dirichlet_weight     AS dirichlet_weight_original,
    dirichlet_weight_raw AS dirichlet_weight_raw_orig,
    prior_prov           AS prior_prov_orig,
    prior_level_used     AS prior_level_used_original
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2`
  WHERE eval_split_v2 != 'HOLD_NOT_GENERATED' OR eval_split_v2 IS NULL
)

SELECT
  n.decision_week,
  n.iso_year,
  n.iso_week,
  n.target_start_week,
  n.target_end_week,
  n.sku_id,
  n.sku_name,
  n.familia,
  n.abc_class,
  n.sb_class,
  COALESCE(w.provincia, 'NACIONAL')                     AS provincia,
  COALESCE(w.provincia, 'NACIONAL')                     AS region,
  n.season_group,
  n.eval_split_v2,

  -- Probabilities
  n.p_oos_12w_rank,
  n.p_oos_12w_report,
  n.p_oos_12w_deploy,
  n.probability_reporting_choice,
  n.alert_score_final            AS alert_score_national,

  -- National forecast (unchanged)
  n.yhat_p50_12w_national,
  n.q90_12w_national,
  n.q95_12w_national,

  -- Provincial forecast (national × final weight)
  n.yhat_p50_12w_national   * COALESCE(w.dirichlet_weight_final, 1.0) AS yhat_p50_12w_prov_final,
  n.q80_12w_national        * COALESCE(w.dirichlet_weight_final, 1.0) AS q80_12w_prov_final,
  n.q90_12w_national        * COALESCE(w.dirichlet_weight_final, 1.0) AS q90_12w_prov_final,
  n.q95_12w_national        * COALESCE(w.dirichlet_weight_final, 1.0) AS q95_12w_prov_final,
  n.q99_12w_national        * COALESCE(w.dirichlet_weight_final, 1.0) AS q99_12w_prov_final,
  n.expected_buffer_q90_national * COALESCE(w.dirichlet_weight_final, 1.0) AS expected_buffer_q90_prov_final,
  n.lost_units_proxy_12w_national * COALESCE(w.dirichlet_weight_final, 1.0) AS lost_units_proxy_12w_prov_final,

  -- Labels
  n.y_true_12w,
  n.stockout_event_12w,

  -- Dirichlet metadata (audit trail)
  COALESCE(o.dirichlet_weight_original, 1.0)  AS dirichlet_weight_original,
  COALESCE(w.raw_weight, 0.0)                 AS dirichlet_weight_raw,
  COALESCE(w.dirichlet_weight_final, 1.0)     AS dirichlet_weight_final,
  COALESCE(o.prior_level_used_original, 'national_fallback_no_geo') AS prior_level_used_original,
  COALESCE(w.prior_level_used_final, 'national_fallback_no_geo')    AS prior_level_used_final,
  COALESCE(w.prior_weight, 0.0)               AS prior_prov,
  COALESCE(w.dirichlet_fix_reason, 'E_no_province') AS dirichlet_fix_reason,

  'h12_v2_final' AS version

FROM national n
JOIN weights w                    -- INNER JOIN: only SKUs with Spanish geo data
  ON w.sku_id = n.sku_id AND w.decision_week = n.decision_week
  AND w.provincia != 'NACIONAL'   -- exclude fallback rows (rule E)
LEFT JOIN orig o
  ON o.sku_id = n.sku_id AND o.decision_week = n.decision_week
    AND o.provincia = w.provincia;

-- ---------------------------------------------------------------------------
-- 2c. RECONCILIATION CHECK (strict: err <= 0.001)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2_final` AS
WITH
prov_sum AS (
  SELECT
    decision_week,
    sku_id,
    COUNT(DISTINCT provincia)               AS n_provincias,
    SUM(dirichlet_weight_final)             AS sum_weight_final,
    SUM(yhat_p50_12w_prov_final)            AS sum_p50_prov,
    SUM(q90_12w_prov_final)                 AS sum_q90_prov,
    SUM(q95_12w_prov_final)                 AS sum_q95_prov,
    COUNTIF(dirichlet_weight_raw = 0)       AS n_zero_raw_rows,
    MAX(dirichlet_fix_reason)               AS fix_reason_summary
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2_final`
  GROUP BY decision_week, sku_id
),
national AS (
  SELECT decision_week, sku_id,
    yhat_p50_12w_national AS p50_nat,
    q90_12w_national      AS q90_nat,
    q95_12w_national      AS q95_nat
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2_final`
  GROUP BY decision_week, sku_id, yhat_p50_12w_national, q90_12w_national, q95_12w_national
)
SELECT
  p.decision_week,
  p.sku_id,
  p.n_provincias,
  ROUND(p.sum_weight_final, 12)                          AS sum_weight_final,
  ABS(p.sum_weight_final - 1.0)                          AS err_weight,
  ROUND(ABS(p.sum_p50_prov - n.p50_nat), 6)             AS err_p50,
  ROUND(ABS(p.sum_q90_prov - n.q90_nat), 6)             AS err_q90,
  ROUND(ABS(p.sum_q95_prov - n.q95_nat), 6)             AS err_q95,
  p.n_zero_raw_rows,
  p.fix_reason_summary,
  CASE
    WHEN ABS(p.sum_weight_final - 1.0) <= 1e-9
     AND ABS(p.sum_p50_prov - n.p50_nat) <= 0.001
     AND ABS(p.sum_q90_prov - n.q90_nat) <= 0.001
     AND ABS(p.sum_q95_prov - n.q95_nat) <= 0.001
    THEN 'PASS' ELSE 'FAIL'
  END AS row_status
FROM prov_sum p
JOIN national n USING (decision_week, sku_id);

-- ---------------------------------------------------------------------------
-- 2d. RECONCILIATION SUMMARY
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_summary_h12_v2_final` AS
SELECT
  COUNT(*)                                              AS n_groups,
  COUNTIF(row_status = 'PASS')                         AS n_pass,
  COUNTIF(row_status = 'FAIL')                         AS n_fail,
  ROUND(MAX(err_weight), 12)                           AS max_err_weight,
  ROUND(MAX(err_p50), 6)                               AS max_err_p50,
  ROUND(MAX(err_q90), 6)                               AS max_err_q90,
  ROUND(MAX(err_q95), 6)                               AS max_err_q95,
  COUNTIF(n_zero_raw_rows > 0 AND n_provincias > 1)   AS n_groups_zero_raw_multi_prov_fixed,
  COUNTIF(fix_reason_summary = 'C_uniform')            AS n_groups_uniform_fallback,
  COUNTIF(fix_reason_summary = 'B_prior_normalised')   AS n_groups_prior_renormalized,
  CASE WHEN COUNTIF(row_status = 'FAIL') = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2_final`;

SELECT * FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_summary_h12_v2_final`;
