-- ============================================================================
-- KPI STEP 00: CREATE KPI SNAPSHOT  (v_kpi_por_articulo → cruzber_models_eu)
-- ============================================================================
-- PURPOSE:
--   Pull the current state of v_kpi_por_articulo (source dataset = @KPI_DATASET,
--   resolved at runtime by the Python runner from env var KPI_DATASET or
--   auto-discovered via INFORMATION_SCHEMA) and materialise it as an idempotent
--   snapshot in cruzber_models_eu.
--
-- PLACEHOLDER:
--   @KPI_DATASET  –  replaced by the runner with the actual dataset name
--                    e.g. "dataset_cruzber"
--
-- OUTPUT TABLE:
--   thequantitativeledger.cruzber_models_eu.kpi_por_articulo_snapshot
--
-- IDEMPOTENCE:  CREATE OR REPLACE → always reflects the latest view state.
-- NEGATIVE MARGIN POLICY:
--   margen_unit_raw can be negative (devolutions, pricing errors).
--   Default: margen_unit_clamped = GREATEST(margen_unit_raw, 0).
--   Raw value is preserved in margen_unit_raw for auditability.
--
-- OBSOLETE / INACTIVE FILTER:
--   Parameterised via sku_active flag computed here; downstream steps use it
--   as a filter. Default definition:
--     sku_active = 1  ↔  estado_articulo IN (10, 100)  AND  obsoleto != 'Sí'
--   Adjust the CASE expression below to match the actual catalogue coding.
-- ============================================================================

CREATE OR REPLACE TABLE `thequantitativeledger.cruzber_models_eu.kpi_por_articulo_snapshot` AS

WITH raw AS (
  SELECT
    -- ── Identifiers ──────────────────────────────────────────────────────────
    CAST(codigo_articulo AS STRING)           AS sku_id,
    codigo_articulo,
    descripcion_articulo,

    -- ── Catalogue hierarchy ──────────────────────────────────────────────────
    codigo_familia,
    codigo_subfamilia,
    descripcion_subfamilia,
    agrupacion_listado,
    descripcion_agrupacion,
    sub_agrupacion_listado,
    area_competencia_lc,

    -- ── Catalogue status ─────────────────────────────────────────────────────
    estado_articulo,
    tipo_abc,
    obsoleto,

    -- ── Volume KPIs ──────────────────────────────────────────────────────────
    CAST(lineas_articulo        AS INT64)     AS lineas_articulo,
    CAST(clientes_articulo      AS INT64)     AS clientes_articulo,
    CAST(albaranes_articulo     AS INT64)     AS albaranes_articulo,
    CAST(unidades_articulo      AS FLOAT64)   AS unidades_articulo,
    CAST(base_imponible_articulo AS FLOAT64)  AS base_imponible_articulo,
    CAST(importe_coste_articulo  AS FLOAT64)  AS importe_coste_articulo,
    CAST(margen_articulo         AS FLOAT64)  AS margen_articulo,
    CAST(margen_porcentual_articulo AS FLOAT64) AS margen_pct,

    -- ── Timeline ─────────────────────────────────────────────────────────────
    primera_venta,
    ultima_venta,
    CAST(dias_en_catalogo AS INT64)           AS dias_en_catalogo,

    -- ── Derived unit economics ────────────────────────────────────────────────
    -- SAFE_DIVIDE avoids ZeroDivisionError when unidades_articulo = 0
    SAFE_DIVIDE(
      CAST(base_imponible_articulo AS FLOAT64),
      NULLIF(CAST(unidades_articulo AS FLOAT64), 0)
    )                                         AS precio_unit_net,

    SAFE_DIVIDE(
      CAST(margen_articulo AS FLOAT64),
      NULLIF(CAST(unidades_articulo AS FLOAT64), 0)
    )                                         AS margen_unit_raw,

    -- Clamped margin: GREATEST(raw, 0). Raw preserved above for audit.
    GREATEST(
      SAFE_DIVIDE(
        CAST(margen_articulo AS FLOAT64),
        NULLIF(CAST(unidades_articulo AS FLOAT64), 0)
      ),
      0.0
    )                                         AS margen_unit,

    -- ── Active SKU flag (adjust coding to match your catalogue) ───────────────
    --   estado_articulo: 10 = activo, 100 = activo especial (common BQ coding)
    --   obsoleto: 'No' = active, 'Sí' = obsolete (Spanish boolean)
    CASE
      WHEN estado_articulo NOT IN (10, 100)   THEN 0
      WHEN UPPER(COALESCE(obsoleto, 'No'))
           IN ('SÍ', 'SI', 'YES', 'Y', '1')  THEN 0
      WHEN ultima_venta < DATE_SUB(CURRENT_DATE(), INTERVAL 365 DAY) THEN 0
      ELSE 1
    END                                       AS sku_active,

    -- ── Snapshot metadata ────────────────────────────────────────────────────
    CURRENT_TIMESTAMP()                       AS snapshot_ts

  FROM `@KPI_DATASET.v_kpi_por_articulo`
),

-- Dedup: if the source view somehow returns duplicate sku_id entries,
-- keep the one with the highest lineas_articulo (most traded SKU record).
deduped AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY sku_id
      ORDER BY lineas_articulo DESC, primera_venta ASC
    ) AS _row_num
  FROM raw
)

SELECT
  sku_id,
  codigo_articulo,
  descripcion_articulo,
  codigo_familia,
  codigo_subfamilia,
  descripcion_subfamilia,
  agrupacion_listado,
  descripcion_agrupacion,
  sub_agrupacion_listado,
  area_competencia_lc,
  estado_articulo,
  tipo_abc,
  obsoleto,
  lineas_articulo,
  clientes_articulo,
  albaranes_articulo,
  unidades_articulo,
  base_imponible_articulo,
  importe_coste_articulo,
  margen_articulo,
  margen_pct,
  primera_venta,
  ultima_venta,
  dias_en_catalogo,
  precio_unit_net,
  margen_unit_raw,
  margen_unit,
  sku_active,
  snapshot_ts

FROM deduped
WHERE _row_num = 1;


-- ── Quick sanity check ─────────────────────────────────────────────────────
SELECT
  COUNT(*)                                    AS n_skus_total,
  COUNTIF(sku_active = 1)                     AS n_skus_active,
  COUNTIF(margen_unit_raw < 0)                AS n_negative_margin_raw,
  COUNTIF(precio_unit_net IS NULL)            AS n_null_precio_unit,
  COUNTIF(margen_unit IS NULL)                AS n_null_margen_unit,
  ROUND(AVG(margen_pct), 4)                   AS avg_margen_pct,
  ROUND(AVG(precio_unit_net), 4)              AS avg_precio_unit_net,
  ROUND(AVG(margen_unit), 4)                  AS avg_margen_unit,
  snapshot_ts
FROM `thequantitativeledger.cruzber_models_eu.kpi_por_articulo_snapshot`
GROUP BY snapshot_ts;
