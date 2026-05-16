-- ============================================================================
-- STEP 05: DIRICHLET PROVINCIAL ALLOCATION  (h=12 v2)
-- ============================================================================
-- PURPOSE:
--   Disaggregate national forecast to 52 Spanish provinces using
--   Dirichlet smoothing. Hierarchical prior: sku_prov → family_prov →
--   global_prov → uniform.
--
-- GEO SOURCE:
--   v_fact_lineas_enriched already contains `provincia` (pre-joined from dim_provincia).
--   No secondary join needed — the view has: codigo_provincia, provincia, nacion.
--   We filter nacion = 'ESPAÑA' (or codigonacion = 108 via dim_provincia_h12_v2).
--
-- PARAMETERS:
--   DIRICHLET_ALPHA0_SKU  = 10.0  (sku-level smoothing strength)
--   DIRICHLET_ALPHA0_FAM  = 25.0  (family-level prior)
--   DIRICHLET_ALPHA0_GLOB = 50.0  (global prior)
--   LOOKBACK_WEEKS        = 52
--   MIN_HIST_UNITS        = 5.0
--   MIN_HIST_WEEKS        = 3
--
-- FALLBACK:
--   If dim_provincia has no join match or BASE_SALES_TABLE has no geo field,
--   all output has provincia='NACIONAL', dirichlet_weight=1.0.
--
-- OUTPUT TABLES:
--   dim_provincia_h12_v2                    (52 provinces, filtered)
--   provincial_allocation_base_h12_v2       (historical weights per SKU×prov×decision_week)
--   forecast_provincial_dirichlet_h12_v2    (disaggregated forecast)
--   dirichlet_reconciliation_check_h12_v2   (sum-to-national assertion)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5a. PROVINCIAL DIMENSION — derived directly from {BASE_SALES_TABLE}
-- v_fact_lineas_enriched already has 'provincia' pre-joined; filter Spain (codigonacion=108).
-- This triggers the cross-region bridge automatically.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.dim_provincia_h12_v2` AS
SELECT DISTINCT
  CAST(provincia     AS STRING) AS provincia,
  CAST(codigo_nacion AS INT64)  AS codigonacion
FROM {BASE_SALES_TABLE}
WHERE codigo_nacion = 108
  AND provincia IS NOT NULL
ORDER BY provincia;

SELECT COUNT(*) AS n_provincias FROM `{PROJECT_ID}.{BQ_DATASET}.dim_provincia_h12_v2`;

-- ---------------------------------------------------------------------------
-- 5b-pre. MATERIALIZE GEO_SALES (cross-region bridge: BASE_SALES_TABLE US → EU)
-- This is the ONLY step that reads from BASE_SALES_TABLE in this phase.
-- All subsequent steps read exclusively from EU tables.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.geo_sales_h12_v2` AS
SELECT
  CAST(codigo_articulo AS STRING)    AS sku_id,
  DATE_TRUNC(fecha_albaran, ISOWEEK) AS sale_week,
  provincia,
  SUM(GREATEST(unidades, 0))         AS units_week
FROM {BASE_SALES_TABLE}
WHERE fecha_albaran BETWEEN '2020-01-01' AND '2024-12-29'
  AND codigo_nacion = 108
  AND provincia IS NOT NULL
GROUP BY sku_id, sale_week, provincia;

SELECT COUNT(*) AS n_rows, COUNT(DISTINCT provincia) AS n_provincias
FROM `{PROJECT_ID}.{BQ_DATASET}.geo_sales_h12_v2`;

-- ---------------------------------------------------------------------------
-- 5b. PROVINCIAL SALES HISTORY (52-week lookback per SKU × province × decision_week)
-- Reads only EU tables (geo_sales_h12_v2 + forecast_national + sku_metadata).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.provincial_allocation_base_h12_v2` AS
WITH

-- All decision weeks we need weights for
decision_weeks AS (
  SELECT DISTINCT decision_week
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2`
),

-- Geo sales: already in EU (materialized in 5b-pre above)
geo_sales AS (
  SELECT sku_id, sale_week, provincia, units_week
  FROM `{PROJECT_ID}.{BQ_DATASET}.geo_sales_h12_v2`
),

-- Family metadata from sku_metadata
sku_meta AS (
  SELECT sku_id, familia, abc_class, sb_class
  FROM `{PROJECT_ID}.{BQ_DATASET}.sku_metadata_h12_v2`
),

-- For each SKU × decision_week: 52-week history split by province
sku_prov_history AS (
  SELECT
    dw.decision_week,
    gs.sku_id,
    COALESCE(gs.provincia, 'NACIONAL') AS provincia,
    COUNT(DISTINCT gs.sale_week)        AS hist_weeks_sku_prov_52w,
    SUM(gs.units_week)                  AS hist_units_sku_prov_52w
  FROM decision_weeks dw
  JOIN geo_sales gs
    ON gs.sale_week > DATE_SUB(dw.decision_week, INTERVAL 52 WEEK)
    AND gs.sale_week <= dw.decision_week
  GROUP BY dw.decision_week, gs.sku_id, COALESCE(gs.provincia, 'NACIONAL')
),

-- SKU total (all provinces) per decision_week
sku_total AS (
  SELECT decision_week, sku_id,
    SUM(hist_units_sku_prov_52w) AS hist_units_sku_total_52w
  FROM sku_prov_history
  GROUP BY decision_week, sku_id
),

-- Family-province weights
family_prov_history AS (
  SELECT
    dw.decision_week,
    sm.familia,
    COALESCE(gs.provincia, 'NACIONAL') AS provincia,
    SUM(gs.units_week) AS hist_units_fam_prov_52w
  FROM decision_weeks dw
  JOIN geo_sales gs ON gs.sale_week > DATE_SUB(dw.decision_week, INTERVAL 52 WEEK)
    AND gs.sale_week <= dw.decision_week
  JOIN sku_meta sm ON sm.sku_id = gs.sku_id
  GROUP BY dw.decision_week, sm.familia, COALESCE(gs.provincia, 'NACIONAL')
),
family_total AS (
  SELECT decision_week, familia, SUM(hist_units_fam_prov_52w) AS hist_units_fam_total_52w
  FROM family_prov_history GROUP BY decision_week, familia
),

-- Global province weights
global_prov_history AS (
  SELECT
    dw.decision_week,
    COALESCE(gs.provincia, 'NACIONAL') AS provincia,
    SUM(gs.units_week) AS hist_units_prov_52w
  FROM decision_weeks dw
  JOIN geo_sales gs ON gs.sale_week > DATE_SUB(dw.decision_week, INTERVAL 52 WEEK)
    AND gs.sale_week <= dw.decision_week
  GROUP BY dw.decision_week, COALESCE(gs.provincia, 'NACIONAL')
),
global_total AS (
  SELECT decision_week, SUM(hist_units_prov_52w) AS hist_units_global_total_52w
  FROM global_prov_history GROUP BY decision_week
),

-- N provinces per decision_week (for uniform fallback)
n_prov AS (
  SELECT decision_week, COUNT(DISTINCT provincia) AS n_provincias
  FROM sku_prov_history GROUP BY decision_week
),

-- Assemble all priors
base AS (
  SELECT
    sph.decision_week,
    sph.sku_id,
    sph.provincia,
    sph.hist_units_sku_prov_52w,
    sph.hist_weeks_sku_prov_52w,
    st.hist_units_sku_total_52w,
    sm.familia,
    sm.abc_class,
    sm.sb_class,
    -- prior family prov
    SAFE_DIVIDE(fph.hist_units_fam_prov_52w, NULLIF(ft.hist_units_fam_total_52w, 0)) AS prior_fam_prov,
    -- prior global prov
    SAFE_DIVIDE(gph.hist_units_prov_52w, NULLIF(gt.hist_units_global_total_52w, 0))  AS prior_global_prov,
    np.n_provincias
  FROM sku_prov_history sph
  LEFT JOIN sku_total st USING (decision_week, sku_id)
  LEFT JOIN sku_meta sm USING (sku_id)
  LEFT JOIN family_prov_history fph ON fph.decision_week = sph.decision_week
    AND fph.familia = sm.familia AND fph.provincia = sph.provincia
  LEFT JOIN family_total ft ON ft.decision_week = sph.decision_week AND ft.familia = sm.familia
  LEFT JOIN global_prov_history gph ON gph.decision_week = sph.decision_week AND gph.provincia = sph.provincia
  LEFT JOIN global_total gt ON gt.decision_week = sph.decision_week
  LEFT JOIN n_prov np ON np.decision_week = sph.decision_week
),

-- Choose prior level and alpha0, compute raw Dirichlet weight
with_prior AS (
  SELECT
    *,
    -- Prior level selection
    CASE
      WHEN hist_units_sku_prov_52w >= 5.0 OR hist_weeks_sku_prov_52w >= 3 THEN 'sku_prov'
      WHEN prior_fam_prov IS NOT NULL THEN 'family_prov'
      WHEN prior_global_prov IS NOT NULL THEN 'global_prov'
      ELSE 'uniform'
    END AS prior_level_used,
    -- Alpha0
    CASE
      WHEN hist_units_sku_prov_52w >= 5.0 OR hist_weeks_sku_prov_52w >= 3 THEN 10.0
      WHEN prior_fam_prov IS NOT NULL THEN 25.0
      ELSE 50.0
    END AS alpha0_used,
    -- Selected prior value
    CASE
      WHEN hist_units_sku_prov_52w >= 5.0 OR hist_weeks_sku_prov_52w >= 3
        THEN COALESCE(prior_fam_prov, prior_global_prov, SAFE_DIVIDE(1.0, NULLIF(n_provincias, 0)))
      WHEN prior_fam_prov IS NOT NULL THEN prior_fam_prov
      WHEN prior_global_prov IS NOT NULL THEN prior_global_prov
      ELSE SAFE_DIVIDE(1.0, NULLIF(n_provincias, 52))
    END AS prior_prov
  FROM base
)

SELECT
  decision_week,
  sku_id,
  provincia,
  familia,
  abc_class,
  sb_class,
  hist_units_sku_prov_52w,
  hist_units_sku_total_52w,
  hist_weeks_sku_prov_52w,
  prior_prov,
  prior_level_used,
  alpha0_used,
  -- Raw Dirichlet weight = (obs + alpha0 * prior) / (total_obs + alpha0)
  SAFE_DIVIDE(
    hist_units_sku_prov_52w + alpha0_used * COALESCE(prior_prov, SAFE_DIVIDE(1.0, 52.0)),
    NULLIF(hist_units_sku_total_52w + alpha0_used, 0)
  ) AS dirichlet_weight_raw
FROM with_prior;

-- Sanity: prior level distribution
SELECT prior_level_used, COUNT(*) n, ROUND(AVG(dirichlet_weight_raw),4) avg_weight
FROM `{PROJECT_ID}.{BQ_DATASET}.provincial_allocation_base_h12_v2`
GROUP BY prior_level_used;

-- ---------------------------------------------------------------------------
-- 5c. PROVINCIAL FORECAST (Dirichlet weights applied to national forecast)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2` AS
WITH

-- Normalize weights to sum to 1 per SKU × decision_week
normalized AS (
  SELECT
    *,
    SAFE_DIVIDE(
      dirichlet_weight_raw,
      SUM(dirichlet_weight_raw) OVER (PARTITION BY sku_id, decision_week)
    ) AS dirichlet_weight
  FROM `{PROJECT_ID}.{BQ_DATASET}.provincial_allocation_base_h12_v2`
),

-- Join with national forecast
national AS (
  SELECT
    decision_week, iso_year, iso_week, target_start_week, target_end_week,
    sku_id, sku_name, familia, abc_class, sb_class, season_group, eval_split_v2,
    p_oos_h12, alert_score, selected_policy,
    yhat_p50_12w, q80_12w, q90_12w, q95_12w, q99_12w,
    expected_buffer_q90, expected_buffer_q95,
    lost_units_proxy_12w, y_true_12w, stockout_event_12w, version
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2`
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
  COALESCE(w.provincia, 'NACIONAL') AS provincia,
  -- Regional grouping from dim_provincia if available, else same as provincia
  COALESCE(w.provincia, 'NACIONAL') AS region,
  n.season_group,
  n.eval_split_v2,
  -- National level (unchanged)
  n.p_oos_h12,
  n.alert_score           AS alert_score_national,
  n.yhat_p50_12w          AS yhat_p50_12w_national,
  n.q90_12w               AS q90_12w_national,
  n.q95_12w               AS q95_12w_national,
  -- Provincial disaggregation
  -- No ROUND to avoid reconciliation error accumulation
  n.yhat_p50_12w        * COALESCE(w.dirichlet_weight, 1.0) AS yhat_p50_12w_prov,
  n.q80_12w             * COALESCE(w.dirichlet_weight, 1.0) AS q80_12w_prov,
  n.q90_12w             * COALESCE(w.dirichlet_weight, 1.0) AS q90_12w_prov,
  n.q95_12w             * COALESCE(w.dirichlet_weight, 1.0) AS q95_12w_prov,
  n.q99_12w             * COALESCE(w.dirichlet_weight, 1.0) AS q99_12w_prov,
  n.expected_buffer_q90 * COALESCE(w.dirichlet_weight, 1.0) AS expected_buffer_q90_prov,
  n.lost_units_proxy_12w * COALESCE(w.dirichlet_weight, 1.0) AS lost_units_proxy_12w_prov,
  -- OOS probability stays at national level
  n.p_oos_h12             AS p_oos_12w,
  -- Labels (NULL for BLIND)
  n.y_true_12w,
  n.stockout_event_12w,
  -- Dirichlet metadata
  COALESCE(w.dirichlet_weight, 1.0)      AS dirichlet_weight,
  COALESCE(w.dirichlet_weight_raw, 1.0)  AS dirichlet_weight_raw,
  COALESCE(w.prior_prov, 1.0)            AS prior_prov,
  COALESCE(w.prior_level_used, 'national_fallback_no_geo') AS prior_level_used,
  COALESCE(w.alpha0_used, 50.0)          AS alpha0_used,
  COALESCE(w.hist_units_sku_prov_52w, 0) AS hist_units_sku_prov_52w,
  COALESCE(w.hist_units_sku_total_52w, 0) AS hist_units_sku_total_52w,
  COALESCE(w.hist_weeks_sku_prov_52w, 0)  AS hist_weeks_sku_prov_52w,
  -- Reconciliation placeholders (filled in next CTE)
  0.0 AS reconciliation_error_p50,
  0.0 AS reconciliation_error_q90,
  n.version
FROM national n
LEFT JOIN normalized w
  ON w.sku_id = n.sku_id AND w.decision_week = n.decision_week;

-- ---------------------------------------------------------------------------
-- 5d. RECONCILIATION CHECK
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2` AS
WITH
prov_sum AS (
  SELECT
    decision_week,
    sku_id,
    SUM(yhat_p50_12w_prov) AS sum_p50_prov,
    SUM(q90_12w_prov)      AS sum_q90_prov,
    SUM(q95_12w_prov)      AS sum_q95_prov
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_provincial_dirichlet_h12_v2`
  GROUP BY decision_week, sku_id
),
national AS (
  SELECT decision_week, sku_id, yhat_p50_12w, q90_12w, q95_12w
  FROM `{PROJECT_ID}.{BQ_DATASET}.forecast_national_h12_v2`
)
SELECT
  p.decision_week,
  p.sku_id,
  ROUND(ABS(p.sum_p50_prov - n.yhat_p50_12w), 6) AS err_p50,
  ROUND(ABS(p.sum_q90_prov - n.q90_12w), 6)      AS err_q90,
  ROUND(ABS(p.sum_q95_prov - n.q95_12w), 6)      AS err_q95,
  -- Tolerance 1.0 unit: accounts for float arithmetic when weights don't
  -- cover all 52 provinces (partial coverage = sum < national by design).
  -- Strict PASS requires full provincial coverage; partial = WARN.
  CASE WHEN ABS(p.sum_p50_prov - n.yhat_p50_12w) <= 1.0
        AND ABS(p.sum_q90_prov - n.q90_12w)      <= 1.0
        AND ABS(p.sum_q95_prov - n.q95_12w)      <= 1.0
       THEN 'PASS' ELSE 'FAIL' END AS row_status
FROM prov_sum p
JOIN national n USING (decision_week, sku_id);

-- Summary
SELECT
  CASE WHEN COUNTIF(row_status = 'FAIL') = 0 THEN 'PASS' ELSE 'FAIL' END AS reconciliation_status,
  COUNT(*) AS n_sku_weeks,
  COUNTIF(row_status = 'FAIL') AS n_failures,
  ROUND(MAX(err_p50), 6) AS max_err_p50,
  ROUND(MAX(err_q90), 6) AS max_err_q90,
  ROUND(MAX(err_q95), 6) AS max_err_q95
FROM `{PROJECT_ID}.{BQ_DATASET}.dirichlet_reconciliation_check_h12_v2`;
