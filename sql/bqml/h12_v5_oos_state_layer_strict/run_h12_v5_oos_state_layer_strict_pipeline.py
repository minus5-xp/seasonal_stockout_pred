"""
h12_v5 OOS State Layer Pipeline Runner
========================================
Orchestrates execution of v5 OOS detection layer.

CRITICAL: v5 does NOT replace v3_2 or v4_2.
v5 is an ORTHOGONAL layer for OOS state detection/alerts.

Phase dependencies:
  0 → 1 → 2 → (3, separate) → (4, uses 3) → 5 → 6 → 7, 8
  99 depends on all

Usage:
  python run_h12_v5_oos_state_layer_strict_pipeline.py [--phase N] [--dry-run]
"""

import argparse
import sys
import time
from pathlib import Path
from google.cloud import bigquery
from google.api_core.exceptions import GoogleAPIError

# ──────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────

PROJECT_ID = "thequantitativeledger"
DATASET_ID = "cruzber_models_eu"
LOCATION = "EU"

SQL_DIR = Path(__file__).parent
PHASE_DEPENDENCIES = {
    0: [],
    1: [0],
    2: [1],
    3: [1, 2],
    4: [3],
    5: [4],
    6: [1, 5],
    7: [6],
    8: [6],
    99: [0, 1, 2, 3, 4, 5, 6, 7, 8]
}

PHASE_FILES = {
    0: "00_reproduce_inputs_h12_v5.sql",
    1: "01_build_oos_state_feature_matrix_h12_v5.sql",
    2: "02_generate_oos_policy_candidates_h12_v5.sql",
    3: "03_score_oos_state_candidates_dev_tune_h12_v5.sql",
    4: "04_eval_oos_state_candidates_dev_select_h12_v5.sql",
    5: "05_select_frozen_oos_state_policy_h12_v5.sql",
    6: "06_build_final_oos_state_scores_h12_v5.sql",
    7: "07_final_locked_test_oos_metrics_h12_v5.sql",
    8: "08_compare_v3_v4_v5_h12.sql",
    99: "99_audit_leakage_h12_v5.sql",
}

# ──────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────

def get_bq_client():
    """Initialize BigQuery client with ADC."""
    return bigquery.Client(project=PROJECT_ID, location=LOCATION)

def execute_sql_file(client, phase_num, sql_file_path, dry_run=False):
    """Execute SQL file and report results."""
    if not sql_file_path.exists():
        print(f"❌ Phase {phase_num}: SQL file not found: {sql_file_path}")
        return False
    
    print(f"\n{'='*70}")
    print(f"PHASE {phase_num}: {sql_file_path.name}")
    print(f"{'='*70}")
    
    if dry_run:
        print(f"[DRY-RUN] Would execute: {sql_file_path}")
        return True
    
    sql_content = sql_file_path.read_text(encoding='utf-8')
    
    try:
        start_time = time.time()
        job_config = bigquery.QueryJobConfig()
        query_job = client.query(sql_content, job_config=job_config)
        
        # Wait for completion and get results
        results = query_job.result()
        elapsed = time.time() - start_time
        
        # Print any SELECT results
        if query_job.statement_type == 'SELECT' and results.total_rows > 0:
            print("\nQuery Results:")
            for row in results:
                print(" ", dict(row))
        
        # Report statistics
        print(f"\n✅ Phase {phase_num} completed in {elapsed:.1f}s")
        if query_job.total_bytes_processed:
            gb_processed = query_job.total_bytes_processed / (1024**3)
            print(f"   Processed: {gb_processed:.3f} GB")
        
        return True
        
    except GoogleAPIError as e:
        print(f"\n❌ Phase {phase_num} FAILED:")
        print(f"   {str(e)}")
        return False
    except Exception as e:
        print(f"\n❌ Phase {phase_num} FAILED with unexpected error:")
        print(f"   {type(e).__name__}: {str(e)}")
        return False

def check_dependencies(phase_num, completed_phases):
    """Check if all dependencies for a phase are completed."""
    deps = PHASE_DEPENDENCIES.get(phase_num, [])
    missing = [d for d in deps if d not in completed_phases]
    if missing:
        print(f"❌ Phase {phase_num} cannot run: missing dependencies {missing}")
        return False
    return True

# ──────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="h12_v5 OOS State Layer Pipeline Runner"
    )
    parser.add_argument(
        "--phase",
        type=int,
        choices=list(PHASE_FILES.keys()) + [999],
        help="Run specific phase only (999 = all phases)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be executed without running"
    )
    args = parser.parse_args()
    
    client = get_bq_client()
    print(f"\n{'='*70}")
    print(f"h12_v5 OOS State Layer Pipeline")
    print(f"Project: {PROJECT_ID}")
    print(f"Dataset: {DATASET_ID}")
    print(f"Location: {LOCATION}")
    print(f"{'='*70}")
    
    if args.dry_run:
        print("\n⚠️  DRY-RUN MODE: No queries will be executed")
    
    # Determine phases to run
    if args.phase == 999:
        phases_to_run = sorted(PHASE_FILES.keys())
    elif args.phase is not None:
        phases_to_run = [args.phase]
    else:
        # Default: run all available phases in order
        phases_to_run = sorted(PHASE_FILES.keys())
    
    print(f"\nPhases to run: {phases_to_run}")
    
    # Execute phases
    completed_phases = []
    failed_phases = []
    
    for phase_num in phases_to_run:
        # Check dependencies
        if not check_dependencies(phase_num, completed_phases):
            failed_phases.append(phase_num)
            continue
        
        # Get SQL file
        sql_file = SQL_DIR / PHASE_FILES[phase_num]
        
        # Execute
        success = execute_sql_file(client, phase_num, sql_file, dry_run=args.dry_run)
        
        if success:
            completed_phases.append(phase_num)
        else:
            failed_phases.append(phase_num)
            print(f"\n❌ Stopping pipeline due to Phase {phase_num} failure")
            break
    
    # Summary
    print(f"\n{'='*70}")
    print("PIPELINE SUMMARY")
    print(f"{'='*70}")
    print(f"✅ Completed: {len(completed_phases)} phases - {completed_phases}")
    if failed_phases:
        print(f"❌ Failed: {len(failed_phases)} phases - {failed_phases}")
        print("\nPipeline FAILED. Review errors above.")
        sys.exit(1)
    else:
        print("\n✅ Pipeline completed successfully!")
        print("\n📊 h12_v5 OOS State Layer Complete:")
        print("   - Three-layer system: v3_2 (p50) + v4_2 (quantiles) + v5 (OOS alerts)")
        print("   - v5 is ORTHOGONAL - does NOT replace v3_2 or v4_2")
        print("   - Run Phase 99 for comprehensive leakage audit")
        sys.exit(0)

if __name__ == "__main__":
    main()
