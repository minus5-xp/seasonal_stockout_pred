# OOS Seasonal Fillrate — Cruzber H4

Proyecto académico (ISDI MDA — Troncal) de predicción probabilística de stockouts para Cruzber, distribuidor español de accesorios de vehículo (familia CRUZ). Horizonte de predicción: **h = 4 semanas**. Datos de entrenamiento: 2020–2023. Validación: 2024 completo.

**GCP**: `thequantitativeledger.cruzber_models_eu` · **GCS**: `bucket-isdi-mda-online/proyecto-troncal/cruzber/`

---

## Flujo del proyecto

### Fase 0 — Base de datos relacional (dic 2025)

Migración de 9 archivos XLSX a MySQL 8 normalizado (`dataset_cruzber`).

- 938 230 líneas de albarán · 30 531 artículos · 52 provincias · 2 095 días (2019–2024)
- Problemas resueltos: parser de fechas español multi-formato, tipos FK/PK incompatibles, cobertura del 30% al 100% de columnas
- Tablas clave: `fact_lineas_albaran`, `dim_articulo`, `dim_cliente`, `dim_fecha`, `hhi_clientes`

---

### Fase 1 — Modelo de clasificación de stockouts (ene–feb 2026)

Clasificador binario BQML (`BOOSTED_TREE_CLASSIFIER`) para predecir probabilidad de OOS por SKU × semana con h=4.

**Features (14 en total):**

| Grupo | Features |
|-------|---------|
| Core demand | `lag_1/2/4`, `roll4_mean`, `roll13_mean/std`, `amplitude`, `cv_roll13`, `n_days_nonzero` |
| Seasonality | `iso_week`, `is_high_season` |
| Concentration | `hhi_base_roll13`, `top_customer_share`, `n_customers_roll13` |

**Protocolo de evaluación:** SEGMENTED por temporada (HIGH_SEASON / REST), cada una con su propio Top-100. Validación en 231 036 observaciones VAL 2024.

**Métricas del modelo canónico (Run A, auditado):**

| Métrica | HIGH_SEASON | REST |
|---------|-------------|------|
| AUC-ROC | 0,8455 | 0,8455 |
| Precision@100 | 24% | 30% |
| Lift@100 | 13,95× | 14,94× |
| Brier calibrado | 0,0171 | 0,0171 |

**Baselines evaluados:**

| Modelo | AUC-ROC | Lift@100 |
|--------|---------|----------|
| H0 heurístico | 0,9517 (invertido) | 66× |
| H1 logístico | 0,9109 | 10× |
| H2 temporal | 0,9772 (invertido) | 66× |
| **MAIN BoostedTree** | **0,9886** | **60×** |
| Random | 0,4996 | 2× |

> H0 y H2 producían scores invertidos (`1 − P(stockout)`). Tras corrección sistemática, todos los modelos demuestran poder discriminativo real. La ventaja del modelo principal es la combinación de AUC alto y PR-AUC elevada (0,593 vs 0,09–0,14 de baselines).

**Estudio de ablación (HITO 4):** Las features de core demand capturan el 98,9% del rendimiento. El modelo reducido A1_NO_WHALES (11 features, sin concentración HHI) alcanza AUC 0,9887 vs 0,9891 del full — candidato a modelo canónico de producción.

---

### Fase 2 — Cuantiles conformales Track B (feb 2026)

Generación de intervalos probabilísticos de demanda (P50/P90/P95) con calibración Mondrian en 3 ejes para uso en política de inventario.

**Arquitectura de calibración (h4 v4):**

```
TRAIN (2020–2023) → CALIB → VAL_TUNE (2/3 de VAL) → VAL_TEST (1/3 de VAL)
```

- **Segmentación**: `season_group × demand_decile × volatility_bucket` (NTILE-5 sobre CV-13w)
- **Scores de conformidad**: residuo normalizado `(y_true − ŷ) / scale`, NULL para filas inactivas (`amplitude < 5`)
- **Corrección de cobertura**: `correction_factor = clip(viol_rate_p90 / 0.10, 0.80, 3.00)` medido en VAL_TUNE

**Gate B3** — cobertura condicional P90 en [8%, 12%]:

| Segmento | Cobertura condicional | Estado |
|----------|-----------------------|--------|
| HIGH × HIGH | 9,70% | ✅ PASS |
| HIGH × LOW | 9,77% | ✅ PASS |
| HIGH × MEDIUM | 7,18% | ❌ FAIL |
| REST × HIGH | 7,94% | ❌ FAIL |
| REST × LOW | 6,64% | ❌ FAIL |
| REST × MEDIUM | 8,33% | ✅ PASS |

**Estado Track B: 🔴 NO-GO** — 3/6 segmentos fuera de rango. Causa raíz: segmentación HHI demasiado gruesa para la heterogeneidad de volatilidad dentro de los bins, especialmente REST × LOW (66% de la población).

**Gate B4** — simulación de política (fill-rate vs naive): ✅ PASS. Política P3 Option-B alcanza fill 96,4% (β=0,9) vs 79,5% naive.

---

### Fase 3 — Política de inventario Newsvendor V4f (abr–may 2026)

Backtest dinámico de política de reposición a nivel SKU × provincia × semana (52 provincias, 998 919 filas, S01–S27 2024). El bloque anterior (V4i/V4d/V4e) fallaba por evaluar stock entero semanal sin carry-over. V4f corrige la simulación física:

```
inventario_t = inventario_{t-1} + reposicion_t
servido_t    = min(inventario_t, real_t)
inventario_t = inventario_t − servido_t
```

**Comparativa de versiones:**

| Versión | Tipo | Fill % | Stock/real | Rotura | Ceros | Inv. final |
|---------|------|-------:|----------:|-------:|------:|----------:|
| V3 dinámica | dinámica | 91,757 | 1,638× | 96 462 | 76 150 | 843 282 |
| V4c continuo | estática | 91,782 | 1,692× | 96 166 | 79 292 | — |
| V4i | dinámica | 90,363 | 1,722× | 112 781 | 94 640 | 957 140 |
| V4d | dinámica | 90,515 | 1,751× | 111 003 | 78 026 | 989 381 |
| V4e | dinámica | 92,202 | 1,744× | 91 260 | 85 724 | 961 829 |
| **V4f** (`repl_hybrid_topup_v4f`) | **dinámica** | **90,910** | **1,722×** | **106 374** | **82 582** | **950 907** |

**Criterios de aceptación V4f:**

| Criterio | Resultado | Estado |
|----------|-----------|--------|
| Fill dinámico ≥ 90,91% | 90,910% | ✅ PASS |
| Fill dinámico ≤ 91,80% | 90,910% | ✅ PASS |
| Stock/real ≤ 1,80× | 1,722× | ✅ PASS |
| Stock en ceros ≤ 120 000 | 82 582 | ✅ PASS |
| Sin NaN / Inf | Sí | ✅ PASS |
| Sin negativos | Sí | ✅ PASS |

**Validación estadística — bootstrap pareado (5 000 réplicas, semilla 20260503):**

| Comparación | Δ wMAPE | IC 95% | p | Veredicto |
|-------------|---------|--------|---|-----------|
| T4 vs T0 (global) | +0,75 pp | [−0,66%, +1,52%] | 0,238 | No significativo |
| T4 vs T0 (Intermittent/Lumpy) | **−2,65 pp** | [−4,22%, −1,10%] | 0,000 | ✅ Mejor |

V4f es la única variante con mejora estadísticamente significativa en el segmento crítico de demanda intermitente y lumpy.

**Bias del forecast base:** 0,869 (objetivo conceptual ≈ 0,945). El modelo infraestima en Intermittent (0,679) y Lumpy (0,813). V4f actúa como política de reposición compensatoria, no como forecast calibrado.

**Decisión:** V4f aprobado con reservas como política de rescate operativo. V3 dinámica sigue siendo el benchmark de eficiencia agregada.

---

## Estado de gates (mayo 2026)

| Gate | Criterio | Estado |
|------|----------|--------|
| A0 | Offline validation — Precision@100, AUC, Brier | ✅ PASS |
| A1 | Shadow mode 4 semanas (W08–W11 2026) | ⏳ Pendiente |
| B3 | Cobertura condicional P90 ∈ [8%, 12%] | 🔴 FAIL — 3/6 segmentos |
| B4 | Fill-rate política vs naive | ✅ PASS |
| B5 | Submission readiness (ablations + anti-leakage) | ✅ PASS |
| V4f | 6 criterios obligatorios inventario | ✅ PASS |

---

## Estructura del repositorio

```
oos_seasonal_fillrate/
├── sql/
│   ├── bqml/
│   │   ├── h4_v4/          # Pipeline v4: features, scoring, conformal, forecast, policy
│   │   ├── quantiles/       # Mondrian split-conformal v1
│   │   └── quantiles_v2/    # Mondrian con volatility bucket (fix B3)
│   ├── baselines/           # H0–H2 + corrección de inversión
│   ├── anti_leakage/        # Tests de validación temporal
│   └── ablations/           # Ablación de grupos de features
├── src/
│   ├── bq/                  # Cliente BigQuery + ejecutores
│   ├── eval/
│   │   ├── quantiles_eval.py   # Gate B3
│   │   └── policy_sim.py       # Gate B4 (políticas P0–P3)
│   ├── reports/             # Generadores de informes
│   └── config/              # Configuración entorno
├── scripts/
│   └── r/
│       ├── run_newsvendor_v4f_inventory_simulation.R
│       ├── Forecast_Cruzber_FillRate_Newsvendor_v2.R
│       └── bootstrap_wmape_pareado.R
├── notebooks/
│   ├── margin_ranking_vertex.ipynb
│   ├── PAPER_READINESS_CRUZBER_H4.ipynb
│   └── WORKBENCH_H4_END2END_v2_kmeans_mondrian.ipynb
├── reports/
│   └── newsvendor_v4f/      # Audit V4f + fuente QMD del informe Sprint 8
├── docs/                    # Guías operativas (Docker, Cloud Shell, IAM)
└── data/                    # Datos locales (git-ignored, *.csv)
```

---

## Ejecución

### Pipeline Python (Track B)

```bash
# Pipeline completo
python -m src.entrypoint run

# Solo gate B3
python src/bq/run_optionB_b3_fix.py \
  --project-id thequantitativeledger \
  --dataset-id cruzber_models_eu

# Docker
docker build -t oos-h4-pipeline .
docker run --rm -v ~/.config/gcloud:/root/.config/gcloud:ro oos-h4-pipeline
```

### Scripts R (Newsvendor V4f)

```r
# Backtest dinámico de inventario
source("scripts/r/run_newsvendor_v4f_inventory_simulation.R")

# Validación bootstrap wMAPE
Rscript scripts/r/bootstrap_wmape_pareado.R \
  --input data/plantilla_bootstrap.csv \
  --baseline T0 --targets T0,T1,T2,T3,T4
```

---

## Trabajo pendiente

1. **Fix gate B3**: recalibrar segmento REST × LOW con volatility bucketing 4-bin (`sql/bqml/quantiles_v2/`)
2. **Calibración de bias**: implementar capa de ajuste para demanda Intermittent/Lumpy (`src/calibration/` vacío)
3. **Shadow mode A1**: activar dashboard Looker Studio + loop de feedback (target W08 2026)
4. **Carry-over productivo**: integrar lógica de inventario dinámico de V4f en `src/eval/policy_sim.py`
