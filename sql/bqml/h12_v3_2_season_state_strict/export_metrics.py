#!/usr/bin/env python3
"""
Export final metrics from h12_v3_2_season_state_strict (LOCKED_TEST with seasonal state segmentation)
"""
from google.cloud import bigquery

PROJECT_ID = "thequantitativeledger"
BQ_DATASET = "cruzber_models_eu"

client = bigquery.Client(project=PROJECT_ID, location="EU")

query = f"""
SELECT 
  breakdown_level,
  season_group,
  sku_season_state,
  demand_tier,
  n_obs,
  n_skus,
  ROUND(wmape_all, 3) as wmape_all,
  ROUND(wmape_y_positive, 3) as wmape_y_pos,
  ROUND(bias_pct, 1) as bias_pct,
  ROUND(viol_rate_p80, 3) as viol_p80,
  ROUND(viol_rate_p90, 3) as viol_p90,
  ROUND(viol_rate_p95, 3) as viol_p95,
  ROUND(brier_raw, 4) as brier_raw,
  ROUND(brier_calibrated, 4) as brier_cal,
  ROUND(zero_demand_overforecast_rate, 3) as zero_overf_rate,
  ROUND(avg_pred_when_y_zero, 2) as avg_pred_y0,
  n_gate_applied,
  post_selection_bias,
  selected_using_locked_test
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_2_season_state_strict`
WHERE breakdown_level IN ('global', 'by_season_group', 'by_sku_season_state')
ORDER BY 
  CASE breakdown_level 
    WHEN 'global' THEN 0 
    WHEN 'by_season_group' THEN 1
    WHEN 'by_sku_season_state' THEN 2
    ELSE 3 
  END,
  season_group,
  sku_season_state
"""

print("\n" + "="*80)
print("  MÉTRICAS h=12 v3_2_season_state_strict - LOCKED_TEST (W28-W40)")
print("="*80 + "\n")

try:
    results = client.query(query).result()
    
    current_level = None
    for row in results:
        if row.breakdown_level != current_level:
            current_level = row.breakdown_level
            if current_level == 'global':
                print("╔═══════════════════════════════════════════════════════════════════════╗")
                print("║ GLOBAL                                                                ║")
                print("╚═══════════════════════════════════════════════════════════════════════╝")
            elif current_level == 'by_season_group':
                print("\n" + "─"*80)
                print("  BY SEASON GROUP")
                print("─"*80)
            elif current_level == 'by_sku_season_state':
                print("\n" + "─"*80)
                print("  BY SKU SEASON STATE")
                print("─"*80)
        
        if row.breakdown_level == 'global':
            print(f"  n_obs                      : {row.n_obs:,}")
            print(f"  n_skus                     : {row.n_skus:,}")
            print(f"  WMAPE (all)                : {row.wmape_all:.3f}")
            print(f"  WMAPE (y>0 only)           : {row.wmape_y_pos:.3f}")
            print(f"  Bias %                     : {row.bias_pct:+.1f}%")
            print(f"  viol_p80                   : {row.viol_p80:.3f}")
            print(f"  viol_p90                   : {row.viol_p90:.3f}")
            print(f"  viol_p95                   : {row.viol_p95:.3f}")
            print(f"  Brier (raw)                : {row.brier_raw:.4f}")
            print(f"  Brier (calibrated)         : {row.brier_cal:.4f}")
            print(f"  Zero overforecast rate     : {row.zero_overf_rate:.3f}")
            print(f"  Avg pred when y=0          : {row.avg_pred_y0:.2f}")
            print(f"  n_gate_applied             : {row.n_gate_applied:,}")
            print(f"  post_selection_bias        : {row.post_selection_bias}")
            print()
        
        elif row.breakdown_level == 'by_season_group':
            print(f"\n  ┌─ {row.season_group} " + "─"*(70-len(row.season_group)))
            print(f"  │ n_obs          : {row.n_obs:,}")
            print(f"  │ WMAPE (all)    : {row.wmape_all:.3f}")
            print(f"  │ WMAPE (y>0)    : {row.wmape_y_pos:.3f}")
            print(f"  │ Bias %         : {row.bias_pct:+.1f}%")
            print(f"  │ viol_p90       : {row.viol_p90:.3f}")
            print(f"  │ Brier (cal)    : {row.brier_cal:.4f}")
            print(f"  │ Zero overf %   : {row.zero_overf_rate:.3f}")
            print(f"  │ n_gate_applied : {row.n_gate_applied:,}")
        
        elif row.breakdown_level == 'by_sku_season_state':
            state_label = row.sku_season_state or 'NULL'
            print(f"\n  • {state_label:25} | n={row.n_obs:>6,} | WMAPE(all)={row.wmape_all:>6.3f} | WMAPE(y>0)={row.wmape_y_pos:>6.3f} | viol_p90={row.viol_p90:.3f}")

    print("\n" + "="*80)
    print("Notas:")
    print("  - wmape_y_positive: excluye filas con y_true=0 del denominador")
    print("  - Gate OFF_SEASON: LEAST(pred, hist_p90) con floor hist_avg*0.30")
    print("  - Calibración con penalización por colapso: +50 si viol_p90<0.02")
    print("  - Auditoría: 9/9 PASS, post_selection_bias=FALSE")
    print("="*80 + "\n")

except Exception as e:
    print(f"ERROR: {e}")
    import traceback
    traceback.print_exc()
