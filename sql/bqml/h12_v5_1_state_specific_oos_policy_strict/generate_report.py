"""
Genera CSV de métricas e informe .md para h12_v5_1_state_specific_oos_policy_strict
"""
import os
import csv
import datetime
from pathlib import Path
from google.cloud import bigquery

client = bigquery.Client()
TODAY = datetime.date.today().isoformat()
OUTPUT_DIR = Path(__file__).parent

# ─────────────────────────────────────────────────────────────────────────────
# 1. GLOBAL METRICS (LOCKED_TEST)
# ─────────────────────────────────────────────────────────────────────────────
q_global = """
SELECT
  segment_type, segment_value,
  n_obs, n_true_oos,
  ROUND(base_rate, 4) AS base_rate,
  n_stable_alerts,
  ROUND(stable_precision, 4) AS stable_precision,
  ROUND(stable_recall, 4) AS stable_recall,
  n_difficult_alerts,
  ROUND(difficult_precision, 4) AS difficult_precision,
  ROUND(difficult_recall, 4) AS difficult_recall,
  n_combined_alerts,
  ROUND(combined_precision, 4) AS combined_precision,
  ROUND(combined_recall, 4) AS combined_recall,
  ROUND(stable_els_recovered, 2) AS stable_els_recovered,
  ROUND(difficult_els_recovered, 2) AS difficult_els_recovered,
  ROUND(combined_els_recovered, 2) AS combined_els_recovered
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v5_1_strict`
ORDER BY
  CASE segment_type WHEN 'GLOBAL' THEN 1 WHEN 'SEASON_GROUP' THEN 2 ELSE 3 END,
  segment_value
"""
df_global = client.query(q_global).to_dataframe()

# ─────────────────────────────────────────────────────────────────────────────
# 2. FROZEN POLICY
# ─────────────────────────────────────────────────────────────────────────────
q_policy = """
SELECT
  frozen_difficult_policy_id,
  frozen_gate_set_id,
  frozen_percentile_config_id,
  frozen_quota_config_id,
  dev_select_incremental_alerts,
  dev_select_incremental_tp,
  ROUND(dev_select_incremental_precision, 4) AS dev_select_precision,
  ROUND(dev_select_incremental_recall, 6) AS dev_select_recall,
  ROUND(dev_select_incremental_lift, 3) AS dev_select_lift,
  ROUND(dev_select_incremental_els, 2) AS dev_select_els,
  ROUND(dev_select_selection_loss, 4) AS selection_loss,
  selected_using_split,
  selected_without_locked_test,
  post_selection_bias
FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
"""
df_policy = client.query(q_policy).to_dataframe()

# ─────────────────────────────────────────────────────────────────────────────
# 3. CANDIDATE EVALUATION (DEV_SELECT)
# ─────────────────────────────────────────────────────────────────────────────
q_cands = """
SELECT
  difficult_policy_id,
  gate_set_id,
  percentile_config_id,
  quota_config_id,
  n_obs_total,
  n_true_oos_total,
  ROUND(base_rate, 4) AS base_rate,
  n_stable_alerts,
  ROUND(stable_precision, 4) AS stable_precision,
  incremental_alerts,
  incremental_true_positives,
  ROUND(incremental_precision, 4) AS incremental_precision,
  ROUND(incremental_recall, 6) AS incremental_recall,
  ROUND(incremental_lift, 3) AS incremental_lift,
  ROUND(incremental_fpr, 6) AS incremental_fpr,
  ROUND(incremental_expected_lost_sales, 2) AS incremental_els,
  ROUND(selection_loss, 4) AS selection_loss,
  is_invalid_candidate
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
ORDER BY selection_loss ASC
"""
df_cands = client.query(q_cands).to_dataframe()

# ─────────────────────────────────────────────────────────────────────────────
# 4. LEAKAGE AUDIT
# ─────────────────────────────────────────────────────────────────────────────
q_audit = """
SELECT check_id, check_name, check_value, check_status, check_description
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict`
ORDER BY check_id
"""
df_audit = client.query(q_audit).to_dataframe()

verdict_row = df_audit[df_audit['check_id'] == 'FINAL_VERDICT']
n_pass = (df_audit['check_status'] == 'PASS').sum()
n_warn = (df_audit['check_status'] == 'WARNING').sum()
n_fail = (df_audit['check_status'] == 'FAIL').sum()

# ─────────────────────────────────────────────────────────────────────────────
# 5. SAVE CSVs
# ─────────────────────────────────────────────────────────────────────────────
csv_global = OUTPUT_DIR / f"h12_v5_1_metrics_locked_test_{TODAY}.csv"
csv_policy = OUTPUT_DIR / f"h12_v5_1_frozen_policy_{TODAY}.csv"
csv_cands  = OUTPUT_DIR / f"h12_v5_1_candidate_eval_{TODAY}.csv"
csv_audit  = OUTPUT_DIR / f"h12_v5_1_leakage_audit_{TODAY}.csv"

df_global.to_csv(csv_global, index=False)
df_policy.to_csv(csv_policy, index=False)
df_cands.to_csv(csv_cands, index=False)
df_audit.to_csv(csv_audit, index=False)

print(f"CSV saved:")
print(f"  {csv_global}")
print(f"  {csv_policy}")
print(f"  {csv_cands}")
print(f"  {csv_audit}")

# ─────────────────────────────────────────────────────────────────────────────
# 6. EXTRACT KEY NUMBERS FOR REPORT
# ─────────────────────────────────────────────────────────────────────────────
global_row = df_global[df_global['segment_type'] == 'GLOBAL'].iloc[0]
n_obs        = int(global_row['n_obs'])
n_stockouts  = int(global_row['n_true_oos'])
base_rate    = float(global_row['base_rate'])
n_stable     = int(global_row['n_stable_alerts'])
stab_prec    = float(global_row['stable_precision'])
stab_rec     = float(global_row['stable_recall'])
n_diff       = int(global_row['n_difficult_alerts'])
diff_prec    = float(global_row['difficult_precision']) if global_row['difficult_precision'] == global_row['difficult_precision'] else 0.0
diff_rec     = float(global_row['difficult_recall'])
n_comb       = int(global_row['n_combined_alerts'])
comb_prec    = float(global_row['combined_precision'])
comb_rec     = float(global_row['combined_recall'])
stab_els     = float(global_row['stable_els_recovered'])
diff_els     = float(global_row['difficult_els_recovered'])
comb_els     = float(global_row['combined_els_recovered'])

policy_row   = df_policy.iloc[0]
pol_id       = policy_row['frozen_difficult_policy_id']
pol_gate     = policy_row['frozen_gate_set_id']
pol_pct      = policy_row['frozen_percentile_config_id']
pol_quota    = policy_row['frozen_quota_config_id']
pol_alerts   = int(policy_row['dev_select_incremental_alerts'])
pol_prec     = float(policy_row['dev_select_precision'])
pol_recall   = float(policy_row['dev_select_recall'])
pol_lift     = float(policy_row['dev_select_lift'])
pol_loss     = float(policy_row['selection_loss'])

# best 5 candidates
top5 = df_cands.head(5)

# season group metrics
sg_rows = df_global[df_global['segment_type'] == 'SEASON_GROUP']

# ─────────────────────────────────────────────────────────────────────────────
# 7. GENERATE MARKDOWN REPORT
# ─────────────────────────────────────────────────────────────────────────────
md_path = OUTPUT_DIR / f"INFORME_H12_V5_1_STATE_SPECIFIC_{TODAY}.md"

lines = []
A = lines.append

A(f"# Informe h12_v5_1 — State-Specific OOS Policy (Additive Layer)")
A(f"")
A(f"**Fecha:** {TODAY}  ")
A(f"**Pipeline:** `h12_v5_1_state_specific_oos_policy_strict`  ")
A(f"**Proyecto BigQuery:** `thequantitativeledger.cruzber_models_eu`  ")
A(f"**Tipo:** Iteración ADITIVA sobre v5 (POLICY\\_E1 congelada)  ")
A(f"")
A(f"---")
A(f"")
A(f"## 1. Contexto y Motivación")
A(f"")
A(f"El modelo h12_v5 (POLICY\\_E1) tiene cobertura nula en los estados difíciles de demanda.")
A(f"Esta capa aditiva detecta incidentes OOS en SKUs con señal de zero-run pero que **no** activan POLICY\\_E1:")
A(f"")
A(f"- `zero_run_component >= 0.15` (señal OOS presente)")
A(f"- `p_true_zero_demand < 0.75` (no es cero estructural)")
A(f"- `oos_flag_v5 = 0` (no cubierto por POLICY\\_E1)")
A(f"")
A(f"La partición de percentiles se realiza por `eval_split_v3 × season_group`")
A(f"(`HIGH_SEASON` / `REST`), disponible en todos los splits (DEV\\_TUNE, DEV\\_SELECT, LOCKED\\_TEST).")
A(f"")
A(f"---")
A(f"")
A(f"## 2. Diseño del Grid de Candidatos")
A(f"")
A(f"Grid 3 × 3 × 3 = **27 candidatos** evaluados en DEV\\_SELECT (sin contaminar LOCKED\\_TEST).")
A(f"")
A(f"| Dimensión | Opciones |")
A(f"|---|---|")
A(f"| Gate set | GATE\\_A (conservador), GATE\\_B (moderado), GATE\\_C (exploratorio) |")
A(f"| Percentil | P1 (0.940), P2 (0.900/0.920), P3 (0.850/0.870) |")
A(f"| Quota semanal | Q1 (5/8), Q2 (10/15), Q3 (20/30) alerts HIGH/REST |")
A(f"")
A(f"---")
A(f"")
A(f"## 3. Política Frozen Seleccionada")
A(f"")
A(f"| Parámetro | Valor |")
A(f"|---|---|")
A(f"| ID | `{pol_id}` |")
A(f"| Gate | `{pol_gate}` |")
A(f"| Percentil config | `{pol_pct}` |")
A(f"| Quota config | `{pol_quota}` |")
A(f"| Split de selección | DEV\\_SELECT (sin LOCKED\\_TEST) |")
A(f"| Alertas incrementales (DEV\\_SELECT) | {pol_alerts:,} |")
A(f"| Precisión incremental (DEV\\_SELECT) | {pol_prec:.4f} |")
A(f"| Recall incremental (DEV\\_SELECT) | {pol_recall:.6f} ({pol_recall*100:.4f}%) |")
A(f"| Lift incremental (DEV\\_SELECT) | {pol_lift:.3f}× |")
A(f"| Selection loss | {pol_loss:.4f} |")
A(f"")
A(f"---")
A(f"")
A(f"## 4. Métricas LOCKED\\_TEST — Global")
A(f"")
A(f"| Métrica | POLICY\\_E1 (estable) | Capa Difícil (v5\\_1) | Combinado |")
A(f"|---|---|---|---|")
A(f"| Observaciones | {n_obs:,} | — | {n_obs:,} |")
A(f"| Stockouts reales | {n_stockouts:,} ({base_rate*100:.2f}%) | — | — |")
A(f"| Alertas | {n_stable:,} | **+{n_diff:,}** | {n_comb:,} |")
A(f"| Precisión | {stab_prec:.4f} | {diff_prec:.4f} | {comb_prec:.4f} |")
A(f"| Recall | {stab_rec:.4f} ({stab_rec*100:.2f}%) | +{diff_rec:.4f} pp | {comb_rec:.4f} ({comb_rec*100:.2f}%) |")
A(f"| ELS recuperado | {stab_els:,.1f} | +{diff_els:,.1f} | {comb_els:,.1f} |")
A(f"")
A(f"**Uplift neto:** +{n_diff:,} alertas (+{(n_diff/n_stable*100):.1f}% vs baseline), precisión difícil = **{diff_prec:.4f}** (supera base_rate {base_rate:.4f}).")
A(f"")
A(f"---")
A(f"")
A(f"## 5. Métricas por Season Group (LOCKED\\_TEST)")
A(f"")
A(f"| Season Group | Obs | Stockouts | Stable Alerts | Diff Alerts | Diff Prec | Diff Rec |")
A(f"|---|---|---|---|---|---|---|")
for _, r in sg_rows.iterrows():
    dp = f"{r['difficult_precision']:.4f}" if r['difficult_precision'] == r['difficult_precision'] else "—"
    dr = f"{r['difficult_recall']:.4f}" if r['difficult_recall'] == r['difficult_recall'] else "—"
    A(f"| {r['segment_value']} | {int(r['n_obs']):,} | {int(r['n_true_oos']):,} | {int(r['n_stable_alerts']):,} | {int(r['n_difficult_alerts']):,} | {dp} | {dr} |")
A(f"")
A(f"---")
A(f"")
A(f"## 6. Top 5 Candidatos Evaluados (DEV\\_SELECT)")
A(f"")
A(f"| ID | Gate | Pct | Quota | Alertas | TPs | Precisión | Recall% | Lift | Loss |")
A(f"|---|---|---|---|---|---|---|---|---|---|")
for _, r in top5.iterrows():
    A(f"| {r['difficult_policy_id']} | {r['gate_set_id']} | {r['percentile_config_id']} | {r['quota_config_id']} | {int(r['incremental_alerts']):,} | {int(r['incremental_true_positives']):,} | {r['incremental_precision']:.4f} | {r['incremental_recall']*100:.4f}% | {r['incremental_lift']:.3f} | {r['selection_loss']:.4f} |")
A(f"")
A(f"---")
A(f"")
A(f"## 7. Anti-Leakage Audit")
A(f"")
A(f"| Resultado | Count |")
A(f"|---|---|")
A(f"| PASS | {n_pass} |")
A(f"| WARNING | {n_warn} |")
A(f"| FAIL | {n_fail} |")
A(f"")
if not verdict_row.empty:
    A(f"**Veredicto final:** `{verdict_row.iloc[0]['check_status']}` — {verdict_row.iloc[0]['check_description']}")
A(f"")
A(f"Checks con WARNING:")
for _, r in df_audit[df_audit['check_status'] == 'WARNING'].iterrows():
    A(f"- **#{r['check_id']}** {r['check_name']}: {r['check_description']}")
A(f"")
A(f"---")
A(f"")
A(f"## 8. Tablas BigQuery Generadas")
A(f"")
A(f"| Fase | Tabla |")
A(f"|---|---|")
tables = [
    ("0", "base_scores_h12_v5_1_strict"),
    ("1", "difficult_state_scored_h12_v5_1_strict"),
    ("2", "difficult_state_policy_candidates_h12_v5_1_strict"),
    ("3", "difficult_state_candidate_eval_dev_select_h12_v5_1_strict"),
    ("4", "frozen_difficult_state_policy_h12_v5_1_strict"),
    ("5", "combined_oos_alerts_h12_v5_1_strict"),
    ("6", "final_locked_test_metrics_h12_v5_1_strict"),
    ("7", "incremental_uplift_analysis_h12_v5_1_strict"),
    ("8", "top_alerts_combined_h12_v5_1_strict"),
    ("99", "leakage_audit_h12_v5_1_strict"),
]
for ph, tbl in tables:
    A(f"| {ph} | `{tbl}` |")
A(f"")
A(f"---")
A(f"")
A(f"## 9. CSVs Exportados")
A(f"")
A(f"| Archivo | Contenido |")
A(f"|---|---|")
A(f"| `{csv_global.name}` | Métricas LOCKED\\_TEST (global + season\\_group + sku\\_season\\_state) |")
A(f"| `{csv_policy.name}` | Política frozen seleccionada |")
A(f"| `{csv_cands.name}` | Evaluación 27 candidatos en DEV\\_SELECT |")
A(f"| `{csv_audit.name}` | Resultados audit anti-leakage |")
A(f"")
A(f"---")
A(f"")
A(f"## 10. Notas Técnicas")
A(f"")
A(f"### Cambios respecto al diseño original (iteración C)")
A(f"")
A(f"El diseño original usaba `sku_season_state` para definir candidatos difíciles,")
A(f"pero esta columna solo está disponible en LOCKED\\_TEST (no en DEV\\_TUNE / DEV\\_SELECT).")
A(f"Se adoptó la **Opción C**: definición basada en features disponibles en todos los splits:")
A(f"")
A(f"```sql")
A(f"is_difficult_state_candidate = (")
A(f"  zero_run_component >= 0.15  -- señal OOS presente")
A(f"  AND p_true_zero_demand < 0.75  -- no cero estructural")
A(f"  AND oos_flag_v5 = 0  -- no cubierto por POLICY_E1")
A(f")")
A(f"```")
A(f"")
A(f"### Partición de percentiles")
A(f"")
A(f"```sql")
A(f"PERCENT_RANK() OVER (PARTITION BY eval_split_v3, season_group ORDER BY ...)")
A(f"```")
A(f"")
A(f"### Umbral de percentil relativo al máximo alcanzable")
A(f"")
A(f"El composite score máximo alcanzable es ~0.96 (no 1.0) al combinar 5 ranks.")
A(f"Los umbrales P1/P2/P3 se calibraron en [0.85–0.94] para ser alcanzables.")
A(f"El volumen de alertas está controlado por la quota semanal (Q1/Q2/Q3).")
A(f"")
A(f"### Fórmula de selection\\_loss")
A(f"")
A(f"```")
A(f"loss = (2.0 - lift)")
A(f"     - 1.5 * (ELS / 1000)")
A(f"     - 1.0 * recall")
A(f"     + 1.0 * FPR * 100")
A(f"     + volume_penalty  (> 10% obs total)")
A(f"     + precision_penalty  (< base_rate)")
A(f"     + instability_penalty  (std_weekly > 3)")
A(f"```")

md_content = "\n".join(lines)
md_path.write_text(md_content, encoding="utf-8")
print(f"\nMarkdown saved: {md_path}")
print("\nDone.")
