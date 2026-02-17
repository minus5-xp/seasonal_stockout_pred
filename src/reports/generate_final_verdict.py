#!/usr/bin/env python3
"""
Generate final verdict: PASS/FAIL based on all gates.
"""
import sys
from pathlib import Path
from datetime import datetime


def generate_verdict():
    """Generate FINAL_VERDICT.md with submit readiness assessment."""
    
    from src.config.env import load_config
    from src.bq.client import get_default_client
    
    config = load_config(check_gcs=False)
    client = get_default_client(config.project_id, config.location)
    
    print("\nGenerating final verdict...\n")
    
    verdict_lines = []
    verdict_lines.append("# FINAL VERDICT")
    verdict_lines.append("")
    verdict_lines.append(f"**Generated:** {datetime.utcnow().isoformat()}Z")
    verdict_lines.append(f"**Run ID:** {config.run_id}")
    verdict_lines.append(f"**Dataset:** {config.dataset_ref}")
    verdict_lines.append("")
    
    # Check gates
    gates = []
    
    # Gate B3: Conditional Coverage
    try:
        q_b3 = f"""
        SELECT COUNT(*) passed
        FROM {config.dataset_ref}.b3_fix_gate_summary_h4
        WHERE status = 'PASS' AND scope = 'seg2'
        """
        b3_passed = list(client.query(q_b3).result())[0].passed > 0
        gates.append(("Gate B3", "Conditional Coverage", b3_passed))
    except Exception as e:
        gates.append(("Gate B3", "Conditional Coverage", False))
        print(f"  ⚠️  B3 check failed: {e}")
    
    # Gate B4: Policy Performance
    try:
        q_b4 = f"""
        SELECT MAX(efficiency_score) best_score
        FROM {config.dataset_ref}.policy_simulation_results_h4
        """
        result = list(client.query(q_b4).result())
        b4_passed = result[0].best_score > 0.8 if result else False
        gates.append(("Gate B4", "Policy Performance", b4_passed))
    except Exception as e:
        gates.append(("Gate B4", "Policy Performance", False))
        print(f"  ⚠️  B4 check failed: {e}")
    
    # Overall verdict
    all_passed = all(g[2] for g in gates)
    
    if all_passed:
        verdict_lines.append("## ✓ PASS - Submit Ready")
        verdict_lines.append("")
        verdict_lines.append("All quality gates passed. The pipeline is ready for paper submission.")
    else:
        verdict_lines.append("## ✗ FAIL - Not Submit Ready")
        verdict_lines.append("")
        verdict_lines.append("Some quality gates failed. Review reports before submission.")
    
    verdict_lines.append("")
    verdict_lines.append("## Gate Summary")
    verdict_lines.append("")
    verdict_lines.append("| Gate | Requirement | Status |")
    verdict_lines.append("|------|-------------|--------|")
    
    for gate_id, requirement, passed in gates:
        status = "✓ PASS" if passed else "✗ FAIL"
        verdict_lines.append(f"| {gate_id} | {requirement} | {status} |")
    
    verdict_lines.append("")
    
    # Deliverables checklist
    verdict_lines.append("## Deliverables")
    verdict_lines.append("")
    
    deliverables = [
        ("Bundle", "dist/cruzber_optionB_bundle_*.tar.gz"),
        ("B3 Report", "reports_generated/B3_GATE_REPORT.md"),
        ("B4 Report", "reports_generated/B4_POLICY_REPORT.md"),
        ("Paper Pack", "paper/*/paper_pack_manifest.json"),
        ("Checklist", "checklist_status_final.csv"),
    ]
    
    verdict_lines.append("| Deliverable | Path | Status |")
    verdict_lines.append("|-------------|------|--------|")
    
    import glob
    for name, path_pattern in deliverables:
        matches = glob.glob(path_pattern)
        status = "✓" if matches else "✗"
        path_str = matches[0] if matches else path_pattern
        verdict_lines.append(f"| {name} | {path_str} | {status} |")
    
    verdict_lines.append("")
    
    # Next steps
    if all_passed:
        verdict_lines.append("## Next Steps")
        verdict_lines.append("")
        verdict_lines.append("1. Upload bundle to GCS:")
        verdict_lines.append(f"   ```bash")
        verdict_lines.append(f"   ./scripts/upload_bundle_to_gcs.sh dist/cruzber_optionB_bundle_{config.run_id}.tar.gz")
        verdict_lines.append("   ```")
        verdict_lines.append("")
        verdict_lines.append("2. Review paper pack exports in `paper/` directory")
        verdict_lines.append("")
        verdict_lines.append("3. Submit paper with:")
        verdict_lines.append("   - FINAL_VERDICT.md (this file)")
        verdict_lines.append("   - B3_GATE_REPORT.md")
        verdict_lines.append("   - B4_POLICY_REPORT.md")
        verdict_lines.append("   - Paper pack JSON files")
    else:
        verdict_lines.append("## Required Actions")
        verdict_lines.append("")
        verdict_lines.append("Review failed gates:")
        verdict_lines.append("")
        for gate_id, requirement, passed in gates:
            if not passed:
                verdict_lines.append(f"- **{gate_id}:** {requirement} failed")
        verdict_lines.append("")
        verdict_lines.append("Re-run pipeline after fixes:")
        verdict_lines.append("```bash")
        verdict_lines.append("python -m src.entrypoint run")
        verdict_lines.append("```")
    
    # Write verdict
    output_path = Path("FINAL_VERDICT.md")
    
    with open(output_path, 'w') as f:
        f.write("\n".join(verdict_lines))
    
    print(f"✓ Verdict saved: {output_path}")
    
    if all_passed:
        print("\n🎉 All gates PASSED - Pipeline is submit-ready!")
    else:
        print("\n⚠️  Some gates FAILED - Review reports")


if __name__ == "__main__":
    generate_verdict()
