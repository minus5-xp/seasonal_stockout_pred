#!/usr/bin/env python3
"""
Generate B4 policy performance report.
"""
import sys
from pathlib import Path
from google.cloud import bigquery


def generate_b4_policy_report():
    """Generate B4 policy simulation report."""
    
    from src.config.env import load_config
    from src.bq.client import get_default_client
    
    config = load_config(check_gcs=False)
    client = get_default_client(config.project_id, config.location)
    
    print("\nGenerating B4 Policy Report...\n")
    
    # Query policy results
    query = f"""
    SELECT 
      policy_name,
      total_skus,
      procurement_volume,
      expected_stockouts,
      coverage_rate,
      efficiency_score
    FROM {config.dataset_ref}.policy_simulation_results_h4
    ORDER BY efficiency_score DESC
    """
    
    try:
        results = list(client.query(query).result())
    except Exception as e:
        print(f"⚠️  Could not query policy results: {e}")
        return None
    
    # Build report
    report_lines = []
    report_lines.append("# Gate B4: Policy Performance Report")
    report_lines.append("")
    report_lines.append(f"**Run ID:** {config.run_id}")
    report_lines.append(f"**Dataset:** {config.dataset_ref}")
    report_lines.append("")
    
    if not results:
        report_lines.append("❌ **Status:** NO DATA")
        report_lines.append("")
        report_lines.append("Policy simulation table is empty.")
    else:
        report_lines.append("## Policy Comparison")
        report_lines.append("")
        report_lines.append("| Policy | SKUs | Volume | Exp Stockouts | Coverage | Efficiency |")
        report_lines.append("|--------|------|--------|---------------|----------|------------|")
        
        for r in results:
            report_lines.append(
                f"| {r.policy_name} | {r.total_skus:,} | "
                f"{r.procurement_volume:,.0f} | {r.expected_stockouts:,.1f} | "
                f"{r.coverage_rate:.2%} | {r.efficiency_score:.3f} |"
            )
        
        report_lines.append("")
        
        # Best policy
        best = results[0]
        report_lines.append("## Recommendation")
        report_lines.append("")
        report_lines.append(f"**Best Policy:** {best.policy_name}")
        report_lines.append(f"- Coverage: {best.coverage_rate:.2%}")
        report_lines.append(f"- Efficiency: {best.efficiency_score:.3f}")
        report_lines.append(f"- Expected stockouts: {best.expected_stockouts:,.0f}")
    
    # Write report
    output_path = Path("reports_generated") / "B4_POLICY_REPORT.md"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(output_path, 'w') as f:
        f.write("\n".join(report_lines))
    
    print(f"✓ Report saved: {output_path}")
    
    return output_path


if __name__ == "__main__":
    generate_b4_policy_report()
