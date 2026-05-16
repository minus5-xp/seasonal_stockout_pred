from google.cloud import bigquery

client = bigquery.Client()

print("=== Phase 3 evaluation (DEV_SELECT) ===")
query = """
SELECT 
  difficult_policy_id,
  gate_set_id,
  percentile_config_id,
  quota_config_id,
  incremental_alerts,
  incremental_true_positives,
  ROUND(incremental_precision, 3) as incr_prec,
  ROUND(selection_loss, 2) as loss,
  is_invalid_candidate
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
ORDER BY selection_loss ASC
LIMIT 10
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))

print("\n=== Phase 4 frozen policy ===")
query2 = """
SELECT *
FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
"""
df2 = client.query(query2).to_dataframe()
for col in df2.columns:
    print(f"  {col}: {df2[col].iloc[0] if len(df2) > 0 else 'NO DATA'}")

print("\n=== Phase 5 combined alerts distribution ===")
query3 = """
SELECT 
  eval_split_v3,
  alert_source,
  COUNT(*) as n_alerts
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
WHERE is_difficult_state_alert = TRUE OR is_stable_core_alert = TRUE
GROUP BY 1, 2
ORDER BY 1, 2
"""
df3 = client.query(query3).to_dataframe()
print(df3.to_string(index=False))
