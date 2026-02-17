# INFORME DE RECONCILIACIÓN: Run A vs Run B

**Fecha:** 2026-02-14  
**Autor:** Lead DS/MLE CRUZBER OOS Forecasting  
**Propósito:** Explicar discrepancias métricas entre DICTAMEN (Run A) y MODELO TRANSFERIDO (Run B)

---

## RESUMEN EJECUTIVO

**Veredicto:** Los Runs A y B **NO son directamente comparables** debido a diferencias fundamentales en el protocolo de evaluación, específicamente en el cálculo de **Precision@100**.

**Diferencia clave:**
- **Run A (DICTAMEN):** Precision@100 calculada por separado para cada temporada (HIGH vs REST) → 24% y 30%
- **Run B (TRANSFERIDO):** Precision@100 calculada globalmente (pooled) → 94%

**Implicación:** La diferencia 24-30% → 94% **NO representa una mejora 3x en la calidad del modelo**, sino un cambio en cómo se define y calcula el Top-100.

---

## TABLA COMPARATIVA: Run A vs Run B

| **Campo**                  | **Run A (DICTAMEN AUDITADO)**        | **Run B (MODELO TRANSFERIDO)**       | **Comparable?** |
|----------------------------|--------------------------------------|--------------------------------------|-----------------|
| **Identificación**         |                                      |                                      |                 |
| Proyecto GCP               | voltaic-tuner-475510-s4              | thequantitativeledger                | ❌ Diferente    |
| Dataset                    | dataset_cruzber_eu                   | cruzber_models_eu                    | ✅ Mismo dominio (EU) |
| Modelo BQML                | m_oos_h4                             | cruzber_boosted_tree_model           | ⚠️ Nombre diferente  |
| Ejecución                  | 2026-02-12 16:19:46                  | (fecha no registrada en MD)          | N/A             |
| **Datos y Splits**         |                                      |                                      |                 |
| TRAIN                      | 2020-01-06 a 2023-06-30 (804k obs)   | 2020-01-06 a 2023-06-30 (804k obs)   | ✅ MATCH         |
| CALIB                      | 2023 H2 (115k obs)                   | 2023 H2 (115k obs)                   | ✅ MATCH         |
| VAL                        | 2024 completo (231k obs)             | 2024 completo (231k obs)             | ✅ MATCH         |
| EXCLUDE                    | ~35k obs                             | ~35k obs                             | ✅ MATCH         |
| Prevalencia VAL            | 1.52% (3,504 positivos)              | 1.52% (3,504 positivos)              | ✅ MATCH         |
| **Métricas Clave**         |                                      |                                      |                 |
| ROC-AUC VAL                | **0.8455**                           | **0.9895**                           | ❌ GRAN DIFERENCIA (+17pp, +54% rel) |
| Precision@100              | **24% (HIGH), 30% (REST)**           | **94%**                              | ❌ NO COMPARABLE (protocolo diferente) |
| Lift@100                   | 13.95x (HIGH), 14.94x (REST)         | 61.98x                               | ❌ NO COMPARABLE |
| Brier calibrado            | 0.0171                               | 0.0099                               | ✅ Mejora (-42%) |
| Precision global           | ~27% (weighted avg)                  | 29.4%                                | ✅ Similar       |
| Recall global              | (no reportado en DICTAMEN)           | 91.6%                                | N/A             |
| **Protocolo de Evaluación**|                                      |                                      |                 |
| Precision@100 calculation  | **Segmented by season_type**         | **Pooled (global ranking)**          | ❌ INCOMPATIBLE  |
| Top-100 definition         | 100 per season (HIGH), 100 per season (REST) | 100 global across all VAL dates | ❌ INCOMPATIBLE  |
| Seasonal adjustment        | ✅ YES (separate rankings)            | ❌ NO (single ranking)                | ❌              |
| **Calibración**            |                                      |                                      |                 |
| Método                     | Platt scaling (m_platt_oos_h4)       | (no especificado en MD, pero aplicada) | ⚠️ Verificar    |
| Brier mejora               | -37.9% (0.0276 → 0.0171)             | -63% (0.0271 → 0.0099)               | ✅ Ambos calibrados |
| **Auditoría**              |                                      |                                      |                 |
| Verificación externa       | ✅ Sí (AUDITORIA_DICTAMEN_H4_RESUMEN.md, 19/21 claims match) | ❌ No auditado | ❌              |
| CSVs disponibles           | ❌ No (sólo MD docs)                  | ✅ Sí (results_model_evaluate.csv, etc.) | N/A             |
| Red flags identificados    | BR1 (calibration inversion), BR2 (HHI 10.23x) | Ninguno reportado | ⚠️              |

---

## ANÁLISIS DE CAUSA RAÍZ

### 1. Precision@100: Protocolo Segmented vs Pooled

**Run A (DICTAMEN):**
```sql
-- Calcular Top-100 SEPARADAMENTE para cada season_type
SELECT season_type,
       SAFE_DIVIDE(COUNTIF(rank_within_season <= 100 AND label_true = 1), 100) AS prec_at_100
FROM (
  SELECT *, 
         ROW_NUMBER() OVER (PARTITION BY season_type ORDER BY prob DESC) AS rank_within_season
  FROM predictions_val
)
GROUP BY season_type
-- Resultado: HIGH = 24%, REST = 30%
```

**Run B (TRANSFERIDO):**
```sql
-- Calcular Top-100 GLOBALMENTE (sin segmentación)
SELECT SAFE_DIVIDE(COUNTIF(rank_global <= 100 AND label_true = 1), 100) AS prec_at_100
FROM (
  SELECT *, 
         ROW_NUMBER() OVER (ORDER BY prob DESC) AS rank_global
  FROM predictions_val
)
-- Resultado: GLOBAL = 94%
```

**Interpretación:**
- En protocolo segmented, hay 2 Top-100 (uno por temporada) = 200 predicciones totales
- En protocolo pooled, hay 1 Top-100 (global) = 100 predicciones totales
- Si hay 3,504 positivos en VAL:
  - Segmented: intentas capturar con 200 slots → tasa de captura menor
  - Pooled: intentas capturar con 100 slots, pero los slots están "mejor gastados" → tasa de captura mayor
- **Conclusión:** 94% vs 24-30% NO es una mejora de modelo, es efecto del protocolo.

### 2. ROC-AUC: 0.8455 vs 0.9895

**Posibles causas de +17pp de diferencia:**

1. **Hipótesis 1: Misma causa (segmentación)**
   - Si AUC se calcula separadamente por season en Run A, luego promedia → puede producir AUC menor
   - Si AUC se calcula pooled en Run B → AUC puede ser mayor
   - **Verificar:** ¿DICTAMEN calcula AUC por season o global?

2. **Hipótesis 2: Diferencia real en el modelo**
   - Run B podría tener features adicionales (no documentadas en MD)
   - Run B podría tener hyperparameters diferentes
   - Run B podría tener label engineering diferente
   - **Verificar:** Comparar CREATE MODEL statements de ambos

3. **Hipótesis 3: Subset diferente de VAL**
   - Run A podría excluir ciertas categorías (ej: whales, low-volume SKUs)
   - Run B podría evaluar en todo VAL sin filtros adicionales
   - **Verificar:** Comparar filtros WHERE en evaluación

**Acción requerida:**
- Ejecutar `sql/repro/10_eval_run_A.sql` y `sql/repro/11_eval_run_B.sql` en sus respectivos proyectos
- Comparar resultados con valores reportados en MD docs
- Si hay discrepancia, investigar diferencias en:
  - Feature engineering (v_features_h4_weekly schema)
  - Model hyperparameters (OPTIONS en CREATE MODEL)
  - Evaluation filters (WHERE clauses)

### 3. Calibración: Brier Score

**Ambos runs muestran mejora significativa post-calibración:**
- Run A: 0.0276 → 0.0171 (-37.9%)
- Run B: 0.0271 → 0.0099 (-63%)

**Observación:** Run B tiene mejor Brier final (0.0099 vs 0.0171), lo cual sugiere:
- Calibración más efectiva (isotonic vs Platt?)
- O modelo base con probabilidades más confiables
- **No concluyente sin conocer método exacto de calibración en Run B**

---

## EXPERIMENTOS DE RECONCILIACIÓN

Para resolver la ambigüedad, se proponen 4 experimentos:

### Experimento R1: Run A con protocolo pooled
**Objetivo:** Calcular Precision@100 de Run A usando ranking global (sin segmentación)  
**Hipótesis:** Si protocolo es la causa, Run A debería dar ~94% también (o valor cercano)  
**SQL:** Modificar `sql/repro/10_eval_run_A.sql` eliminando `PARTITION BY season_type`

### Experimento R2: Run B con protocolo segmented
**Objetivo:** Calcular Precision@100 de Run B usando segmentación por temporada  
**Hipótesis:** Si protocolo es la causa, Run B debería dar ~24-30% también  
**SQL:** Modificar `sql/repro/11_eval_run_B.sql` añadiendo `PARTITION BY season_type`

### Experimento R3: Comparar features efectivos
**Objetivo:** Verificar que ambos modelos usan mismo conjunto de features  
**SQL:**
```sql
-- Run A
SELECT column_name, data_type 
FROM `voltaic-tuner-475510-s4.dataset_cruzber_eu.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'v_features_h4_weekly'
ORDER BY ordinal_position;

-- Run B
SELECT column_name, data_type 
FROM `thequantitativeledger.cruzber_models_eu.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'v_features_h4_weekly'
ORDER BY ordinal_position;

-- Comparar outputs
```

### Experimento R4: Comparar CREATE MODEL statements
**Objetivo:** Verificar que hyperparameters son idénticos  
**SQL:**
```sql
-- Run A
SELECT ddl 
FROM `voltaic-tuner-475510-s4.dataset_cruzber_eu.INFORMATION_SCHEMA.MODELS`
WHERE model_name = 'm_oos_h4';

-- Run B
SELECT ddl 
FROM `thequantitativeledger.cruzber_models_eu.INFORMATION_SCHEMA.MODELS`
WHERE model_name = 'cruzber_boosted_tree_model';
```

---

## IMPLICACIONES PARA EL PAPER

### ❌ NO HACER:
- **NO** reportar mejora 24-30% → 94% como "avance del modelo"
- **NO** comparar AUC 0.8455 vs 0.9895 sin explicar diferencia de protocolo
- **NO** usar Run B sin auditoría externa (Run A tiene 90.5% match rate, Run B no tiene CSV verificados)

### ✅ SÍ HACER:
1. **Elegir UN run canónico** (ver `reports/decision_log.md`)
2. **Documentar protocolo de evaluación** explícitamente:
   - "Precision@100 calculada por temporada (HIGH/REST) para reflejar heterogeneidad estacional"
   - O: "Precision@100 calculada globalmente para maximizar eficiencia de ranking"
3. **Ejecutar experimentos R1-R4** para entender discrepancias
4. **Reportar métricas conservadoras:** Si hay duda, reportar valores auditados (Run A)

---

## RECOMENDACIONES

### Inmediato (HITO 0):
1. ✅ Crear experiment registry (`sql/registry/00_create_registry.sql`)
2. ✅ Registrar ambos runs con metadatos completos
3. ⏳ Ejecutar R1-R4 en ambos proyectos
4. ⏳ Documentar diferencias encontradas en `reports/experiment_R1_R4_results.md`

### Antes de submit paper:
1. Decidir run canónico (ver `decision_log.md`)
2. Re-calcular TODOS los baselines con mismo protocolo que run canónico
3. Generar figuras Precision@k curves con CI 95% (bootstrap)
4. Añadir sección "Evaluation Protocol" en Methods del paper

### Para reproducibilidad:
1. Subir `sql/repro/*.sql` a repositorio Git
2. Documentar PROJECT_ID, DATASET_ID, MODEL_NAME en README
3. Crear script `reproduce.sh` que ejecute todas las queries
4. Generar data hash (FARM_FINGERPRINT) de v_features_h4_weekly

---

## CONCLUSIONES

1. **Root cause identificada:** Diferencia en cálculo de Precision@100 (segmented vs pooled)
2. **NO comparable:** Runs A y B no pueden compararse directamente sin normalizar protocolo
3. **Acción crítica:** Ejecutar R1-R4 para validar hipótesis y decidir run canónico
4. **Para paper:** Elegir protocolo consistente y documentarlo exhaustivamente

**Próximos pasos:** Ver `reports/decision_log.md` para decisión final sobre run canónico.

---

**Archivos relacionados:**
- `DICTAMEN_VIABILIDAD_STOCKOUT_H4_REVISADO.md` (Run A metadata)
- `RESULTADOS_MODELO_TRANSFERIDO.md` (Run B metadata)
- `AUDITORIA_DICTAMEN_H4_RESUMEN.md` (Run A verification)
- `sql/repro/10_eval_run_A.sql` (reproducción Run A)
- `sql/repro/11_eval_run_B.sql` (reproducción Run B)
- `reports/decision_log.md` (decisión run canónico)
