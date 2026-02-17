#!/usr/bin/env python3
"""
Generate latest pipeline status summary.
"""
import sys
from pathlib import Path
from datetime import datetime


def generate_latest_status():
    """Generate latest status markdown."""
    
    from src.config.env import load_config
    from src.bq.client import get_default_client
    
    config = load_config(check_gcs=False)
    client = get_default_client(config.project_id, config.location)
    
    print("\nGenerating latest status...\n")
    
    status_lines = []
    status_lines.append("# Pipeline Status Report")
    status_lines.append("")
    status_lines.append(f"**Generated:** {datetime.utcnow().isoformat()}Z")
    status_lines.append(f"**Run ID:** {config.run_id}")
    status_lines.append(f"**Dataset:** {config.dataset_ref}")
    status_lines.append("")
    
    # Check key tables
    key_tables = [
        "experiments_registry",
        "features_core_h4",
        "pred_point_uc_h4",
        "mondrian_quantiles_v2_h4",
        "pred_quantiles_v2_h4",
        "eval_quantiles_conditional_v2_h4",
    ]
    
    status_lines.append("## Key Tables")
    status_lines.append("")
    status_lines.append("| Table | Status | Rows |")
    status_lines.append("|-------|--------|------|")
    
    for table_name in key_tables:
        try:
            table_ref = f"{config.dataset_ref}.{table_name}"
            table = client.get_table(table_ref)
            status_lines.append(f"| {table_name} | ✓ | {table.num_rows:,} |")
        except Exception:
            status_lines.append(f"| {table_name} | ✗ | - |")
    
    status_lines.append("")
    
    # Write report
    output_path = Path("reports_generated") / "LATEST_STATUS.md"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w') as f:
        f.write("\n".join(status_lines))
    
    print(f"✓ Status saved: {output_path}")


if __name__ == "__main__":
    generate_latest_status()
