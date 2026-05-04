# OOS Seasonal Fillrate Forecasting (h=4)

**Proyecto**: Predicción de Out-of-Stock con horizonte 4 semanas  
**Cliente**: CRUZBER  
**Dataset**: `thequantitativeledger.cruzber_models_eu`

---

## Estado actual (mayo 2026)

| Track | Sistema | Estado | Gate |
|-------|---------|--------|------|
| **Track A** | Alerting Top-K | 🟡 Conditional GO | A0 PASS · A1 pending shadow mode |
| **Track B** | Cuantiles P10/P50/P90 | 🔴 NO-GO | B3 FAIL — 3/6 segmentos fuera de [8%, 12%] |
| **Newsvendor V4f** | Política dinámica de inventario | ✅ Aprobado técnicamente | 6/6 criterios obligatorios PASS |

---

## Estructura

```
oos_seasonal_fillrate/
├── sql/                         # Queries SQL/BQML
│   ├── bqml/                    # Pipeline completo (B0-B5)
│   │   ├── h4_v4/               # Versión productiva v4 (conformal 3-eje)
│   │   └── quantiles/           # Mondrian split-conformal
│   ├── baselines/               # Modelos baseline (H0-H2)
│   ├── anti_leakage/            # Tests de validación
│   └── ablations/               # Estudios de ablación
├── src/                         # Código Python
│   ├── bq/                      # Cliente BigQuery + ejecutores
│   ├── eval/                    # Evaluación (quantiles, policy)
│   ├── reports/                 # Generadores de informes
│   ├── bundle/                  # Empaquetado GCS
│   └── config/                  # Configuración entorno
├── scripts/
│   └── r/                       # Scripts R — modelo newsvendor
│       ├── run_newsvendor_v4f_inventory_simulation.R
│       ├── Forecast_Cruzber_FillRate_Newsvendor_v2.R
│       └── bootstrap_wmape_pareado.R
├── reports/
│   └── newsvendor_v4f/          # Informe ejecutivo Sprint 8 + audit V4f
├── notebooks/                   # Jupyter notebooks
├── docs/                        # Documentación operativa
└── data/                        # Datos locales (git-ignored)
```

---

## Dos enfoques complementarios

### Track B — Cuantiles conformales (Python + BigQuery ML)

Pipeline BQML con calibración Mondrian en 3 ejes (`season_group × demand_decile × volatility_bucket`) y corrección de cobertura en dos etapas (CALIB → VAL_TUNE → VAL_TEST).

```bash
# Pipeline completo
python -m src.entrypoint run

# Solo evaluación B3
python src/bq/run_optionB_b3_fix.py --project-id thequantitativeledger --dataset-id cruzber_models_eu
```

**Gate B3** (cobertura condicional P90 en [8%, 12%]): actualmente **FAIL** en 3/6 segmentos — pendiente de recalibración.

### Newsvendor V4f — Backtest dinámico de inventario (R)

Simulación física de inventario con carry-over a nivel SKU × provincia × semana (52 provincias, 998K filas, S01–S27 2024). La estrategia ganadora `repl_hybrid_topup_v4f` pasa todos los criterios obligatorios.

```r
# Backtest dinámico V4f
source("scripts/r/run_newsvendor_v4f_inventory_simulation.R")

# Validación estadística bootstrap (5 000 réplicas)
Rscript scripts/r/bootstrap_wmape_pareado.R \
  --input plantilla_bootstrap.csv \
  --baseline T0 --targets T0,T1,T2,T3,T4
```

| Métrica | Resultado | Estado |
|---------|-----------|--------|
| Fill dinámico | 90,910% | ✅ PASS |
| Stock / real | 1,722x | ✅ PASS (≤ 1,80x) |
| Stock en ceros | 82.582 | ✅ PASS (≤ 120.000) |
| T4 vs T0 wMAPE (global) | +0,75 pp, p=0,238 | ✅ No significativo |
| T4 vs T0 wMAPE (Intermittent/Lumpy) | −2,65 pp, p=0,000 | ✅ Mejor |

Ver informe completo: [`reports/newsvendor_v4f/informe_ejecutivo_newsvendor_v4f_corregido_sprint8_bootstrap.html`](reports/newsvendor_v4f/informe_ejecutivo_newsvendor_v4f_corregido_sprint8_bootstrap.html)

---

## Docker

```bash
docker build -t oos-h4-pipeline .
docker run --rm -v ~/.config/gcloud:/root/.config/gcloud:ro oos-h4-pipeline
```

## Gates de calidad

| Gate | Criterio | Estado |
|------|----------|--------|
| B3 | Cobertura condicional P90 ∈ [8%, 12%] | 🔴 FAIL — 3/6 segmentos |
| B4 | Fill-rate política vs naive | ✅ PASS |
| B5 | Submission readiness | ✅ PASS |
| V4f | 6 criterios obligatorios inventario | ✅ PASS |

## Resultados

- Informes detallados: `reports/`
- Análisis paper-readiness: `notebooks/PAPER_READINESS_CRUZBER_H4.ipynb`
- Audit V4f: `reports/newsvendor_v4f/cruzber_newsvendor_v4f_audit.md`
