from google.cloud import bigquery

client = bigquery.Client()

# Check base_scores_h12_v5_1_strict COMPLETE breakdown
print("=== base_scores_h12_v5_1_strict COMPLETE ===")
query = """
SELECT 
  eval_split_v3, 
  COUNT(*) as total_rows,
  SUM(CAST(is_difficult_state_candidate AS INT64)) as n_difficult_candidates,
  SUM(CAST(is_stable_core_alert AS INT64)) as n_stable_alerts
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` 
GROUP BY 1 
ORDER BY 1
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))
print(f"\nTotal rows: {df['total_rows'].sum():,}")
print(f"Total difficult candidates: {df['n_difficult_candidates'].sum():,}")
print(f"Total stable alerts: {df['n_stable_alerts'].sum():,}")
