from google.cloud import bigquery

client = bigquery.Client()

# Check splits in season_state table
print("=== Splits in sku_season_state table ===")
query = """
SELECT 
  split,
  COUNT(*) as n_rows,
  COUNT(DISTINCT sku_id) as n_skus,
  COUNT(DISTINCT decision_week) as n_weeks
FROM `thequantitativeledger.cruzber_models_eu.sku_season_state_h12_v3_2_season_state_strict`
GROUP BY 1
ORDER BY 1
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))
