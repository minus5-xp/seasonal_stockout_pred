#!/usr/bin/env python3
"""
Generate final checklist from BigQuery results and file checks.
"""
import sys
from pathlib import Path
from google.cloud import bigquery
from datetime import datetime


def generate_final_checklist():
    """Generate final checklist CSV with completion status."""
    
    # Initialize client
    from src.config.env import load_config
    from src.bq.client import get_default_client
    
    config = load_config(check_gcs=False)
    client = get_default_client(config.project_id, config.location)
    
    print("\nGenerating final checklist...\n")
    
    checklist = []
    
    # Define checks
    checks = [
        ("Infrastructure", "experiments_registry created", check_table_exists, ["experiments_registry"]),
        ("Features", "features_core_h4 created", check_table_exists, ["features_core_h4"]),
        ("Features", "labels_uc_oos_h4 created", check_table_exists, ["labels_uc_oos_h4"]),
        ("Models", "p_oos_h4 model trained", check_model_exists, ["p_oos_h4"]),
        ("Models", "pred_point_uc_h4 scored", check_table_exists, ["pred_point_uc_h4"]),
        ("Unconstraining", "U3 predictions generated", check_table_exists, ["pred_point_uc_h4"]),
        ("Quantiles", "mondrian_quantiles_v2_h4 created", check_table_exists, ["mondrian_quantiles_v2_h4"]),
        ("Quantiles", "pred_quantiles_v2_h4 created", check_table_exists, ["pred_quantiles_v2_h4"]),
        ("Evaluation", "eval_quantiles_conditional_v2_h4", check_table_exists, ["eval_quantiles_conditional_v2_h4"]),
        ("Gates", "Gate B3 checked", check_table_exists, ["b3_fix_gate_summary_h4"]),
        ("Policy", "policy inputs prepared", check_table_exists, ["policy_inputs_h4"]),
        ("Baselines", "baselines evaluated", check_file_exists, ["baselines_comparison_v2.csv"]),
        ("Anti-leakage", "permutation tests run", check_table_exists, ["anti_leakage_permutation_runs"]),
        ("Reporting", "FINAL_VERDICT.md generated", check_file_exists, ["FINAL_VERDICT.md"]),
        ("Bundle", "Bundle created", check_file_exists, ["dist/*.tar.gz"]),
    ]
    
    for category, item, check_func, args in checks:
        try:
            status = check_func(client, config, *args)
            status_str = "PASS" if status else "FAIL"
        except Exception as e:
            status_str = f"ERROR: {e}"
        
        checklist.append({
            "category": category,
            "item": item,
            "status": status_str,
            "timestamp": datetime.utcnow().isoformat() + "Z"
        })
        
        symbol = "✓" if status_str == "PASS" else "✗"
        print(f"  {symbol} [{category}] {item}")
    
    # Write CSV
    output_path = Path("checklist_status_final.csv")
    
    with open(output_path, 'w') as f:
        # Header
        f.write("category,item,status,timestamp\n")
        
        # Rows
        for row in checklist:
            f.write(f"{row['category']},{row['item']},{row['status']},{row['timestamp']}\n")
    
    print(f"\n✓ Checklist saved: {output_path}")
    
    # Summary
    passed = sum(1 for r in checklist if r['status'] == 'PASS')
    total = len(checklist)
    
    print(f"\nSummary: {passed}/{total} checks passed")
    
    return checklist


def check_table_exists(client, config, table_name):
    """Check if BigQuery table exists."""
    try:
        table_ref = f"{config.dataset_ref}.{table_name}"
        client.get_table(table_ref)
        return True
    except Exception:
        return False


def check_model_exists(client, config, model_name):
    """Check if BQML model exists."""
    return check_table_exists(client, config, model_name)


def check_file_exists(client, config, file_pattern):
    """Check if file exists (supports glob)."""
    import glob
    matches = glob.glob(file_pattern)
    return len(matches) > 0


if __name__ == "__main__":
    generate_final_checklist()
