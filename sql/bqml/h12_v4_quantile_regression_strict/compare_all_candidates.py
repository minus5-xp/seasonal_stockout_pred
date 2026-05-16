"""
Compare all 3 QR candidates on LOCKED_TEST.
"""
from google.cloud import bigquery
import pandas as pd
import numpy as np

PROJECT = 'thequantitativeledger'
DATASET = 'cruzber_models_eu'
LOCATION = 'EU'

client = bigquery.Client(project=PROJECT, location=LOCATION)

# ── Load predictions ─────────────────────────────────────────────────────────
query = f"""
SELECT
  sku_id,
  decision_week,
  y_true_12w,
  yhat_p50_base,
  yhat_p50_gated,
  season_group,
  sku_season_state,
  p_oos_calibrated,
  -- QR_DIRECT
  q50_qr_direct,
  q80_qr_direct,
  q90_qr_direct,
  q95_qr_direct,
  -- QR_RESIDUAL
  q50_qr_residual,
  q80_qr_residual,
  q90_qr_residual,
  q95_qr_residual,
  -- QR_ZERO_AWARE
  q50_qr_zero_aware,
  q80_qr_zero_aware,
  q90_qr_zero_aware,
  q95_qr_zero_aware
FROM `{PROJECT}.{DATASET}.qr_predictions_h12_v4_qr_strict`
WHERE eval_split_v3 = 'LOCKED_TEST'
"""

print("Loading LOCKED_TEST predictions...")
df = client.query(query).to_dataframe()
print(f"  {len(df):,} observations loaded")

# ── Helper functions ─────────────────────────────────────────────────────────
def compute_metrics(df, q50_col, q80_col, q90_col, q95_col):
    """Compute metrics for one candidate."""
    y = df['y_true_12w'].values
    q50 = df[q50_col].values
    q80 = df[q80_col].values
    q90 = df[q90_col].values
    q95 = df[q95_col].values
    
    # WMAPE
    mask_pos = y > 0
    n_pos = mask_pos.sum()
    if n_pos > 0:
        wmape_all = np.abs(y - q50).sum() / (y.sum() + 1e-9)
        wmape_ypos = np.abs(y[mask_pos] - q50[mask_pos]).sum() / (y[mask_pos].sum() + 1e-9)
    else:
        wmape_all = 0.0
        wmape_ypos = 0.0
    
    # Bias
    bias_pct = ((q50.sum() - y.sum()) / (y.sum() + 1e-9)) * 100
    
    # Violations
    viol_p80 = (y > q80).mean()
    viol_p90 = (y > q90).mean()
    viol_p95 = (y > q95).mean()
    
    # Zero overforecast
    mask_zero = y == 0
    n_zero = mask_zero.sum()
    if n_zero > 0:
        zero_overf = (q50[mask_zero] > 0).mean()
        avg_pred_when_zero = q50[mask_zero].mean()
    else:
        zero_overf = 0.0
        avg_pred_when_zero = 0.0
    
    # Monotonicity
    mono_q80_lt_q50 = (q80 < q50).mean()
    mono_q90_lt_q80 = (q90 < q80).mean()
    mono_q95_lt_q90 = (q95 < q90).mean()
    
    # Spread
    spread = q90 - q50
    avg_spread = spread.mean()
    std_spread = spread.std()
    
    return {
        'n_obs': len(df),
        'n_pos': n_pos,
        'pct_pos': n_pos / len(df) * 100,
        'wmape_all': wmape_all,
        'wmape_ypos': wmape_ypos,
        'bias_pct': bias_pct,
        'viol_p80': viol_p80,
        'viol_p90': viol_p90,
        'viol_p95': viol_p95,
        'zero_overf': zero_overf,
        'avg_pred_when_zero': avg_pred_when_zero,
        'mono_q80_lt_q50': mono_q80_lt_q50,
        'mono_q90_lt_q80': mono_q90_lt_q80,
        'mono_q95_lt_q90': mono_q95_lt_q90,
        'avg_spread_p50_to_p90': avg_spread,
        'std_spread_p50_to_p90': std_spread,
    }

def compute_composite_loss(metrics):
    """Compute composite loss as in selection script."""
    loss = (
        2.0 * abs(metrics['viol_p80'] - 0.20) +
        3.0 * abs(metrics['viol_p90'] - 0.10) +
        2.0 * abs(metrics['viol_p95'] - 0.05) +
        1.0 * metrics['wmape_ypos'] +
        0.5 * metrics['zero_overf'] +
        10.0 * (metrics['mono_q90_lt_q80'] + metrics['mono_q95_lt_q90']) +
        0.0  # highseason degradation penalty omitted for simplicity
    )
    return loss

# ── Global metrics for each candidate ────────────────────────────────────────
print("\nComputing global metrics...")
candidates = {
    'QR_DIRECT': ('q50_qr_direct', 'q80_qr_direct', 'q90_qr_direct', 'q95_qr_direct'),
    'QR_RESIDUAL': ('q50_qr_residual', 'q80_qr_residual', 'q90_qr_residual', 'q95_qr_residual'),
    'QR_ZERO_AWARE': ('q50_qr_zero_aware', 'q80_qr_zero_aware', 'q90_qr_zero_aware', 'q95_qr_zero_aware'),
}

global_metrics = {}
for name, cols in candidates.items():
    print(f"  {name}...")
    global_metrics[name] = compute_metrics(df, *cols)
    global_metrics[name]['composite_loss'] = compute_composite_loss(global_metrics[name])

# ── By season_group ──────────────────────────────────────────────────────────
print("\nComputing by season_group...")
season_metrics = {}
for name, cols in candidates.items():
    season_metrics[name] = {}
    for season in ['HIGH_SEASON', 'REST']:
        df_season = df[df['season_group'] == season]
        if len(df_season) > 0:
            season_metrics[name][season] = compute_metrics(df_season, *cols)

# ── By sku_season_state ──────────────────────────────────────────────────────
print("\nComputing by sku_season_state...")
state_metrics = {}
for name, cols in candidates.items():
    state_metrics[name] = {}
    for state in df['sku_season_state'].unique():
        if pd.notna(state):
            df_state = df[df['sku_season_state'] == state]
            if len(df_state) > 0:
                state_metrics[name][state] = compute_metrics(df_state, *cols)

# ── Generate markdown report ─────────────────────────────────────────────────
md_lines = []
md_lines.append("# Comparación Completa de Candidatos v4 - LOCKED_TEST")
md_lines.append("")
md_lines.append(f"**Dataset:** LOCKED_TEST ({len(df):,} observaciones)")
md_lines.append("")

# Global comparison
md_lines.append("## Métricas Globales")
md_lines.append("")
md_lines.append("| Métrica | QR_DIRECT | QR_RESIDUAL | QR_ZERO_AWARE | Target |")
md_lines.append("|---------|-----------|-------------|---------------|--------|")

metrics_to_show = [
    ('n_obs', 'n_obs', '{:,}', 'N/A'),
    ('WMAPE(all)', 'wmape_all', '{:.3f}', '< 2.0'),
    ('WMAPE(y>0)', 'wmape_ypos', '{:.3f}', '< 3.0'),
    ('Bias %', 'bias_pct', '{:+.1f}%', '±10%'),
    ('viol_p80', 'viol_p80', '{:.4f}', '[0.15, 0.25]'),
    ('viol_p90', 'viol_p90', '{:.4f}', '[0.05, 0.15]'),
    ('viol_p95', 'viol_p95', '{:.4f}', '[0.02, 0.08]'),
    ('Zero overf', 'zero_overf', '{:.3f}', '< 0.70'),
    ('Avg pred @ y=0', 'avg_pred_when_zero', '{:.2f}', 'N/A'),
    ('Mono q80<q50', 'mono_q80_lt_q50', '{:.4f}', '< 0.01'),
    ('Mono q90<q80', 'mono_q90_lt_q80', '{:.4f}', '< 0.01'),
    ('Mono q95<q90', 'mono_q95_lt_q90', '{:.4f}', '< 0.01'),
    ('Spread p50→p90', 'avg_spread_p50_to_p90', '{:.2f}', 'N/A'),
    ('Std spread', 'std_spread_p50_to_p90', '{:.2f}', 'N/A'),
    ('**Composite Loss**', 'composite_loss', '**{:.4f}**', '**MIN**'),
]

for label, key, fmt, target in metrics_to_show:
    if key == 'bias_pct':
        row = f"| {label} | "
        row += f"{global_metrics['QR_DIRECT'][key]:+.1f}% | "
        row += f"{global_metrics['QR_RESIDUAL'][key]:+.1f}% | "
        row += f"{global_metrics['QR_ZERO_AWARE'][key]:+.1f}% | "
        row += f"{target} |"
    elif '**' in fmt:
        row = f"| {label} | "
        row += f"**{global_metrics['QR_DIRECT'][key]:.4f}** | "
        row += f"**{global_metrics['QR_RESIDUAL'][key]:.4f}** | "
        row += f"**{global_metrics['QR_ZERO_AWARE'][key]:.4f}** | "
        row += f"{target} |"
    else:
        row = f"| {label} | "
        row += fmt.format(global_metrics['QR_DIRECT'][key]) + " | "
        row += fmt.format(global_metrics['QR_RESIDUAL'][key]) + " | "
        row += fmt.format(global_metrics['QR_ZERO_AWARE'][key]) + " | "
        row += f"{target} |"
    md_lines.append(row)

md_lines.append("")

# Winner
sorted_candidates = sorted(global_metrics.items(), key=lambda x: x[1]['composite_loss'])
winner_name = sorted_candidates[0][0]
md_lines.append(f"**Ganador por composite loss:** {winner_name} ({sorted_candidates[0][1]['composite_loss']:.4f})")
md_lines.append("")

# By season_group
md_lines.append("## Por Season Group")
md_lines.append("")
for season in ['HIGH_SEASON', 'REST']:
    md_lines.append(f"### {season}")
    md_lines.append("")
    md_lines.append("| Métrica | QR_DIRECT | QR_RESIDUAL | QR_ZERO_AWARE |")
    md_lines.append("|---------|-----------|-------------|---------------|")
    
    simple_metrics = [
        ('n_obs', '{:,}'),
        ('WMAPE(y>0)', '{:.3f}', 'wmape_ypos'),
        ('viol_p80', '{:.4f}'),
        ('viol_p90', '{:.4f}'),
        ('viol_p95', '{:.4f}'),
        ('Zero overf', '{:.3f}', 'zero_overf'),
    ]
    
    for item in simple_metrics:
        if len(item) == 2:
            label, fmt = item
            key = label.lower().replace(' ', '_').replace('(', '').replace(')', '').replace('>', '').replace('=', '')
        else:
            label, fmt, key = item
        
        if season in season_metrics['QR_DIRECT']:
            row = f"| {label} | "
            row += fmt.format(season_metrics['QR_DIRECT'][season][key]) + " | "
            row += fmt.format(season_metrics['QR_RESIDUAL'][season][key]) + " | "
            row += fmt.format(season_metrics['QR_ZERO_AWARE'][season][key]) + " |"
            md_lines.append(row)
    
    md_lines.append("")

# Top 5 states by n_obs
md_lines.append("## Top 5 Estados por Volumen")
md_lines.append("")
state_counts = df['sku_season_state'].value_counts()
top_states = state_counts.head(5).index.tolist()

for state in top_states:
    md_lines.append(f"### {state}")
    md_lines.append("")
    md_lines.append("| Métrica | QR_DIRECT | QR_RESIDUAL | QR_ZERO_AWARE |")
    md_lines.append("|---------|-----------|-------------|---------------|")
    
    simple_metrics = [
        ('n_obs', '{:,}'),
        ('% del total', '{:.1f}%', 'pct_of_total'),
        ('WMAPE(y>0)', '{:.3f}', 'wmape_ypos'),
        ('viol_p90', '{:.4f}'),
    ]
    
    for item in simple_metrics:
        if len(item) == 2:
            label, fmt = item
            key = label.lower().replace(' ', '_').replace('(', '').replace(')', '').replace('>', '')
        else:
            label, fmt, key = item
        
        if key == 'pct_of_total':
            pct = (state_metrics['QR_DIRECT'][state]['n_obs'] / len(df)) * 100
            row = f"| {label} | {pct:.1f}% | {pct:.1f}% | {pct:.1f}% |"
        elif state in state_metrics['QR_DIRECT']:
            row = f"| {label} | "
            row += fmt.format(state_metrics['QR_DIRECT'][state][key]) + " | "
            row += fmt.format(state_metrics['QR_RESIDUAL'][state][key]) + " | "
            row += fmt.format(state_metrics['QR_ZERO_AWARE'][state][key]) + " |"
        else:
            continue
        md_lines.append(row)
    
    md_lines.append("")

# Analysis section
md_lines.append("## Análisis Comparativo")
md_lines.append("")

# QR_DIRECT analysis
md_lines.append("### QR_DIRECT")
md_lines.append("")
direct = global_metrics['QR_DIRECT']
md_lines.append(f"- **Composite loss:** {direct['composite_loss']:.4f}")
md_lines.append(f"- **Fortalezas:**")
if 0.15 <= direct['viol_p80'] <= 0.25:
    md_lines.append(f"  - viol_p80 = {direct['viol_p80']:.4f} (dentro de target [0.15, 0.25])")
if 0.05 <= direct['viol_p90'] <= 0.15:
    md_lines.append(f"  - viol_p90 = {direct['viol_p90']:.4f} (dentro de target [0.05, 0.15])")
if direct['wmape_ypos'] < 3.0:
    md_lines.append(f"  - WMAPE(y>0) = {direct['wmape_ypos']:.3f} (< 3.0)")
if direct['mono_q90_lt_q80'] < 0.01:
    md_lines.append(f"  - Monotonicity q90<q80 = {direct['mono_q90_lt_q80']:.4f} (< 1%)")
md_lines.append(f"- **Debilidades:**")
if direct['viol_p80'] < 0.15 or direct['viol_p80'] > 0.25:
    md_lines.append(f"  - viol_p80 = {direct['viol_p80']:.4f} (fuera de target)")
if direct['viol_p90'] < 0.05 or direct['viol_p90'] > 0.15:
    md_lines.append(f"  - viol_p90 = {direct['viol_p90']:.4f} (fuera de target)")
if direct['wmape_ypos'] >= 3.0:
    md_lines.append(f"  - WMAPE(y>0) = {direct['wmape_ypos']:.3f} (≥ 3.0)")
if direct['mono_q90_lt_q80'] >= 0.01:
    md_lines.append(f"  - Monotonicity violations = {direct['mono_q90_lt_q80']:.4f}")
md_lines.append("")

# QR_RESIDUAL analysis
md_lines.append("### QR_RESIDUAL (Seleccionado)")
md_lines.append("")
residual = global_metrics['QR_RESIDUAL']
md_lines.append(f"- **Composite loss:** {residual['composite_loss']:.4f}")
md_lines.append(f"- **Fortalezas:**")
if residual['wmape_ypos'] < 3.0:
    md_lines.append(f"  - WMAPE(y>0) = {residual['wmape_ypos']:.3f} (< 3.0)")
if residual['zero_overf'] < 0.70:
    md_lines.append(f"  - Zero overf = {residual['zero_overf']:.3f} (< 0.70)")
md_lines.append(f"- **Debilidades:**")
if residual['viol_p80'] < 0.15:
    md_lines.append(f"  - viol_p80 = {residual['viol_p80']:.4f} (demasiado conservador, target [0.15, 0.25])")
if residual['viol_p90'] < 0.05:
    md_lines.append(f"  - viol_p90 = {residual['viol_p90']:.4f} (demasiado conservador, target [0.05, 0.15])")
if residual['viol_p95'] < 0.02:
    md_lines.append(f"  - viol_p95 = {residual['viol_p95']:.4f} (demasiado conservador, target [0.02, 0.08])")
if abs(residual['bias_pct']) > 10:
    md_lines.append(f"  - Bias = {residual['bias_pct']:+.1f}% (fuera de ±10%)")
if residual['mono_q90_lt_q80'] >= 0.01:
    md_lines.append(f"  - Monotonicity violations = {residual['mono_q90_lt_q80']:.4f}")
md_lines.append("")

# QR_ZERO_AWARE analysis
md_lines.append("### QR_ZERO_AWARE")
md_lines.append("")
zero_aware = global_metrics['QR_ZERO_AWARE']
md_lines.append(f"- **Composite loss:** {zero_aware['composite_loss']:.4f}")
md_lines.append(f"- **Fortalezas:**")
if zero_aware['wmape_ypos'] < 3.0:
    md_lines.append(f"  - WMAPE(y>0) = {zero_aware['wmape_ypos']:.3f} (< 3.0)")
if zero_aware['zero_overf'] < 0.70:
    md_lines.append(f"  - Zero overf = {zero_aware['zero_overf']:.3f} (< 0.70)")
md_lines.append(f"- **Debilidades:**")
if zero_aware['viol_p80'] < 0.15 or zero_aware['viol_p80'] > 0.25:
    md_lines.append(f"  - viol_p80 = {zero_aware['viol_p80']:.4f} (fuera de target [0.15, 0.25])")
if zero_aware['viol_p90'] < 0.05 or zero_aware['viol_p90'] > 0.15:
    md_lines.append(f"  - viol_p90 = {zero_aware['viol_p90']:.4f} (fuera de target [0.05, 0.15])")
if zero_aware['mono_q90_lt_q80'] >= 0.01:
    md_lines.append(f"  - Monotonicity violations = {zero_aware['mono_q90_lt_q80']:.4f}")
md_lines.append("")

# Recommendation
md_lines.append("## Recomendación")
md_lines.append("")
if winner_name != 'QR_RESIDUAL':
    md_lines.append(f"⚠️ **{winner_name} tiene mejor composite loss ({sorted_candidates[0][1]['composite_loss']:.4f}) que QR_RESIDUAL ({global_metrics['QR_RESIDUAL']['composite_loss']:.4f})**")
    md_lines.append("")
    md_lines.append(f"Considerar re-ejecutar fase 5 (final metrics) con {winner_name} en lugar de QR_RESIDUAL.")
    md_lines.append("")
else:
    md_lines.append("✓ QR_RESIDUAL es el mejor candidato según composite loss en LOCKED_TEST.")
    md_lines.append("")
    md_lines.append("Sin embargo, todos los candidatos tienen violations demasiado bajas (cuantiles sobre-conservadores).")
    md_lines.append("")

md_lines.append("### Opciones de Mejora")
md_lines.append("")
md_lines.append("1. **Re-entrenar con loss ajustado:** Reducir penalizaciones de violation en composite loss")
md_lines.append("2. **Isotonic post-processing:** Aplicar calibración isotónica a quantiles para garantizar monotonicity")
md_lines.append("3. **Ensemble:** Combinar QR_DIRECT (mejor spread) con QR_ZERO_AWARE (mejor zero handling)")
md_lines.append("4. **Feature engineering:** Agregar features de variabilidad temporal y efectos promocionales")
md_lines.append("")

# Write to file
output_path = 'COMPARACION_CANDIDATOS_V4_LOCKED_TEST.md'
with open(output_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(md_lines))

print(f"\n✓ Report written to {output_path}")
print(f"\nComposite Loss Summary:")
for name, metrics_dict in sorted_candidates:
    print(f"  {name:15s}: {metrics_dict['composite_loss']:.4f}")
