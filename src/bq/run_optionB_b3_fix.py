"""
B3 FIX v2: Mondrian split-conformal with volatility refinement + nested tuning
Runner for implementing paper-grade solution to Gate B3 coverage issues.

Architecture:
1. Volatility bucketing (CV per SKU)
2. 26-week calibration split (CALIB_A for scores, CALIB_B for tuning)
3. Hierarchical fallback: seg3 (season|hhi|vol) → seg2 → seg1 → global
4. Nested tuning: optimize coverage_target per seg2 using CALIB_B
5. Apply to VAL and evaluate conditional coverage

Usage:
    python run_optionB_b3_fix.py --project-id PROJECT --dataset-id DATASET [--location LOCATION]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from .config import BQConfig
    from .run_sql import SQLRunner
except ImportError:
    from src.bq.config import BQConfig
    from src.bq.run_sql import SQLRunner


def run_sql_stage(
    runner: SQLRunner,
    stage_name: str,
    sql_files: list[Path],
    verbose: bool = True,
) -> bool:
    """Execute SQL files in sequence."""
    if verbose:
        print(f"\n{'=' * 88}")
        print(f"[{stage_name}]")
        print('=' * 88)
    
    for sql_file in sql_files:
        if verbose:
            print(f"\nExecuting: {sql_file.name}")
        
        result = runner.execute_sql_file(
            sql_file,
            params=None,
            dry_run=False,
        )
        
        if not result:
            print(f"❌ FAILED: {sql_file.name}")
            return False
        
        if verbose:
            print(f"✅ SUCCESS: {sql_file.name}")
    
    return True


def check_gate_b3(runner: SQLRunner) -> tuple[bool, dict]:
    """Query gate summary and return PASS/FAIL status."""
    query = f"""
    SELECT
      segment_level,
      segment_name,
      n_active,
      viol_rate_p90_cond,
      gate_status
    FROM `{runner.config.dataset_ref}.b3_fix_gate_summary_h4`
    ORDER BY
      CASE segment_level WHEN 'GLOBAL' THEN 0 ELSE 1 END,
      gate_status DESC
    """
    
    results = list(runner.client.query(query).result())
    
    # Count passes and fails
    n_pass = sum(1 for r in results if r.gate_status == 'PASS')
    n_total = len(results)
    n_fail = n_total - n_pass
    
    # Overall verdict: pass if all SEG2 segments pass (and at least one exists)
    seg2_results = [r for r in results if r.segment_level == 'SEG2']
    if len(seg2_results) == 0:
        overall_pass = False  # No SEG2 data = FAIL
    else:
        overall_pass = all(r.gate_status == 'PASS' for r in seg2_results)
    
    summary = {
        'overall_pass': overall_pass,
        'n_pass': n_pass,
        'n_fail': n_fail,
        'n_total': n_total,
        'segments': [
            {
                'level': r.segment_level,
                'name': r.segment_name,
                'n_active': r.n_active,
                'viol_rate': r.viol_rate_p90_cond,
                'status': r.gate_status,
            }
            for r in results
        ]
    }
    
    return overall_pass, summary


def print_gate_summary(summary: dict):
    """Print gate evaluation summary."""
    print("\n" + "=" * 88)
    print("GATE B3 EVALUATION - FINAL VERDICT")
    print("=" * 88)
    
    print(f"\nOverall Status: {'✅ PASS' if summary['overall_pass'] else '❌ FAIL'}")
    print(f"Segments: {summary['n_pass']}/{summary['n_total']} passed")
    
    if summary['n_fail'] > 0:
        print(f"\n⚠️  {summary['n_fail']} segment(s) failed:")
        for seg in summary['segments']:
            if seg['status'] == 'FAIL':
                viol_str = f"{seg['viol_rate']:.4f}" if seg['viol_rate'] is not None else "NULL"
                n_str = str(seg['n_active']) if seg['n_active'] is not None else "NULL"
                print(f"  - {seg['name']}: viol_rate={viol_str} (n={n_str})")
    
    print("\nDetailed results:")
    print(f"{'Segment':<40} {'N_active':<12} {'Viol_rate':<12} {'Status':<8}")
    print("-" * 88)
    for seg in summary['segments']:
        n_str = str(seg['n_active']) if seg['n_active'] is not None else "NULL"
        viol_str = f"{seg['viol_rate']:.4f}" if seg['viol_rate'] is not None else "NULL"
        print(
            f"{seg['name']:<40} "
            f"{n_str:<12} "
            f"{viol_str:<12} "
            f"{seg['status']:<8}"
        )
    print()


def main():
    parser = argparse.ArgumentParser(
        description="B3 FIX v2: Run Mondrian conformal quantiles with volatility refinement"
    )
    parser.add_argument("--project-id", required=True, help="GCP project ID")
    parser.add_argument("--dataset-id", required=True, help="BigQuery dataset ID")
    parser.add_argument("--location", default="EU", help="BigQuery location")
    parser.add_argument("--verbose", action="store_true", help="Verbose output")
    args = parser.parse_args()
    
    root = Path(__file__).resolve().parents[2]
    config = BQConfig(
        project_id=args.project_id,
        dataset_id=args.dataset_id,
        location=args.location,
    )
    
    print(f"B3 FIX v2 - Mondrian Conformal Quantiles with Volatility Refinement")
    print(f"Dataset: {config.dataset_ref}")
    print(f"Location: {config.location}")
    
    runner = SQLRunner(config)
    
    # Stage 1: Volatility bucketing
    sql_files_stage1 = [
        root / "sql/bqml/quantiles_v2/30_build_volatility_bucket.sql",
    ]
    if not run_sql_stage(runner, "Stage 1: Volatility Bucketing", sql_files_stage1, args.verbose):
        sys.exit(1)
    
    # Stage 2: Calibration window splits
    sql_files_stage2 = [
        root / "sql/bqml/quantiles_v2/31_define_calibration_windows.sql",
    ]
    if not run_sql_stage(runner, "Stage 2: Calibration Windows", sql_files_stage2, args.verbose):
        sys.exit(1)
    
    # Stage 3: Mondrian conformal with fallback
    sql_files_stage3 = [
        root / "sql/bqml/quantiles_v2/32_mondrian_conformal_quantiles_v2.sql",
    ]
    if not run_sql_stage(runner, "Stage 3: Mondrian Conformal v2", sql_files_stage3, args.verbose):
        sys.exit(1)
    
    # Stage 4: Nested tuning using CALIB_B
    sql_files_stage4 = [
        root / "sql/bqml/quantiles_v2/33_tune_segment_coverage_target.sql",
    ]
    if not run_sql_stage(runner, "Stage 4: Nested Tuning (CALIB_B)", sql_files_stage4, args.verbose):
        sys.exit(1)
    
    # Stage 5: Apply to VAL
    sql_files_stage5 = [
        root / "sql/bqml/quantiles_v2/34_apply_targets_and_score_val.sql",
    ]
    if not run_sql_stage(runner, "Stage 5: Apply to VAL", sql_files_stage5, args.verbose):
        sys.exit(1)
    
    # Stage 6: Evaluation
    sql_files_stage6 = [
        root / "sql/bqml/eval/40_eval_quantiles_conditional_v2.sql",
        root / "sql/bqml/eval/41_b3_fix_summary.sql",
    ]
    if not run_sql_stage(runner, "Stage 6: Evaluation", sql_files_stage6, args.verbose):
        sys.exit(1)
    
    # Check gate
    print("\n" + "=" * 88)
    print("Checking Gate B3...")
    print("=" * 88)
    
    overall_pass, summary = check_gate_b3(runner)
    print_gate_summary(summary)
    
    if overall_pass:
        print("\n🎉 Gate B3 PASSED - Ready for submission")
        sys.exit(0)
    else:
        print("\n⚠️  Gate B3 FAILED - Further refinement needed")
        sys.exit(1)


if __name__ == "__main__":
    main()
