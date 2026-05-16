# h=12 v3_strict — Metodología estricta anti-leakage

## Problema que corrige

En `h12_v2` y `h12_v2_final`, varias decisiones de diseño se tomaban y
se evaluaban sobre el **mismo split** (`VAL_GATE`, semanas 21–27 de 2024).
Esto introduce **sesgo post-selección**: las métricas reportadas parecen
mejores de lo que realmente son porque el split que elige la política /
probabilidad / calibración es el mismo que se usa para reportar.

### Problemas específicos de v2

| Archivo v2 | Decisión tomada | Split usado | Split reportado | Sesgo |
|---|---|---|---|---|
| `03_policy_and_gates_h12_v2.sql` | Política A/B/C/D/E | `VAL_GATE` (W21-W27) | `VAL_GATE` | **Sí** |
| `01_fix_probability_brier_h12_v2_final.sql` | RAW vs CALIBRATED | `VAL_GATE` | `VAL_GATE` | **Sí** |
| `02_recalibrate_quantiles_h12_v2.sql` | Grid calibración | `VAL_TUNE` (W01-W20) | `VAL_GATE` | Parcial (correcto para tuning, pero sin tabla frozen auditable) |

La regla de oro: **la split en que se toma una decisión no puede coincidir con
la split en que se reporta la métrica final.**

---

## Por qué existe el embargo con h=12

El horizonte h=12 implica que cada `decision_week` tiene un **target que cubre
las 12 semanas siguientes**. Por ejemplo:

- Decisión en W16 (última semana de `DEV_SELECT`) → targets: W17 a W28
- Decisión en W28 (primera semana de `LOCKED_TEST`) → targets: W29 a W40

No hay solapamiento de targets, pero existe riesgo de contaminación indirecta:
si se calculan estadísticos de normalización, VIF, o medias de `y_true_12w`
sobre el panel completo antes de partir, los resultados de `DEV_SELECT`
(targets W17–W28) podrían contaminar las features de `LOCKED_TEST` de forma
implícita. El **embargo W17–W27** elimina ese riesgo creando un buffer de
11 semanas.

```
W01─W08   DEV_TUNE     calibración
W09─W16   DEV_SELECT   selección
W17─W27   EMBARGO      buffer h=12, nunca usado
W28─W40   LOCKED_TEST  test final (etiquetas ciegas → PENDING)
```

---

## Splits y su uso estrictamente asignado

| Split | Semanas | `can_tune` | `can_select` | `can_report_final` | `labels_allowed` |
|---|---|---|---|---|---|
| `DEV_TUNE` | W01–W08 2024 | ✓ | ✗ | ✗ | ✓ |
| `DEV_SELECT` | W09–W16 2024 | ✗ | ✓ | ✗ | ✓ |
| `EMBARGO` | W17–W27 2024 | ✗ | ✗ | ✗ | N/A |
| `LOCKED_TEST` | W28–W40 2024 | ✗ | ✗ | ✓ | ✗ (blind) |
| `OTHER` | resto | ✗ | ✗ | ✗ | N/A |

---

## Decisiones congeladas

### `frozen_quantile_config_h12_v3_strict`
- **Seleccionada en**: `DEV_TUNE` (W01–W08)
- **Criterio**: mínima `calibration_loss` (igual que v2)
- **Contenido**: `scale_multiplier`, `q90_offset`, `q95_offset`, `factor_clip_hi`
- **Auditado por**: check A1, A12 del leakage audit
- **Prohibido**: recalibrar en `DEV_SELECT`, `EMBARGO`, o `LOCKED_TEST`

### `frozen_probability_mode_h12_v3_strict`
- **Seleccionada en**: `DEV_SELECT` (W09–W16)
- **Criterio**: Brier RAW vs CALIBRATED (tolerancia 1%)
- **Contenido**: `selected_for_reporting`, `selected_for_ranking`
- **Auditado por**: check A2, A11
- **Prohibido**: re-seleccionar en `LOCKED_TEST` aunque ahí el otro gane

### `frozen_policy_h12_v3_strict`
- **Seleccionada en**: `DEV_SELECT` (W09–W16)
- **Criterio**: mayor `avg_lift_at_100` de policy_A/B/C/D/E
- **Contenido**: `policy` (ej. `policy_B`)
- **Auditado por**: check A3, A10
- **Prohibido**: re-seleccionar en `LOCKED_TEST`

---

## Estado actual de `LOCKED_TEST`

**Las etiquetas W28–W40 son ciegas** (`y_true_12w = NULL`).

Por tanto:
- `final_locked_test_metrics_h12_v3_strict.test_status = 'LOCKED_TEST_PENDING'`
- `leakage_audit_final_verdict_h12_v3_strict.final_verdict = 'NO_LOCKED_TEST_LABELS'`
- Todas las métricas numéricas (`wmape`, `lift_at_100`, etc.) son `NULL`.
- Esto **no es un error**: la estructura del pipeline es metodológicamente correcta.
- Cuando las etiquetas estén disponibles, basta con re-ejecutar las fases 6–9.

---

## Métricas aptas para presentar al tutor

### ✅ Presentables como métricas de selección/desarrollo (no test ciego)

| Tabla | Split | Métrica | Descripción |
|---|---|---|---|
| `calibration_grid_eval_dev_tune_h12_v3_strict` | DEV_TUNE | `calibration_loss`, `viol_p90` | Evaluación del grid; split correcto |
| `probability_selection_dev_select_h12_v3_strict` | DEV_SELECT | `brier_raw`, `brier_calibrated` | Selección de modo; split correcto |
| `policy_sweep_dev_select_h12_v3_strict` | DEV_SELECT | `lift_at_100`, `precision_at_100` | Selección de política; split correcto |

### ✅ Presentables como test ciego (cuando labels lleguen)

| Tabla | Condición | Métricas |
|---|---|---|
| `final_locked_test_metrics_h12_v3_strict` | `test_status = 'LOCKED_TEST_EVALUATED'` y `post_selection_bias = FALSE` | WMAPE, bias, viol_p80/90/95, Brier, lift@100, precision@100, recall@100 |

### ❌ NO presentables como test ciego

| Tabla | Razón |
|---|---|
| `gate_verdict_h12_v2` | Selección y reporting en VAL_GATE |
| `policy_sweep_h12_v2` | Sweep en VAL_GATE |
| `probability_selection_h12_v2_final` | Selección en VAL_GATE |
| Cualquier métrica calculada en `VAL_GATE` de v2 | Post-selection bias |

---

## Outputs aptos para despliegue

| Tabla | Descripción | Labels incluidas |
|---|---|---|
| `blind_deploy_export_h12_v3_strict` | Forecast W28-W40 con decisiones congeladas | No (`labels_included=FALSE`) |
| `alerts_locked_test_h12_v3_strict` | Alert ranking con frozen policy | No |

---

## Cómo ejecutar

```bash
# Requisitos
pip install google-cloud-bigquery

# Verificación en seco (no escribe en BQ)
python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --dry-run

# Pipeline completo
python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py

# Solo contrato temporal
python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --stop-after-phase 1

# Calibración + aplicación (sin selección de política/prob)
python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --start-phase 2 --stop-after-phase 3

# Solo auditoría (todas las tablas deben existir)
python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --start-phase 9
```

## Queries clave para revisar métricas

```sql
-- ¿Cuál es el estado del test final?
SELECT test_status, is_locked_test, post_selection_bias,
       n_total_locked_test, n_labelled_rows,
       frozen_policy, frozen_prob_mode_reporting,
       wmape, viol_rate_p90, lift_at_100
FROM `{PROJECT}.{DATASET}.final_locked_test_metrics_h12_v3_strict`;

-- ¿Pasó la auditoría anti-leakage?
SELECT final_verdict, n_failures, n_passes, verdict_message
FROM `{PROJECT}.{DATASET}.leakage_audit_final_verdict_h12_v3_strict`;

-- Detalle de todos los checks
SELECT check_id, check_name, verdict, detail
FROM (
  SELECT check_id, check_name, verdict, COALESCE(detail, '') AS detail
  FROM `{PROJECT}.{DATASET}.leakage_audit_split_usage_h12_v3_strict`
  UNION ALL
  SELECT check_id, check_name, verdict,
         CONCAT('overlapping_rows=', CAST(n_overlapping_rows AS STRING))
  FROM `{PROJECT}.{DATASET}.leakage_audit_target_overlap_h12_v3_strict`
  UNION ALL
  SELECT check_id, check_name, verdict, detail
  FROM `{PROJECT}.{DATASET}.leakage_audit_decision_sources_h12_v3_strict`
)
ORDER BY check_id;

-- Calibración congelada
SELECT config_id, scale_multiplier, q90_offset, q95_offset, factor_clip_hi,
       viol_p90_dev_tune, calibration_loss, selected_using_split, used_locked_test
FROM `{PROJECT}.{DATASET}.frozen_quantile_config_h12_v3_strict`;

-- Probabilidad congelada
SELECT selected_for_reporting, selected_for_ranking,
       brier_raw, brier_calibrated, brier_selected,
       selected_using_split, used_locked_test
FROM `{PROJECT}.{DATASET}.frozen_probability_mode_h12_v3_strict`;

-- Política congelada
SELECT policy, avg_lift_at_100, avg_precision_at_100,
       selected_using_split, used_locked_test
FROM `{PROJECT}.{DATASET}.frozen_policy_h12_v3_strict`;

-- Verificar violaciones de cuantil por split (DEV_TUNE vs DEV_SELECT)
SELECT eval_split_v3, split_original,
       COUNT(*) AS n_rows,
       ROUND(AVG(CASE WHEN y_true_12w > q90_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p90,
       ROUND(AVG(CASE WHEN y_true_12w > q80_12w THEN 1.0 ELSE 0.0 END), 4) AS viol_p80
FROM `{PROJECT}.{DATASET}.forecast_recalibrated_h12_v3_strict`
WHERE y_true_12w IS NOT NULL
GROUP BY eval_split_v3, split_original
ORDER BY eval_split_v3;
```

---

## Invariantes del pipeline (no se deben romper)

1. `frozen_quantile_config_h12_v3_strict.selected_using_split = 'DEV_TUNE'`
2. `frozen_probability_mode_h12_v3_strict.selected_using_split = 'DEV_SELECT'`
3. `frozen_policy_h12_v3_strict.selected_using_split = 'DEV_SELECT'`
4. `frozen_*.used_locked_test = FALSE` para las tres tablas
5. `final_locked_test_metrics_h12_v3_strict.post_selection_bias = FALSE`
6. `leakage_audit_final_verdict_h12_v3_strict.final_verdict != 'FAIL'`
7. Ninguna tabla `_h12_v3_strict` sobreescribe tablas `_h12_v1`, `_h12_v2`, ni `_h12_v2_final`

---

## Advertencias

> **LOCKED_TEST labels = NULL (estado actual)**
> Las semanas W28–W40 de 2024 son ciegas en la fuente de datos. El pipeline
> está metodológicamente limpio, pero `final_locked_test_metrics` no puede
> mostrar métricas numéricas hasta que lleguen los labels reales.
>
> El auditor verá `final_verdict = NO_LOCKED_TEST_LABELS`, lo cual es el
> resultado correcto y esperado, no un fallo.

> **No mezclar con métricas de v2**
> Las métricas de `gate_verdict_h12_v2` y `probability_selection_h12_v2_final`
> NO son comparables con las de v3_strict. Las primeras tienen post-selection
> bias confirmado; las segundas no. Cualquier comparación debe aclarar esto.
