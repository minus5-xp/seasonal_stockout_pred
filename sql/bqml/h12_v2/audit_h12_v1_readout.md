# Auditoría h12_v1 → base de h12_v2

**Fecha**: 2026-05-09 | **Auditor**: GitHub Copilot

---

## Archivos inspeccionados

| Archivo | Estado |
|---|---|
| `sql/bqml/h12_v1/00_config_h12_v1.sql` | OK — doc only |
| `sql/bqml/h12_v1/01_build_weekly_features_h12_v1.sql` | OK — denso, autocontenido desde BASE_SALES_TABLE |
| `sql/bqml/h12_v1/02_train_models_h12_v1.sql` | OK — classifier + Platt + regressor |
| `sql/bqml/h12_v1/02b_score_models_h12_v1.sql` | OK — scale formula corregida |
| `sql/bqml/h12_v1/03_residuals_quantile_lookup_h12_v1.sql` | OK — Mondrian conformal |
| `sql/bqml/h12_v1/04_conformal_calibration_h12_v1.sql` | OK — tuned v1.1 (CLIP_HI=3.0, MIN_N_TUNE=50) |
| `sql/bqml/h12_v1/05_forecast_h12_v1.sql` | OK — monotone, capped |
| `sql/bqml/h12_v1/06_policy_sweep_alerts_h12_v1.sql` | OK — 5 políticas, best por lift |
| `sql/bqml/h12_v1/07_coverage_gate_h12_v1.sql` | OK — B3 gate |
| `sql/bqml/h12_v1/08_alerts_eval_leakage_h12_v1.sql` | OK — leakage + comparison scope |
| `sql/bqml/h12_v1/09_run_summary_h12_v1.sql` | OK |
| `sql/bqml/h12_v1/run_h12_v1_pipeline.py` | OK — cross-region bridge para step 01 |
| `reports/AUDIT_H12_V1_FOR_CHATGPT.md` | Informe de auditoría anterior |

---

## Modelos BQ detectados (cruzber_models_eu)

| Modelo | Tipo | Label | Estado |
|---|---|---|---|
| `m_oos_h12_v1` | BOOSTED_TREE_CLASSIFIER | `stockout_event_12w` | Entrenado ✅ |
| `m_platt_oos_h12_v1` | LOGISTIC_REG | `true_label` (Platt) | Entrenado ✅ |
| `m_demand_h12_v1` | BOOSTED_TREE_REGRESSOR | `y_true_12w` | Entrenado ✅ |

**v2 NO re-entrena estos modelos.**

---

## Tablas BQ detectadas (cruzber_models_eu, sufijo _h12_v1)

- `sales_weekly_base_h12_v1`, `weekly_features_h12_v1`, `train_calib_split_h12_v1`
- `enriched_base_h12_v1`, `score_oos_h12_all_v1`, `score_oos_h12_calibrated_v1`
- `base_scores_h12_v1` ← **input principal de v2**
- `residuals_h12_v1`, `quantile_lookup_h12_v1`, `volatility_bucket_thresholds_h12_v1`
- `viol_rate_valtune_h12_v1`, `quantile_factors_h12_v1` ← usados en diagnósticos
- `forecast_h12_v1`, `alerts_top100_h12_v1`
- `eval_coverage_h12_v1_conditional`, `eval_coverage_summary_h12_v1_conditional`
- `eval_alerts_top100_h12_pooled_v1`, `eval_demand_h12_v1`, `leakage_check_h12_v1`
- `comparison_scope_h12_vs_R_v11`, `run_summary_h12_v1`

---

## Gates del último run (v1.1, 2026-05-09)

| Gate | Valor | Objetivo | Estado |
|---|---|---|---|
| B3 `viol_rate_p90` | **0.1268** | [0.08, 0.12] | ❌ FAIL |
| B4 `lift@100` | **3.84** | > 1.5 | ✅ PASS |
| `WMAPE 12W` | **0.61** | referencia | ⚠️ aceptable |
| `leakage` | **PASS** | PASS | ✅ |
| `scope vs R` | **OK** | OK | ✅ |
| `deployment_decision` | **HOLD** | DEPLOY | ❌ |

Historial de tuning v1:

| Iteración | CLIP_HI | MIN_N_TUNE | viol_p90 |
|---|---|---|---|
| v1.0 | 2.00 | 200 | 0.1507 |
| v1.1 | 3.00 | 50 | 0.1268 |
| **Objetivo v2** | grid | grid | **≤ 0.12** |

---

## Hipótesis de mejora priorizadas

### P1 — Scale subestimada (más probable)
`scale = roll13_std * SQRT(12)` asume independencia semanal. Con autocorrelación positiva en retail, la varianza real del acumulado 12W > `Var_semanal × 12`. Los scores normalizados son sistemáticamente mayores → q90 empírico bajo.

**Fix v2**: `scale_h12_v2 = scale_h12_v1 * segment_vif * scale_multiplier`, donde `segment_vif` mide el ratio de varianza real/teórica en CALIB.

### P2 — Offset del cuantil (simple, efectivo)
CALIB usa `APPROX_QUANTILES(score, 100)[OFFSET(90)]`. Si hay right-skew residual en VAL, usar OFFSET(92) o (93) del score CALIB como q90 efectivo da más headroom.

**Fix v2**: grid sobre `q90_offset ∈ {90, 91, 92, 93}`.

### P3 — Shift distribucional CALIB→VAL
CALIB = H2 2023 (6 meses). VAL = 2024 completo. Si 2024 tiene demanda más volátil o picos más altos, los cuantiles aprendidos en CALIB infraestiman la cola VAL.

**Fix v2**: `segment_vif` compensa parcialmente. VAL_GATE evalúa la robustez.

### P4 — Partición VAL_TUNE demasiado larga
En v1, VAL_TUNE = primeros 2/3 de 2024. El correction_factor se ajusta a esas semanas pero el test real incluye también H2. En v2, VAL_TUNE = W1-W20, VAL_GATE = W21-W27, separación más limpia.

---

## Confirmación de no-modificación

> ✅ h12_v1 no será sobrescrito. Todos los cambios en v2 crean tablas y modelos nuevos con sufijo `_h12_v2`. Las tablas de v1 son solo fuente de lectura.

---

## Datos geográficos confirmados

- Tabla: `{PROJECT_ID}.{BQ_DATASET}.dim_provincia`
- Filtro: `codigonacion = 108` → 52 provincias de España
- Campo provincia: `provincia`
- Join desde `fact_lineas_albaran`: campo `codigo_provincia` (ajustar si es distinto)
