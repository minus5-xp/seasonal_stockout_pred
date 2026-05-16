"""
h12_v5_2 Recall-Safe OOS Policy Pipeline Runner
=================================================
Orchestrates execution of v5_2 additive recall-safe OOS detection layer.

CRITICAL: v5_2 is ADDITIVE on top of:
  - v5  (POLICY_E1, frozen stable core)
  - v5_1 (GATE_C_P3_Q3, frozen difficult-state layer)

v5_2 adds targeted alerts for recall-safe cases NOT covered by v5 or v5_1.
Neither v5 nor v5_1 policies are modified.

Phase dependencies:
  0 (base) → 1 (score) → 2 (grid) → 3 (eval DEV_SELECT) → 4 (freeze)
  0 + 1 + 2 + 4 → 5 (combined alerts, all splits)
  5 → 6 (LOCKED_TEST metrics)
  6 → 7 (verdict)
  5 → 8 (top alerts)
  5 → 9 (diagnostics)
  all → 99 (audit)

Usage:
  python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py [--phase N] [--dry-run]
  python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase all
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

PHASE_FILES = {
    0: "00_prepare_v5_2_base_scores.sql",
    1: "01_build_recall_safe_scores_h12_v5_2.sql",
    2: "02_generate_recall_safe_policy_candidates_h12_v5_2.sql",
    3: "03_eval_recall_safe_candidates_dev_select_h12_v5_2.sql",
    4: "04_select_frozen_recall_safe_policy_h12_v5_2.sql",
    5: "05_build_combined_oos_alerts_h12_v5_2.sql",
    6: "06_final_locked_test_metrics_h12_v5_2.sql",
    7: "07_incremental_uplift_analysis_h12_v5_2.sql",
    8: "08_top_alerts_combined_h12_v5_2.sql",
    9: "09_recall_frontier_diagnostics_h12_v5_2.sql",
    99: "99_leakage_audit_h12_v5_2.sql",
}

PHASE_DEPENDENCIES = {
    0: [],
    1: [0],
    2: [],         # Parameter grid; no dependency on scored data
    3: [0, 1, 2],  # Evaluation needs base scores, scored candidates, and grid
    4: [3],        # Freeze policy from evaluation results
    5: [0, 1, 2, 4],  # Apply frozen policy to all splits
    6: [5],        # Final LOCKED_TEST metrics
    7: [6],        # Verdict from metrics
    8: [5],        # Top alerts from combined
    9: [5],        # Diagnostics from combined
    99: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]  # Audit depends on all
}

# ──────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────

def get_bq_client():
    """Initialize BigQuery client with Application Default Credentials."""
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

        # Wait for completion and collect results
        results = query_job.result()
        elapsed = time.time() - start_time

        # Print SELECT validation results
        if query_job.statement_type == 'SELECT' and results.total_rows > 0:
            print("\nQuery Results:")
            for row in results:
                print(" ", dict(row))

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
        description="h12_v5_2 Recall-Safe OOS Policy Pipeline Runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run all phases in sequence
  python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py

  # Run specific phase
  python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase 3

  # Dry-run to see execution plan
  python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --dry-run

  # Run all phases explicitly
  python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase all

PowerShell tip (bypass dependency prompt):
  echo y | python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase 3
        """
    )
    parser.add_argument(
        "--phase",
        help="Run specific phase only (0-9, 99) or 'all' for all phases"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be executed without running"
    )
    args = parser.parse_args()

    client = get_bq_client()
    print(f"\n{'='*70}")
    print(f"h12_v5_2 Recall-Safe OOS Policy Pipeline")
    print(f"Project: {PROJECT_ID}")
    print(f"Dataset: {DATASET_ID}")
    print(f"Location: {LOCATION}")
    print(f"{'='*70}")

    if args.dry_run:
        print("\n⚠️  DRY-RUN MODE: No queries will be executed")

    # Determine phases to run
    if args.phase == "all" or args.phase is None:
        phases_to_run = sorted(PHASE_FILES.keys())
    else:
        try:
            phase_num = int(args.phase)
            if phase_num not in PHASE_FILES:
                print(f"❌ Invalid phase: {phase_num}")
                print(f"   Valid phases: {sorted(PHASE_FILES.keys())}")
                sys.exit(1)
            phases_to_run = [phase_num]
        except ValueError:
            print(f"❌ Invalid phase: {args.phase}")
            print("   Use a number (0-9, 99) or 'all'")
            sys.exit(1)

    print(f"\nPhases to run: {phases_to_run}")
    print(f"Total phases: {len(phases_to_run)}")

    # Execute phases
    completed_phases = []
    failed_phases = []

    for phase_num in phases_to_run:
        # Check dependencies
        if not check_dependencies(phase_num, completed_phases):
            # Single-phase run: allow override with user confirmation
            if len(phases_to_run) == 1:
                print(f"⚠️  WARNING: Running phase {phase_num} without dependencies")
                print("    This may fail if dependent tables don't exist.")
                response = input("    Continue anyway? [y/N]: ")
                if response.lower() != 'y':
                    print("Aborted.")
                    sys.exit(1)
                # User confirmed: do NOT mark as failed yet; fall through to execution
            else:
                failed_phases.append(phase_num)
                print(f"❌ Stopping pipeline due to missing dependencies for Phase {phase_num}")
                break

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
        print("\n✅✅✅ Pipeline completed successfully! ✅✅✅")
        print("\nNext steps:")
        print("  1. Review Phase 7 verdict (incremental_uplift_analysis_h12_v5_2_strict)")
        print("  2. Review Phase 99 audit (leakage_audit_h12_v5_2_strict)")
        print("  3. PROMOTE_RECALL_SAFE_CONTROLLED → deploy with fresh holdout validation")
        print("  4. EXPERIMENTAL_RECALL_SAFE → shadow mode / further holdout testing")
        print("  5. KEEP_V5_1 or REJECT → no deployment; v5_1 remains active")
        sys.exit(0)


if __name__ == "__main__":
    main()
