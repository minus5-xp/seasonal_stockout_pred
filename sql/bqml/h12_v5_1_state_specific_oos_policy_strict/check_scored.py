from google.cloud import bigquery

client = bigquery.Client()

print("=== Scored candidates distribution ===")
query = """
SELECT 
  eval_split_v3,
  season_group,
  COUNT(*) as n,
  ROUND(AVG(difficult_state_score), 3) as avg_score,
  ROUND(MAX(difficult_state_score), 4) as max_score,
  SUM(CAST(passes_gate_c AS INT64)) as n_gate_c,
  SUM(CASE WHEN passes_gate_c AND difficult_state_score >= 0.970 THEN 1 ELSE 0 END) as n_high_threshold,
  SUM(CASE WHEN passes_gate_c AND difficult_state_score >= 0.980 THEN 1 ELSE 0 END) as n_rest_threshold
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_scored_h12_v5_1_strict`
GROUP BY 1, 2
ORDER BY 1, 2
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))

print("\n=== Policy params ===")
query2 = """
SELECT 
  c.gate_set_id,
  c.percentile_config_id,
  c.quota_config_id,
  c.percentile_high_season,
  c.percentile_rest,
  c.quota_high_season,
  c.quota_rest
FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict` f
JOIN `thequantitativeledger.cruzber_models_eu.difficult_state_policy_candidates_h12_v5_1_strict` c
  ON f.frozen_difficult_policy_id = c.difficult_policy_id
"""
df2 = client.query(query2).to_dataframe()
print(df2.to_string(index=False))

print("\n=== Phase 5 combined alerts by split ===")
query3 = """
SELECT 
  eval_split_v3,
  alert_source,
  COUNT(*) as n
FROM `thequantitativeledger.cruzber_models_eu.combined_oos_alerts_h12_v5_1_strict`
WHERE is_difficult_state_alert = TRUE OR is_stable_core_alert = TRUE
GROUP BY 1, 2
ORDER BY 1, 2
"""
df3 = client.query(query3).to_dataframe()
print(df3.to_string(index=False))
