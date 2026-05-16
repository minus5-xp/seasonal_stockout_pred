from google.cloud import bigquery
import pandas as pd

pd.set_option('display.max_columns', None)
pd.set_option('display.width', None)
pd.set_option('display.max_colwidth', 50)

client = bigquery.Client(project='thequantitativeledger', location='EU')

print('='*80)
print('1. FROZEN OVERLAY POLICY')
print('='*80)
policy = client.query('''
SELECT 
    candidate_id,
    method,
    cap_strategy,
    min_n_segment,
    ROUND(composite_loss, 4) AS loss,
    ROUND(wmape_ypos, 4) AS wmape,
    ROUND(viol_p80, 3) AS p80,
    ROUND(viol_p90, 3) AS p90,
    ROUND(viol_p95, 3) AS p95,
    ROUND(avg_spread_p50_p90, 2) AS spread90,
    ROUND(monotonicity_violation_rate, 4) AS mono_viol,
    selected_using_split
FROM `thequantitativeledger.cruzber_models_eu.frozen_overlay_policy_h12_v4_2_strict`
''').to_dataframe()
print(policy.to_string(index=False))

print('\n' + '='*80)
print('2. v3_2 vs v4_2 COMPARISON (GLOBAL + SEASON)')
print('='*80)
comparison = client.query('''
SELECT 
    segment,
    n_obs,
    ROUND(v3_2_wmape_ypos, 3) AS v3_2_wmape,
    ROUND(v4_2_wmape_ypos, 3) AS v4_2_wmape,
    ROUND(delta_wmape_ypos, 4) AS delta_wmape,
    ROUND(v3_2_viol_p90, 3) AS v3_2_p90,
    ROUND(v4_2_viol_p90, 3) AS v4_2_p90,
    ROUND(delta_viol_p90, 4) AS delta_p90,
    ROUND(v4_2_avg_spread_p90, 2) AS spread90,
    verdict
FROM `thequantitativeledger.cruzber_models_eu.compare_v3_2_vs_v4_2_h12_strict`
WHERE segment IN ('GLOBAL', 'HIGH_SEASON', 'REST')
ORDER BY 
    CASE segment 
        WHEN 'GLOBAL' THEN 1 
        WHEN 'HIGH_SEASON' THEN 2 
        ELSE 3 
    END
''').to_dataframe()
print(comparison.to_string(index=False))

print('\n' + '='*80)
print('3. FINAL LOCKED_TEST METRICS (v4_2)')
print('='*80)
metrics = client.query('''
SELECT 
    COALESCE(season_group, sku_season_state, 'GLOBAL') AS segment,
    n_obs,
    ROUND(wmape_ypos, 3) AS wmape,
    ROUND(bias_pct, 2) AS bias_pct,
    ROUND(viol_p80, 3) AS p80,
    ROUND(viol_p90, 3) AS p90,
    ROUND(viol_p95, 3) AS p95,
    ROUND(avg_spread_p50_p90, 2) AS spread90,
    ROUND(monotonicity_violation_rate, 4) AS mono_viol
FROM `thequantitativeledger.cruzber_models_eu.final_locked_test_metrics_h12_v4_2_strict`
WHERE metric_level IN ('v4_2_global', 'v4_2_by_season')
ORDER BY n_obs DESC
''').to_dataframe()
print(metrics.to_string(index=False))

print('\n' + '='*80)
print('SUMMARY')
print('='*80)
