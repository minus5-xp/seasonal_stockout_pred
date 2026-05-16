# Informe h12_v5_1 — State-Specific OOS Policy (Additive Layer)

**Fecha:** 2026-05-13  
**Pipeline:** `h12_v5_1_state_specific_oos_policy_strict`  
**Proyecto BigQuery:** `thequantitativeledger.cruzber_models_eu`  
**Tipo:** Iteración ADITIVA sobre v5 (POLICY\_E1 congelada)  

---

## 1. Contexto y Motivación

El modelo h12_v5 (POLICY\_E1) tiene cobertura nula en los estados difíciles de demanda.
Esta capa aditiva detecta incidentes OOS en SKUs con señal de zero-run pero que **no** activan POLICY\_E1:

- `zero_run_component >= 0.15` (señal OOS presente)
- `p_true_zero_demand < 0.75` (no es cero estructural)
- `oos_flag_v5 = 0` (no cubierto por POLICY\_E1)

La partición de percentiles se realiza por `eval_split_v3 × season_group`
(`HIGH_SEASON` / `REST`), disponible en todos los splits (DEV\_TUNE, DEV\_SELECT, LOCKED\_TEST).

---

## 2. Diseño del Grid de Candidatos

Grid 3 × 3 × 3 = **27 candidatos** evaluados en DEV\_SELECT (sin contaminar LOCKED\_TEST).

| Dimensión | Opciones |
|---|---|
| Gate set | GATE\_A (conservador), GATE\_B (moderado), GATE\_C (exploratorio) |
| Percentil | P1 (0.940), P2 (0.900/0.920), P3 (0.850/0.870) |
| Quota semanal | Q1 (5/8), Q2 (10/15), Q3 (20/30) alerts HIGH/REST |

---

## 3. Política Frozen Seleccionada

| Parámetro | Valor |
|---|---|
| ID | `GATE_C_P3_Q3` |
| Gate | `GATE_C` |
| Percentil config | `P3` |
| Quota config | `Q3` |
| Split de selección | DEV\_SELECT (sin LOCKED\_TEST) |
| Alertas incrementales (DEV\_SELECT) | 690 |
| Precisión incremental (DEV\_SELECT) | 0.9522 |
| Recall incremental (DEV\_SELECT) | 0.024360 (2.4360%) |
| Lift incremental (DEV\_SELECT) | 3.794× |
| Selection loss | -6.1544 |

---

## 4. Métricas LOCKED\_TEST — Global

| Métrica | POLICY\_E1 (estable) | Capa Difícil (v5\_1) | Combinado |
|---|---|---|---|
| Observaciones | 214,916 | — | 214,916 |
| Stockouts reales | 50,367 (23.44%) | — | — |
| Alertas | 26,972 | **+292** | 27,264 |
| Precisión | 0.6489 | 0.7192 | 0.6496 |
| Recall | 0.3475 (34.75%) | +0.0042 pp | 0.3516 (35.16%) |
| ELS recuperado | 276,484.8 | +981.4 | 277,466.2 |

**Uplift neto:** +292 alertas (+1.1% vs baseline), precisión difícil = **0.7192** (supera base_rate 0.2344).

---

## 5. Métricas por Season Group (LOCKED\_TEST)

| Season Group | Obs | Stockouts | Stable Alerts | Diff Alerts | Diff Prec | Diff Rec |
|---|---|---|---|---|---|---|
| HIGH_SEASON | 66,128 | 19,353 | 9,329 | 85 | 0.9294 | 0.0041 |
| REST | 148,788 | 31,014 | 17,643 | 207 | 0.6329 | 0.0042 |

---

## 6. Top 5 Candidatos Evaluados (DEV\_SELECT)

| ID | Gate | Pct | Quota | Alertas | TPs | Precisión | Recall% | Lift | Loss |
|---|---|---|---|---|---|---|---|---|---|
| GATE_C_P3_Q3 | GATE_C | P3 | Q3 | 690 | 657 | 0.9522 | 2.4360% | 3.794 | -6.1544 |
| GATE_A_P3_Q3 | GATE_A | P3 | Q3 | 690 | 657 | 0.9522 | 2.4360% | 3.794 | -6.1544 |
| GATE_B_P3_Q3 | GATE_B | P3 | Q3 | 690 | 657 | 0.9522 | 2.4360% | 3.794 | -6.1544 |
| GATE_B_P2_Q3 | GATE_B | P2 | Q3 | 659 | 628 | 0.9530 | 2.3285% | 3.797 | -5.0080 |
| GATE_C_P2_Q3 | GATE_C | P2 | Q3 | 659 | 628 | 0.9530 | 2.3285% | 3.797 | -5.0080 |

---

## 7. Anti-Leakage Audit

| Resultado | Count |
|---|---|
| PASS | 14 |
| WARNING | 2 |
| FAIL | 0 |


Checks con WARNING:
- **#12** Temporal ordering (decision_week range): decision_week must be in expected range (W01-W40 for 2024)
- **#14** Candidate grid count: Expected 81 candidates (3 gates × 3 percentiles × 3 quotas)

---

## 8. Tablas BigQuery Generadas

| Fase | Tabla |
|---|---|
| 0 | `base_scores_h12_v5_1_strict` |
| 1 | `difficult_state_scored_h12_v5_1_strict` |
| 2 | `difficult_state_policy_candidates_h12_v5_1_strict` |
| 3 | `difficult_state_candidate_eval_dev_select_h12_v5_1_strict` |
| 4 | `frozen_difficult_state_policy_h12_v5_1_strict` |
| 5 | `combined_oos_alerts_h12_v5_1_strict` |
| 6 | `final_locked_test_metrics_h12_v5_1_strict` |
| 7 | `incremental_uplift_analysis_h12_v5_1_strict` |
| 8 | `top_alerts_combined_h12_v5_1_strict` |
| 99 | `leakage_audit_h12_v5_1_strict` |

---

## 9. CSVs Exportados

| Archivo | Contenido |
|---|---|
| `h12_v5_1_metrics_locked_test_2026-05-13.csv` | Métricas LOCKED\_TEST (global + season\_group + sku\_season\_state) |
| `h12_v5_1_frozen_policy_2026-05-13.csv` | Política frozen seleccionada |
| `h12_v5_1_candidate_eval_2026-05-13.csv` | Evaluación 27 candidatos en DEV\_SELECT |
| `h12_v5_1_leakage_audit_2026-05-13.csv` | Resultados audit anti-leakage |

---

## 10. Notas Técnicas

### Cambios respecto al diseño original (iteración C)

El diseño original usaba `sku_season_state` para definir candidatos difíciles,
pero esta columna solo está disponible en LOCKED\_TEST (no en DEV\_TUNE / DEV\_SELECT).
Se adoptó la **Opción C**: definición basada en features disponibles en todos los splits:

```sql
is_difficult_state_candidate = (
  zero_run_component >= 0.15  -- señal OOS presente
  AND p_true_zero_demand < 0.75  -- no cero estructural
  AND oos_flag_v5 = 0  -- no cubierto por POLICY_E1
)
```

### Partición de percentiles

```sql
PERCENT_RANK() OVER (PARTITION BY eval_split_v3, season_group ORDER BY ...)
```

### Umbral de percentil relativo al máximo alcanzable

El composite score máximo alcanzable es ~0.96 (no 1.0) al combinar 5 ranks.
Los umbrales P1/P2/P3 se calibraron en [0.85–0.94] para ser alcanzables.
El volumen de alertas está controlado por la quota semanal (Q1/Q2/Q3).

### Fórmula de selection\_loss

```
loss = (2.0 - lift)
     - 1.5 * (ELS / 1000)
     - 1.0 * recall
     + 1.0 * FPR * 100
     + volume_penalty  (> 10% obs total)
     + precision_penalty  (< base_rate)
     + instability_penalty  (std_weekly > 3)
```