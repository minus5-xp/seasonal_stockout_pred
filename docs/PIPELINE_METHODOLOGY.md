# Metodología del Pipeline Cruzber h=4 v4
## Sistema de Alertas de Rotura de Stock con Intervalos Conformes y Extensión de Margen

> **Versión:** h4\_v4 | **Fecha de pipeline:** 2025 | **Veredicto final:** DEPLOY  
> `B3=PASS | B4=CONDITIONAL_PASS | lift=10.83x | leakage=PASS`

---

## 1. Visión General

El pipeline genera semanalmente una lista de **top-100 alertas de riesgo de rotura de stock** con un horizonte de predicción de **h=4 semanas** (decision\_week → target\_week = decision\_week + 4 semanas). Para cada SKU activo se produce:

| Salida | Descripción |
|--------|-------------|
| `p_oos_h4` | Probabilidad de rotura de stock en la semana objetivo |
| `yhat_p50_h4` | Demanda esperada (P50) en unidades |
| `q90_h4`, `q95_h4`, `q99_h4` | Intervalos de predicción conformes (quantiles superiores) |
| `eur_at_risk` | Euros de margen en riesgo = p_oos × q90 × margen\_unit |

El pipeline está implementado íntegramente en **BigQuery ML (BQML)** y ejecutado en **Cloud Run Jobs** con imagen Docker, sin dependencias de servidor persistente.

---

## 2. Datos y Particiones Temporales

### 2.1 Fuentes de datos
- **Demanda semanal:** histórico de ventas unitarias por SKU (`week_start_date`, nivel semana ISO)
- **KPI / márgenes:** vista `v_kpi_por_articulo` (proyecto `voltaic-tuner-475510-s4`, dataset `dataset_cruzber`, ubicación **US**)
- **Features de demanda:** calculadas con ventanas rolling de 13 semanas hacia atrás

### 2.2 Particiones

| Split | Período | n filas (SKU-semana) | Uso |
|-------|---------|---------------------|-----|
| `TRAIN` | 2020-01-06 → 2023-06-26 | ~808.626 | Entrenamiento de modelos BQML |
| `CALIB` | 2023-07-03 → 2023-12-25 | ~115.518 | Calibración conforme (quantile scores) |
| `VAL` | 2024-01-01 → 2024-11-25 | ~213.264 | Evaluación (VAL\_TUNE + VAL\_TEST) |

> **IMPORTANTE:** No existe partición `TEST` independiente.  
> Dentro de `VAL`, los primeros 2/3 de semanas se designan `VAL_TUNE` (usado para fitear el factor de corrección conforme) y el último 1/3 es `VAL_TEST` (evaluación paper-clean sin ningún snooping).

### 2.3 Definición de temporada
- `HIGH_SEASON`: semanas de mayo a agosto (el segmento de mayor volumen en Cruzber)
- `REST`: resto del año

---

## 3. Ingeniería de Features

### 3.1 Features base (heredadas de v3)

| Feature | Cálculo | Ventana |
|---------|---------|---------|
| `amplitude` | Media de ventas no nulas en últimas 13 semanas | [T-13w, T-1w] |
| `roll13_mean` | Media móvil de ventas | [T-13w, T-1w] |
| `roll13_std` | Desviación estándar móvil | [T-13w, T-1w] |
| `cv_13w` | Coeficiente de variación = std/mean | [T-13w, T-1w] |
| `hhi_base_roll13` | Índice Herfindahl-Hirschman de concentración de clientes | [T-13w, T-1w] |
| `is_high_season` | Flag binario de temporada alta | - |
| `p_oos_h4` (regresor) | Probabilidad OOS del paso anterior (señal exógena) | - |

### 3.2 Features nuevas en v4 — Demanda intermitente

Motivación: Cruzber tiene una fracción importante de SKUs con demanda intermitente (muchas semanas en cero). Los modelos con sólo media/std no capturan bien el patrón de llegada. Se añaden tres features de Croston-inspired:

| Feature | Fórmula | Interpretación |
|---------|---------|----------------|
| `zero_share_13w` | Fracción de semanas con ventas=0 en [T-13w, T-1w] | Nivel de intermitencia |
| `last_nonzero_lag` | Número de semanas desde la última venta no nula | Recencia de actividad |
| `mean_interarrival_13w` | Media de gaps entre semanas con venta en [T-13w, T-1w] | Frecuencia de demanda |

Todas las ventanas son estrictamente hacia atrás (`week_start_date - 13w` a `week_start_date - 1w`) — **no hay leakage temporal**.

---

## 4. Modelos de Machine Learning

Se entrenan dos modelos BQML separados en el split `TRAIN`:

### 4.1 Clasificador OOS — `m_oos_h4_v4`

```
model_type = 'BOOSTED_TREE_CLASSIFIER'
label      = y_oos_h4  (BOOL: ¿hubo rotura en semana objetivo?)
```

| Hiperparámetro | Valor | Justificación |
|---------------|-------|---------------|
| `num_parallel_tree` | 6 | Ensemble de 6 árboles paralelos (bagging interno) |
| `max_tree_depth` | 6 | Profundidad moderada — evita sobreajuste en SKUs raros |
| `subsample` | 0.8 | Stochastic gradient boosting, reduce varianza |
| `l1_reg / l2_reg` | 0.1 / 1.0 | Regularización L2 dominante para pesos suaves |
| `learn_rate` | 0.05 | Conservador con 300 iteraciones máx |
| `early_stop` | TRUE | Para en cuanto mejora relativa < 0.1% |

**¿Por qué Boosted Trees y no regresión logística?**  
La demanda intermitente genera interacciones no lineales entre `zero_share`, `amplitude` y `cv_13w`. Un clasificador lineal supondría independencia entre estas señales; los árboles capturan automáticamente los umbrales de corte (e.g., "alto riesgo OOS si zero_share > 0.7 AND last_nonzero_lag > 4").

### 4.2 Regresor de demanda — `m_demand_h4_v4`

```
model_type = 'BOOSTED_TREE_REGRESSOR'
label      = GREATEST(0, y_true_h4)  (unidades vendidas, no negativo)
```

Mismos hiperparámetros que el clasificador. La predicción `yhat_p50_h4` se usa como estimación puntual P50 para el cálculo de intervalos. Las filas OOS (demanda=0) **también se incluyen** en el entrenamiento del regresor — predecir cero cuando hay rotura es información válida.

**Scoring**: Se ejecuta en un script separado (`02b_score_models_h4_v4.sql`) para que la flag `--skip-training` pueda omitir el reentrenamiento BQML (que dura ~30 min) sin perder el scoring.

---

## 5. Calibración Conforme — Intervalos de Predicción con Cobertura Garantizada

### 5.1 Marco teórico

Se usa **Mondrian Conformal Prediction** (Vovk et al.), que produce intervalos con garantía de cobertura marginal por segmento:

$$P(y_{T+4} \leq \hat{q}_{0.90} \mid \text{segmento}) \geq 0.90$$

El score de conformidad por fila es el **residuo normalizado** en el split CALIB:

$$\text{score}_i = \frac{y_{\text{true},i} - \hat{y}_{P50,i}}{\text{scale}_i}$$

donde `scale` es una estimación de la dispersión local (de base\_scores). Los scores son `NULL` para SKUs con `amplitude < 5.0` (inactivos), que **no participan** en la calibración ni en la evaluación B3.

### 5.2 Segmentación — `segment_id_child`

Los quantiles se estiman por segmento tridimensional (mismo esquema que v2/v3):

```
segment_id_child = season_group + "_D" + demand_decile + "_V" + volatility_bucket
```

- `demand_decile`: decil de amplitude (del 1=baja al 10=alta)
- `volatility_bucket`: quintil de `cv_13w`, calculado **sólo en CALIB** (umbrales exportados a `volatility_bucket_thresholds_h4_v4`) para que la asignación en VAL sea determinista y no dependa de la población

### 5.3 Dos etapas de calibración

**Etapa 1 (CALIB):** Se computa el quantile empírico P90/P95/P99 del score por segmento → `quantile_lookup_h4_v4`

**Etapa 2 (VAL\_TUNE):** Se mide la tasa de violación observada con los quantiles crudos y se ajusta:

$$\text{correction\_factor} = \text{CLIP}\!\left(\frac{\text{viol\_rate}_{P90}}{0.10},\ 0.80,\ 3.00\right)$$

Si la cobertura era del 85% (demasiado ajustada), correction\_factor = 0.85/0.10 = 0.85 → se amplían los intervalos. Si era del 97% (demasiado ancha), se reduce (mínimo 0.80).

**Jerarquía de fallback:**
1. `child` — segmento completo (season × decile × bucket)
2. `season_group` — sólo por temporada (si n\_obs\_tune < 200)
3. `global` — z-score normal estándar 1.645 (si todo falla)

### 5.4 Cap de cola

$$q^* \leftarrow \min\!\left(q^*,\ 2.0 \times P99_{\text{TRAIN+CALIB}}(y_{\text{true}} \mid \text{season})\right)$$

Evita intervalos extremos por outliers en el quantile lookup. Monotonicity enforcement: `q90 ≤ q95 ≤ q99`.

---

## 6. Política de Puntuación y Selección de Alertas

Se evalúan 5 políticas de scoring sobre `VAL_TUNE` para seleccionar la que maximiza `lift@100`:

| Política | Fórmula | Intuición |
|----------|---------|-----------|
| A (baseline v3) | `p_oos × (q95 − yhat_P50)` | Riesgo × amplitud del intervalo |
| **B (seleccionada)** | **`p_oos × q90`** | **Unidades en riesgo esperadas** |
| C\_0.5 | `p_oos^0.5 × (q95 − yhat_P50)` | Downweight de probabilidades altas |
| C\_1.0 | equal to A | — |
| C\_1.5 | `p_oos^1.5 × (q95 − yhat_P50)` | Penaliza más las probabilidades bajas |

La política B fue seleccionada porque es directamente interpretable como **unidades esperadas no vendidas** y produjo el mayor lift@100 en el sweep sobre VAL\_TUNE.

El resultado es `alerts_top100_h4_v4`: los 100 SKUs de mayor riesgo para cada semana de decisión.

---

## 7. Gates de Calidad

### Gate B3 — Cobertura del Intervalo P90

**¿Qué mide?** Que la tasa de violación empírica en VAL (la fracción de filas activas donde `y_true > q90`) esté dentro del rango tolerado.

| Criterio | Threshold |
|---------|----------|
| `viol_rate_p90` | ∈ [0.08, 0.12] por season\_group |
| Población | `amplitude ≥ 5.0` (SKUs activos) |

**Resultado:** `B3 = PASS`

> Evaluado también en `VAL_TEST` (1/3 final de VAL, sin snooping de VAL\_TUNE) — ambos pasan.

### Gate B4 — Calidad de Alertas

**¿Qué mide?** Que el lift@100 (precision del modelo / prevalencia base) sea ≥ 1.5, y que haya mejora respecto a v3.

| Métrica | Threshold | Resultado |
|--------|----------|---------|
| `lift@100_model` | ≥ 1.5× | **10.83×** ✅ |
| Comparación vs v3 | mejora | mejor ✅ |

**Resultado:** `B4 = CONDITIONAL_PASS` (el lift supera ampliamente el umbral; "conditional" indica que la mejora vs v3 supera el mínimo pero con muestra limitada en HIGH_SEASON)

### Leakage Check

Se verifica que `decision_week + 4 = target_week` en todas las filas de VAL → `neg_after=0`. **PASS**.

---

## 8. Extensión KPI — Re-ranking por Margen (€ en Riesgo)

La lista de alertas base ordena por probabilidad × volumen. La extensión KPI re-rankea por **valor económico en riesgo**.

### 8.1 Arquitectura cross-region

| Componente | Proyecto | Dataset | Región BQ |
|-----------|---------|---------|----------|
| Modelos / forecasts | `thequantitativeledger` | `cruzber_models_eu` | **EU** |
| KPI / márgenes (`v_kpi_por_articulo`) | `voltaic-tuner-475510-s4` | `dataset_cruzber` | **US** |

BigQuery no permite leer en EU dato que reside en US con un cliente EU. Se usa un **pandas bridge**:
1. `kpi_client` (ubicación US) ejecuta la SELECT sobre `v_kpi_por_articulo`
2. El resultado (4.580 SKUs) se carga en memoria como DataFrame pandas  
3. `eu_client.load_table_from_dataframe()` escribe en `kpi_por_articulo_snapshot` (EU)

Dependencias añadidas al contenedor: `pandas>=2.0.0`, `pyarrow>=12.0.0`

### 8.2 Fórmula de euros en riesgo

$$\text{eur\_at\_risk} = p\_oos_{h4} \times q90_{h4} \times \text{margen\_unit}$$

- $p\_oos_{h4}$: probabilidad de rotura
- $q90_{h4}$: unidades P90 — estimación del tamaño de la demanda en escenario adverso
- $\text{margen\_unit}$: margen neto unitario (€) del KPI snapshot

### 8.3 Re-ranking

`alerts_top100_h4_margin`: mismos 100 SKUs re-ordenados por `eur_at_risk DESC` — prioriza SKUs donde el coste de la rotura es mayor, no sólo los más probables.

### 8.4 Resultados de evaluación (VAL 2024)

| Segmento | Precision | Recall | Lift | € at Risk |
|---------|----------|-------|------|----------|
| GLOBAL | 0.2119 | 0.2494 | **11.08×** | 382.557 € |
| REST | — | — | **13.12×** | 241.387 € |
| HIGH_SEASON | — | — | **6.32×** | 141.170 € |

---

## 9. Sesgos Conocidos y Limitaciones

### 9.1 Excusión de SKUs inactivos (amplitude < 5.0)
Los SKUs con demanda muy baja o cero en las últimas 13 semanas no participan en la calibración conforme ni en la evaluación B3. La cobertura P90 no está garantizada para estos SKUs. En producción, sus cuantiles se calculan pero con intervalos más anchos (fallback a z normal).

### 9.2 Selection bias en KPI matching
4.580 de los SKUs en forecasts tienen correspondencia en `v_kpi_por_articulo`. Los SKUs sin match tienen `eur_at_risk = 0` y quedan automáticamente fuera del top-100 margins — este es el comportamiento conservador correcto, pero puede "esconder" SKUs de alto volumen sin margen catalogado.

### 9.3 VAL_TUNE como ajuste de corrección
El `correction_factor` se estima sobre los primeros 2/3 de VAL (2024-01-01 a ~2024-08). Hay un doble uso parcial de datos: VAL\_TUNE ajusta el factor, y luego la evaluación B3 de producción incluye ese mismo subconjunto. La evaluación **paper-clean** (B3 en VAL\_TEST) es la referencia honesta — **ambas pasan**.

### 9.4 Baja cobertura en HIGH_SEASON
HIGH_SEASON abarca ~8–10 semanas (mayo–agosto). El tamaño de muestra de calibración CALIB HIGH_SEASON (~40k filas, ~6 semanas) es más reducido que REST, lo que produce intervalos algo más anchos y un lift menor (6.32× vs 13.12×).

### 9.5 Horizonte fijo h=4
El modelo es válido **exclusivamente** para predicciones a 4 semanas vista. No interpolar a h=1, 2 o 8. Requiere reentrenamiento si el horizonte cambia.

### 9.6 Sin regressores externos
No se incorporan datos de meteorología, promociones, precios competidores ni indicadores macroeconómicos. La estacionalidad se captura únicamente via `is_high_season` y los rolling stats. Eventos excepcionales (stockouts de proveedor, promociones puntuales) generarán residuos fuera de los cuantiles empíricos → el correction_factor de la siguiente CALIB se ajustará.

### 9.7 Demanda observada vs. demanda potencial
`y_true_h4` es demanda **vendida**, no demanda potencial (no hay datos de demanda insatisfecha). Los modelos aprenden a predecir ventas reales, que ya incluyen el efecto de roturas pasadas → los cuantiles pueden estar subestimados en SKUs con historial frecuente de stockout (efecto de censura).

---

## 10. Flujo del Pipeline (resumen)

```
01_intermittent_features_h4_v4.sql   → weekly_features_h4_v4         (features intermitentes)
02_train_models_h4_v4.sql            → m_oos_h4_v4, m_demand_h4_v4   (entrenamiento BQML)
02b_score_models_h4_v4.sql           → base_scores_h4_v4              (scoring all splits)
03_residuals_quantile_lookup_h4_v4   → residuals_h4_v4, quantile_lookup_h4_v4
04_conformal_calibration_h4_v4.sql   → quantile_factors_h4_v4        (correction factors)
05_forecast_h4_v4.sql                → forecast_h4_v4                 (intervalos conformes)
06_policy_sweep_alerts_h4_v4.sql     → alerts_top100_h4_v4           (top-100 weekly alerts)
07_coverage_gate_b3_h4_v4.sql        → gate_b3_verdict_h4_v4         (B3: cobertura)
08_alerts_eval_gate_b4_leakage.sql   → gate_b4_verdict_h4_v4         (B4: lift + leakage)
─────── KPI extension ───────────────────────────────────────────────────────────
kpi/00_create_kpi_snapshot.sql       → kpi_por_articulo_snapshot      (pandas bridge US→EU)
kpi/10_enrich_forecast_with_kpi.sql  → forecast_h4_v4_kpi            (enrich + eur_at_risk)
kpi/20_alerts_top100_h4_margin.sql   → alerts_top100_h4_margin        (re-rank por margen)
kpi/30_eval_alerts_top100_h4_margin  → eval_alerts_top100_h4_margin   (eval con margen)
```

---

## 11. Configuración de Producción

| Variable | Valor |
|---------|-------|
| Cloud Run Job | `cruzber-h4-pipeline` (region `europe-west1`) |
| Imagen Docker | `sha256:d4d63e35...` |
| `BQ_DATASET` | `cruzber_models_eu` |
| `BQ_LOCATION` | `EU` |
| `KPI_DATASET` | `voltaic-tuner-475510-s4.dataset_cruzber` |
| `KPI_LOCATION` | `US` |
| `ENABLE_MARGIN_RANKING` | `1` |
| SA | `bq-proxy-sa@thequantitativeledger.iam.gserviceaccount.com` |
| SA roles | `bigquery.dataEditor` en `cruzber_models_eu`, `bigquery.dataViewer` en `voltaic-tuner-475510-s4` |

---

## 12. Referencias

- Vovk, V., Gammerman, A., Shafer, G. (2005). *Algorithmic Learning in a Random World*. Springer.
- Angelopoulos, A.N., Bates, S. (2022). *A Gentle Introduction to Conformal Prediction and Distribution-Free Uncertainty Quantification*. arXiv:2107.07511.
- Chen, T., Guestrin, C. (2016). *XGBoost: A Scalable Tree Boosting System*. KDD 2016. _(BQML BOOSTED_TREE es compatible con XGBoost)_
- Syntetos, A.A., Boylan, J.E. (2005). *The accuracy of intermittent demand estimates*. Int. J. Forecasting.
