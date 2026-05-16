from google.cloud import bigquery

client = bigquery.Client()

# Check sku_season_state table
print("=== sku_season_state_h12_v3_2_season_state_strict structure ===")
query = """
SELECT * 
FROM `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict`
LIMIT 5
"""
df = client.query(query).to_dataframe()
print(df.head().to_string())

print("\n=== Row count and state distribution ===")
query2 = """
SELECT 
  sku_season_state,
  COUNT(*) as n_skus
FROM `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict`
GROUP BY 1
ORDER BY 2 DESC
"""
df2 = client.query(query2).to_dataframe()
print(df2.to_string(index=False))
