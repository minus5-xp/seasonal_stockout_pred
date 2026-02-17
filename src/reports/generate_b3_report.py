#!/usr/bin/env python3
"""
Generate B3 gate report from evaluation results.
"""
import sys
from pathlib import Path
from google.cloud import bigquery


def generate_b3_report():
    """Generate B3 gate check report."""
    
    from src.config.env import load_config
    from src.bq.client import get_default_client
    
    config = load_config(check_gcs=False)
    client = get_default_client(config.project_id, config.location)
    
    print("\nGenerating B3 Gate Report...\n")
    
    # Query gate summary
    query = f"""
    SELECT 
      scope,
      metric_name,
      metric_value,
      threshold_min,
      threshold_max,
      status
    FROM {config.dataset_ref}.b3_fix_gate_summary_h4
    WHERE scope = 'seg2'
    ORDER BY metric_name
    """
    
    try:
        results = list(client.query(query).result())
    except Exception as e:
        print(f"⚠️  Could not query gate summary: {e}")
        return None
    
    # Build report
    report_lines = []
    report_lines.append("# Gate B3: Conditional Coverage Report")
    report_lines.append("")
    report_lines.append(f"**Run ID:** {config.run_id}")
    report_lines.append(f"**Dataset:** {config.dataset_ref}")
    report_lines.append("")
    
    if not results:
        report_lines.append("❌ **Status:** NO DATA")
        report_lines.append("")
        report_lines.append("The gate check table is empty. This indicates:")
        report_lines.append("- Evaluation queries did not complete successfully")
        report_lines.append("- No seg2 segments passed minimum sample threshold")
        report_lines.append("- pred_quantiles_v2_h4 may be empty")
    else:
        # Determine overall status
        all_passed = all(r.status == 'PASS' for r in results)
        overall = "✓ PASS" if all_passed else "✗ FAIL"
        
        report_lines.append(f"**Status:** {overall}")
        report_lines.append("")
        report_lines.append("## Metrics")
        report_lines.append("")
        report_lines.append("| Metric | Value | Threshold | Status |")
        report_lines.append("|--------|-------|-----------|--------|")
        
        for r in results:
            val = f"{r.metric_value:.4f}" if r.metric_value is not None else "NULL"
            thresh = f"[{r.threshold_min:.2f}, {r.threshold_max:.2f}]"
            status_icon = "✓" if r.status == 'PASS' else "✗"
            
            report_lines.append(f"| {r.metric_name} | {val} | {thresh} | {status_icon} {r.status} |")
        
        report_lines.append("")
        
        # Interpretation
        report_lines.append("## Interpretation")
        report_lines.append("")
        
        if all_passed:
            report_lines.append("✓ All conditional coverage metrics are within specification.")
            report_lines.append("")
            report_lines.append("The conformal prediction intervals achieve the target")
            report_lines.append("coverage rate (90%) with acceptable deviation across segments.")
        else:
            report_lines.append("✗ Some metrics are outside specification.")
            report_lines.append("")
            report_lines.append("Required actions:")
            report_lines.append("- Review segment-specific calibration")
            report_lines.append("- Adjust coverage target grid")
            report_lines.append("- Increase minimum sample threshold")
    
    # Write report
    output_path = Path("reports_generated") / "B3_GATE_REPORT.md"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w') as f:
        f.write("\n".join(report_lines))
    
    print(f"✓ Report saved: {output_path}")
    
    return output_path


if __name__ == "__main__":
    generate_b3_report()
