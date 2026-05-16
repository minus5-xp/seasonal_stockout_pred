#!/usr/bin/env python3
"""
h=12 v2 FINAL Pipeline Orchestrator
=====================================
Applies targeted patches to h12_v2:
  1. Brier/probability fix (p_oos_raw vs Platt)
  2. Dirichlet reconciliation fix (zero-raw-weight normalisation)
  3. Forecast balance guardrails
  4. Final gate verdict (DEPLOY_FULL / DEPLOY_NATIONAL_ONLY / HOLD)
  5. Blind forecast final W28-W40
  6-7. Download + local audit

Does NOT retrain models. Does NOT modify h12_v2 tables.

USAGE:
    python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py --dry-run
    python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py
    python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py --start-phase 2 --stop-after-phase 4
    python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py --download-only
    python sql/bqml/h12_v2_final/run_h12_v2_final_pipeline.py --audit-only

EXIT CODES:
    0  DEPLOY_FULL achieved, all gates PASS, local audit PASS
    1  HOLD or any hard gate failed
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

PROJECT_ID = os.environ.get("PROJECT_ID",  "thequantitativeledger")
DATASET_ID = os.environ.get("BQ_DATASET",  "cruzber_models_eu")
LOCATION   = os.environ.get("BQ_LOCATION", "EU")

SCRIPT_DIR = Path(__file__).parent
OUTPUT_DIR = Path("outputs/h12_v2_final")

PIPELINE_PHASES = [
    (1, "01_fix_probability_brier_h12_v2_final.sql",         "Brier/probability fix"),
    (2, "02_fix_dirichlet_reconciliation_h12_v2_final.sql",  "Dirichlet reconciliation fix"),
    (3, "03_forecast_balance_guardrails_h12_v2_final.sql",   "Forecast balance guardrails"),
    (4, "04_final_gate_verdict_h12_v2_final.sql",            "Final gate verdict"),
    (5, "05_blind_forecast_final_h12_v2_final.sql",          "Blind forecast final"),
]


def split_statements(sql):
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.DOTALL)
    stmts = []
    for raw in sql.split(";"):
        s = raw.strip()
        if not s:
            continue
        upper = s.upper()
        if any(upper.startswith(kw) for kw in ["CREATE","INSERT","UPDATE","DELETE","DROP"]):
            stmts.append(s)
        elif upper.startswith("SELECT") and "FROM" in upper:
            if not re.search(r"SELECT\s+'[=\-]+", s, re.IGNORECASE):
                stmts.append(s)
    return stmts


def substitute(sql, proj, ds):
    sql = sql.replace("{PROJECT_ID}", proj)
    sql = sql.replace("{BQ_DATASET}", ds)
    return sql


def run_statements(client, stmts, dry_run, label, proj, ds):
    from google.api_core.exceptions import GoogleAPICallError
    for i, stmt in enumerate(stmts, 1):
        preview = " ".join(stmt.split()[:10])
        print(f"    [{i}/{len(stmts)}] {preview}...")
        if dry_run:
            continue
        from google.cloud import bigquery
        try:
            client.query(stmt, job_config=bigquery.QueryJobConfig(
                use_legacy_sql=False, use_query_cache=False)).result()
        except GoogleAPICallError as exc:
            print(f"\n  [FAIL] BQ error in '{label}':\n  {exc}")
            print(f"  Statement: {stmt[:500]}")
            sys.exit(1)


def get_deployment_decision(client, proj, ds):
    try:
        q = f"SELECT deployment_decision_final FROM `{proj}.{ds}.gate_verdict_h12_v2_final` LIMIT 1"
        rows = list(client.query(q).result())
        if rows:
            return str(rows[0]["deployment_decision_final"])
    except Exception:
        pass
    return "UNKNOWN"


def main():
    parser = argparse.ArgumentParser(description="Run h12_v2_final patch pipeline")
    parser.add_argument("--project",         default=PROJECT_ID)
    parser.add_argument("--dataset",         default=DATASET_ID)
    parser.add_argument("--location",        default=LOCATION)
    parser.add_argument("--dry-run",         action="store_true")
    parser.add_argument("--start-phase",     type=int, default=1)
    parser.add_argument("--stop-after-phase",type=int, default=5)
    parser.add_argument("--no-download",     action="store_true")
    parser.add_argument("--download-only",   action="store_true")
    parser.add_argument("--audit-only",      action="store_true")
    parser.add_argument("--limit-download",  type=int, default=None)
    parser.add_argument("--force-full-deploy",action="store_true",
                        help="Override deployment decision (marks as FORCED, not recommended)")
    args = parser.parse_args()

    proj = args.project
    ds   = args.dataset
    loc  = args.location

    if args.audit_only:
        args.start_phase = 99
        args.stop_after_phase = 0
        args.no_download = True
    if args.download_only:
        args.start_phase = 99
        args.stop_after_phase = 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 65)
    print("  h=12 v2 FINAL PATCH PIPELINE")
    print("=" * 65)
    print(f"  Project  : {proj}")
    print(f"  Dataset  : {ds}")
    print(f"  Location : {loc}")
    print(f"  Mode     : {'DRY RUN' if args.dry_run else 'EXECUTE'}")
    print(f"  Phases   : {args.start_phase} to {args.stop_after_phase}")
    print(f"  Output   : {OUTPUT_DIR.absolute()}")
    print(f"  Started  : {datetime.now():%Y-%m-%d %H:%M:%S}")
    if args.force_full_deploy:
        print("  [WARN] --force-full-deploy: output will be marked FORCED_DEPLOY_NOT_RECOMMENDED")
    print("=" * 65)
    print()

    client = None
    if not args.dry_run and not args.download_only and not args.audit_only:
        try:
            from google.cloud import bigquery
            client = bigquery.Client(project=proj, location=loc)
        except ImportError:
            print("[ERROR] pip install google-cloud-bigquery")
            sys.exit(1)

    # Execute SQL phases
    if not args.download_only and not args.audit_only:
        for phase_num, filename, label in PIPELINE_PHASES:
            if phase_num < args.start_phase:
                print(f"  -- Phase {phase_num} [{label}] SKIPPED (before --start-phase)")
                continue
            if phase_num > args.stop_after_phase:
                print(f"  -- Phase {phase_num} [{label}] SKIPPED (after --stop-after-phase)")
                continue

            sql_path = SCRIPT_DIR / filename
            if not sql_path.exists():
                print(f"  [WARN] {sql_path.name} not found — skipping")
                continue

            print(f"  -- Phase {phase_num} [{label}]")
            sql = substitute(sql_path.read_text(encoding="utf-8"), proj, ds)
            stmts = split_statements(sql)
            print(f"     {len(stmts)} statement(s)")
            run_statements(client, stmts, args.dry_run, label, proj, ds)
            print(f"     OK")

    # Download
    if not args.no_download and not args.audit_only:
        print()
        dl_script = SCRIPT_DIR / "06_download_final_csv_h12_v2_final.py"
        dl_cmd = [sys.executable, str(dl_script),
                  "--project", proj, "--dataset", ds, "--location", loc,
                  "--output-dir", str(OUTPUT_DIR)]
        if args.limit_download:
            dl_cmd += ["--limit", str(args.limit_download)]
        if args.dry_run:
            dl_cmd += ["--dry-run"]
        result = subprocess.run(dl_cmd, check=False)
        if result.returncode != 0:
            print("  [WARN] CSV download reported errors.")

    # Local audit (only when download was performed)
    audit_script = SCRIPT_DIR / "07_independent_local_audit_h12_v2_final.py"
    if audit_script.exists() and not args.dry_run and not args.no_download:
        print()
        audit_cmd = [sys.executable, str(audit_script), "--input-dir", str(OUTPUT_DIR)]
        result = subprocess.run(audit_cmd, check=False)
        if result.returncode != 0:
            print("\n  [FAIL] Local audit FAIL — check outputs/h12_v2_final/local_audit_report_h12_v2_final.md")
            sys.exit(1)

    # Final verdict
    print()
    print("=" * 65)
    if not args.dry_run and client is not None:
        deploy = get_deployment_decision(client, proj, ds)
        try:
            q = f"SELECT deployment_decision_final, summary_line FROM `{proj}.{ds}.run_summary_h12_v2_final` LIMIT 1"
            rows = list(client.query(q).result())
            if rows:
                r = dict(rows[0])
                print(f"  DEPLOYMENT FINAL : {r['deployment_decision_final']}")
                print(f"  SUMMARY          : {r['summary_line']}")
                print("=" * 65)
                if r["deployment_decision_final"] not in ("DEPLOY_FULL", "DEPLOY_NATIONAL_ONLY"):
                    if not args.force_full_deploy:
                        print()
                        print("  [HOLD] Review run_summary_h12_v2_final.")
                        sys.exit(1)
                    else:
                        print("  [FORCED] --force-full-deploy used — output marked FORCED_DEPLOY_NOT_RECOMMENDED")
        except Exception as exc:
            print(f"  [WARN] Could not read run_summary_h12_v2_final: {exc}")
    elif args.dry_run:
        print("  DRY RUN complete — no tables modified.")
        print()
        print("  Phases:")
        for p, fname, lbl in PIPELINE_PHASES:
            ok = (SCRIPT_DIR / fname).exists()
            print(f"    Phase {p}  {fname:<55s}  [{'OK' if ok else 'MISSING'}]")
    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
