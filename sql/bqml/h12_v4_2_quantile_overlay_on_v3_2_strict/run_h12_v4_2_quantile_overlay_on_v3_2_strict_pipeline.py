#!/usr/bin/env python3
"""
run_h12_v4_2_quantile_overlay_on_v3_2_strict_pipeline.py
========================================================
PURPOSE:
  Orchestrate the complete h12_v4_2 quantile overlay pipeline.
  v4_2 freezes p50 from v3_2 and adds conformal quantile spreads.

PHASES:
  0: Reproduce v3_2 baseline
  1: Build overlay feature matrix
  2: Calibrate residual spreads (DEV_TUNE only)
  3: Score overlay candidates (DEV_SELECT only)
  4: Select and freeze best overlay policy
  5: Build final forecast (all splits)
  6: Evaluate on LOCKED_TEST (one-time use)
  7: Compare v3_2 vs v4_2
  99: Comprehensive leakage audit

DEPENDENCIES:
  0 → 1 → 2 → 3 → 4 → 5 → 6 → 7
           ↓
          99 (depends on all)

USAGE:
  python run_h12_v4_2_quantile_overlay_on_v3_2_strict_pipeline.py
"""

import os
import re
import sys
from pathlib import Path
from google.cloud import bigquery
from typing import List, Tuple, Optional

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

PROJECT_ID = "thequantitativeledger"
DATASET_ID = "cruzber_models_eu"
LOCATION = "EU"

# Phase configuration
PHASE_FILES = {
    0: "00_reproduce_v3_2_baseline_h12_v4_2.sql",
    1: "01_build_overlay_feature_matrix_h12_v4_2.sql",
    2: "02_calibrate_residual_spreads_dev_tune_h12_v4_2.sql",
    3: "03_score_overlay_candidates_dev_select_h12_v4_2.sql",
    4: "04_select_frozen_overlay_policy_h12_v4_2.sql",
    5: "05_build_final_forecast_h12_v4_2.sql",
    6: "06_final_locked_test_metrics_h12_v4_2.sql",
    7: "07_compare_v3_2_vs_v4_2_h12.sql",
    99: "99_leakage_audit_h12_v4_2.sql"
}

# Phase dependencies
PHASE_DEPENDENCIES = {
    0: [],
    1: [0],
    2: [1],
    3: [1, 2],
    4: [3],
    5: [1, 2, 4],
    6: [5],
    7: [0, 6],
    99: [0, 1, 2, 3, 4, 5, 6, 7]
}

# Dry run mode (set to True to only parse SQL without executing)
DRY_RUN = False

# ══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

def get_script_dir() -> Path:
    """Get directory where this script is located."""
    return Path(__file__).parent.absolute()


def load_sql_file(file_path: Path) -> List[str]:
    """
    Load SQL file and split into individual statements.
    Handles multi-line statements and comments.
    """
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove comments (lines starting with --)
    lines = []
    for line in content.split('\n'):
        stripped = line.strip()
        if not stripped.startswith('--'):
            lines.append(line)
    
    content = '\n'.join(lines)
    
    # Split on semicolons (statement delimiter)
    statements = [stmt.strip() for stmt in content.split(';') if stmt.strip()]
    
    return statements


def execute_statement(client: bigquery.Client, statement: str, phase_id: int) -> Tuple[bool, Optional[int]]:
    """
    Execute a single SQL statement.
    Returns (success, row_count).
    """
    try:
        query_job = client.query(statement)
        result = query_job.result()
        
        # Get row count
        row_count = None
        if result.total_rows is not None:
            row_count = result.total_rows
        elif query_job.num_dml_affected_rows is not None:
            row_count = query_job.num_dml_affected_rows
        
        return True, row_count
    
    except Exception as e:
        print(f"❌ ERROR in Phase {phase_id}: {e}")
        return False, None


def execute_phase(client: bigquery.Client, phase_id: int, sql_file: Path) -> bool:
    """
    Execute all statements in a phase SQL file.
    Returns True if all statements succeeded.
    """
    print(f"\n{'═' * 80}")
    print(f"PHASE {phase_id}: {sql_file.name}")
    print(f"{'═' * 80}")
    
    if not sql_file.exists():
        print(f"❌ File not found: {sql_file}")
        return False
    
    # Load statements
    statements = load_sql_file(sql_file)
    print(f"📝 Loaded {len(statements)} SQL statements")
    
    if DRY_RUN:
        print("🔍 DRY RUN MODE: Skipping execution")
        return True
    
    # Execute each statement
    for i, stmt in enumerate(statements, 1):
        # Skip pure SELECT statements that are just logging
        if re.match(r'^\s*SELECT\s+[\'"].*[\'"]', stmt, re.IGNORECASE):
            continue
        
        print(f"\n  [{i}/{len(statements)}] Executing statement...", end=" ")
        success, row_count = execute_statement(client, stmt, phase_id)
        
        if not success:
            return False
        
        if row_count is not None:
            print(f"✓ ({row_count:,} rows)")
        else:
            print("✓")
    
    print(f"\n✅ Phase {phase_id} complete")
    return True


def check_dependencies(completed_phases: set, phase_id: int) -> bool:
    """Check if all dependencies for a phase are completed."""
    deps = PHASE_DEPENDENCIES.get(phase_id, [])
    return all(dep in completed_phases for dep in deps)


def run_audit_check(client: bigquery.Client) -> bool:
    """
    Run final audit check after Phase 99.
    Returns True if audit passed.
    """
    print(f"\n{'═' * 80}")
    print("FINAL AUDIT CHECK")
    print(f"{'═' * 80}")
    
    query = f"""
    SELECT
      COUNTIF(status = 'FAIL') AS n_failed,
      COUNTIF(status = 'PASS') AS n_passed
    FROM `{PROJECT_ID}.{DATASET_ID}.leakage_audit_h12_v4_2_strict`
    """
    
    try:
        result = client.query(query).result()
        row = next(result)
        n_failed = row['n_failed']
        n_passed = row['n_passed']
        
        print(f"  Checks passed: {n_passed}")
        print(f"  Checks failed: {n_failed}")
        
        if n_failed == 0:
            print("\n✅ AUDIT PASSED")
            return True
        else:
            print("\n❌ AUDIT FAILED")
            # Show failed checks
            query_details = f"""
            SELECT check_id, check_name, violations
            FROM `{PROJECT_ID}.{DATASET_ID}.leakage_audit_h12_v4_2_strict`
            WHERE status = 'FAIL'
            ORDER BY check_id
            """
            result_details = client.query(query_details).result()
            for row in result_details:
                print(f"  ❌ Check {row['check_id']}: {row['check_name']} ({row['violations']} violations)")
            return False
    
    except Exception as e:
        print(f"❌ ERROR checking audit: {e}")
        return False


# ══════════════════════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ══════════════════════════════════════════════════════════════════════════════

def main():
    """Run the complete h12_v4_2 pipeline."""
    print(f"\n{'═' * 80}")
    print("h12_v4_2 QUANTILE OVERLAY PIPELINE")
    print(f"{'═' * 80}")
    print(f"Project: {PROJECT_ID}")
    print(f"Dataset: {DATASET_ID}")
    print(f"Location: {LOCATION}")
    print(f"Dry run: {DRY_RUN}")
    
    # Initialize BigQuery client
    client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
    
    # Get script directory
    script_dir = get_script_dir()
    
    # Track completed phases
    completed_phases = set()
    
    # Execute phases in dependency order
    phase_order = [0, 1, 2, 3, 4, 5, 6, 7, 99]
    
    for phase_id in phase_order:
        # Check dependencies
        if not check_dependencies(completed_phases, phase_id):
            print(f"\n❌ Cannot run Phase {phase_id}: dependencies not met")
            print(f"   Required: {PHASE_DEPENDENCIES[phase_id]}")
            print(f"   Completed: {sorted(completed_phases)}")
            sys.exit(1)
        
        # Get SQL file
        sql_file = script_dir / PHASE_FILES[phase_id]
        
        # Execute phase
        success = execute_phase(client, phase_id, sql_file)
        
        if not success:
            print(f"\n❌ Phase {phase_id} failed. Aborting pipeline.")
            sys.exit(1)
        
        completed_phases.add(phase_id)
    
    # Run audit check after Phase 99
    if not DRY_RUN:
        audit_passed = run_audit_check(client)
        
        if not audit_passed:
            print("\n⚠️  Pipeline completed but AUDIT FAILED")
            print("Review leakage_audit_h12_v4_2_strict table for details")
            sys.exit(1)
    
    # Success
    print(f"\n{'═' * 80}")
    print("✅ PIPELINE COMPLETE")
    print(f"{'═' * 80}")
    print("\nNext steps:")
    print("1. Review comparison table: compare_v3_2_vs_v4_2_h12_strict")
    print("2. Check frozen policy: frozen_overlay_policy_h12_v4_2_strict")
    print("3. Make promotion decision based on verdict column")
    print(f"{'═' * 80}\n")


if __name__ == "__main__":
    main()
