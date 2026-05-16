from google.cloud import bigquery

client = bigquery.Client()

# Find tables with season_state
print("=== Tables with season_state ===")
query = """
SELECT table_name, creation_time
FROM `thequantitativeledger.cruzber_models_eu.INFORMATION_SCHEMA.TABLES`
WHERE table_name LIKE '%season_state%' OR table_name LIKE '%v3_2%'
ORDER BY creation_time DESC
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))
