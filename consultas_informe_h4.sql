-- ============================================================================
-- CONSULTAS PARA INFORME H4 - MÉTRICAS Y CUANTIFICACIÓN ECONÓMICA
-- ============================================================================
-- Uso: Ejecutar estas consultas para obtener datos actualizados del modelo h4
-- Proyecto: thequantitativeledger
-- Dataset: cruzber_models_eu
-- Fecha: 2026-02-17
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. MÉTRICAS PRINCIPALES DEL MODELO
-- ----------------------------------------------------------------------------

-- Resumen principal de métricas
SELECT 
  'MÉTRICAS MODELO H4' as seccion,
  run_ts,
  horizon,
  ROUND(oos_auc_val, 4) as auc_clasificador,
  ROUND(oos_recall_val, 4) as recall_validacion,
  ROUND(oos_precision_val, 4) as precision_global,
  ROUND(oos_logloss_val, 4) as log_loss,
  ROUND(demand_mae_val, 2) as mae_demanda,
  ROUND(demand_r2_val, 4) as r2_demanda,
  ROUND(brier_raw_val, 4) as brier_raw,
  ROUND(brier_cal_val, 4) as brier_calibrado,
  ROUND(prec100_model_high, 4) as precision_top100_high_season,
  ROUND(rec100_model_high, 4) as recall_top100_high_season,
  ROUND(lift100_model_high, 2) as lift_top100_high_season
FROM `thequantitativeledger.cruzber_models_eu.run_summary_h4`;

-- ----------------------------------------------------------------------------
-- 2. ESTADÍSTICAS GENERALES DEL FORECAST
-- ----------------------------------------------------------------------------

-- Resumen por estación
SELECT 
  'FORECAST POR ESTACIÓN' as seccion,
  season_group,
  COUNT(*) as predicciones_totales,
  COUNT(DISTINCT sku_id) as skus_unicos,
  COUNT(DISTINCT decision_week) as semanas_decision,
  COUNT(DISTINCT target_week) as semanas_target,
  ROUND(AVG(p_oos_h4), 4) as prob_stockout_promedio,
  ROUND(AVG(yhat_p50_h4), 2) as demanda_promedio,
  ROUND(SUM(CASE WHEN y_true_h4 = 0 THEN 1 ELSE 0 END) / COUNT(*), 4) as tasa_stockout_real,
  ROUND(AVG(q95_h4 - q90_h4), 2) as amplitud_promedio_cuantiles
FROM `thequantitativeledger.cruzber_models_eu.forecast_h4`
GROUP BY season_group
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- 3. COBERTURA DE CUANTILES POR SEGMENTO
-- ----------------------------------------------------------------------------

-- Resumen de cobertura (solo HIGH_SEASON para el informe)
SELECT 
  'COBERTURA CUANTILES HIGH_SEASON' as seccion,
  segment_id,
  n_obs as observaciones,
  ROUND(viol_rate_p90, 4) as tasa_violacion_p90,
  nominal_rate_p90 as nominal_p90,
  calibration_status_p90 as estado_p90,
  ROUND(viol_rate_p95, 4) as tasa_violacion_p95,
  nominal_rate_p95 as nominal_p95,
  calibration_status_p95 as estado_p95,
  ROUND(ABS(viol_rate_p90 - nominal_rate_p90), 4) as desviacion_p90,
  ROUND(ABS(viol_rate_p95 - nominal_rate_p95), 4) as desviacion_p95
FROM `thequantitativeledger.cruzber_models_eu.eval_coverage_h4`
WHERE season_group = 'HIGH_SEASON'
ORDER BY segment_id;

-- ----------------------------------------------------------------------------
-- 4. ESTADÍSTICAS DE ALERTAS
-- ----------------------------------------------------------------------------

-- Resumen de alertas generadas
SELECT 
  'ALERTAS TOP 100' as seccion,
  COUNT(*) as total_alertas,
  COUNT(DISTINCT sku_id) as skus_unicos_alertados,
  COUNT(DISTINCT decision_week) as semanas_con_alertas,
  ROUND(AVG(p_oos_h4), 4) as prob_stockout_promedio,
  ROUND(AVG(yhat_p50_h4), 2) as demanda_promedio,
  ROUND(AVG(risk_score), 2) as risk_score_promedio,
  SUM(true_stockout_label_model) as stockouts_reales_detectados,
  ROUND(100.0 * SUM(true_stockout_label_model) / COUNT(*), 2) as precision_pct,
  ROUND(AVG(uncertainty_width_p95), 2) as amplitud_incertidumbre_promedio
FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4`;

-- Distribución de alertas por estación
SELECT 
  'ALERTAS POR ESTACIÓN' as seccion,
  season_group,
  COUNT(*) as alertas,
  COUNT(DISTINCT sku_id) as skus_unicos,
  ROUND(AVG(p_oos_h4), 4) as prob_stockout_avg,
  SUM(true_stockout_label_model) as stockouts_reales,
  ROUND(100.0 * SUM(true_stockout_label_model) / COUNT(*), 2) as precision_pct
FROM `thequantitativeledger.cruzber_models_eu.alerts_top100_h4`
GROUP BY season_group
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- 5. IMPACTO ECONÓMICO - HIGH_SEASON
-- ----------------------------------------------------------------------------

WITH precios_sku AS (
  SELECT 
    codigo_articulo as sku_id,
    AVG(SAFE_DIVIDE(base_imponible, NULLIF(unidades, 0))) as precio_unitario,
    SUM(base_imponible) as base_imponible_historica,
    SUM(unidades) as unidades_historicas
  FROM thequantitativeledger.cruzber_models_eu.fact_lineas_albaran
  WHERE unidades > 0 AND base_imponible > 0
  GROUP BY codigo_articulo
),
impacto_high_season AS (
  SELECT
    f.sku_id,
    f.decision_week,
    f.target_week,
    f.p_oos_h4,
    f.yhat_p50_h4,
    f.y_true_h4,
    p.precio_unitario,
    f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0) as venta_esperada_eur,
    f.p_oos_h4 * f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0) as riesgo_stockout_eur,
    CASE WHEN f.y_true_h4 = 0 AND f.yhat_p50_h4 > 1.0 
         THEN f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0)
         ELSE 0 
    END as perdida_real_eur,
    f.q95_h4 * COALESCE(p.precio_unitario, 0) as q95_venta_eur,
    f.p_oos_h4 * f.q95_h4 * COALESCE(p.precio_unitario, 0) as riesgo_q95_eur
  FROM thequantitativeledger.cruzber_models_eu.forecast_h4 f
  LEFT JOIN precios_sku p ON f.sku_id = p.sku_id
  WHERE f.season_group = 'HIGH_SEASON'
    AND p.precio_unitario IS NOT NULL
)
SELECT
  'IMPACTO ECONÓMICO HIGH_SEASON' as seccion,
  COUNT(*) as predicciones_totales,
  COUNT(DISTINCT sku_id) as skus_unicos,
  COUNT(DISTINCT decision_week) as semanas_decisiones,
  ROUND(SUM(venta_esperada_eur), 2) as venta_esperada_total_eur,
  ROUND(SUM(riesgo_stockout_eur), 2) as riesgo_stockout_total_eur,
  ROUND(AVG(riesgo_stockout_eur), 2) as riesgo_promedio_por_pred_eur,
  ROUND(SUM(perdida_real_eur), 2) as perdida_real_observada_eur,
  ROUND(100.0 * SUM(perdida_real_eur) / NULLIF(SUM(venta_esperada_eur), 0), 2) as pct_perdida_real,
  ROUND(100.0 * SUM(riesgo_stockout_eur) / NULLIF(SUM(venta_esperada_eur), 0), 2) as pct_valor_en_riesgo,
  ROUND(SUM(q95_venta_eur), 2) as venta_q95_pesimista_eur,
  ROUND(SUM(riesgo_q95_eur), 2) as riesgo_q95_pesimista_eur
FROM impacto_high_season;

-- ----------------------------------------------------------------------------
-- 6. IMPACTO ECONÓMICO - AÑO COMPLETO (PROYECCIÓN)
-- ----------------------------------------------------------------------------

WITH precios_sku AS (
  SELECT 
    codigo_articulo as sku_id,
    AVG(SAFE_DIVIDE(base_imponible, NULLIF(unidades, 0))) as precio_unitario
  FROM thequantitativeledger.cruzber_models_eu.fact_lineas_albaran
  WHERE unidades > 0 AND base_imponible > 0
  GROUP BY codigo_articulo
),
impacto_por_estacion AS (
  SELECT
    f.season_group,
    COUNT(*) as predicciones,
    COUNT(DISTINCT decision_week) as semanas,
    SUM(f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0)) as venta_esperada_eur,
    SUM(f.p_oos_h4 * f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0)) as riesgo_stockout_eur,
    SUM(CASE WHEN f.y_true_h4 = 0 AND f.yhat_p50_h4 > 1.0 
             THEN f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0)
             ELSE 0 END) as perdida_real_eur
  FROM thequantitativeledger.cruzber_models_eu.forecast_h4 f
  LEFT JOIN precios_sku p ON f.sku_id = p.sku_id
  WHERE p.precio_unitario IS NOT NULL
  GROUP BY f.season_group
)
SELECT
  'PROYECCIÓN ANUAL COMPLETA' as seccion,
  season_group,
  semanas as semanas_validacion,
  ROUND(venta_esperada_eur, 2) as venta_esperada_eur,
  ROUND(riesgo_stockout_eur, 2) as riesgo_stockout_eur,
  ROUND(perdida_real_eur, 2) as perdida_real_eur,
  -- Proyección a 52 semanas (ajustando por cobertura real)
  ROUND(venta_esperada_eur * 52.0 / semanas, 2) as venta_proyectada_52sem_eur,
  ROUND(riesgo_stockout_eur * 52.0 / semanas, 2) as riesgo_proyectado_52sem_eur,
  ROUND(perdida_real_eur * 52.0 / semanas, 2) as perdida_proyectada_52sem_eur,
  ROUND(100.0 * riesgo_stockout_eur / NULLIF(venta_esperada_eur, 0), 2) as pct_riesgo
FROM impacto_por_estacion
ORDER BY season_group;

-- ----------------------------------------------------------------------------
-- 7. TOP 10 SKUs CON MAYOR RIESGO ECONÓMICO (HIGH_SEASON)
-- ----------------------------------------------------------------------------

WITH precios_sku AS (
  SELECT 
    codigo_articulo as sku_id,
    AVG(SAFE_DIVIDE(base_imponible, NULLIF(unidades, 0))) as precio_unitario
  FROM thequantitativeledger.cruzber_models_eu.fact_lineas_albaran
  WHERE unidades > 0 AND base_imponible > 0
  GROUP BY codigo_articulo
),
top_riesgos AS (
  SELECT 
    f.sku_id,
    f.decision_week,
    f.target_week,
    f.p_oos_h4,
    f.yhat_p50_h4,
    f.y_true_h4,
    p.precio_unitario,
    f.p_oos_h4 * f.yhat_p50_h4 * COALESCE(p.precio_unitario, 0) as riesgo_eur
  FROM thequantitativeledger.cruzber_models_eu.forecast_h4 f
  LEFT JOIN precios_sku p ON f.sku_id = p.sku_id
  WHERE f.season_group = 'HIGH_SEASON'
    AND p.precio_unitario IS NOT NULL
  ORDER BY riesgo_eur DESC
  LIMIT 10
)
SELECT 
  'TOP 10 RIESGO ECONÓMICO' as seccion,
  sku_id,
  decision_week,
  target_week,
  ROUND(p_oos_h4 * 100, 2) as prob_stockout_pct,
  ROUND(yhat_p50_h4, 2) as demanda_pred_unidades,
  ROUND(precio_unitario, 2) as precio_eur_unidad,
  ROUND(riesgo_eur, 2) as riesgo_stockout_eur,
  y_true_h4 as demanda_real_unidades
FROM top_riesgos
ORDER BY riesgo_eur DESC;

-- ----------------------------------------------------------------------------
-- 8. ESTADÍSTICAS DE PRECIOS
-- ----------------------------------------------------------------------------

SELECT 
  'ESTADÍSTICAS PRECIOS' as seccion,
  COUNT(*) as skus_con_precio,
  ROUND(MIN(precio_unitario), 2) as precio_min_eur,
  ROUND(MAX(precio_unitario), 2) as precio_max_eur,
  ROUND(AVG(precio_unitario), 2) as precio_promedio_eur,
  ROUND(STDDEV(precio_unitario), 2) as precio_stddev_eur,
  ROUND(APPROX_QUANTILES(precio_unitario, 100)[OFFSET(25)], 2) as precio_p25_eur,
  ROUND(APPROX_QUANTILES(precio_unitario, 100)[OFFSET(50)], 2) as precio_p50_eur,
  ROUND(APPROX_QUANTILES(precio_unitario, 100)[OFFSET(75)], 2) as precio_p75_eur
FROM (
  SELECT 
    codigo_articulo as sku_id,
    AVG(SAFE_DIVIDE(base_imponible, NULLIF(unidades, 0))) as precio_unitario
  FROM thequantitativeledger.cruzber_models_eu.fact_lineas_albaran
  WHERE unidades > 0 AND base_imponible > 0
  GROUP BY codigo_articulo
);

-- ----------------------------------------------------------------------------
-- 9. VERIFICACIÓN DE LEAKAGE
-- ----------------------------------------------------------------------------

SELECT 
  'VERIFICACIÓN LEAKAGE' as seccion,
  *
FROM `thequantitativeledger.cruzber_models_eu.leakage_check_h4`
LIMIT 10;

-- ----------------------------------------------------------------------------
-- 10. RESUMEN DE TABLAS GENERADAS
-- ----------------------------------------------------------------------------

SELECT 
  'TABLAS GENERADAS H4' as seccion,
  table_name,
  ROUND(size_bytes / 1048576, 2) as size_mb,
  row_count as num_rows,
  TIMESTAMP_MILLIS(creation_time) as fecha_creacion
FROM `thequantitativeledger.cruzber_models_eu.__TABLES__`
WHERE REGEXP_CONTAINS(table_name, r'_h4$')
ORDER BY creation_time DESC;

-- ============================================================================
-- FIN DE CONSULTAS
-- ============================================================================
