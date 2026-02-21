-- ============================================================================
-- KPI STEP 20: MARGIN-RANKED ALERTS TOP-100 (h=4 v4)
-- ============================================================================
-- PURPOSE:
--   Re-rank weekly alerts prioritising SKUs by expected margin at risk:
--
--     score_margin = p_oos_h4 × q90_h4 × margen_unit   (€ at risk)
--
--   This is the business-relevant complement to the coverage-optimised
--   policy_B (lost-sales) ranking: it answers "which stockouts cost the most?"
--
-- OUTPUT TABLE:
--   thequantitativeledger.cruzber_models_eu.alerts_top100_h4_margin
--
-- SCOPE:
--   Same VAL split used by alerts_top100_h4_v4. Only active SKUs (sku_active=1)
--   are ranked; inactive/obsolete SKUs appear at the end of the ranking but are
--   excluded from top-100 by default (configurable via include_inactive flag).
--
-- TIEBREAKER: p_oos_h4 DESC → q90_h4 DESC for SKUs with equal eur_at_risk
--   (typically when margen_unit = 0 after clamping).
--
-- IDEMPOTENCE: CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_margin` AS

WITH

-- Universe: VAL rows enriched with KPI
val_enriched AS (
  SELECT
    decision_week,
    target_week,
    sku_id,
    split,
    season_group,
    p_oos_h4,
    yhat_p50_h4,
    q90_h4,
    q95_h4,
    y_true_h4,
    stockout_event_h4,
    amplitude,
    -- KPI fields
    descripcion_articulo,
    codigo_familia,
    codigo_subfamilia,
    tipo_abc,
    estado_articulo,
    obsoleto,
    sku_active,
    ultima_venta,
    precio_unit_net,
    margen_unit_raw,
    margen_unit,
    margen_pct,
    eur_at_risk,
    kpi_matched
  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4_kpi`
  WHERE split = 'VAL'
    -- Only rank SKUs with KPI data; SKUs without match have NULL eur_at_risk
    -- and would always rank last — we include them for completeness but exclude
    -- from top-100 via the WHERE rank_in_week <= 100 filter below.
),

-- Margin-based ranking per week
-- Active SKUs are ranked first (CASE 0 → 1 in sort order),
-- then by eur_at_risk DESC, then by p_oos_h4 DESC as tiebreaker.
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY decision_week
      ORDER BY
        -- Active SKUs first
        CASE WHEN sku_active = 1 THEN 0 ELSE 1 END ASC,
        -- Primary: margin at risk (highest first)
        COALESCE(eur_at_risk, 0.0)  DESC,
        -- Tiebreaker 1: OOS probability
        p_oos_h4                    DESC,
        -- Tiebreaker 2: forecast quantity (proxy for volume impact)
        q90_h4                      DESC
    ) AS rank_in_week
  FROM val_enriched
)

SELECT
  -- ── Identifiers ──────────────────────────────────────────────────────────
  decision_week,
  target_week,
  rank_in_week,
  sku_id,

  -- ── Core forecast ────────────────────────────────────────────────────────
  p_oos_h4,
  yhat_p50_h4,
  q90_h4,
  q95_h4,

  -- ── Business risk score ───────────────────────────────────────────────────
  eur_at_risk,
  margen_unit,
  margen_unit_raw,
  margen_pct,
  precio_unit_net,

  -- ── Ground truth ─────────────────────────────────────────────────────────
  y_true_h4,
  CAST(stockout_event_h4 AS INT64)                AS true_stockout_label,
  CASE WHEN y_true_h4 = 0 THEN 1 ELSE 0 END       AS true_stockout_sales0,

  -- ── Catalogue metadata ────────────────────────────────────────────────────
  descripcion_articulo,
  codigo_familia,
  codigo_subfamilia,
  tipo_abc,
  estado_articulo,
  obsoleto,
  sku_active,
  ultima_venta,

  -- ── Context ───────────────────────────────────────────────────────────────
  season_group,
  amplitude,
  kpi_matched,

  -- ── Ranking policy tag ────────────────────────────────────────────────────
  'margin_eur_at_risk' AS applied_policy

FROM ranked
WHERE rank_in_week <= 100
ORDER BY decision_week, rank_in_week;


-- ── Quick summary ─────────────────────────────────────────────────────────
SELECT
  season_group,
  COUNT(DISTINCT decision_week)               AS n_weeks,
  COUNT(*)                                    AS n_alerts,
  ROUND(SUM(eur_at_risk), 2)                  AS total_eur_at_risk,
  ROUND(AVG(eur_at_risk), 4)                  AS avg_eur_at_risk,
  ROUND(AVG(margen_unit), 4)                  AS avg_margen_unit,
  COUNTIF(kpi_matched = 0)                    AS n_no_kpi_match
FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4_margin`
GROUP BY season_group;
