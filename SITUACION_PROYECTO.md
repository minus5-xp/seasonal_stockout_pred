# SITUACIÓN DEL PROYECTO — OOS Seasonal Fillrate (Cruzber H4)
## Informe de contexto para continuación con ChatGPT

**Fecha**: 2026-01-27  
**Estado**: 🔴 Bug crítico activo en pipeline Python local  
**Objetivo del documento**: Transferir contexto completo del estado del proyecto para continuar trabajo con un nuevo asistente de IA.

---

## 1. Contexto General del Proyecto

### 1.1 ¿Qué es esto?

Proyecto académico (ISDI MDA — Programa Troncal) que replica en Python local un modelo BQML de predicción de stockouts ya productivo en BigQuery. El modelo calcula:

1. **Probabilidad de OOS** (out-of-stock) por SKU × semana para el horizonte H=4 semanas
2. **Riesgo económico** en euros: `riesgo_stockout_eur = p_oos_h4 × yhat_p50_h4 × precio_unitario`
3. **Ranking de alertas** Top-100 SKUs en temporada alta, evaluado con Lift@100

El cliente ficticio es **Cruzber**, distribuidor español de accesorios de vehículo (`familia CRUZ`).

### 1.2 Estructura del modelo de referencia (BQML)

- **Proyecto GCP**: `thequantitativeledger`
- **Dataset**: `cruzber_models_eu`
- **Tablas clave**:
  - `forecast_h4`: predicciones SKU × semana — columnas `p_oos_h4`, `yhat_p50_h4`, `q90_h4`, `q95_h4`, `y_true_h4`, `season_group`
  - `alerts_top100_h4`: Top-100 alertas económicas
  - `run_summary_h4`: métricas agregadas por `season_group` (REST / HIGH_SEASON / ALL)
- **Identidad GCP**: `hdeval@mda.isdi.es`

### 1.3 Benchmarks BQML de referencia (VAL 2024)

| Métrica | GLOBAL | REST | HIGH_SEASON |
|---------|--------|------|-------------|
| **Lift@100** | **11.08×** | **13.12×** | **6.32×** |
| AUC-ROC (MAIN) | 0.9886 | — | — |
| PR-AUC | 0.5931 | — | — |
| Prec@100 | 95% | — | — |

Modelo H1 (logistic baseline): AUC=0.9109, Lift@100≈10×  
Modelo H0 (heuristic): AUC=0.9517, Lift@100≈66× (score invertido corregido)

---

## 2. Estructura del Repositorio

```
oos_seasonal_fillrate/
├── margin_ranking_vertex.ipynb        # NOTEBOOK PRINCIPAL (25 celdas)
├── reports_generated/                 # Outputs del último run
│   ├── alerts_top100_h4.parquet
│   ├── forecast_h4_enriched.parquet
│   ├── run_summary_h4.csv             # Métricas agregadas
│   └── top20_riesgo_economico.csv     # Top 20 SKUs por riesgo €
├── data/                              # CSVs fuente (vacío en repo, se carga desde GCS)
├── reports/                           # Informes de hitos anteriores (.md)
├── scripts/                           # Scripts de configuración y deploy
├── consultas_informe_h4.sql           # Consultas BigQuery de referencia
└── requirements.txt
```

---

## 3. Stack Técnico

### 3.1 Entorno de ejecución

- **Plataforma target**: Vertex AI Workbench (Google Cloud)
- **Python**: 3.10+
- **Identidad**: Application Default Credentials (ADC) `hdeval@mda.isdi.es`
- **GCS bucket**: `bucket-isdi-mda-online`
- **Prefix GCS**: `proyecto-troncal/cruzber/`

### 3.2 Fuentes de datos CSV

| Archivo en GCS | Columnas clave | Descripción |
|---|---|---|
| `fact_lineas_albaran.csv` | `codigo_articulo`, `unidades`, `base_imponible`, `fecha_albaran` | Ventas históricas semanales |
| `dim_articulo.csv` | `codigo_articulo`, `descripcion_articulo`, `codigo_familia`, `tipo_abc`, `precio_venta`, `coste_escandallo` | Maestro de artículos |
| `dim_fecha.csv` | `fecha`, `iso_week`, `is_high_season` | Calendario |
| `dim_cliente.csv` | cliente, segmento | Maestro clientes |
| `hhi_clientes.csv` | `codigo_articulo`, `hhi_base_roll13` | Concentración HHI |

### 3.3 Dependencias Python principales

```python
pandas, numpy, scipy
google-cloud-storage, google-cloud-bigquery
scikit-learn
pyarrow, plotly
```

---

## 4. Notebook: Estado Celda por Celda

El notebook `margin_ranking_vertex.ipynb` tiene **25 celdas**. A continuación el inventario completo:

| # | ID VSC | Tipo | Descripción | Estado |
|---|--------|------|-------------|--------|
| 1 | — | Markdown | Título y descripción del notebook | ✅ |
| 2 | — | Code | Imports: pandas, numpy, gcs, bq, sklearn, plotly | ✅ |
| 3 | — | Code | Auth via ADC (`google.auth.default`), GCS client init | ✅ |
| 4 | — | Code | Descarga CSVs desde GCS → DataFrames en memoria | ✅ |
| 5 | — | Code | Limpieza: parse fechas, cast tipos, agrupación semanal | ✅ |
| 6 | — | Code | Merge dimensional: fact + dim_articulo + HHI + calendario | ✅ |
| **7** | `#VSC-d1d6c9a1` | **Code** | **Config params: H=4, ROLL_W=12, MIN_P=4, TOP_N=100, VAL_YEAR=2024, SEASON_MONTHS** | ⚠️ **BUG AQUÍ** |
| 8 | — | Code | Feature engineering: lags, rolling stats, is_high_season | ✅ |
| **9** | `#VSC-aca1a855` | **Code** | **Pipeline principal completo** (funciones privadas + expansión panel seasonal + forecast) | ✅ BQML-aligned |
| 10 | — | Code | Diagnóstico precio/coste (`precio_unitario`, `coste_unitario`, `margen_unitario`) | ✅ |
| **11** | `#VSC-663dc9a0` | **Code** | **Diagnóstico GUARD + distribución mensual ventas** | ✅ (guard añadido) |
| 12 | `#VSC-4ed9a19c` | Markdown | Fórmulas económicas BQML | ✅ |
| **13** | `#VSC-fc8e8a72` | **Code** | **Step 10**: `riesgo_stockout_eur = p_oos × yhat_p50 × precio_unitario` | ✅ BQML-aligned |
| 14 | — | Code | Diagnóstico intermedio Step 10 | ✅ |
| **15** | `#VSC-9286dc7b` | **Code** | **Step 20**: Ranking + etiquetas `true_stockout_label_model` / `true_stockout_sales0` | ✅ BQML-aligned |
| 16 | — | Code | Diagnóstico intermedio Step 20 | ✅ |
| **17** | `#VSC-f436b791` | **Code** | **Step 30**: `evaluate_alerts()` — Lift@100, Prec@K, económico | ✅ BQML-aligned |
| **18** | `#VSC-27cefba9` | **Code** | Comparación BQML (`risk_score`) vs Policy B (`p_oos×q90`), `lift_bqml` / `lift_std` | ✅ |
| 19 | — | Markdown | Interpretación resultados | ✅ |
| 20 | — | Code | Fig 1: Calibración de probabilidades | ✅ |
| 21 | — | Code | Fig 2: Precision-Recall curve | ✅ |
| 22 | — | Code | Fig 3: Riesgo € por segmento ABC | ✅ |
| 23 | — | Code | Fig 4: Lift curve comparativa BQML vs baseline | ✅ |
| 24 | — | Markdown | Conclusiones e interpretación | ✅ |
| **25** | `#VSC-bc3a1ec3` | **Code** | **Export**: parquet + CSV + HTML figs → `outputs/{RUN_TS}/` | ✅ |

---

## 5. Bug Crítico Activo: SEASON_MONTHS Incorrecto

### 5.1 Descripción del bug

**Celda 7** (`#VSC-d1d6c9a1`) contiene el parámetro:

```python
SEASON_MONTHS = {4, 5, 6, 7, 8}   # ← INCORRECTO para catálogo CRUZ
```

Este parámetro define qué meses se consideran "temporada alta" para construir el panel de evaluación estacional. El problema es que `{4, 5, 6, 7, 8}` corresponde a **primavera-verano de ciclismo**, pero el catálogo real de Cruzber es **100% `familia CRUZ`** = accesorios de vehículo, cuyas ventas ocurren en meses distintos.

### 5.2 Evidencia cuantitativa del fallo en cascada

**Archivo `reports_generated/run_summary_h4.csv`** (último run, valores exactos):

```csv
season_group,n_universe,n_stockouts,prevalence,lift_at_100,sum_riesgo_stockout_eur
REST,7712,7712,1.0,1.0,0.0
HIGH_SEASON,29222,29222,1.0,1.0,0.0
ALL,36934,36934,1.0,1.0,0.0
```

**Archivo `reports_generated/top20_riesgo_economico.csv`** (primeras filas):

```csv
sku_id,descripcion_articulo,tipo_abc,codigo_familia,total_riesgo_stockout_eur,avg_p_oos,avg_yhat_p50
001-106,Caja Nº 8,C,CRUZ,0.0,1.0,0.0
001-267,Caja O-PLUS 2,A,CRUZ,0.0,1.0,0.0
001-268,Caja O-PLUS 3,A,CRUZ,0.0,1.0,0.0
```

**Diagnóstico profundo ejecutado en terminal**:

```
yhat_p50_h4 > 0:  0 / 36,934  (0%)
y_true_h4   > 0:  0 / 36,934  (0%)
SKUs con algún y_true > 0:  0 / 3,060
codigo_familia en alerts: CRUZ = 2,200/2,200 (100%)
```

### 5.3 Mecanismo del fallo en cascada

```
SEASON_MONTHS = {4,5,6,7,8}   (meses configurados como temporada alta)
        ↓
_expand_season_panel() filtra ventas de la familia CRUZ en meses 3–8
        ↓
La familia CRUZ vende principalmente FUERA de esos meses (otoño-invierno)
        ↓
Panel estacional = 100% ceros en y_true
        ↓
rolling median(ROLL_W=12, min_periods=4) sobre ventas cero = 0 en todos
        ↓
yhat_p50 = 0 → riesgo_stockout_eur = p_oos × 0 × precio = 0€
OOS rate sobre panel de ceros = 1.0 → p_oos = 1.0 para todos
prevalence = 1.0 → lift = precision / prevalence = 1.0 / 1.0 = 1.0×
```

### 5.4 Brecha vs benchmarks BQML

| Métrica | Pipeline Python (actual) | BQML referencia | Ratio |
|---|---|---|---|
| `lift@100` GLOBAL | **1.0×** | **11.08×** | 91% de pérdida |
| `lift@100` REST | **1.0×** | **13.12×** | 92% de pérdida |
| `lift@100` HIGH_SEASON | **1.0×** | **6.32×** | 84% de pérdida |
| `avg_p_oos` | **1.0** | ~0.015 | 67× demasiado alto |
| `avg_yhat_p50` | **0.0** | >0 | inválido |
| `sum_riesgo_eur` | **0.0€** | >0€ | inválido |

---

## 6. Fix Requerido

### Paso 1: Ejecutar celda 11 para ver distribución mensual real

La **celda 11** (`#VSC-663dc9a0`) tiene un GUARD que detecta el fallo y muestra automáticamente la distribución de ventas por mes desde `fact_lineas_albaran`. Si `yhat_p50 > 0 == 0%` OR `p_oos == 1.0 > 95%`, imprime:

```
[GUARD] p_oos=1.0 en el 100.0% de las predicciones
[GUARD] yhat_p50_h4>0 en el 0.0% de las predicciones
[DIAGNÓSTICO] Distribución mensual de ventas en fact_lineas_albaran:
  mes  n_lineas  total_unidades  pct_ventas
  ...  (tabla con los meses reales de venta)
→ Los 5 meses con más ventas son: X, X, X, X, X
→ Actualiza SEASON_MONTHS en Cell 7 con esos meses
```

### Paso 2: Actualizar SEASON_MONTHS en celda 7

Con la distribución real, actualizar el parámetro en `#VSC-d1d6c9a1`:

```python
# ANTES (incorrecto - temporada ciclismo):
SEASON_MONTHS = {4, 5, 6, 7, 8}

# DESPUÉS (ejemplo - ajustar con distribución real):
SEASON_MONTHS = {9, 10, 11, 12, 1}  # ← completar con meses reales del diagnóstico
```

### Paso 3: Re-ejecutar notebook completo

Ejecutar desde celda 7 hasta celda 25. Los outputs esperados tras el fix:
- `p_oos` distribuido entre 0 y 1 (media ≈ 0.015–0.05)
- `yhat_p50 > 0` en la mayoría de SKUs activos
- `riesgo_stockout_eur > 0` en los SKUs con alta probabilidad
- `lift@100` > 1.0× (objetivo: acercarse a nivel BQML de 6-13×)

---

## 7. Parámetros de Configuración Actuales (Celda 7)

```python
# Horizonte de predicción
H         = 4            # semanas hacia adelante (alineado con BQML H4)
ROLL_W    = 12           # ventana rolling (≈ 1 trimestre)
MIN_P     = max(4, ROLL_W // 3)  # = 4, min_periods para rolling (evita drop de SKUs cortos)

# Evaluación
VAL_YEAR  = 2024         # año de validación
TOP_N     = 100          # alertas Top-N a rankear

# Temporada ← BUG
SEASON_EVAL   = set(range(3, 9))    # meses temporada eval interna
SEASON_MONTHS = {4, 5, 6, 7, 8}    # ← INCORRECTO para familia CRUZ

# Outputs
RUN_TS    = datetime.now().strftime("%Y%m%dT%H%M%S")
OUT_DIR   = Path(f"outputs/{RUN_TS}")
```

---

## 8. Fórmulas Económicas (BQML-Aligned)

Todas las fórmulas del pipeline Python están alineadas con `cruzber_models_eu.forecast_h4`:

```python
# Precio unitario (media de ventas históricas)
precio_unitario = AVG(base_imponible / unidades)   # = BQML: AVG(SAFE_DIVIDE(base_imponible, unidades))

# Riesgo de stockout en euros
riesgo_stockout_eur = p_oos_h4 × yhat_p50_h4 × precio_unitario

# Riesgo en escenario adverso (percentil 95)
riesgo_q95_eur = p_oos_h4 × q95_h4 × precio_unitario

# Venta esperada sin riesgo
venta_esperada_eur = yhat_p50_h4 × precio_unitario

# Riesgo score compuesto (= columna risk_score de BQML)
risk_score = p_oos_h4 × yhat_p50_h4 × (1 + uncertainty_width / (yhat_p50_h4 + 1e-6))
    donde: uncertainty_width = q95_h4 - q90_h4

# Margen en riesgo
margen_unitario = precio_unitario - coste_unitario
margen_pct      = margen_unitario / precio_unitario
```

---

## 9. Análisis de Ablación BQML (Hito 4 — Referencia)

Para contexto: el modelo BQML usa **14 features** en 5 grupos:

| Grupo | Features | AUC (A0_FULL=0.9891) | Δ sin el grupo |
|---|---|---|---|
| Core demand | lag_1/2/4, roll4_mean, roll13_mean/std, amplitude, cv_roll13, n_days_nonzero | — | -0.4708 (críticos) |
| Whale/concentración | hhi_base_roll13, top_customer_share, n_customers_roll13 | 0.9887 | -0.0004 (insignificante) |
| Seasonality | iso_week, is_high_season | 0.9889 | -0.0002 (insignificante) |

**Recomendación BQML**: Modelo **A1_NO_WHALES** (11 features) es equivalente a full con 21% menos features.

---

## 10. Estado de Tareas

| Tarea | Estado |
|---|---|
| Auth migrado a ADC único `hdeval@mda.isdi.es` | ✅ Completado |
| Pipeline desde CSVs crudos hasta forecast | ✅ Completado |
| Alineación columnas BQML (`unidades`, `base_imponible`, `codigo_articulo`) | ✅ Completado |
| Fórmula precio: `AVG(base_imponible/unidades)` | ✅ Completado |
| Fórmula riesgo económico: `p_oos × yhat_p50 × precio` | ✅ Completado |
| Columnas `risk_score`, `true_stockout_label_model`, `uncertainty_width=q95-q90` | ✅ Completado |
| `min_periods=4` (evita drop masivo de SKUs life-cycle cortos) | ✅ Completado |
| Celdas Step 10/20/30 + figs + export alineadas con BQML | ✅ Completado |
| Guard diagnóstico `SEASON_MONTHS` en celda 11 | ✅ Completado |
| Evaluación outputs `reports_generated/` — root cause identificado | ✅ Completado |
| **Fix `SEASON_MONTHS` para catálogo CRUZ** | 🔴 **PENDIENTE** |
| **Re-ejecutar notebook y validar lift > 1×** | 🔴 **PENDIENTE** |
| **Comparar lift Python vs BQML benchmark (11.08×)** | 🔴 **PENDIENTE** |

---

## 11. Archivos de Contexto Adicional en el Repositorio

| Archivo | Contenido |
|---|---|
| `reports/HITO3_Baseline_Comparison_Report_v2.md` | Benchmarks completos de baselines H0/H1/H2 vs MAIN |
| `reports/HITO4_Ablation_Study_Report.md` | Estudio de ablación de features BQML |
| `consultas_informe_h4.sql` | Consultas BigQuery de referencia para todas las métricas |
| `reports/PIPELINE_METHODOLOGY.md` | Metodología detallada del pipeline |
| `reports/B4_policy_simulation.md` | Simulación de políticas de reposición |
| `INFORME_FORECAST_H4_COMPLETO.md` | Informe ejecutivo completo del modelo |

---

## 12. Instrucciones para el Asistente IA que Continúe

### Contexto de trabajo
- Workspace local en Windows: `c:\Users\hugod\...\oos_seasonal_fillrate\`
- Notebook principal: `margin_ranking_vertex.ipynb`
- **NO** ejecutar el notebook localmente — está diseñado para Vertex AI Workbench
- Puedes editar celdas del notebook con herramientas de edición de archivos

### Tarea inmediata
1. **Leer la distribución mensual de ventas** en `fact_lineas_albaran.csv` (si está disponible localmente en `data/`) o revisar la celda 11 del notebook que la calcula en runtime
2. **Actualizar `SEASON_MONTHS`** en `#VSC-d1d6c9a1` (celda 7) con los meses reales de ventas de la familia CRUZ
3. Verificar que el pipeline produce `p_oos` y `yhat_p50` razonables antes de hacer el run completo

### Si `data/fact_lineas_albaran.csv` existe localmente
Ejecutar este diagnóstico directo:

```python
import pandas as pd
df = pd.read_csv("data/fact_lineas_albaran.csv", parse_dates=["fecha_albaran"])
df["mes"] = df["fecha_albaran"].dt.month
monthly = df.groupby("mes")["unidades"].sum().sort_values(ascending=False)
print("Top meses por unidades vendidas:")
print(monthly.head(8))
print("\nSugerencia SEASON_MONTHS:", set(monthly.head(5).index.tolist()))
```

### Validación del fix
Tras actualizar `SEASON_MONTHS` y re-ejecutar el notebook en Vertex AI:
- `run_summary_h4.csv` debe mostrar `prevalence < 1.0` y `lift_at_100 > 1.0×`
- Objetivo mínimo: `lift@100 > 3×` (mitad del benchmark BQML)
- Objetivo ideal: `lift@100 > 6×` (nivel HIGH_SEASON de BQML)

---

*Documento generado automáticamente como checkpoint de contexto — 2026-01-27*
