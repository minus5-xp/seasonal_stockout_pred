from google.cloud import bigquery

client = bigquery.Client(project='thequantitativeledger')

query = """
SELECT table_name, 
       ROUND(size_bytes/1024/1024, 2) AS size_mb, 
       row_count 
FROM `thequantitativeledger.cruzber_models_eu.__TABLES__` 
WHERE table_name LIKE "%h12_v5%" OR table_name LIKE "%comparison_v3_v4_v5%"
ORDER BY table_name
"""

result = client.query(query).result()

print("\n=== H12_V5 TABLES ===")
for row in result:
    print(f"{row.table_name:60s} | {row.row_count:>10,} rows | {row.size_mb:>8.2f} MB")
