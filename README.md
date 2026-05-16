# Seasonal Stockout Prediction — h = 12 weeks (Cruzber)

Proyecto académico (ISDI MDA — Troncal) de predicción de stockouts estacionales para Cruzber, distribuidor español de accesorios de vehículo (familia CRUZ). Horizonte de predicción: **h = 12 semanas**. Datos de entrenamiento: 2020–2022. Evaluación final: LOCKED TEST 2024 (semanas S1–S27).

**GCP**: BigQuery · proyecto `thequantitativeledger` · dataset `cruzber_models_eu` (EU) · tabla fuente `fact_lineas_albaran`

---

## Resultado final

| Métrica | Valor (LOCKED TEST) |
|---------|-------------------|
| Alertas generadas | **27 264** |
| Precisión | **0.6496** |
| Recall | **0.3516** |
| F1 | **0.456** |
| True OOS events (base) | ~50 367 |
| Base rate | 23.4% |
| Lift sobre base rate | ~2.8× |
| Leakage audit | **20/20 PASS** |
| Versión desplegada | **h12_v5_1** (state-specific OOS policy) |

### ROC-AUC del clasificador base

El clasificador BQML `m_oos_h12_v3_2` (`BOOSTED_TREE_CLASSIFIER`) es el núcleo probabilístico de toda la cadena. Su ROC-AUC puede obtenerse directamente desde BigQuery:

```sql
SELECT *
FROM ML.EVALUATE(
  MODEL `thequantitativeledger.cruzber_models_eu.m_oos_h12_v3_2`,
  (
    SELECT *
    FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_2_strict`
    WHERE eval_split_v3 = 'LOCKED_TEST'
  )
)
```

Las métricas de alerta (P/R/F1 arriba) evalúan la **política desplegada** (umbral + quotas estacionales), que aplica una transformación adicional sobre las probabilidades del modelo. Ambas métricas son complementarias.

---

## Arquitectura del pipeline h=12

La cadena completa tiene 6 versiones iterativas, cada una con 10–11 fases de SQL/Python ejecutadas en BigQuery:

```
fact_lineas_albaran
     │
     ▼
  h12_v1          — Clasificador BQML base h=12, policy sweep h=4
     │
     ▼
  h12_v2          — Diagnósticos, cuantiles Mondrian recalibrados
  h12_v2_final    — Gates de producción, forecast ciego S28–S40
     │
     ▼
  h12_v3_strict   — Protocolo temporal estricto (DEV_TUNE / DEV_SELECT / LOCKED_TEST)
  h12_v3_2        — Segmentación por estado de temporada (HIGH_SEASON / REST)
     │
     ▼
  h12_v4_qr       — Quantile Regression (scikit-learn) sobre residuos del clasificador
  h12_v4_1        — Conformal quantiles eficientes
  h12_v4_2        — Quantile overlay sobre v3_2
     │
     ▼
  h12_v5          — OOS state layer (estado OOS como feature de segunda capa)
  h12_v5_1        — State-specific OOS policy (cuotas por estado de temporada)
     │
     ▼
  h12_v5_2        — Recall-safe policy (VERDICT: KEEP_V5_1 — 0 alertas incrementales)
```

### Decisión de modelo

- **v5_2** evaluó 81 candidatos de política recall-safe en DEV_SELECT. Ninguno superó el precision floor sin aumentar FPR respecto a v5_1. Centinela almacenado: `frozen_recall_safe_policy_id = 'NONE_VALID'`.
- **Versión desplegada: h12_v5_1** con `gate_set_id = HIGH_SEASON_STRICT`, `score_column_name = difficult_state_score`, cuota 60% alta temporada / 45% resto.

---

## Protocolo de evaluación anti-leakage

```
2020–2022  →  TRAIN
S01–S09 2023  →  DEV_TUNE    (calibración de cuantiles y políticas)
S10–S27 2023  →  DEV_SELECT  (selección de hiperparámetros, grid search)
S01–S27 2024  →  LOCKED_TEST (evaluación final — usado una sola vez)
```

- Sin acceso a LOCKED_TEST durante el diseño ni la selección del modelo.
- El audit de 20 controles anti-leakage verifica: ausencia de features futuras, integridad del split temporal, cobertura de evaluación, y estabilidad de probabilidades entre splits.

---

## Estructura del repositorio

```
oos_seasonal_fillrate/
├── sql/bqml/
│   ├── h12_v1/                                      # v1: clasificador base h=12
│   ├── h12_v2/                                      # v2: diagnósticos + cuantiles
│   ├── h12_v2_final/                                # v2 final: gates de producción
│   ├── h12_v3_strict/                               # v3: protocolo temporal estricto
│   ├── h12_v3_2_season_state_strict/                # v3.2: segmentación por temporada
│   ├── h12_v4_quantile_regression_strict/           # v4: quantile regression
│   ├── h12_v4_1_efficient_conformal_quantiles_strict/ # v4.1: conformal eficientes
│   ├── h12_v4_2_quantile_overlay_on_v3_2_strict/   # v4.2: overlay sobre v3.2
│   ├── h12_v5_oos_state_layer_strict/               # v5: OOS state layer
│   ├── h12_v5_1_state_specific_oos_policy_strict/  # v5.1: política state-specific ★
│   └── h12_v5_2_recall_safe_oos_policy_strict/     # v5.2: recall-safe (→KEEP_V5_1)
├── scripts/
│   ├── setup_gcp_local.ps1      # Auth ADC + verificación dataset BQ
│   ├── run_full_pipeline_v1_to_v5_2.ps1  # Orquestador completo (todas las versiones)
│   ├── bq_upload_source_table.ps1        # Carga tabla fuente a BQ
│   ├── check_bq_tables.ps1               # Verificación de tablas en BQ
│   └── r/                               # Scripts R: bootstrap wMAPE, newsvendor
├── requirements.txt
└── Dockerfile
```

Cada directorio de pipeline contiene:
- `00_*.sql` – configuración y protocolo temporal
- `01_*.sql` … `09_*.sql` – fases numeradas
- `99_leakage_audit_*.sql` – audit de integridad
- `run_*_pipeline.py` – orquestador Python CLI
- `README_*.md` – documentación de la versión

---

## Quickstart

### 1. Requisitos previos

- Python ≥ 3.10 con `google-cloud-bigquery`, `pandas`, `tqdm`
- [gcloud SDK](https://cloud.google.com/sdk/docs/install) instalado
- Acceso al proyecto GCP `thequantitativeledger` con roles `BigQuery Data Editor` + `BigQuery Job User`
- Tabla fuente `fact_lineas_albaran` en dataset `cruzber_models_eu`

```bash
pip install -r requirements.txt
```

### 2. Autenticación GCP (PowerShell)

```powershell
# Configura ADC + quota project + dataset verification
.\scripts\setup_gcp_local.ps1 -ProjectId thequantitativeledger -DatasetId cruzber_models_eu

# Para saltar la re-autenticación si ya tienes credenciales válidas:
.\scripts\setup_gcp_local.ps1 -ProjectId thequantitativeledger -DatasetId cruzber_models_eu -SkipAuth
```

### 3. Ejecutar el pipeline completo (v1 → v5_2)

```powershell
.\scripts\run_full_pipeline_v1_to_v5_2.ps1
```

### 4. Ejecutar una versión específica

```bash
# h12_v5_1 (versión desplegada)
python sql/bqml/h12_v5_1_state_specific_oos_policy_strict/run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py

# h12_v5_2 (iteración recall-safe — resultado: KEEP_V5_1)
python sql/bqml/h12_v5_2_recall_safe_oos_policy_strict/run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py

# Fases específicas (ej. fase 6 + audit)
python sql/bqml/h12_v5_2_recall_safe_oos_policy_strict/run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phases 6 99
```

### 5. Verificar tablas en BigQuery

```powershell
.\scripts\check_bq_tables.ps1 -ProjectId thequantitativeledger -DatasetId cruzber_models_eu
```

---

## Evolución de métricas por versión

| Versión | Precisión | Recall | Alertas | Novedad |
|---------|-----------|--------|---------|---------|
| h12_v1 | — | — | — | Clasificador BQML base h=12 |
| h12_v3_strict | ~0.52 | ~0.28 | — | Protocolo temporal estricto |
| h12_v3_2 | ~0.58 | ~0.31 | — | Segmentación HIGH_SEASON/REST |
| h12_v4_2 | ~0.60 | ~0.32 | — | Quantile overlay sobre v3.2 |
| h12_v5_1 | **0.6496** | **0.3516** | **27 264** | State-specific OOS policy ★ |
| h12_v5_2 | = v5_1 | = v5_1 | +0 | KEEP_V5_1 (recall-safe no mejora) |

---

## Configuración BigQuery

| Parámetro | Valor |
|-----------|-------|
| Proyecto | `thequantitativeledger` |
| Dataset | `cruzber_models_eu` |
| Location | `EU` |
| Tabla fuente | `fact_lineas_albaran` |
| Modelo BQML | `m_oos_h12_v3_2` (BOOSTED_TREE_CLASSIFIER) |

---

## Stack tecnológico

- **BigQuery ML** — entrenamiento, scoring, evaluación del clasificador base
- **BigQuery SQL** — feature engineering, split temporal, política de alertas, audit
- **Python 3.10+** — orquestadores CLI, evaluación conformal (scikit-learn), descarga de resultados
- **R** — bootstrap wMAPE pareado, simulación newsvendor
- **GCP gcloud SDK** — autenticación ADC, gestión de proyecto

---

*ISDI MDA — Módulo Troncal — Trabajo de Fin de Máster (2025–2026)*
