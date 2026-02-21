#!/usr/bin/env python3
"""
h=4 v4 Pipeline Orchestrator
==============================
Executes the full v4 pipeline in order:

  01_intermittent_features_h4_v4.sql
  02_train_models_h4_v4.sql             (BQML training — may take 10-30 min)
  03_residuals_quantile_lookup_h4_v4.sql
  04_conformal_calibration_h4_v4.sql
  05_forecast_h4_v4.sql
  06_policy_sweep_alerts_h4_v4.sql
  07_coverage_gate_b3_h4_v4.sql
  08_alerts_eval_gate_b4_leakage_h4_v4.sql
  09_run_summary_h4_v4.sql

USAGE:
    # Full run (conda env jupyter-ai, BQ credentials already set)
    python run_h4_v4_pipeline.py

    # Skip model retraining (use existing m_oos_h4_v4 / m_demand_h4_v4)
    python run_h4_v4_pipeline.py --skip-training

    # Dry-run (parse + validate SQL only, no BQ execution)
    python run_h4_v4_pipeline.py --dry-run

    # Include margin-ranking extension (requires KPI view access)
    python run_h4_v4_pipeline.py --enable-margin-ranking
    # or via env var:
    ENABLE_MARGIN_RANKING=1 KPI_DATASET=dataset_cruzber python run_h4_v4_pipeline.py

ENVIRONMENT:
    GCP_PROJECT            = thequantitativeledger
    BQ_DATASET             = cruzber_models_eu
    BQ_LOCATION            = EU
    ENABLE_MARGIN_RANKING  = 1   (optional; enables KPI snapshot + margin alerts)
    KPI_DATASET            = <dataset containing v_kpi_por_articulo>
                             If not set, auto-discovered from INFORMATION_SCHEMA.

EXIT CODES:
    0 : All gates PASS (or CONDITIONAL_PASS) and deployment_decision = DEPLOY
    1 : Gate failure or execution error
"""

import argparse
import os
import re
import sys
from datetime import datetime
from pathlib import Path

from google.cloud import bigquery
from google.api_core.exceptions import GoogleAPICallError

# ---- constants ---------------------------------------------------------------
PROJECT_ID = "thequantitativeledger"
DATASET_ID = "cruzber_models_eu"
LOCATION   = "EU"

SCRIPT_DIR  = Path(__file__).parent
KPI_SQL_DIR = SCRIPT_DIR.parent.parent / "kpi"   # sql/kpi/

# Ordered pipeline steps
PIPELINE_STEPS = [
    ("01",  "01_intermittent_features_h4_v4.sql",         "Intermittent features"),
    ("02",  "02_train_models_h4_v4.sql",                  "Train BQML models"),
    ("02b", "02b_score_models_h4_v4.sql",                 "Score BQML models"),
    ("03",  "03_residuals_quantile_lookup_h4_v4.sql",     "Residuals & quantile lookup"),
    ("04",  "04_conformal_calibration_h4_v4.sql",         "Two-stage conformal calibration"),
    ("05",  "05_forecast_h4_v4.sql",                      "Generate forecasts"),
    ("06",  "06_policy_sweep_alerts_h4_v4.sql",           "Policy sweep & alerts"),
    ("07",  "07_coverage_gate_b3_h4_v4.sql",              "Coverage eval & Gate B3"),
    ("08",  "08_alerts_eval_gate_b4_leakage_h4_v4.sql",   "Alerts eval, Gate B4 & leakage"),
    ("09",  "09_run_summary_h4_v4.sql",                   "Run summary"),
]

TRAINING_STEP_ID = "02"

# KPI margin-ranking extension (runs after step 09 when enabled)
KPI_STEPS = [
    ("kpi_00", "00_create_kpi_snapshot.sql",                  "KPI snapshot"),
    ("kpi_10", "10_enrich_forecast_with_kpi.sql",              "Enrich forecast with KPI"),
    ("kpi_20", "20_alerts_top100_h4_margin.sql",               "Margin-ranked alerts Top-100"),
    ("kpi_30", "30_eval_alerts_top100_h4_margin_pooled.sql",   "Evaluate margin alerts"),
]

# ---- helpers -----------------------------------------------------------------

def split_statements(sql: str) -> list[str]:
    """Strip comments and split SQL into individual statements."""
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
        # Keep CREATE / INSERT / UPDATE / DELETE / DROP / SELECT with FROM
        if any(upper.startswith(kw) for kw in
               ["CREATE", "INSERT", "UPDATE", "DELETE", "DROP"]):
            stmts.append(s)
        elif upper.startswith("SELECT") and "FROM" in upper:
            # Skip pure display headers like SELECT '=========='
            if not re.search(r"SELECT\s+'[=\-]+", s, re.IGNORECASE):
                stmts.append(s)
    return stmts


def run_kpi_snapshot_bridge(
    eu_client: bigquery.Client,
    us_client: bigquery.Client,
    sql_raw: str,
    dry_run: bool,
) -> None:
    """
    Cross-region bridge for kpi_00:
      - Source view  lives in US  (dataset_cruzber @ voltaic-tuner-475510-s4)
      - Destination table lives in EU (cruzber_models_eu @ thequantitativeledger)
    BigQuery forbids a single SQL statement that crosses regions, so we:
      1. Run the SELECT body via a US-location client → pandas DataFrame
      2. Load the DataFrame into the EU destination via the EU client
      3. Run the trailing sanity-check SELECT on the EU client
    """
    import pandas as pd  # noqa: F401 – checked at build time via requirements

    stmts = split_statements(sql_raw)
    create_stmt = stmts[0]

    # Parse:  CREATE OR REPLACE TABLE `dest` AS <select>
    m = re.search(
        r'CREATE\s+OR\s+REPLACE\s+TABLE\s+`([^`]+)`\s+AS\s+(.*)',
        create_stmt, re.DOTALL | re.IGNORECASE,
    )
    if not m:
        raise RuntimeError("kpi_00 bridge: could not parse CREATE statement")

    dest_table = m.group(1)   # e.g. project.dataset.table
    select_sql = m.group(2).strip()

    if dry_run:
        print(f"    [DRY RUN] Bridge SELECT (US): {' '.join(select_sql.split()[:8])}...")
        print(f"    [DRY RUN] Destination (EU):  {dest_table}")
        return

    print(f"    [1/{len(stmts)}] Fetching KPI data via US client (pandas bridge)...")
    df = us_client.query(select_sql).to_dataframe()
    print(f"    {len(df):,} rows fetched from US source.")

    print(f"    Writing to EU table: {dest_table}")
    load_cfg = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    load_job = eu_client.load_table_from_dataframe(df, dest_table, job_config=load_cfg)
    load_job.result()
    print(f"    Load complete.")

    # Run trailing sanity-check statements with the EU client
    for idx, stmt in enumerate(stmts[1:], start=2):
        print(f"    [{idx}/{len(stmts)}] {' '.join(stmt.split()[:8])}...")
        jc = bigquery.QueryJobConfig(use_legacy_sql=False, use_query_cache=False)
        eu_client.query(stmt, job_config=jc).result()


def discover_kpi_dataset(client: bigquery.Client) -> str:
    """
    Auto-discover the dataset that contains v_kpi_por_articulo by querying the
    EU-region INFORMATION_SCHEMA.VIEWS. Returns the dataset_id string.
    Raises RuntimeError if no match (or multiple matches) is found.
    """
    q = f"""
    SELECT table_schema AS dataset_id, table_name
    FROM `{PROJECT_ID}.region-EU.INFORMATION_SCHEMA.VIEWS`
    WHERE table_name = 'v_kpi_por_articulo'
    LIMIT 10
    """
    try:
        rows = list(client.query(q).result())
    except GoogleAPICallError as exc:
        raise RuntimeError(
            f"INFORMATION_SCHEMA discovery query failed: {exc}\n"
            f"Set KPI_DATASET env var explicitly to bypass auto-discovery."
        ) from exc

    if not rows:
        raise RuntimeError(
            "v_kpi_por_articulo not found in any dataset of project "
            f"{PROJECT_ID} (region EU). Check that the view exists and "
            "the service account has INFORMATION_SCHEMA access, or set "
            "KPI_DATASET env var explicitly."
        )
    if len(rows) > 1:
        datasets = [r["dataset_id"] for r in rows]
        print(f"  [WARN] v_kpi_por_articulo found in multiple datasets: {datasets}")
        print(f"  [WARN] Using first match: {datasets[0]}. Set KPI_DATASET to override.")
    return rows[0]["dataset_id"]


def run_statements(client: bigquery.Client, stmts: list[str],
                   dry_run: bool, label: str) -> None:
    total = len(stmts)
    for i, stmt in enumerate(stmts, 1):
        preview = " ".join(stmt.split()[:8])
        print(f"    [{i}/{total}] {preview}...")
        if dry_run:
            continue
        job_config = bigquery.QueryJobConfig(
            use_legacy_sql=False,
            use_query_cache=False,
        )
        try:
            job = client.query(stmt, job_config=job_config)
            job.result()  # wait
        except GoogleAPICallError as exc:
            print(f"\n  [FAIL] BQ error in step '{label}':")
            print(f"  {exc}")
            print(f"\n  Statement:\n  {stmt[:400]}")
            sys.exit(1)


# ---- main --------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run h=4 v4 pipeline")
    parser.add_argument("--dry-run",        action="store_true",
                        help="Parse SQL only; do not execute against BigQuery")
    parser.add_argument("--enable-margin-ranking", action="store_true",
                        help="Run KPI snapshot + margin-ranked alerts after main pipeline "
                             "(also enabled by ENABLE_MARGIN_RANKING=1 env var)")
    parser.add_argument("--skip-training",  action="store_true",
                        help="Skip step 02 (assume models already trained)")
    parser.add_argument("--start-step",     default=None,
                        help="Start from this step ID (e.g. '04'). Earlier steps are skipped.")
    args = parser.parse_args()

    print("=" * 70)
    print("  h=4 v4 PIPELINE")
    print("=" * 70)
    print(f"  Project  : {PROJECT_ID}")
    print(f"  Dataset  : {DATASET_ID}")
    print(f"  Location : {LOCATION}")
    print(f"  Mode     : {'DRY RUN' if args.dry_run else 'EXECUTE'}")
    if args.skip_training:
        print(f"  Training : SKIPPED (step {TRAINING_STEP_ID})")
    if args.start_step:
        print(f"  Starting : from step {args.start_step}")
    print(f"  Start    : {datetime.now():%Y-%m-%d %H:%M:%S}")
    print("=" * 70)
    print()

    # ---- env-var flags ---------------------------------------------------
    enable_margin = (
        args.enable_margin_ranking
        or os.environ.get("ENABLE_MARGIN_RANKING", "").strip() in ("1", "true", "yes")
    )
    kpi_dataset_env = os.environ.get("KPI_DATASET", "").strip() or None
    kpi_location    = os.environ.get("KPI_LOCATION", "US").strip() or "US"

    if enable_margin:
        print(f"  Margin   : ENABLED" +
              (f"  |  KPI_DATASET={kpi_dataset_env}" if kpi_dataset_env else
               "  |  KPI_DATASET=auto-discover") +
              f"  |  KPI_LOCATION={kpi_location}")

    client = bigquery.Client(project=PROJECT_ID, location=LOCATION) \
        if not args.dry_run else None

    for step_id, filename, label in PIPELINE_STEPS:
        # --start-step: skip all steps before the specified one
        if args.start_step:
            step_ids = [s[0] for s in PIPELINE_STEPS]
            try:
                start_idx = step_ids.index(args.start_step)
                current_idx = step_ids.index(step_id)
                if current_idx < start_idx:
                    print(f"  -- {step_id} [{label}] SKIPPED (before --start-step)")
                    continue
            except ValueError:
                pass  # unknown step ID — don't skip

        if args.skip_training and step_id == TRAINING_STEP_ID:
            print(f"  -- {step_id} [{label}] SKIPPED")
            continue

        sql_path = SCRIPT_DIR / filename
        if not sql_path.exists():
            print(f"  [WARN] File not found: {sql_path} — skipping")
            continue

        print(f"  -- {step_id} [{label}]")
        sql = sql_path.read_text(encoding="utf-8")
        stmts = split_statements(sql)
        print(f"     {len(stmts)} statement(s)")
        run_statements(client, stmts, args.dry_run, label)
        print(f"     OK")

    # ---- KPI margin-ranking extension -----------------------------------
    if enable_margin:
        print()
        print("=" * 70)
        print("  KPI MARGIN-RANKING EXTENSION")
        print("=" * 70)

        # Resolve KPI dataset
        kpi_dataset = kpi_dataset_env
        if kpi_dataset is None and not args.dry_run:
            print("  Discovering KPI dataset via INFORMATION_SCHEMA...")
            kpi_dataset = discover_kpi_dataset(client)
            print(f"  Found: {kpi_dataset}")
        elif kpi_dataset is None:
            kpi_dataset = "<auto-discover>"  # placeholder for dry-run

        # KPI source data may live in a different BQ region (e.g. US).
        # Use a dedicated client with KPI_LOCATION so cross-location queries work.
        kpi_client = (
            bigquery.Client(project=PROJECT_ID, location=kpi_location)
            if not args.dry_run else None
        )
        print(f"  KPI client location: {kpi_location}")

        for step_id, filename, label in KPI_STEPS:
            sql_path = KPI_SQL_DIR / filename
            if not sql_path.exists():
                print(f"  [WARN] File not found: {sql_path} — skipping")
                continue

            print(f"  -- {step_id} [{label}]")
            sql_raw = sql_path.read_text(encoding="utf-8")

            # Substitute KPI_DATASET placeholder
            sql = sql_raw.replace("@KPI_DATASET", kpi_dataset)

            if filename == "00_create_kpi_snapshot.sql":
                # Cross-region bridge: source=US, destination=EU
                run_kpi_snapshot_bridge(client, kpi_client, sql, args.dry_run)
            else:
                # All other KPI steps read/write within EU (cruzber_models_eu)
                stmts = split_statements(sql)
                print(f"     {len(stmts)} statement(s)")
                run_statements(client, stmts, args.dry_run, label)
            print(f"     OK")

        if not args.dry_run:
            # Print margin eval summary
            q_margin = f"""
            SELECT period, season_group,
                   ROUND(precision_model, 4)  AS precision_model,
                   ROUND(recall_model,    4)  AS recall_model,
                   ROUND(lift_model,      4)  AS lift_model,
                   sum_eur_at_risk_top100,
                   avg_eur_at_risk_top100
            FROM `{PROJECT_ID}.{DATASET_ID}.eval_alerts_top100_h4_margin_pooled`
            ORDER BY period DESC, season_group
            """
            print()
            print("  MARGIN EVAL SUMMARY")
            print("  " + "-" * 65)
            for r in client.query(q_margin).result():
                d = dict(r)
                print(f"  {d}")

        print()
        print("=" * 70)
        print("  Tables created in cruzber_models_eu:")
        for _, fn, lbl in KPI_STEPS:
            tbl = fn.replace(".sql", "").replace("00_create_kpi_", "kpi_") \
                    .replace("10_enrich_forecast_with_", "forecast_h4_v4_") \
                    .replace("20_", "").replace("30_", "")
            print(f"    - {tbl}   ({lbl})")

    print()
    print("=" * 70)

    if not args.dry_run:
        # Read final verdict
        q = f"""
        SELECT deployment_decision, summary_line, run_at
        FROM `{PROJECT_ID}.{DATASET_ID}.run_summary_h4_v4`
        LIMIT 1
        """
        row = list(client.query(q).result())
        if row:
            r = row[0]
            print(f"  DEPLOYMENT DECISION : {r['deployment_decision']}")
            print(f"  SUMMARY             : {r['summary_line']}")
            print(f"  RUN AT              : {r['run_at']}")
            print("=" * 70)
            if r["deployment_decision"] != "DEPLOY":
                print("  [HOLD] One or more gates failed. Check run_summary_h4_v4.")
                sys.exit(1)
        else:
            print("  [WARN] run_summary_h4_v4 is empty. Check pipeline output.")
            sys.exit(1)
    else:
        print("  DRY RUN complete — no tables modified.")

    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
