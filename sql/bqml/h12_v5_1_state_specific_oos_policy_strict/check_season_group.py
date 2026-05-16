from google.cloud import bigquery

client = bigquery.Client()

print("=== season_group values by eval_split_v3 ===")
query = """
SELECT 
  eval_split_v3,
  season_group,
  COUNT(*) as n_rows
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` 
GROUP BY 1, 2
ORDER BY 1, 2
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))

print("\n=== Distinct season_group values ===")
query2 = """
SELECT DISTINCT season_group
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict`
ORDER BY 1
"""
df2 = client.query(query2).to_dataframe()
print(df2.to_string(index=False))
