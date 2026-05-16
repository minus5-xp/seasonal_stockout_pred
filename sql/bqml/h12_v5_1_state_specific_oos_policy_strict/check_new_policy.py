from google.cloud import bigquery

client = bigquery.Client()

print("=== Phase 3 NEW evaluation (updated penalty) ===")
query = """
SELECT 
  difficult_policy_id,
  gate_set_id,
  percentile_config_id,
  quota_config_id,
  incremental_alerts,
  incremental_true_positives,
  ROUND(incremental_precision, 3) as incr_prec,
  ROUND(incremental_recall*100, 4) as incr_rec_pct,
  ROUND(selection_loss, 3) as loss,
  is_invalid_candidate
FROM `thequantitativeledger.cruzber_models_eu.difficult_state_candidate_eval_dev_select_h12_v5_1_strict`
ORDER BY selection_loss ASC
LIMIT 15
"""
df = client.query(query).to_dataframe()
print(df.to_string(index=False))

print("\n=== Phase 4 NEW frozen policy ===")
query2 = """
SELECT
  frozen_difficult_policy_id,
  frozen_gate_set_id,
  frozen_percentile_config_id,
  frozen_quota_config_id,
  dev_select_incremental_alerts,
  dev_select_incremental_tp,
  ROUND(dev_select_incremental_precision, 3) as incr_prec,
  ROUND(dev_select_incremental_recall*100, 5) as incr_rec_pct,
  ROUND(dev_select_selection_loss, 3) as loss
FROM `thequantitativeledger.cruzber_models_eu.frozen_difficult_state_policy_h12_v5_1_strict`
"""
df2 = client.query(query2).to_dataframe()
print(df2.to_string(index=False))
