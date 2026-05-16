from google.cloud import bigquery

client = bigquery.Client()

# Check week numbers and states
print("=== Week numbers and states by split ===")
query = """
SELECT 
  eval_split_v3,
  EXTRACT(ISOWEEK FROM week_start_date) as iso_week,
  sku_season_state,
  COUNT(*) as n_rows
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` 
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3
LIMIT 100
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))

print("\n=== Unique states per split ===")
query2 = """
SELECT 
  eval_split_v3,
  COUNT(DISTINCT sku_season_state) as n_unique_states,
  STRING_AGG(DISTINCT sku_season_state ORDER BY sku_season_state) as states_list
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` 
GROUP BY 1
ORDER BY 1
"""
df2 = client.query(query2).to_dataframe()
print(df2.to_string(index=False))
