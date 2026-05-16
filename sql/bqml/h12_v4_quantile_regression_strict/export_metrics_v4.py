#!/usr/bin/env python3
"""
Export h12_v4_qr_strict LOCKED_TEST metrics to markdown.
"""
from google.cloud import bigquery
import pandas as pd

PROJECT_ID = "thequantitativeledger"
DATASET_ID = "cruzber_models_eu"
LOCATION = "EU"

client = bigquery.Client(project=PROJECT_ID, location=LOCATION)

# ── Query all metrics ────────────────────────────────────────────────────────
query = f"""
SELECT
  breakdown_level,
  season_group,
  sku_season_state,
  frozen_qr_model_type,
  n_obs,
  n_skus,
  wmape_all,
  wmape_y_positive,
  bias_pct,
  mae,
  viol_rate_p80,
  viol_rate_p90,
  viol_rate_p95,
  zero_demand_overforecast_rate,
  avg_pred_when_y_zero,
  pct_q80_lt_q50,
  pct_q90_lt_q80,
  pct_q95_lt_q90,
  avg_spread_p50_to_p90,
  std_spread_p50_to_p90,
  selected_using_locked_test,
  post_selection_bias
FROM `{PROJECT_ID}.{DATASET_ID}.final_locked_test_metrics_h12_v4_qr_strict`
ORDER BY 
  CASE breakdown_level
    WHEN 'GLOBAL' THEN 1
    WHEN 'BY_SEASON_GROUP' THEN 2
    WHEN 'BY_SKU_SEASON_STATE' THEN 3
  END,
  season_group NULLS LAST,
  sku_season_state NULLS LAST
"""

df = client.query(query).to_dataframe()

# ── Generate markdown ────────────────────────────────────────────────────────
md_lines = []
md_lines.append("# h12_v4_quantile_regression_strict - LOCKED_TEST Metrics")
md_lines.append("")
md_lines.append(f"**Model selected:** {df.iloc[0]['frozen_qr_model_type']}")
md_lines.append("")

# Global
global_row = df[df['breakdown_level'] == 'GLOBAL'].iloc[0]
md_lines.append("## Global Metrics")
md_lines.append("")
md_lines.append(f"- **n_obs:** {global_row['n_obs']:,}")
md_lines.append(f"- **n_skus:** {global_row['n_skus']:,}")
md_lines.append(f"- **WMAPE (all):** {global_row['wmape_all']:.3f}")
md_lines.append(f"- **WMAPE (y>0):** {global_row['wmape_y_positive']:.3f}")
md_lines.append(f"- **Bias:** {global_row['bias_pct']:.1f}%")
md_lines.append(f"- **MAE:** {global_row['mae']:.2f}")
md_lines.append(f"- **viol_p80:** {global_row['viol_rate_p80']:.4f}")
md_lines.append(f"- **viol_p90:** {global_row['viol_rate_p90']:.4f}")
md_lines.append(f"- **viol_p95:** {global_row['viol_rate_p95']:.4f}")
md_lines.append(f"- **Zero overforecast rate:** {global_row['zero_demand_overforecast_rate']:.3f}")
md_lines.append(f"- **Avg pred when y=0:** {global_row['avg_pred_when_y_zero']:.2f}")
md_lines.append(f"- **Avg spread p50→p90:** {global_row['avg_spread_p50_to_p90']:.2f}")
md_lines.append(f"- **Std spread p50→p90:** {global_row['std_spread_p50_to_p90']:.2f}")
md_lines.append("")
md_lines.append("### Monotonicity")
md_lines.append(f"- **q80 < p50:** {global_row['pct_q80_lt_q50']:.4f}")
md_lines.append(f"- **q90 < q80:** {global_row['pct_q90_lt_q80']:.4f}")
md_lines.append(f"- **q95 < q90:** {global_row['pct_q95_lt_q90']:.4f}")
md_lines.append("")

# By season_group
season_df = df[df['breakdown_level'] == 'BY_SEASON_GROUP'].sort_values('season_group')
if not season_df.empty:
    md_lines.append("## By Season Group")
    md_lines.append("")
    md_lines.append("| Season Group | n_obs | WMAPE(all) | WMAPE(y>0) | viol_p80 | viol_p90 | viol_p95 | Zero Overf |")
    md_lines.append("|--------------|-------|------------|------------|----------|----------|----------|------------|")
    for _, row in season_df.iterrows():
        md_lines.append(
            f"| {row['season_group']} | {row['n_obs']:,} | "
            f"{row['wmape_all']:.3f} | {row['wmape_y_positive']:.3f} | "
            f"{row['viol_rate_p80']:.4f} | {row['viol_rate_p90']:.4f} | "
            f"{row['viol_rate_p95']:.4f} | {row['zero_demand_overforecast_rate']:.3f} |"
        )
    md_lines.append("")

# By sku_season_state
state_df = df[df['breakdown_level'] == 'BY_SKU_SEASON_STATE'].sort_values('n_obs', ascending=False)
if not state_df.empty:
    md_lines.append("## By SKU Season State")
    md_lines.append("")
    md_lines.append("| State | n_obs | % | WMAPE(y>0) | viol_p80 | viol_p90 | viol_p95 |")
    md_lines.append("|-------|-------|---|------------|----------|----------|----------|")
    total_obs = df[df['breakdown_level'] == 'GLOBAL'].iloc[0]['n_obs']
    for _, row in state_df.iterrows():
        pct = 100.0 * row['n_obs'] / total_obs
        md_lines.append(
            f"| {row['sku_season_state']} | {row['n_obs']:,} | {pct:.1f}% | "
            f"{row['wmape_y_positive']:.3f} | {row['viol_rate_p80']:.4f} | "
            f"{row['viol_rate_p90']:.4f} | {row['viol_rate_p95']:.4f} |"
        )
    md_lines.append("")

# Audit flags
md_lines.append("## Audit Flags")
md_lines.append(f"- **selected_using_locked_test:** {global_row['selected_using_locked_test']}")
md_lines.append(f"- **post_selection_bias:** {global_row['post_selection_bias']}")
md_lines.append("")

# Write to file
output_path = "METRICAS_V4_QR_LOCKED_TEST.md"
with open(output_path, "w", encoding="utf-8") as f:
    f.write("\n".join(md_lines))

print(f"✓ Exported to {output_path}")
print(f"  Total rows: {len(df)}")
print(f"  Model: {df.iloc[0]['frozen_qr_model_type']}")
print(f"  Global WMAPE(y>0): {global_row['wmape_y_positive']:.3f}")
print(f"  Global viol_p90: {global_row['viol_rate_p90']:.4f}")
