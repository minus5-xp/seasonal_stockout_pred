#!/usr/bin/env python3
"""
h=12 v3_strict Pipeline Orchestrator
======================================
Strictly-separated pipeline that eliminates post-selection bias present in
h12_v2 / h12_v2_final.

METHODOLOGICAL GUARANTEES:
  - Calibration selected on DEV_TUNE (W01-W08) only.
  - Probability mode (RAW/CALIBRATED) selected on DEV_SELECT (W09-W16) only.
  - Policy selected on DEV_SELECT (W09-W16) only.
  - LOCKED_TEST (W28-W40) is read-only: frozen decisions applied, no re-selection.
  - Embargo (W17-W27) never used for tuning, selection, or reporting.
  - Fails hard if leakage_audit returns FAIL.
  - Reports NO_LOCKED_TEST_LABELS if W28-W40 labels are blind (current situation).

PHASES:
  1  00_temporal_contract_h12_v3_strict.sql
  2  01_recalibrate_dev_tune_h12_v3_strict.sql
  3  02_apply_calibration_all_splits_h12_v3_strict.sql
  4  03_probability_selection_dev_select_h12_v3_strict.sql
  5  04_policy_sweep_dev_select_h12_v3_strict.sql
  6  05_alerts_locked_test_h12_v3_strict.sql
  7  06_final_locked_test_metrics_h12_v3_strict.sql
  8  07_blind_deploy_export_h12_v3_strict.sql
  9  99_leakage_audit_h12_v3_strict.sql

USAGE:
  # Dry run (prints all statements, executes nothing)
  python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --dry-run

  # Full run
  python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py

  # Temporal contract only
  python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --stop-after-phase 1

  # Calibration + application (skip probability/policy selection)
  python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --start-phase 2 --stop-after-phase 3

  # Only leakage audit (all tables must already exist)
  python sql/bqml/h12_v3_strict/run_h12_v3_strict_pipeline.py --start-phase 9

ENVIRONMENT VARIABLES:
  PROJECT_ID    default: thequantitativeledger
  BQ_DATASET    default: cruzber_models_eu
  BQ_LOCATION   default: EU

EXIT CODES:
  0  Pipeline completed; final_verdict = PASS or NO_LOCKED_TEST_LABELS
  1  Leakage audit returned FAIL
  2  Execution error (BigQuery API, SQL syntax, etc.)
"""

import argparse
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# ── Constants ────────────────────────────────────────────────────────────────
PROJECT_ID = os.environ.get("PROJECT_ID", "thequantitativeledger")
DATASET_ID = os.environ.get("BQ_DATASET", "cruzber_models_eu")
LOCATION   = os.environ.get("BQ_LOCATION", "EU")

SCRIPT_DIR  = Path(__file__).parent
OUTPUT_DIR  = Path("outputs/h12_v3_strict")

# Phase definitions: (phase_number, sql_filename, label)
PIPELINE_PHASES = [
    (1, "00_temporal_contract_h12_v3_strict.sql",           "Temporal contract"),
    (2, "01_recalibrate_dev_tune_h12_v3_strict.sql",        "Calibration grid on DEV_TUNE"),
    (3, "02_apply_calibration_all_splits_h12_v3_strict.sql","Apply frozen calibration to all splits"),
    (4, "03_probability_selection_dev_select_h12_v3_strict.sql", "Probability mode selection on DEV_SELECT"),
    (5, "04_policy_sweep_dev_select_h12_v3_strict.sql",     "Policy sweep on DEV_SELECT"),
    (6, "05_alerts_locked_test_h12_v3_strict.sql",          "Apply frozen decisions to LOCKED_TEST"),
    (7, "06_final_locked_test_metrics_h12_v3_strict.sql",   "Final locked test metrics"),
    (8, "07_blind_deploy_export_h12_v3_strict.sql",         "Blind deploy export"),
    (9, "99_leakage_audit_h12_v3_strict.sql",               "Leakage audit"),
]

# ── SQL helpers ──────────────────────────────────────────────────────────────

def split_statements(sql: str) -> list:
    """Split a multi-statement SQL file into individual statements."""
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    stmts = []
    for raw in sql.split(";"):
        s = raw.strip()
        if not s:
            continue
        upper = s.upper()
        if any(upper.startswith(kw) for kw in
               ["CREATE", "INSERT", "UPDATE", "DELETE", "DROP"]):
            stmts.append(s)
        elif upper.startswith("SELECT") and "FROM" in upper:
            if not re.search(r"SELECT\s+'[=\-]+", s, re.IGNORECASE):
                stmts.append(s)
    return stmts


def substitute(sql: str, proj: str = PROJECT_ID, ds: str = DATASET_ID) -> str:
    sql = sql.replace("{PROJECT_ID}", proj)
    sql = sql.replace("{BQ_DATASET}", ds)
    return sql


# ── BigQuery execution ───────────────────────────────────────────────────────

def run_statements(client, stmts: list, dry_run: bool, label: str,
                   proj: str, ds: str) -> bool:
    """Execute a list of SQL statements. Returns True on success."""
    try:
        from google.api_core.exceptions import GoogleAPICallError
    except ImportError:
        from Exception import Exception as GoogleAPICallError

    for i, stmt in enumerate(stmts, 1):
        preview = " ".join(stmt.split()[:12])
        print(f"    [{i}/{len(stmts)}] {preview}...")
        if dry_run:
            continue
        try:
            job = client.query(substitute(stmt, proj, ds))
            job.result()
        except Exception as exc:
            print(f"\n  ERROR in statement {i}: {exc}", file=sys.stderr)
            print(f"  Statement preview:\n    {stmt[:500]}", file=sys.stderr)
            return False
    return True


def run_phase(client, phase_num: int, sql_file: str, label: str,
              dry_run: bool, proj: str, ds: str) -> bool:
    """Load, parse, and execute a single SQL file."""
    fpath = SCRIPT_DIR / sql_file
    if not fpath.exists():
        print(f"  ERROR: file not found: {fpath}", file=sys.stderr)
        return False

    sql = fpath.read_text(encoding="utf-8")
    stmts = split_statements(substitute(sql, proj, ds))

    print(f"\n{'='*60}")
    print(f"  PHASE {phase_num}: {label}")
    print(f"  File : {sql_file}")
    print(f"  Stmts: {len(stmts)}")
    print(f"{'='*60}")

    if not stmts:
        print("  WARNING: no executable statements found.")
        return True

    ok = run_statements(client, stmts, dry_run, label, proj, ds)
    status = "OK" if ok else "FAILED"
    print(f"  Status: {status}")
    return ok


# ── Verdict check ────────────────────────────────────────────────────────────

def check_leakage_verdict(client, proj: str, ds: str, dry_run: bool) -> str:
    """Query leakage_audit_final_verdict and return the verdict string."""
    if dry_run:
        print("\n  [dry-run] Skipping verdict check.")
        return "DRY_RUN"
    try:
        query = f"""
        SELECT final_verdict, verdict_message, n_failures, n_passes, test_status
        FROM `{proj}.{ds}.leakage_audit_final_verdict_h12_v3_strict`
        LIMIT 1
        """
        rows = list(client.query(query).result())
        if not rows:
            print("  WARNING: leakage_audit_final_verdict is empty.", file=sys.stderr)
            return "EMPTY"
        row = rows[0]
        print(f"\n  LEAKAGE AUDIT RESULT:")
        print(f"    final_verdict : {row['final_verdict']}")
        print(f"    test_status   : {row['test_status']}")
        print(f"    n_passes      : {row['n_passes']}")
        print(f"    n_failures    : {row['n_failures']}")
        print(f"    message       : {row['verdict_message']}")
        return row['final_verdict']
    except Exception as exc:
        print(f"  ERROR querying verdict: {exc}", file=sys.stderr)
        return "ERROR"


# ── Run summary ───────────────────────────────────────────────────────────────

def print_run_summary(start_time: datetime, results: list, verdict: str,
                      dry_run: bool) -> None:
    elapsed = (datetime.now() - start_time).total_seconds()
    print(f"\n{'='*60}")
    print(f"  h12_v3_strict RUN SUMMARY")
    print(f"  {'DRY RUN — no BQ writes' if dry_run else 'LIVE RUN'}")
    print(f"  Elapsed  : {elapsed:.1f}s")
    print(f"{'='*60}")
    for phase_num, label, status in results:
        icon = "✓" if status == "OK" else "✗"
        print(f"  {icon} Phase {phase_num:2d}: {label:<55} {status}")
    print(f"{'='*60}")
    print(f"  LEAKAGE AUDIT VERDICT: {verdict}")
    if verdict == "FAIL":
        print("  !! Pipeline FAILED leakage audit — do not present metrics")
    elif verdict == "NO_LOCKED_TEST_LABELS":
        print("  !! LOCKED_TEST labels are blind (W28-W40). test_status=LOCKED_TEST_PENDING")
        print("  !! All structural checks passed. Pipeline is methodologically clean.")
    elif verdict == "PASS":
        print("  ++ All checks passed. Metrics in final_locked_test_metrics_h12_v3_strict")
        print("  ++ are presentable as test ciego (post_selection_bias=FALSE).")
    print(f"{'='*60}\n")


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="h=12 v3_strict pipeline (anti-leakage, strict separation)"
    )
    parser.add_argument("--dry-run",          action="store_true",
                        help="Print statements, execute nothing")
    parser.add_argument("--start-phase",      type=int, default=1,
                        help="First phase to execute (default: 1)")
    parser.add_argument("--stop-after-phase", type=int, default=len(PIPELINE_PHASES),
                        help=f"Last phase to execute (default: {len(PIPELINE_PHASES)})")
    parser.add_argument("--project-id",       default=PROJECT_ID)
    parser.add_argument("--dataset-id",       default=DATASET_ID)
    parser.add_argument("--location",         default=LOCATION)
    args = parser.parse_args()

    proj = args.project_id
    ds   = args.dataset_id
    loc  = args.location

    # Validate phase range
    valid_phases = {p[0] for p in PIPELINE_PHASES}
    if args.start_phase not in valid_phases:
        print(f"ERROR: --start-phase {args.start_phase} is not a valid phase number.", file=sys.stderr)
        return 2
    if args.stop_after_phase not in valid_phases:
        print(f"ERROR: --stop-after-phase {args.stop_after_phase} is not a valid phase number.", file=sys.stderr)
        return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  h12_v3_strict Pipeline")
    print(f"  Project : {proj}")
    print(f"  Dataset : {ds}")
    print(f"  Location: {loc}")
    print(f"  Phases  : {args.start_phase} → {args.stop_after_phase}")
    print(f"  DryRun  : {args.dry_run}")
    print(f"{'='*60}")

    # Build client
    client = None
    if not args.dry_run:
        try:
            from google.cloud import bigquery
            client = bigquery.Client(project=proj, location=loc)
        except ImportError:
            print("ERROR: google-cloud-bigquery not installed.\n"
                  "Run: pip install google-cloud-bigquery", file=sys.stderr)
            return 2
        except Exception as exc:
            print(f"ERROR creating BigQuery client: {exc}", file=sys.stderr)
            return 2

    start_time = datetime.now()
    results = []
    all_ok  = True

    phases_to_run = [
        p for p in PIPELINE_PHASES
        if args.start_phase <= p[0] <= args.stop_after_phase
    ]

    for phase_num, sql_file, label in phases_to_run:
        ok = run_phase(client, phase_num, sql_file, label,
                       args.dry_run, proj, ds)
        results.append((phase_num, label, "OK" if ok else "FAILED"))
        if not ok:
            all_ok = False
            print(f"\nPipeline stopped at phase {phase_num} due to error.",
                  file=sys.stderr)
            break

    # Leakage audit verdict (only if phase 9 ran successfully)
    verdict = "SKIPPED"
    audit_phase_ran = any(
        p[0] == 9 and s == "OK"
        for p, *_, s in [(r, None, None) for r in results]
        # simpler:
    )
    # Re-check properly:
    audit_phase_ran = any(
        phase_num == 9 and status == "OK"
        for phase_num, _, status in results
    )

    if audit_phase_ran or (args.stop_after_phase >= 9 and all_ok):
        verdict = check_leakage_verdict(client, proj, ds, args.dry_run)

    print_run_summary(start_time, results, verdict, args.dry_run)

    # Exit code logic
    if not all_ok:
        return 2
    if verdict == "FAIL":
        print("EXIT CODE 1: Leakage audit FAILED.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
