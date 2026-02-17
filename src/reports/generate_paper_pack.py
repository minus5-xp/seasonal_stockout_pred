#!/usr/bin/env python3
"""
Generate paper pack: export key results for paper figures/tables.
"""
import sys
from pathlib import Path
from google.cloud import bigquery
import json


def generate_paper_pack():
    """Generate paper pack with key results."""
    
    from src.config.env import load_config
    from src.bq.client import get_default_client
    
    config = load_config(check_gcs=False)
    client = get_default_client(config.project_id, config.location)
    
    print("\nGenerating Paper Pack...\n")
    
    output_dir = Path("paper") / config.run_id
    output_dir.mkdir(parents=True, exist_ok=True)
    
    paper_pack = {
        "run_id": config.run_id,
        "dataset": config.dataset_ref,
        "exports": []
    }
    
    # Key exports for paper
    exports = [
        {
            "name": "conditional_coverage_by_segment",
            "query": f"""
                SELECT 
                  seg2,
                  COUNT(*) n_samples,
                  AVG(coverage) mean_coverage,
                  STDDEV(coverage) std_coverage,
                  AVG(interval_width) mean_width
                FROM {config.dataset_ref}.eval_quantiles_conditional_v2_h4
                WHERE split = 'val'
                GROUP BY seg2
                ORDER BY seg2
            """,
            "description": "Table for Figure 3: Coverage by segment"
        },
        {
            "name": "policy_performance",
            "query": f"""
                SELECT 
                  policy_name,
                  coverage_rate,
                  efficiency_score,
                  expected_stockouts
                FROM {config.dataset_ref}.policy_simulation_results_h4
                ORDER BY efficiency_score DESC
            """,
            "description": "Table for Figure 5: Policy comparison"
        },
        {
            "name": "baseline_comparison",
            "query": f"""
                SELECT 
                  model_name,
                  auc_roc,
                  precision_at_k,
                  recall_at_k
                FROM {config.dataset_ref}.baselines_evaluation_v2
                ORDER BY auc_roc DESC
            """,
            "description": "Table for Figure 2: Baseline model performance"
        },
    ]
    
    for export_def in exports:
        print(f"Exporting: {export_def['name']}...")
        
        try:
            results = list(client.query(export_def['query']).result())
            
            # Convert to list of dicts
            data = [dict(row) for row in results]
            
            # Save as JSON
            output_file = output_dir / f"{export_def['name']}.json"
            with open(output_file, 'w') as f:
                json.dump(data, f, indent=2, default=str)
            
            print(f"  ✓ Saved {len(data)} rows to {output_file}")
            
            paper_pack["exports"].append({
                "name": export_def['name'],
                "file": str(output_file),
                "rows": len(data),
                "description": export_def['description']
            })
            
        except Exception as e:
            print(f"  ⚠️  Failed: {e}")
            paper_pack["exports"].append({
                "name": export_def['name'],
                "error": str(e)
            })
    
    # Save manifest
    manifest_path = output_dir / "paper_pack_manifest.json"
    with open(manifest_path, 'w') as f:
        json.dump(paper_pack, f, indent=2)
    
    print(f"\n✓ Paper pack generated: {output_dir}")
    print(f"  Manifest: {manifest_path}")


if __name__ == "__main__":
    generate_paper_pack()
