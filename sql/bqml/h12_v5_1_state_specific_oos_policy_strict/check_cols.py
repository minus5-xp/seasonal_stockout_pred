from google.cloud import bigquery

c = bigquery.Client()
q = "SELECT * FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v5_1_strict` LIMIT 2"
df = c.query(q).to_dataframe()
print(list(df.columns))
