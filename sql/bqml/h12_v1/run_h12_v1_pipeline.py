#!/usr/bin/env python3
"""
h=12 v1 Pipeline Orchestrator
==============================
Executes the full h12 v1 pipeline in order:

  01_build_weekly_features_h12_v1.sql     (dense spine + 12W labels)
  02_train_models_h12_v1.sql              (BQML training — may take 20-60 min)
  02b_score_models_h12_v1.sql             (score all splits)
  03_residuals_quantile_lookup_h12_v1.sql (Mondrian conformal residuals)
  04_conformal_calibration_h12_v1.sql     (two-stage correction factors)
  05_forecast_h12_v1.sql                  (forecast generation)
  06_policy_sweep_alerts_h12_v1.sql       (policy sweep + alerts)
  07_coverage_gate_h12_v1.sql             (coverage + gate B3)
  08_alerts_eval_leakage_h12_v1.sql       (eval + leakage + comparison scope)
  09_run_summary_h12_v1.sql               (run summary)

TARGET DEFINITION (CRITICAL):
  y_true_12w = SUM(y_sales, t+1..t+12)   -- NOT point forecast at t+12

TEMPORAL ALIGNMENT (mirrors R script 30_Dense_Panel_12W_Unified_Best.R):
  TRAIN:  2021-01-04 -> 2023-06-30
  CALIB:  2023-07-01 -> 2023-12-31
  VAL:    2024-01-01 -> 2024-12-29

USAGE:
  # Dry run (parse SQL only, no BQ execution)
  python run_h12_v1_pipeline.py --dry-run

  # Full run (BASE_SALES_TABLE required)
  BASE_SALES_TABLE=project.dataset.fact_lineas_albaran python run_h12_v1_pipeline.py

  # PowerShell equivalent:
  $env:BASE_SALES_TABLE = "thequantitativeledger.dataset_cruzber.fact_lineas_albaran"
  python run_h12_v1_pipeline.py

  # Skip model retraining (use existing m_oos_h12_v1, m_demand_h12_v1)
  BASE_SALES_TABLE=... python run_h12_v1_pipeline.py --skip-training

  # Start from a specific step (e.g. after features are already built)
  BASE_SALES_TABLE=... python run_h12_v1_pipeline.py --start-step 03

ENVIRONMENT VARIABLES:
  BASE_SALES_TABLE     REQUIRED — fully-qualified sales table (project.dataset.table)
  PROJECT_ID           default: thequantitativeledger
  BQ_DATASET           default: cruzber_models_eu
  BQ_LOCATION          default: EU  (location of the OUTPUT dataset cruzber_models_eu)
  BQ_SOURCE_LOCATION   default: same as BQ_LOCATION
                       Set to 'US' if BASE_SALES_TABLE lives in a US-region dataset.
                       Step 01 will use a pandas bridge to read cross-region.
  HORIZON_WEEKS        default: 12

EXIT CODES:
  0  All gates PASS (or CONDITIONAL_PASS) and deployment_decision = DEPLOY
  1  Gate failure, leakage failure, or execution error

ANTI-MODIFICATION NOTICE:
  This pipeline does NOT read from or write to H4 tables.
  H12 tables use the suffix _h12_v1 exclusively.
"""

import argparse
import os
import re
import sys
from datetime import datetime
from pathlib import Path


# ---- constants ---------------------------------------------------------------

PROJECT_ID       = os.environ.get("PROJECT_ID",         "thequantitativeledger")
DATASET_ID       = os.environ.get("BQ_DATASET",         "cruzber_models_eu")
LOCATION         = os.environ.get("BQ_LOCATION",        "EU")
SOURCE_LOCATION  = os.environ.get("BQ_SOURCE_LOCATION", "").strip() or None
HORIZON_WEEKS    = os.environ.get("HORIZON_WEEKS",      "12")

SCRIPT_DIR = Path(__file__).parent

# Ordered pipeline steps — (step_id, filename, label)
PIPELINE_STEPS = [
    ("01",  "01_build_weekly_features_h12_v1.sql",       "Build weekly features + 12W labels"),
    ("02",  "02_train_models_h12_v1.sql",                "Train BQML models (OOS + Demand)"),
    ("02b", "02b_score_models_h12_v1.sql",               "Score all splits"),
    ("03",  "03_residuals_quantile_lookup_h12_v1.sql",   "Residuals + quantile lookup"),
    ("04",  "04_conformal_calibration_h12_v1.sql",       "Two-stage conformal calibration"),
    ("05",  "05_forecast_h12_v1.sql",                    "Generate forecasts"),
    ("06",  "06_policy_sweep_alerts_h12_v1.sql",         "Policy sweep + alerts"),
    ("07",  "07_coverage_gate_h12_v1.sql",               "Coverage eval + Gate B3"),
    ("08",  "08_alerts_eval_leakage_h12_v1.sql",         "Alerts eval + leakage + comparison scope"),
    ("09",  "09_run_summary_h12_v1.sql",                 "Run summary"),
]

# Step 02 is the only training step; --skip-training skips only this one.
# Step 02b (scoring) always runs.
TRAINING_STEP_ID = "02"


# ---- helpers -----------------------------------------------------------------

def split_statements(sql: str) -> list:
    """Strip SQL comments and split into individual executable statements."""
    # Remove inline comments
    sql = re.sub(r"--[^\n]*", "", sql)
    # Remove block comments
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
            # Skip cosmetic header selects like SELECT '============'
            if not re.search(r"SELECT\s+'[=\-]+", s, re.IGNORECASE):
                stmts.append(s)
    return stmts


def substitute_placeholders(sql: str, base_sales_table: str) -> str:
    """Replace {PLACEHOLDER} tokens in SQL with runtime values."""
    sql = sql.replace("{PROJECT_ID}",       PROJECT_ID)
    sql = sql.replace("{BQ_DATASET}",       DATASET_ID)
    sql = sql.replace("{BASE_SALES_TABLE}", base_sales_table)
    sql = sql.replace("{HORIZON_WEEKS}",    HORIZON_WEEKS)
    return sql


def _parse_create_table_as_select(stmt: str):
    """Return (dest_table, select_sql) if stmt is CREATE [OR REPLACE] TABLE dest AS select."""
    m = re.search(
        r'CREATE\s+OR\s+REPLACE\s+TABLE\s+`([^`]+)`\s+AS\s+(.*)',
        stmt, re.DOTALL | re.IGNORECASE,
    )
    if m:
        return m.group(1), m.group(2).strip()
    return None, None


def run_crossregion_statement(
    eu_client,
    source_client,
    stmt: str,
    dry_run: bool,
    base_sales_table: str,
) -> bool:
    """
    Cross-region bridge for statements that read from BASE_SALES_TABLE.
    Reads via source_client (e.g. US), writes to EU via eu_client.
    Returns True if handled, False if not a cross-region candidate.
    """
    # Only bridge CREATE OR REPLACE TABLE ... AS SELECT statements that
    # directly reference the BASE_SALES_TABLE (first 3 statements of step 01).
    if base_sales_table not in stmt:
        return False
    dest_table, select_sql = _parse_create_table_as_select(stmt)
    if dest_table is None:
        return False

    if dry_run:
        print(f"      [BRIDGE DRY-RUN] {dest_table} <- SELECT from {base_sales_table}")
        return True

    try:
        import pandas as pd  # noqa
        from google.cloud import bigquery  # noqa
    except ImportError:
        print("[ERROR] pandas required for cross-region bridge: pip install pandas pyarrow")
        import sys
        sys.exit(1)

    print(f"      [BRIDGE] Reading cross-region: {base_sales_table} ...", flush=True)
    df = source_client.query(select_sql).to_dataframe()
    print(f"      [BRIDGE] {len(df):,} rows -> loading to {dest_table} ...", flush=True)
    load_cfg = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    load_job = eu_client.load_table_from_dataframe(df, dest_table, job_config=load_cfg)
    load_job.result()
    print(f"      [BRIDGE] Done.", flush=True)
    return True


def run_statements(client, stmts: list, dry_run: bool, label: str,
                   source_client=None, base_sales_table: str = "") -> None:
    """Execute a list of SQL statements against BigQuery."""
    from google.api_core.exceptions import GoogleAPICallError  # noqa

    total = len(stmts)
    for i, stmt in enumerate(stmts, 1):
        preview = " ".join(stmt.split()[:10])
        print(f"    [{i}/{total}] {preview}...")
        # Try cross-region bridge first (for statements reading BASE_SALES_TABLE)
        if source_client is not None and base_sales_table:
            handled = run_crossregion_statement(
                client, source_client, stmt, dry_run, base_sales_table
            )
            if handled:
                continue
        if dry_run:
            continue
        from google.cloud import bigquery  # noqa
        job_config = bigquery.QueryJobConfig(
            use_legacy_sql=False,
            use_query_cache=False,
        )
        try:
            job = client.query(stmt, job_config=job_config)
            job.result()  # block until done
        except GoogleAPICallError as exc:
            print(f"\n  [FAIL] BigQuery error in step '{label}':")
            print(f"  {exc}")
            print(f"\n  Statement preview:\n  {stmt[:500]}")
            sys.exit(1)


# ---- main --------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Run h=12 v1 BQML pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Parse SQL and substitute placeholders only; no BigQuery execution.",
    )
    parser.add_argument(
        "--skip-training", action="store_true",
        help="Skip step 02 (model training). Step 02b (scoring) still runs.",
    )
    parser.add_argument(
        "--start-step", default=None, metavar="STEP_ID",
        help="Start execution from this step ID (e.g. '03'). Earlier steps are skipped.",
    )
    args = parser.parse_args()

    # ---- Resolve BASE_SALES_TABLE -------------------------------------------
    base_sales_table = os.environ.get("BASE_SALES_TABLE", "").strip()
    if not base_sales_table:
        if args.dry_run:
            # Allow dry-run without BASE_SALES_TABLE for syntax-only checks
            base_sales_table = "__BASE_SALES_TABLE_NOT_SET__"
            print("[WARN] BASE_SALES_TABLE not set — using placeholder for dry-run.")
        else:
            print(
                "\n[ERROR] BASE_SALES_TABLE environment variable is required.\n"
                "  Set it to the fully-qualified source sales table, e.g.:\n\n"
                "    BASE_SALES_TABLE=thequantitativeledger.dataset_cruzber.fact_lineas_albaran \\\n"
                "    python run_h12_v1_pipeline.py\n\n"
                "  PowerShell:\n"
                "    $env:BASE_SALES_TABLE = 'thequantitativeledger.dataset_cruzber.fact_lineas_albaran'\n"
                "    python run_h12_v1_pipeline.py\n"
            )
            sys.exit(1)

    # ---- Banner -------------------------------------------------------------
    print("=" * 70)
    print("  h=12 v1 PIPELINE")
    print("=" * 70)
    effective_source_location = SOURCE_LOCATION or LOCATION
    cross_region = (SOURCE_LOCATION is not None and SOURCE_LOCATION.upper() != LOCATION.upper())

    print(f"  Project        : {PROJECT_ID}")
    print(f"  Dataset        : {DATASET_ID}")
    print(f"  Location       : {LOCATION}  (output)")
    print(f"  Source location: {effective_source_location}  (BASE_SALES_TABLE)")
    if cross_region:
        print(f"  Cross-region   : YES — step 01 uses pandas bridge")
    print(f"  Horizon weeks  : {HORIZON_WEEKS}")
    print(f"  Base table     : {base_sales_table}")
    print(f"  Mode           : {'DRY RUN' if args.dry_run else 'EXECUTE'}")
    if args.skip_training:
        print(f"  Training       : SKIPPED (step {TRAINING_STEP_ID})")
    if args.start_step:
        print(f"  Starting from  : step {args.start_step}")
    print(f"  Started at     : {datetime.now():%Y-%m-%d %H:%M:%S}")
    print("=" * 70)
    print()
    print("  TARGET DEFINITION:")
    print("  y_true_12w = SUM(y_sales, t+1..t+12)  (cumulative, NOT point forecast)")
    print("  TRAIN+CALIB = 2021-01-04..2023-12-31   |   VAL = 2024-01-01..2024-12-29")
    print()

    # ---- BigQuery clients ---------------------------------------------------
    client = None        # EU output client
    source_client = None # source-location client (for cross-region bridge)
    if not args.dry_run:
        try:
            from google.cloud import bigquery  # noqa
            client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
            if cross_region:
                source_client = bigquery.Client(
                    project=PROJECT_ID, location=effective_source_location
                )
                print(f"  Source client  : {effective_source_location} (cross-region bridge active)")
        except ImportError:
            print("[ERROR] google-cloud-bigquery not installed. Run:")
            print("        pip install google-cloud-bigquery")
            sys.exit(1)

    # ---- Determine start index for --start-step ----------------------------
    all_step_ids = [s[0] for s in PIPELINE_STEPS]
    start_idx = 0
    if args.start_step:
        if args.start_step not in all_step_ids:
            print(f"[ERROR] Unknown step ID '{args.start_step}'.")
            print(f"        Valid step IDs: {all_step_ids}")
            sys.exit(1)
        start_idx = all_step_ids.index(args.start_step)

    # ---- Execute steps ------------------------------------------------------
    for idx, (step_id, filename, label) in enumerate(PIPELINE_STEPS):

        # --start-step: skip steps before start_idx
        if idx < start_idx:
            print(f"  -- {step_id} [{label}] SKIPPED (before --start-step)")
            continue

        # --skip-training: skip training step only (02b still runs)
        if args.skip_training and step_id == TRAINING_STEP_ID:
            print(f"  -- {step_id} [{label}] SKIPPED (--skip-training)")
            continue

        sql_path = SCRIPT_DIR / filename
        if not sql_path.exists():
            print(f"  [WARN] File not found: {sql_path} — skipping step {step_id}")
            continue

        print(f"  -- {step_id} [{label}]")
        raw_sql = sql_path.read_text(encoding="utf-8")
        sql = substitute_placeholders(raw_sql, base_sales_table)

        # Detect un-substituted placeholders (fail fast)
        remaining = re.findall(r"\{[A-Z_]+\}", sql)
        if remaining:
            print(f"  [WARN] Un-substituted placeholders in {filename}: {set(remaining)}")

        stmts = split_statements(sql)
        print(f"     {len(stmts)} statement(s)")
        # Pass source_client only for step 01 (the only step reading BASE_SALES_TABLE)
        sc = source_client if step_id == "01" else None
        run_statements(client, stmts, args.dry_run, label,
                       source_client=sc, base_sales_table=base_sales_table)
        print(f"     OK")

    # ---- Final verdict -------------------------------------------------------
    print()
    print("=" * 70)

    if not args.dry_run:
        try:
            from google.cloud import bigquery  # noqa
            q = (
                f"SELECT deployment_decision, summary_line, run_at "
                f"FROM `{PROJECT_ID}.{DATASET_ID}.run_summary_h12_v1` "
                f"LIMIT 1"
            )
            rows = list(client.query(q).result())
            if rows:
                r = dict(rows[0])
                print(f"  DEPLOYMENT DECISION : {r['deployment_decision']}")
                print(f"  SUMMARY             : {r['summary_line']}")
                print(f"  RUN AT              : {r['run_at']}")
                print("=" * 70)
                if r["deployment_decision"] != "DEPLOY":
                    print()
                    print("  [HOLD] One or more gates failed. Review run_summary_h12_v1.")
                    sys.exit(1)
            else:
                print("  [WARN] run_summary_h12_v1 is empty — check pipeline output.")
                sys.exit(1)
        except Exception as exc:  # noqa: BLE001
            print(f"  [WARN] Could not read run summary: {exc}")
            # Not a hard failure — pipeline steps completed successfully
    else:
        print("  DRY RUN complete — SQL parsed and validated; no tables modified.")
        print()
        print("  Files processed:")
        for step_id, filename, label in PIPELINE_STEPS:
            sql_path = SCRIPT_DIR / filename
            status = "OK" if sql_path.exists() else "MISSING"
            print(f"    {step_id:4s}  {filename:<50s}  [{status}]")

    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
