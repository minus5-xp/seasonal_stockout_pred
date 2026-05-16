from google.cloud import bigquery

client = bigquery.Client(project='thequantitativeledger')

tables = [
    'oos_state_inputs_h12_v5_strict',
    'oos_state_feature_matrix_h12_v5_strict',
    'oos_policy_candidates_h12_v5_strict',
    'oos_candidate_scores_dev_tune_h12_v5_strict',
    'oos_candidate_evaluation_dev_select_h12_v5_strict',
    'oos_frozen_policy_h12_v5_strict',
    'oos_final_scores_h12_v5_strict',
    'oos_locked_test_metrics_h12_v5_strict',
    'comparison_v3_v4_v5_h12_strict'
]

print('\n' + '=' * 80)
print('H12_V5 TABLE STATUS')
print('=' * 80)

existing_tables = [tb.table_id for tb in client.list_tables('cruzber_models_eu')]

for t in tables:
    if t in existing_tables:
        table = client.get_table(f'thequantitativeledger.cruzber_models_eu.{t}')
        print(f'{t:60s} | {table.num_rows:>10,} rows')
    else:
        print(f'{t:60s} | NOT FOUND')

print('=' * 80)
