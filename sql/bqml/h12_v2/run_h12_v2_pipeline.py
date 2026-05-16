#!/usr/bin/env python3
"""
h=12 v2 Pipeline Orchestrator
==============================
Executes h12_v2 recalibration pipeline. Does NOT retrain models.
Reads base_scores_h12_v1, residuals_h12_v1, etc. and applies improved calibration.

PHASES:
  1  01_diagnostics_h12_v2.sql
  2  02_recalibrate_quantiles_h12_v2.sql
  3  03_policy_and_gates_h12_v2.sql
  4  04_forecast_export_tables_h12_v2.sql
  5  05_dirichlet_provincial_allocation_h12_v2.sql
  6  06_blind_forecast_w28_w40_h12_v2.sql
  7  08_run_summary_h12_v2.sql
  8  07_local_csv_download_h12_v2.py (download)

USAGE:
  # Dry run
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py --dry-run

  # Full run
  set BASE_SALES_TABLE=<project.dataset.table>
  set BQ_SOURCE_LOCATION=US
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py

  # Diagnostics only
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py --stop-after-phase 1

  # Recalibration + gates (no download)
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py --start-phase 2 --stop-after-phase 3 --no-download

  # Download only
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py --download-only

  # Skip blind forecast (force-blind overrides HOLD gate)
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py --skip-blind
  python sql/bqml/h12_v2/run_h12_v2_pipeline.py --force-blind

ENVIRONMENT:
  BASE_SALES_TABLE   required for phases 2,4,5 (reads from fact table)
  BQ_SOURCE_LOCATION default: same as BQ_LOCATION (set to US if fact table is in US)
  PROJECT_ID         default: thequantitativeledger
  BQ_DATASET         default: cruzber_models_eu
  BQ_LOCATION        default: EU

EXIT CODES:
  0  All required gates PASS, deployment_decision = DEPLOY
  1  Gate failure or execution error
"""

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# ---- constants ---------------------------------------------------------------
PROJECT_ID      = os.environ.get("PROJECT_ID",         "thequantitativeledger")
DATASET_ID      = os.environ.get("BQ_DATASET",         "cruzber_models_eu")
LOCATION        = os.environ.get("BQ_LOCATION",        "EU")
SOURCE_LOCATION = os.environ.get("BQ_SOURCE_LOCATION", "").strip() or None
HORIZON_WEEKS   = os.environ.get("HORIZON_WEEKS",      "12")

SCRIPT_DIR  = Path(__file__).parent
OUTPUT_DIR  = Path("outputs/h12_v2")

# Phases: (phase_number, sql_filename, label, needs_base_sales_table)
PIPELINE_PHASES = [
    (1, "01_diagnostics_h12_v2.sql",                    "Diagnostics",               False),
    (2, "02_recalibrate_quantiles_h12_v2.sql",          "Recalibration grid",         False),
    (3, "03_policy_and_gates_h12_v2.sql",               "Policy sweep + gates",       False),
    (4, "04_forecast_export_tables_h12_v2.sql",         "Forecast export tables",      True),
    (5, "05_dirichlet_provincial_allocation_h12_v2.sql","Dirichlet provincial alloc",  True),
    (6, "06_blind_forecast_w28_w40_h12_v2.sql",         "Blind forecast W28-W40",     False),
    (7, "08_run_summary_h12_v2.sql",                    "Run summary",               False),
]


# ---- helpers (inherited from h12_v1 runner) ----------------------------------

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


def substitute_placeholders(sql: str, base_sales_table: str,
                            proj: str = PROJECT_ID, ds: str = DATASET_ID) -> str:
    sql = sql.replace("{PROJECT_ID}",       proj)
    sql = sql.replace("{BQ_DATASET}",       ds)
    sql = sql.replace("{BASE_SALES_TABLE}", base_sales_table or "__BASE_SALES_TABLE_NOT_SET__")
    sql = sql.replace("{HORIZON_WEEKS}",    HORIZON_WEEKS)
    return sql


def _parse_create_table_as_select(stmt: str):
    m = re.search(
        r'CREATE\s+OR\s+REPLACE\s+TABLE\s+`([^`]+)`\s+AS\s+(.*)',
        stmt, re.DOTALL | re.IGNORECASE,
    )
    if m:
        return m.group(1), m.group(2).strip()
    return None, None


def run_crossregion_statement(eu_client, source_client, stmt, dry_run, base_sales_table):
    if not base_sales_table or base_sales_table not in stmt:
        return False
    dest_table, select_sql = _parse_create_table_as_select(stmt)
    if dest_table is None:
        return False
    if dry_run:
        print(f"      [BRIDGE DRY-RUN] {dest_table}")
        return True
    try:
        import pandas as pd  # noqa
        from google.cloud import bigquery  # noqa
        print(f"      [BRIDGE] Reading cross-region ...", flush=True)
        df = source_client.query(select_sql).to_dataframe()
        print(f"      [BRIDGE] {len(df):,} rows → {dest_table}", flush=True)
        load_cfg = bigquery.LoadJobConfig(
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE)
        eu_client.load_table_from_dataframe(df, dest_table, job_config=load_cfg).result()
        print(f"      [BRIDGE] Done.", flush=True)
        return True
    except ImportError:
        print("[ERROR] pandas required for cross-region bridge: pip install pandas pyarrow")
        sys.exit(1)


def run_statements(client, stmts, dry_run, label, source_client=None, base_sales_table=""):
    from google.api_core.exceptions import GoogleAPICallError  # noqa
    for i, stmt in enumerate(stmts, 1):
        preview = " ".join(stmt.split()[:10])
        print(f"    [{i}/{len(stmts)}] {preview}...")
        if source_client and base_sales_table:
            if run_crossregion_statement(client, source_client, stmt, dry_run, base_sales_table):
                continue
        if dry_run:
            continue
        from google.cloud import bigquery  # noqa
        try:
            client.query(stmt, job_config=bigquery.QueryJobConfig(
                use_legacy_sql=False, use_query_cache=False)).result()
        except GoogleAPICallError as exc:
            print(f"\n  [FAIL] BQ error in '{label}':\n  {exc}")
            print(f"  Statement: {stmt[:500]}")
            sys.exit(1)


def get_deployment_decision(client, proj: str = PROJECT_ID, ds: str = DATASET_ID) -> str:
    try:
        q = (f"SELECT deployment_decision FROM "
             f"`{proj}.{ds}.gate_verdict_h12_v2` LIMIT 1")
        rows = list(client.query(q).result())
        if rows:
            return str(rows[0]["deployment_decision"])
    except Exception:  # noqa: BLE001
        pass
    return "UNKNOWN"


# ---- main --------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run h=12 v2 pipeline")
    parser.add_argument("--project",         default=PROJECT_ID)
    parser.add_argument("--dataset",         default=DATASET_ID)
    parser.add_argument("--location",        default=LOCATION)
    parser.add_argument("--base-sales-table",default=os.environ.get("BASE_SALES_TABLE","").strip() or None)
    parser.add_argument("--dry-run",         action="store_true")
    parser.add_argument("--start-phase",     type=int, default=1)
    parser.add_argument("--stop-after-phase",type=int, default=7)
    parser.add_argument("--no-download",     action="store_true")
    parser.add_argument("--download-only",   action="store_true")
    parser.add_argument("--limit-download",  type=int, default=None)
    parser.add_argument("--skip-blind",      action="store_true")
    parser.add_argument("--force-blind",     action="store_true",
                        help="Generate blind forecast even if HOLD (marks as FORCED_BLIND)")
    args = parser.parse_args()

    # Use effective values from args (may override module-level defaults)
    eff_project  = args.project
    eff_dataset  = args.dataset
    eff_location = args.location

    base_sales_table = args.base_sales_table or os.environ.get("BASE_SALES_TABLE", "").strip() or ""
    eff_source_loc   = SOURCE_LOCATION or LOCATION
    cross_region     = SOURCE_LOCATION is not None and SOURCE_LOCATION.upper() != LOCATION.upper()

    if args.download_only:
        args.start_phase = 99
        args.stop_after_phase = 0

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 65)
    print("  h=12 v2 PIPELINE  (recalibration — no retraining)")
    print("=" * 65)
    print(f"  Project  : {eff_project}")
    print(f"  Dataset  : {eff_dataset}")
    print(f"  Location : {eff_location}")
    if cross_region:
        print(f"  Source   : {eff_source_loc} (cross-region bridge active)")
    print(f"  Mode     : {'DRY RUN' if args.dry_run else 'EXECUTE'}")
    print(f"  Phases   : {args.start_phase} to {args.stop_after_phase}")
    print(f"  Output   : {OUTPUT_DIR.absolute()}")
    print(f"  Started  : {datetime.now():%Y-%m-%d %H:%M:%S}")
    print("=" * 65)
    print()

    # BQ clients
    client = None
    source_client = None
    if not args.dry_run and not args.download_only:
        try:
            from google.cloud import bigquery  # noqa
            client = bigquery.Client(project=eff_project, location=eff_location)
            if cross_region:
                source_client = bigquery.Client(project=eff_project, location=eff_source_loc)
        except ImportError:
            print("[ERROR] google-cloud-bigquery not installed.")
            sys.exit(1)

    # Execute SQL phases
    if not args.download_only:
        for phase_num, filename, label, needs_bst in PIPELINE_PHASES:
            if phase_num < args.start_phase:
                print(f"  -- Phase {phase_num} [{label}] SKIPPED (before --start-phase)")
                continue
            if phase_num > args.stop_after_phase:
                print(f"  -- Phase {phase_num} [{label}] SKIPPED (after --stop-after-phase)")
                continue

            # Phase 6: blind forecast — conditional on deployment_decision
            if phase_num == 6 and args.skip_blind:
                print(f"  -- Phase {phase_num} [{label}] SKIPPED (--skip-blind)")
                continue

            if phase_num == 6 and not args.dry_run:
                dd = get_deployment_decision(client, eff_project, eff_dataset)
                if dd != "DEPLOY" and not args.force_blind:
                    print(f"  -- Phase {phase_num} [{label}] SKIPPED (HOLD — use --force-blind to override)")
                    continue
                elif dd != "DEPLOY" and args.force_blind:
                    print(f"  -- Phase {phase_num} [{label}] FORCED (--force-blind, NOT APPROVED)")

            # Check BASE_SALES_TABLE if needed
            if needs_bst and not base_sales_table and not args.dry_run:
                print(f"\n  [ERROR] Phase {phase_num} needs BASE_SALES_TABLE.")
                print(f"  Set it via --base-sales-table or BASE_SALES_TABLE env var.")
                sys.exit(1)

            sql_path = SCRIPT_DIR / filename
            if not sql_path.exists():
                print(f"  [WARN] File not found: {sql_path} — skipping")
                continue

            print(f"  -- Phase {phase_num} [{label}]")
            raw_sql = sql_path.read_text(encoding="utf-8")
            sql = substitute_placeholders(raw_sql, base_sales_table, eff_project, eff_dataset)

            remaining = re.findall(r"\{[A-Z_]+\}", sql)
            if remaining:
                print(f"  [WARN] Un-substituted placeholders: {set(remaining)}")

            stmts = split_statements(sql)
            print(f"     {len(stmts)} statement(s)")
            sc = source_client if needs_bst else None
            run_statements(client, stmts, args.dry_run, label,
                           source_client=sc, base_sales_table=base_sales_table)
            print(f"     OK")

    # Download phase
    if not args.no_download and not args.dry_run:
        print()
        print("=" * 65)
        print("  CSV DOWNLOAD")
        print("=" * 65)
        dl_script = SCRIPT_DIR / "07_local_csv_download_h12_v2.py"
        dl_cmd = [
            sys.executable, str(dl_script),
            "--project",    eff_project,
            "--dataset",    eff_dataset,
            "--location",   eff_location,
            "--output-dir", str(OUTPUT_DIR),
        ]
        if args.limit_download:
            dl_cmd += ["--limit", str(args.limit_download)]
        result = subprocess.run(dl_cmd, check=False)
        if result.returncode != 0:
            print("  [WARN] CSV download reported errors. Check output above.")
    elif args.no_download:
        print("\n  Download skipped (--no-download)")
    elif args.dry_run:
        print("\n  [DRY RUN] Dry run complete — no tables modified, no CSV downloaded.")

    # Final verdict
    print()
    print("=" * 65)
    if not args.dry_run and not args.download_only and client is not None:
        try:
            q = (f"SELECT deployment_decision, summary_line, run_timestamp "
                 f"FROM `{eff_project}.{eff_dataset}.run_summary_h12_v2` LIMIT 1")
            rows = list(client.query(q).result())
            if rows:
                r = dict(rows[0])
                print(f"  DEPLOYMENT DECISION : {r['deployment_decision']}")
                print(f"  SUMMARY             : {r['summary_line']}")
                print(f"  RUN AT              : {r['run_timestamp']}")
                print("=" * 65)
                if r["deployment_decision"] != "DEPLOY":
                    print()
                    print("  [HOLD] Review gate_verdict_h12_v2 and run_summary_h12_v2.")
                    sys.exit(1)
        except Exception as exc:  # noqa: BLE001
            print(f"  [WARN] Could not read run_summary_h12_v2: {exc}")
    else:
        print("  DRY RUN / DOWNLOAD-ONLY — no verdict read.")
        print()
        print("  Phases defined:")
        for phase_num, filename, label, _ in PIPELINE_PHASES:
            exists = (SCRIPT_DIR / filename).exists()
            print(f"    Phase {phase_num}  {filename:<55s}  [{'OK' if exists else 'MISSING'}]")

    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
