-- ============================================================================
-- KPI STEP 10: ENRICH FORECAST WITH KPI UNIT ECONOMICS
-- ============================================================================
-- PURPOSE:
--   Join forecast_h4_v4 (all splits) with kpi_por_articulo_snapshot to add:
--     - precio_unit_net    : net price per unit (base_imponible / unidades)
--     - margen_unit_raw    : raw unit margin (can be negative)
--     - margen_unit        : clamped unit margin = GREATEST(raw, 0)
--     - margen_pct         : margin percentage
--     - eur_at_risk        : p_oos_h4 * q90_h4 * margen_unit
--     - catalogue flags    : obsoleto, estado_articulo, ultima_venta, sku_active
--
-- OUTPUT TABLE:
--   thequantitativeledger.cruzber_models_eu.forecast_h4_v4_kpi
--
-- JOIN NOTE:
--   1:1 join on sku_id. The snapshot is pre-deduped in step 00.
--   SKUs with no KPI match (new SKUs not yet in catalogue) get NULL margin fields
--   and eur_at_risk = NULL. They are NOT excluded so the forecast remains complete.
--
-- IDEMPOTENCE: CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.forecast_h4_v4_kpi` AS

WITH

-- Latest snapshot (should only be 1 row per sku_id already, but guard anyway)
kpi AS (
  SELECT
    sku_id,
    descripcion_articulo,
    codigo_familia,
    codigo_subfamilia,
    area_competencia_lc,
    tipo_abc,
    estado_articulo,
    obsoleto,
    sku_active,
    primera_venta,
    ultima_venta,
    dias_en_catalogo,
    precio_unit_net,
    margen_unit_raw,
    margen_unit,
    margen_pct,
    snapshot_ts
  FROM (
    SELECT *,
      ROW_NUMBER() OVER (
        PARTITION BY sku_id
        ORDER BY snapshot_ts DESC
      ) AS _rn
    FROM `thequantitativeledger.cruzber_models_eu.kpi_por_articulo_snapshot`
  )
  WHERE _rn = 1
),

enriched AS (
  SELECT
    -- ── Forecast core fields ─────────────────────────────────────────────────
    f.decision_week,
    f.target_week,
    f.sku_id,
    f.split,
    f.season_group,
    f.segment_id_child,
    f.demand_decile,
    f.volatility_bucket,

    f.p_oos_h4,
    f.yhat_p50_h4,
    f.q90_h4,
    f.q95_h4,
    f.q99_h4,

    f.y_true_h4,
    f.stockout_event_h4,
    f.amplitude,
    f.scale,

    f.segment_n_calib,
    f.qlookup_fallback,
    f.correction_factor,
    f.cap_value,
    f.version,

    -- ── KPI unit economics (NULL-safe) ────────────────────────────────────────
    k.descripcion_articulo,
    k.codigo_familia,
    k.codigo_subfamilia,
    k.area_competencia_lc,
    k.tipo_abc,
    k.estado_articulo,
    k.obsoleto,
    k.sku_active,
    k.primera_venta,
    k.ultima_venta,
    k.dias_en_catalogo,
    k.precio_unit_net,
    k.margen_unit_raw,
    k.margen_unit,
    k.margen_pct,
    k.snapshot_ts                                             AS kpi_snapshot_ts,

    -- ── Business risk score: margin at risk ───────────────────────────────────
    --   €_at_risk = P(OOS) × q90 × unit_margin_clamped
    --   Represents the expected gross margin lost if this SKU goes OOS.
    --   NULL when KPI not matched (new or unknown SKUs).
    SAFE_MULTIPLY(
      SAFE_MULTIPLY(f.p_oos_h4, f.q90_h4),
      k.margen_unit
    )                                                         AS eur_at_risk,

    -- ── Derived: match flag ───────────────────────────────────────────────────
    CASE WHEN k.sku_id IS NOT NULL THEN 1 ELSE 0 END          AS kpi_matched

  FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4` f
  LEFT JOIN kpi k
    USING (sku_id)
)

SELECT * FROM enriched;


-- ── Coverage diagnostics ──────────────────────────────────────────────────
SELECT
  split,
  season_group,
  COUNT(*)                                    AS n_rows,
  COUNTIF(kpi_matched = 1)                    AS n_rows_kpi_matched,
  ROUND(COUNTIF(kpi_matched = 1) / COUNT(*), 4) AS pct_kpi_matched,
  COUNTIF(eur_at_risk IS NULL)                AS n_null_eur_at_risk,
  ROUND(AVG(eur_at_risk), 4)                  AS avg_eur_at_risk,
  ROUND(MAX(eur_at_risk), 4)                  AS max_eur_at_risk
FROM `thequantitativeledger.cruzber_models_eu.forecast_h4_v4_kpi`
GROUP BY split, season_group
ORDER BY split, season_group;
