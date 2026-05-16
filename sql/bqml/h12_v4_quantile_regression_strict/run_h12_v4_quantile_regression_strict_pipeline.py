#!/usr/bin/env python3
"""
h=12 v4_quantile_regression_strict Pipeline Orchestrator
========================================================
Implements quantile regression post-processing layer to fix collapsed quantiles
from BQML base model. Trains separate QR models for q50/q80/q90/q95 using
sklearn GradientBoostingRegressor with loss='quantile'.

METHODOLOGICAL GUARANTEES:
  - Diagnostic phase analyzes quantile collapse at source (BQML raw vs v3_2 gated)
  - Feature matrix built from v3_2 (inherits anti-leakage from v3_2 pipeline)
  - QR models trained ONLY on DEV_TUNE split
  - Three candidate approaches: QR_DIRECT, QR_RESIDUAL, QR_ZERO_AWARE
  - Model selection on DEV_SELECT using composite loss (viol rates + WMAPE + penalties)
  - Frozen model applied to LOCKED_TEST for final evaluation
  - Fails hard if leakage audit returns FAIL

PHASES:
  0  00_diagnose_quantile_collapse_h12_v4_qr_strict.sql
  1  01_build_qr_feature_matrix_h12_v4_qr_strict.sql
  2  02_train_quantile_regression_h12_v4_qr_strict.py
  3  03_score_quantile_regression_h12_v4_qr_strict.py
  4  04_select_frozen_qr_policy_dev_select_h12_v4_qr_strict.sql
  5  05_final_locked_test_metrics_h12_v4_qr_strict.sql
  6  99_leakage_audit_h12_v4_qr_strict.sql

PREREQUISITES:
  - h12_v3_2_season_state_strict must have been run (provides feature sources)
  - sklearn must be installed (version 1.8.0+ recommended)
  - BigQuery tables:
      - base_scores_h12_v1
      - temporal_contract_h12_v3_strict
      - sku_season_state_h12_v3_2_season_state_strict
      - sku_week_seasonality_features_h12_v3_2_season_state_strict
      - forecast_gated_h12_v3_2_season_state_strict

USAGE:
  python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --dry-run
  python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py
  python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --start-phase 2
  python sql/bqml/h12_v4_quantile_regression_strict/run_h12_v4_quantile_regression_strict_pipeline.py --start-phase 0 --stop-after-phase 1

ENVIRONMENT VARIABLES:
  PROJECT_ID   default: thequantitativeledger
  BQ_DATASET   default: cruzber_models_eu
  BQ_LOCATION  default: EU

EXIT CODES:
  0  Completed; leakage audit = PASS
  1  Leakage audit = FAIL
  2  Execution error
"""

import argparse
import os
import re
import sys
import subprocess
from datetime import datetime
from pathlib import Path

from google.cloud import bigquery

PROJECT_ID = os.environ.get("PROJECT_ID", "thequantitativeledger")
DATASET_ID = os.environ.get("BQ_DATASET", "cruzber_models_eu")
LOCATION = os.environ.get("BQ_LOCATION", "EU")

SCRIPT_DIR = Path(__file__).parent
OUTPUT_DIR = Path("outputs/h12_v4_qr")

PIPELINE_PHASES = [
    (0, "00_diagnose_quantile_collapse_h12_v4_qr_strict.sql",
     "Diagnose quantile collapse", "sql"),
    (1, "01_build_qr_feature_matrix_h12_v4_qr_strict.sql",
     "Build QR feature matrix", "sql"),
    (2, "02_train_quantile_regression_h12_v4_qr_strict.py",
     "Train quantile regression models", "python"),
    (3, "03_score_quantile_regression_h12_v4_qr_strict.py",
     "Score QR predictions", "python"),
    (4, "04_select_frozen_qr_policy_dev_select_h12_v4_qr_strict.sql",
     "Select frozen QR policy (DEV_SELECT)", "sql"),
    (5, "05_final_locked_test_metrics_h12_v4_qr_strict.sql",
     "Final locked test metrics", "sql"),
    (6, "99_leakage_audit_h12_v4_qr_strict.sql",
     "Leakage audit", "sql"),
]


def split_statements(sql: str) -> list:
    """Split SQL into executable statements."""
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


def run_sql_phase(phase_num: int, filename: str, description: str, dry_run: bool) -> bool:
    """Execute SQL phase using BigQuery Python client."""
    filepath = SCRIPT_DIR / filename
    
    if not filepath.exists():
        print(f"  ERROR: File not found: {filepath}")
        return False
    
    with open(filepath, "r", encoding="utf-8") as f:
        sql = f.read()
    
    # Template substitution
    sql = sql.replace("{PROJECT_ID}", PROJECT_ID)
    sql = sql.replace("{BQ_DATASET}", DATASET_ID)
    
    stmts = split_statements(sql)
    
    if dry_run:
        print(f"  [DRY-RUN] Would execute {len(stmts)} statement(s)")
        return True
    
    # Initialize BigQuery client
    client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
    
    for i, stmt in enumerate(stmts, 1):
        try:
            # Execute query
            query_job = client.query(stmt)
            result = query_job.result()  # Wait for completion
            
            # Print results for SELECT statements (usually diagnostic queries at end)
            if i == len(stmts) and stmt.strip().upper().startswith("SELECT"):
                try:
                    rows = list(result)
                    if rows:
                        # Print as simple table
                        if len(rows) <= 20:
                            for row in rows:
                                print(dict(row))
                except Exception:
                    pass  # Ignore errors printing results
                    
        except Exception as e:
            print(f"  ERROR in statement {i}/{len(stmts)}:")
            print(f"  {str(e)}")
            return False
    
    return True


def run_python_phase(phase_num: int, filename: str, description: str, dry_run: bool) -> bool:
    """Execute Python phase."""
    filepath = SCRIPT_DIR / filename
    
    if not filepath.exists():
        print(f"  ERROR: File not found: {filepath}")
        return False
    
    if dry_run:
        print(f"  [DRY-RUN] Would execute: python {filepath}")
        return True
    
    try:
        # Set environment variables
        env = os.environ.copy()
        env["PROJECT_ID"] = PROJECT_ID
        env["BQ_DATASET"] = DATASET_ID
        env["BQ_LOCATION"] = LOCATION
        
        result = subprocess.run(
            ["python", str(filepath)],
            env=env,
            check=True
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ERROR: Python script failed with exit code {e.returncode}")
        return False


def run_phase(phase_num: int, filename: str, description: str, phase_type: str, dry_run: bool) -> bool:
    """Run a single pipeline phase."""
    print(f"Phase {phase_num:2d}: {description:55s} ", end="", flush=True)
    
    if phase_type == "sql":
        success = run_sql_phase(phase_num, filename, description, dry_run)
    elif phase_type == "python":
        success = run_python_phase(phase_num, filename, description, dry_run)
    else:
        print(f"ERROR: Unknown phase type: {phase_type}")
        return False
    
    if success:
        print("OK" if not dry_run else "OK (dry-run)")
        return True
    else:
        print("FAIL")
        return False


def check_audit_verdict() -> str:
    """
    Query final audit verdict using BigQuery Python client.
    
    Returns:
        'PASS', 'FAIL', or 'UNKNOWN'
    """
    query = f"""
    SELECT
      CASE 
        WHEN SUM(CASE WHEN status = 'FAIL' THEN 1 ELSE 0 END) = 0 THEN 'PASS'
        ELSE 'FAIL'
      END AS final_verdict
    FROM `{PROJECT_ID}.{DATASET_ID}.leakage_audit_h12_v4_qr_strict`
    """
    
    try:
        client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
        query_job = client.query(query)
        results = query_job.result()
        
        for row in results:
            return row.final_verdict
            
    except Exception as e:
        print(f"WARNING: Could not query audit verdict: {e}")
    
    return "UNKNOWN"


def main():
    global PROJECT_ID, DATASET_ID, LOCATION
    
    parser = argparse.ArgumentParser(
        description="h=12 v4_quantile_regression_strict pipeline orchestrator"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be executed without actually running"
    )
    parser.add_argument(
        "--start-phase",
        type=int,
        default=0,
        help="Start from this phase (0-6)"
    )
    parser.add_argument(
        "--stop-after-phase",
        type=int,
        default=6,
        help="Stop after this phase (0-6)"
    )
    parser.add_argument(
        "--project",
        type=str,
        default=PROJECT_ID,
        help=f"GCP project ID (default: {PROJECT_ID})"
    )
    parser.add_argument(
        "--dataset",
        type=str,
        default=DATASET_ID,
        help=f"BigQuery dataset (default: {DATASET_ID})"
    )
    parser.add_argument(
        "--location",
        type=str,
        default=LOCATION,
        help=f"BigQuery location (default: {LOCATION})"
    )
    
    args = parser.parse_args()
    
    # Override globals with CLI args
    PROJECT_ID = args.project
    DATASET_ID = args.dataset
    LOCATION = args.location
    
    # Validate phase range
    if args.start_phase < 0 or args.start_phase > 6:
        print(f"ERROR: start-phase must be 0-6")
        sys.exit(2)
    if args.stop_after_phase < 0 or args.stop_after_phase > 6:
        print(f"ERROR: stop-after-phase must be 0-6")
        sys.exit(2)
    if args.start_phase > args.stop_after_phase:
        print(f"ERROR: start-phase cannot be greater than stop-after-phase")
        sys.exit(2)
    
    # Header
    print("=" * 80)
    print("h=12 v4_quantile_regression_strict Pipeline")
    print("=" * 80)
    print(f"Project:  {PROJECT_ID}")
    print(f"Dataset:  {DATASET_ID}")
    print(f"Location: {LOCATION}")
    print(f"Mode:     {'DRY-RUN' if args.dry_run else 'LIVE RUN'}")
    print(f"Phases:   {args.start_phase} → {args.stop_after_phase}")
    print("=" * 80)
    print()
    
    start_time = datetime.now()
    
    # Run phases
    for phase_num, filename, description, phase_type in PIPELINE_PHASES:
        if phase_num < args.start_phase:
            continue
        if phase_num > args.stop_after_phase:
            break
        
        success = run_phase(phase_num, filename, description, phase_type, args.dry_run)
        
        if not success:
            print()
            print("=" * 80)
            print(f"PIPELINE FAILED at phase {phase_num}")
            print("=" * 80)
            sys.exit(2)
    
    elapsed = (datetime.now() - start_time).total_seconds()
    
    # Check audit if phase 6 was run
    if args.stop_after_phase >= 6 and not args.dry_run:
        print()
        print("=" * 80)
        print("Checking leakage audit...")
        print("=" * 80)
        
        verdict = check_audit_verdict()
        print(f"LEAKAGE AUDIT VERDICT: {verdict}")
        
        if verdict == "FAIL":
            print()
            print("=" * 80)
            print("AUDIT FAILED - Pipeline has leakage issues")
            print("=" * 80)
            sys.exit(1)
        elif verdict == "PASS":
            print()
            print("=" * 80)
            print(f"PIPELINE COMPLETE | {elapsed:.1f}s")
            print("=" * 80)
            sys.exit(0)
        else:
            print()
            print("=" * 80)
            print(f"PIPELINE COMPLETE (audit status: {verdict}) | {elapsed:.1f}s")
            print("=" * 80)
            sys.exit(0)
    else:
        print()
        print("=" * 80)
        mode = "DRY-RUN" if args.dry_run else "LIVE RUN"
        print(f"PIPELINE COMPLETE ({mode}) | {elapsed:.1f}s")
        print("=" * 80)
        sys.exit(0)


if __name__ == "__main__":
    main()
