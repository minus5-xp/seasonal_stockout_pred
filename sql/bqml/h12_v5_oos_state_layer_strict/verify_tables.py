from google.cloud import bigquery
import sys

try:
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
    
    print()
    print('=' * 90)
    print('H12_V5 TABLE STATUS')
    print('=' * 90)
    
    existing_tables = {tb.table_id for tb in client.list_tables('cruzber_models_eu')}
    
    for t in tables:
        if t in existing_tables:
            try:
                table = client.get_table(f'thequantitativeledger.cruzber_models_eu.{t}')
                print(f'{t:65s} | {table.num_rows:>10,} rows')
            except Exception as e:
                print(f'{t:65s} | ERROR: {str(e)}')
        else:
            print(f'{t:65s} | NOT FOUND')
    
    print('=' * 90)
    print()
    
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
