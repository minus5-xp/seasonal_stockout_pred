#!/usr/bin/env python3
"""
run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py

Orchestrates the h12_v4_1 pipeline execution:
  - 8 phases (0-7, 99) of BigQuery SQL scripts
  - Phase dependencies validated
  - Anti-leakage audit with exit code

Usage:
  python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py
  python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py --dry-run
  python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py --start-phase 3
  python run_h12_v4_1_efficient_conformal_quantiles_strict_pipeline.py --stop-after-phase 5

Exit codes:
  0: Success (audit PASS)
  1: Failure (audit FAIL or execution error)
"""

import argparse
import sys
import time
from pathlib import Path
from google.cloud import bigquery


# ============================================================================
# Configuration
# ============================================================================
PROJECT_ID = "thequantitativeledger"
DATASET_ID = "cruzber_models_eu"
LOCATION = "EU"

PIPELINE_DIR = Path(__file__).parent
PHASE_FILES = [
    "00_diagnostics_eda_shift_h12_v4_1.sql",
    "01_build_feature_matrix_h12_v4_1.sql",
    "02_build_point_forecast_candidates_h12_v4_1.sql",
    "03_calibrate_segmented_residual_spreads_h12_v4_1.sql",
    "04_score_conformal_quantile_candidates_h12_v4_1.sql",
    "05_select_frozen_efficient_policy_dev_select_h12_v4_1.sql",
    "06_final_locked_test_metrics_h12_v4_1.sql",
    "07_compare_v3_2_vs_v4_1_h12.sql",
    "99_leakage_audit_h12_v4_1.sql",
]

PHASE_NAMES = [
    "Phase 0: EDA & Distributional Shift Diagnostics",
    "Phase 1: Build Anti-Leakage Feature Matrix",
    "Phase 2: Build Point Forecast Candidates (A0-A3)",
    "Phase 3: Calibrate Segmented Residual Spreads",
    "Phase 4: Score Conformal Quantile Candidates (A×B)",
    "Phase 5: Select Frozen Efficient Policy (DEV_SELECT)",
    "Phase 6: Final LOCKED_TEST Metrics (ONE-TIME USE)",
    "Phase 7: Compare v3_2 vs v4_1",
    "Phase 99: Anti-Leakage Audit",
]

PHASE_DEPENDENCIES = {
    0: [],
    1: [0],
    2: [1],
    3: [2],
    4: [2, 3],
    5: [4],
    6: [5],
    7: [6],
    99: [0, 1, 2, 3, 4, 5, 6, 7],
}


# ============================================================================
# Helper Functions
# ============================================================================
def split_statements(sql_script: str) -> list[str]:
    """
    Split SQL script into individual statements.
    Returns list of non-empty statements.
    """
    statements = []
    current = []
    
    for line in sql_script.split('\n'):
        stripped = line.strip()
        # Skip comments
        if stripped.startswith('--'):
            continue
        current.append(line)
        # Split on semicolon at end of line
        if stripped.endswith(';'):
            stmt = '\n'.join(current).strip()
            if stmt and not stmt.startswith('--'):
                statements.append(stmt)
            current = []
    
    # Handle last statement if no trailing semicolon
    if current:
        stmt = '\n'.join(current).strip()
        if stmt and not stmt.startswith('--'):
            statements.append(stmt)
    
    return statements


def execute_sql_file(client: bigquery.Client, sql_file: Path, dry_run: bool = False) -> bool:
    """
    Execute all statements in SQL file.
    Returns True on success, False on failure.
    """
    print(f"\n{'='*80}")
    print(f"Executing: {sql_file.name}")
    print(f"{'='*80}")
    
    if not sql_file.exists():
        print(f"ERROR: File not found: {sql_file}")
        return False
    
    sql_script = sql_file.read_text(encoding='utf-8')
    statements = split_statements(sql_script)
    
    print(f"Found {len(statements)} SQL statements")
    
    if dry_run:
        print("DRY RUN: Skipping execution")
        return True
    
    for i, stmt in enumerate(statements, 1):
        stmt_preview = stmt[:100].replace('\n', ' ') + ('...' if len(stmt) > 100 else '')
        print(f"\n[{i}/{len(statements)}] Executing: {stmt_preview}")
        
        try:
            query_job = client.query(stmt)
            result = query_job.result()  # Wait for completion
            
            # Print row count if available (for SELECT queries)
            if query_job.statement_type == 'SELECT':
                row_count = result.total_rows
                print(f"  ✓ Returned {row_count} rows")
            else:
                print(f"  ✓ Success")
                
        except Exception as e:
            print(f"  ✗ ERROR: {e}")
            return False
    
    print(f"\n✓ Successfully completed {sql_file.name}")
    return True


def check_audit_verdict(client: bigquery.Client) -> bool:
    """
    Check final audit verdict.
    Returns True if PASS, False if FAIL.
    """
    query = f"""
    SELECT
      COUNTIF(check_passed) AS passed_checks,
      COUNT(*) AS total_checks
    FROM `{PROJECT_ID}.{DATASET_ID}.leakage_audit_h12_v4_1_strict`
    """
    
    try:
        result = client.query(query).result()
        row = next(result)
        passed = row.passed_checks
        total = row.total_checks
        
        if passed == total:
            print(f"\n{'='*80}")
            print(f"✓✓✓ AUDIT PASSED: {passed}/{total} checks successful")
            print(f"{'='*80}")
            return True
        else:
            print(f"\n{'='*80}")
            print(f"✗✗✗ AUDIT FAILED: {passed}/{total} checks passed")
            print(f"{'='*80}")
            return False
    except Exception as e:
        print(f"ERROR checking audit: {e}")
        return False


# ============================================================================
# Main Pipeline
# ============================================================================
def main():
    parser = argparse.ArgumentParser(
        description="Run h12_v4_1 efficient conformal quantiles pipeline"
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Parse SQL files but do not execute'
    )
    parser.add_argument(
        '--start-phase',
        type=int,
        help='Start from this phase (0-99)',
        default=0
    )
    parser.add_argument(
        '--stop-after-phase',
        type=int,
        help='Stop after this phase (0-99)',
        default=99
    )
    args = parser.parse_args()
    
    print("="*80)
    print("h12_v4_1 Efficient Conformal Quantiles Pipeline")
    print("="*80)
    print(f"Project: {PROJECT_ID}")
    print(f"Dataset: {DATASET_ID}")
    print(f"Location: {LOCATION}")
    print(f"Dry run: {args.dry_run}")
    print(f"Phase range: {args.start_phase} to {args.stop_after_phase}")
    print("="*80)
    
    # Initialize BigQuery client
    try:
        client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
        print(f"✓ Connected to BigQuery as {client.project}")
    except Exception as e:
        print(f"ERROR: Failed to initialize BigQuery client: {e}")
        return 1
    
    # Map phase files to phase numbers
    phase_map = {}
    for i, file in enumerate(PHASE_FILES):
        if file.startswith("99_"):
            phase_num = 99
        else:
            phase_num = int(file.split('_')[0])
        phase_map[phase_num] = (file, PHASE_NAMES[i])
    
    # Determine phases to execute
    phases_to_run = []
    for phase_num in sorted(phase_map.keys()):
        if args.start_phase <= phase_num <= args.stop_after_phase:
            phases_to_run.append(phase_num)
    
    print(f"\nPhases to execute: {phases_to_run}")
    
    # Execute phases
    start_time = time.time()
    completed_phases = set()
    
    for phase_num in phases_to_run:
        file_name, phase_name = phase_map[phase_num]
        
        # Check dependencies
        missing_deps = [d for d in PHASE_DEPENDENCIES.get(phase_num, []) 
                       if d not in completed_phases and d < args.start_phase]
        if missing_deps:
            print(f"\nWARNING: Phase {phase_num} depends on phases {missing_deps}")
            print("Continuing anyway (dependencies may have been run previously)")
        
        print(f"\n{'#'*80}")
        print(f"# {phase_name}")
        print(f"{'#'*80}")
        
        sql_file = PIPELINE_DIR / file_name
        success = execute_sql_file(client, sql_file, args.dry_run)
        
        if not success:
            print(f"\n✗ Pipeline FAILED at {phase_name}")
            return 1
        
        completed_phases.add(phase_num)
    
    elapsed = time.time() - start_time
    print(f"\n{'='*80}")
    print(f"Pipeline completed in {elapsed:.1f} seconds")
    print(f"{'='*80}")
    
    # Check audit verdict if Phase 99 was executed
    if 99 in completed_phases and not args.dry_run:
        if check_audit_verdict(client):
            print("\n✓ Pipeline execution complete: LEAK-FREE and VALID")
            return 0
        else:
            print("\n✗ Pipeline execution complete: AUDIT FAILED")
            print("Results are INVALID due to data leakage")
            return 1
    else:
        print("\n✓ Pipeline execution complete (audit not run)")
        return 0


if __name__ == "__main__":
    sys.exit(main())
