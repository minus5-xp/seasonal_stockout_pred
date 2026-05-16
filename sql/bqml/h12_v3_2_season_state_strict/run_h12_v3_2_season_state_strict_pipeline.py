#!/usr/bin/env python3
"""
h=12 v3_2_season_state_strict Pipeline Orchestrator
=====================================================
Extends h12_v3_strict with SKU-level seasonal state detection and
an OFF_SEASON forecast gate to correct the REST W28-W40 regime shift.

METHODOLOGICAL GUARANTEES (inherited + extended from v3_strict):
  - Seasonality features built from TRAIN+CALIB (prior years only).
  - State classification rules frozen from analysis; no LOCKED_TEST calibration.
  - OFF_SEASON gate cap derived from historical weekly stats (TRAIN+CALIB).
  - Quantile recalibration per state on DEV_TUNE only.
  - Probability mode and policy selected on DEV_SELECT only.
  - LOCKED_TEST is read-only: frozen decisions applied, no re-selection.
  - Fails hard if leakage audit returns FAIL.

PHASES:
  1  01_sku_week_seasonality_features_h12_v3_2_season_state_strict.sql
  2  02_assign_sku_season_state_h12_v3_2_season_state_strict.sql
  3  03_diagnose_season_state_distribution_h12_v3_2_season_state_strict.sql
  4  04_apply_offseason_forecast_gate_h12_v3_2_season_state_strict.sql
  5  05_quantile_recalibration_by_season_state_h12_v3_2_season_state_strict.sql
  6  06_frozen_probability_policy_by_season_state_h12_v3_2_season_state_strict.sql
  7  07_final_locked_test_metrics_h12_v3_2_season_state_strict.sql
  8  99_leakage_audit_h12_v3_2_season_state_strict.sql

PREREQUISITES:
  - h12_v3_strict must have been run (provides forecast_recalibrated_h12_v3_strict,
    temporal_contract_h12_v3_strict, frozen_policy_h12_v3_strict,
    frozen_probability_mode_h12_v3_strict).

USAGE:
  python sql/bqml/h12_v3_2_season_state_strict/run_h12_v3_2_season_state_strict_pipeline.py --dry-run
  python sql/bqml/h12_v3_2_season_state_strict/run_h12_v3_2_season_state_strict_pipeline.py
  python sql/bqml/h12_v3_2_season_state_strict/run_h12_v3_2_season_state_strict_pipeline.py --start-phase 3 --stop-after-phase 4
  python sql/bqml/h12_v3_2_season_state_strict/run_h12_v3_2_season_state_strict_pipeline.py --start-phase 8

ENVIRONMENT VARIABLES:
  PROJECT_ID   default: thequantitativeledger
  BQ_DATASET   default: cruzber_models_eu
  BQ_LOCATION  default: EU

EXIT CODES:
  0  Completed; leakage audit = PASS (or NO_LOCKED_TEST_LABELS)
  1  Leakage audit = FAIL
  2  Execution error
"""

import argparse
import os
import re
import sys
from datetime import datetime
from pathlib import Path

PROJECT_ID = os.environ.get("PROJECT_ID", "thequantitativeledger")
DATASET_ID = os.environ.get("BQ_DATASET",  "cruzber_models_eu")
LOCATION   = os.environ.get("BQ_LOCATION", "EU")

SCRIPT_DIR = Path(__file__).parent
OUTPUT_DIR = Path("outputs/h12_v3_2_season_state_strict")

PIPELINE_PHASES = [
    (1, "01_sku_week_seasonality_features_h12_v3_2_season_state_strict.sql",
     "SKU-week seasonality features"),
    (2, "02_assign_sku_season_state_h12_v3_2_season_state_strict.sql",
     "Assign sku_season_state"),
    (3, "03_diagnose_season_state_distribution_h12_v3_2_season_state_strict.sql",
     "Regime diagnostics"),
    (4, "04_apply_offseason_forecast_gate_h12_v3_2_season_state_strict.sql",
     "OFF_SEASON forecast gate"),
    (5, "05_quantile_recalibration_by_season_state_h12_v3_2_season_state_strict.sql",
     "Quantile recalibration by state (DEV_TUNE only)"),
    (6, "06_frozen_probability_policy_by_season_state_h12_v3_2_season_state_strict.sql",
     "Freeze probability mode and policy by state (DEV_SELECT only)"),
    (7, "07_final_locked_test_metrics_h12_v3_2_season_state_strict.sql",
     "Final locked test metrics"),
    (8, "99_leakage_audit_h12_v3_2_season_state_strict.sql",
     "Leakage audit"),
]


def split_statements(sql: str) -> list:
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


def substitute(sql: str, proj: str, ds: str) -> str:
    return sql.replace("{PROJECT_ID}", proj).replace("{BQ_DATASET}", ds)


def run_phase(client, phase_num: int, sql_file: str, label: str,
              dry_run: bool, proj: str, ds: str) -> bool:
    fpath = SCRIPT_DIR / sql_file
    if not fpath.exists():
        print(f"  ERROR: {fpath} not found", file=sys.stderr)
        return False

    sql   = fpath.read_text(encoding="utf-8")
    stmts = split_statements(substitute(sql, proj, ds))

    print(f"\n{'='*60}")
    print(f"  PHASE {phase_num}: {label}")
    print(f"  File : {sql_file}")
    print(f"  Stmts: {len(stmts)}")
    print(f"{'='*60}")

    if not stmts:
        print("  WARNING: no executable statements found.")
        return True

    for i, stmt in enumerate(stmts, 1):
        preview = " ".join(stmt.split()[:12])
        print(f"    [{i}/{len(stmts)}] {preview}...")
        if dry_run:
            continue
        try:
            client.query(stmt).result()
        except Exception as exc:
            print(f"\n  ERROR stmt {i}: {exc}", file=sys.stderr)
            print(f"  Statement: {stmt[:400]}", file=sys.stderr)
            return False

    print(f"  Status: OK")
    return True


def check_verdict(client, proj: str, ds: str, dry_run: bool) -> str:
    if dry_run:
        return "DRY_RUN"
    try:
        rows = list(client.query(
            f"SELECT final_verdict, verdict_message, n_failures, n_passes "
            f"FROM `{proj}.{ds}.leakage_audit_season_state_verdict_h12_v3_2_season_state_strict` "
            f"LIMIT 1"
        ).result())
        if not rows:
            return "EMPTY"
        r = rows[0]
        print(f"\n  LEAKAGE AUDIT:")
        print(f"    final_verdict : {r['final_verdict']}")
        print(f"    n_passes      : {r['n_passes']}")
        print(f"    n_failures    : {r['n_failures']}")
        print(f"    message       : {r['verdict_message']}")
        return r['final_verdict']
    except Exception as e:
        print(f"  ERROR querying verdict: {e}", file=sys.stderr)
        return "ERROR"


def print_summary(start: datetime, results: list, verdict: str, dry_run: bool):
    elapsed = (datetime.now() - start).total_seconds()
    print(f"\n{'='*60}")
    print(f"  h12_v3_2_season_state_strict RUN SUMMARY")
    print(f"  {'DRY RUN' if dry_run else 'LIVE RUN'}  |  {elapsed:.1f}s")
    print(f"{'='*60}")
    for pn, lbl, status in results:
        icon = "✓" if status == "OK" else "✗"
        print(f"  {icon} Phase {pn:2d}: {lbl:<55} {status}")
    print(f"{'='*60}")
    print(f"  LEAKAGE AUDIT VERDICT: {verdict}")
    if verdict == "FAIL":
        print("  !! FAIL — do not present metrics as test ciego")
    elif verdict in ("PASS", "NO_LOCKED_TEST_LABELS"):
        print("  ++ PASS — metrics in final_locked_test_metrics_h12_v3_2_season_state_strict")
        print("  ++ post_selection_bias=FALSE, selected_using_locked_test=FALSE")
    print(f"{'='*60}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--start-phase",       type=int, default=1)
    parser.add_argument("--stop-after-phase",  type=int, default=len(PIPELINE_PHASES))
    parser.add_argument("--project-id",        default=PROJECT_ID)
    parser.add_argument("--dataset-id",        default=DATASET_ID)
    parser.add_argument("--location",          default=LOCATION)
    args = parser.parse_args()

    proj, ds, loc = args.project_id, args.dataset_id, args.location
    valid = {p[0] for p in PIPELINE_PHASES}

    for flag, val in [("--start-phase", args.start_phase),
                      ("--stop-after-phase", args.stop_after_phase)]:
        if val not in valid:
            print(f"ERROR: {flag} {val} invalid. Valid: {sorted(valid)}", file=sys.stderr)
            return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  h12_v3_2_season_state_strict Pipeline")
    print(f"  Project : {proj}  |  Dataset: {ds}  |  Loc: {loc}")
    print(f"  Phases  : {args.start_phase} → {args.stop_after_phase}")
    print(f"  DryRun  : {args.dry_run}")
    print(f"{'='*60}")

    client = None
    if not args.dry_run:
        try:
            from google.cloud import bigquery
            client = bigquery.Client(project=proj, location=loc)
        except ImportError:
            print("ERROR: pip install google-cloud-bigquery", file=sys.stderr)
            return 2
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return 2

    start    = datetime.now()
    results  = []
    all_ok   = True
    phases   = [p for p in PIPELINE_PHASES
                if args.start_phase <= p[0] <= args.stop_after_phase]

    for phase_num, sql_file, label in phases:
        ok = run_phase(client, phase_num, sql_file, label,
                       args.dry_run, proj, ds)
        results.append((phase_num, label, "OK" if ok else "FAILED"))
        if not ok:
            all_ok = False
            print(f"\nPipeline stopped at phase {phase_num}.", file=sys.stderr)
            break

    verdict = "SKIPPED"
    audit_ran = any(pn == 8 and st == "OK" for pn, _, st in results)
    if audit_ran:
        verdict = check_verdict(client, proj, ds, args.dry_run)

    print_summary(start, results, verdict, args.dry_run)

    if not all_ok:
        return 2
    if verdict == "FAIL":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
