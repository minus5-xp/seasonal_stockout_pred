#!/usr/bin/env python3
"""
Export final metrics from h12_v3_strict (LOCKED_TEST without leakage)
"""
from google.cloud import bigquery

PROJECT_ID = "thequantitativeledger"
BQ_DATASET = "cruzber_models_eu"

client = bigquery.Client(project=PROJECT_ID, location="EU")

query = f"""
SELECT 
  test_status,
  is_locked_test,
  post_selection_bias,
  n_obs,
  n_skus,
  n_weeks,
  n_labelled_rows,
  n_labelled_stockout,
  ROUND(prevalence_stockout, 4) as prevalence,
  ROUND(wmape, 3) as wmape,
  ROUND(bias_pct, 1) as bias_pct,
  ROUND(viol_rate_p80, 3) as viol_p80,
  ROUND(viol_rate_p90, 3) as viol_p90,
  ROUND(viol_rate_p95, 3) as viol_p95,
  ROUND(brier_raw, 4) as brier_raw,
  ROUND(brier_calibrated, 4) as brier_cal,
  ROUND(brier_selected, 4) as brier_sel,
  n_alerts_top100,
  n_tp_top100,
  ROUND(precision_at_100, 3) as prec_100,
  ROUND(recall_at_100, 3) as rec_100,
  ROUND(lift_at_100, 2) as lift_100,
  frozen_prob_mode_reporting,
  frozen_policy,
  ROUND(frozen_policy_dev_select_lift, 2) as policy_dev_lift,
  frozen_q_scale_multiplier,
  frozen_q90_offset,
  ROUND(frozen_q_calibration_loss, 4) as q_loss
FROM `{PROJECT_ID}.{BQ_DATASET}.final_locked_test_metrics_h12_v3_strict`
"""

print("\n" + "="*80)
print("  MÉTRICAS h=12 v3_strict - LOCKED_TEST (W28-W40, sin leakage)")
print("="*80 + "\n")

try:
    results = client.query(query).result()
    
    for row in results:
        print("══ ESTADO DEL TEST ════════════════════════════════════════════")
        print(f"  Test status       : {row.test_status}")
        print(f"  Is locked test    : {row.is_locked_test}")
        print(f"  Post-sel bias     : {row.post_selection_bias}")
        print()
        
        print("══ COBERTURA ══════════════════════════════════════════════════")
        print(f"  n_obs             : {row.n_obs:,}")
        print(f"  n_skus            : {row.n_skus:,}")
        print(f"  n_weeks           : {row.n_weeks}")
        print(f"  n_labelled        : {row.n_labelled_rows:,}")
        print(f"  n_stockouts       : {row.n_labelled_stockout:,}")
        print(f"  Prevalence OOS    : {row.prevalence:.4f}")
        print()
        
        print("══ MÉTRICAS DE FORECAST ═══════════════════════════════════════")
        print(f"  WMAPE             : {row.wmape:.3f}")
        print(f"  Bias %            : {row.bias_pct:+.1f}%")
        print(f"  viol_p80          : {row.viol_p80:.3f}")
        print(f"  viol_p90          : {row.viol_p90:.3f}")
        print(f"  viol_p95          : {row.viol_p95:.3f}")
        print()
        
        print("══ MÉTRICAS DE CLASIFICACIÓN ══════════════════════════════════")
        print(f"  Brier (RAW)       : {row.brier_raw:.4f}")
        print(f"  Brier (CAL)       : {row.brier_cal:.4f}")
        print(f"  Brier (SELECTED)  : {row.brier_sel:.4f}")
        print()
        
        print("══ MÉTRICAS DE RANKING ════════════════════════════════════════")
        print(f"  Lift@100          : {row.lift_100:.2f}×")
        print(f"  Precision@100     : {row.prec_100:.3f}")
        print(f"  Recall@100        : {row.rec_100:.3f}")
        print(f"  Alerts top100     : {row.n_alerts_top100}")
        print(f"  True positives    : {row.n_tp_top100}")
        print()
        
        print("══ DECISIONES CONGELADAS ══════════════════════════════════════")
        print(f"  Prob mode (report): {row.frozen_prob_mode_reporting}")
        print(f"  Policy            : {row.frozen_policy}")
        print(f"  Policy DEV lift   : {row.policy_dev_lift:.2f}×")
        print(f"  Q scale mult      : {row.frozen_q_scale_multiplier:.2f}")
        print(f"  Q90 offset        : {row.frozen_q90_offset}")
        print(f"  Q calib loss      : {row.q_loss:.4f}")
        print()

    print("="*80)
    print("Notas:")
    print("  - Decisiones congeladas en DEV_SELECT (W09-W16)")
    print("  - LOCKED_TEST (W28-W40) nunca usado para calibración/selección")
    print("  - Post-selection bias = FALSE")
    print("="*80 + "\n")

except Exception as e:
    print(f"ERROR: {e}")
    import traceback
    traceback.print_exc()
