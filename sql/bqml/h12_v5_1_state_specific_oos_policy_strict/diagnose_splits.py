from google.cloud import bigquery

client = bigquery.Client()

# Check distribution of difficult states BY SPLIT
print("=== Difficult state distribution BY SPLIT ===")
query = """
SELECT 
  eval_split_v3,
  sku_season_state,
  COUNT(*) as n_rows,
  SUM(CAST(oos_flag_v5 = 0 AS INT64)) as n_not_flagged_v5,
  SUM(CAST(is_difficult_state_candidate AS INT64)) as n_difficult_candidates
FROM `thequantitativeledger.cruzber_models_eu.base_scores_h12_v5_1_strict` 
WHERE sku_season_state IN ('OFF_SEASON', 'TRANSITION_UP', 'TRANSITION_DOWN', 'INTERMITTENT_RANDOM')
GROUP BY 1, 2
ORDER BY 1, 2
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))

print("\n=== Summary by split ===")
summary = df.groupby('eval_split_v3')[['n_rows', 'n_not_flagged_v5', 'n_difficult_candidates']].sum()
print(summary)
