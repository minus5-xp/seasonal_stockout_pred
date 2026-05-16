#!/usr/bin/env python3
"""
07_local_csv_download_h12_v2.py
================================
Downloads h12_v2 BigQuery tables to local CSV files.
Uses chunked streaming to avoid loading large tables into memory.

USAGE:
    # Download all tables
    python sql/bqml/h12_v2/07_local_csv_download_h12_v2.py

    # With explicit args
    python sql/bqml/h12_v2/07_local_csv_download_h12_v2.py \\
      --project thequantitativeledger \\
      --dataset cruzber_models_eu \\
      --location EU \\
      --output-dir outputs/h12_v2

    # Dry run (list tables only)
    python sql/bqml/h12_v2/07_local_csv_download_h12_v2.py --dry-run

    # Download single table
    python sql/bqml/h12_v2/07_local_csv_download_h12_v2.py --only forecast_national_h12_v2

    # Limit rows for testing
    python sql/bqml/h12_v2/07_local_csv_download_h12_v2.py --limit 1000
"""

import argparse
import csv
import os
import sys
from datetime import datetime
from pathlib import Path


# ---- defaults ----------------------------------------------------------------
DEFAULT_PROJECT  = os.environ.get("PROJECT_ID",    "thequantitativeledger")
DEFAULT_DATASET  = os.environ.get("BQ_DATASET",    "cruzber_models_eu")
DEFAULT_LOCATION = os.environ.get("BQ_LOCATION",   "EU")
DEFAULT_OUTPUT   = "outputs/h12_v2"
PAGE_SIZE        = 50_000


# ---- table registry ----------------------------------------------------------
# (table_name, mandatory, description)
MANDATORY_TABLES = [
    ("forecast_national_h12_v2",              True,  "National forecast (all splits)"),
    ("forecast_alerts_top100_h12_v2",         True,  "Top-100 alerts (all VAL)"),
    ("forecast_scorecard_h12_v2",             True,  "Scorecard / gate summary"),
    ("gate_verdict_h12_v2",                   True,  "Gate verdict"),
]

OPTIONAL_TABLES = [
    ("forecast_provincial_dirichlet_h12_v2",  False, "Provincial forecast (Dirichlet)"),
    ("provincial_allocation_base_h12_v2",     False, "Dirichlet allocation base"),
    ("dirichlet_reconciliation_check_h12_v2", False, "Reconciliation check"),
    ("alerts_top100_h12_v2",                  False, "Top-100 alerts (gate eval)"),
    ("run_summary_h12_v2",                    False, "Run summary"),
]

BLIND_TABLES = [
    ("blind_forecast_national_w28_w40_h12_v2",    False, "Blind national forecast W28-W40"),
    ("blind_forecast_provincial_w28_w40_h12_v2",  False, "Blind provincial forecast W28-W40"),
    ("blind_alerts_top100_w28_w40_h12_v2",        False, "Blind alerts W28-W40"),
    ("blind_leakage_check_h12_v2",                False, "Blind leakage check"),
]

ALL_TABLES = MANDATORY_TABLES + OPTIONAL_TABLES + BLIND_TABLES


# ---- helpers -----------------------------------------------------------------

def get_deployment_decision(client, project: str, dataset: str) -> str:
    """Read deployment_decision from gate_verdict_h12_v2."""
    try:
        q = (f"SELECT deployment_decision FROM "
             f"`{project}.{dataset}.gate_verdict_h12_v2` LIMIT 1")
        rows = list(client.query(q).result())
        if rows:
            return str(rows[0]["deployment_decision"])
    except Exception as exc:  # noqa: BLE001
        print(f"  [WARN] Could not read gate_verdict_h12_v2: {exc}")
    return "UNKNOWN"


def download_table(
    client,
    project: str,
    dataset: str,
    table: str,
    out_path: Path,
    limit: int | None = None,
    dry_run: bool = False,
) -> tuple[bool, int]:
    """
    Stream-download a BQ table to a CSV file.
    Returns (success, n_rows).
    """
    limit_clause = f"LIMIT {limit}" if limit else ""
    sql = f"SELECT * FROM `{project}.{dataset}.{table}` {limit_clause}"

    if dry_run:
        print(f"  [DRY-RUN] Would download: {table} → {out_path}")
        return True, 0

    print(f"  Downloading: {table} → {out_path.name} ...", end="", flush=True)
    try:
        job = client.query(sql)
        rows_iter = job.result(page_size=PAGE_SIZE)

        n_rows = 0
        header_written = False
        with open(out_path, "w", newline="", encoding="utf-8") as f:
            writer = None
            for page in rows_iter.pages:
                for row in page:
                    row_dict = dict(row)
                    if not header_written:
                        writer = csv.DictWriter(f, fieldnames=list(row_dict.keys()))
                        writer.writeheader()
                        header_written = True
                    writer.writerow(row_dict)
                    n_rows += 1

        if not header_written:
            # Empty table — write header from schema
            schema = rows_iter.schema
            with open(out_path, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow([field.name for field in schema])

        print(f" {n_rows:,} rows")
        return True, n_rows

    except Exception as exc:  # noqa: BLE001
        print(f"\n  [FAIL] {exc}")
        return False, 0


# ---- main --------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Download h12_v2 tables to local CSV")
    parser.add_argument("--project",    default=DEFAULT_PROJECT)
    parser.add_argument("--dataset",    default=DEFAULT_DATASET)
    parser.add_argument("--location",   default=DEFAULT_LOCATION)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT,
                        help="Local directory for CSV output")
    parser.add_argument("--limit",      type=int, default=None,
                        help="Limit rows per table (for testing)")
    parser.add_argument("--only",       default=None,
                        help="Download only this table name")
    parser.add_argument("--dry-run",    action="store_true",
                        help="List what would be downloaded; no BQ calls")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 65)
    print("  h12_v2 CSV DOWNLOAD")
    print("=" * 65)
    print(f"  Project    : {args.project}")
    print(f"  Dataset    : {args.dataset}")
    print(f"  Output dir : {output_dir.absolute()}")
    print(f"  Mode       : {'DRY RUN' if args.dry_run else 'EXECUTE'}")
    if args.limit:
        print(f"  Row limit  : {args.limit}")
    if args.only:
        print(f"  Only table : {args.only}")
    print(f"  Started    : {datetime.now():%Y-%m-%d %H:%M:%S}")
    print("=" * 65)

    # BQ client
    client = None
    if not args.dry_run:
        try:
            from google.cloud import bigquery  # noqa
            client = bigquery.Client(project=args.project, location=args.location)
        except ImportError:
            print("[ERROR] google-cloud-bigquery not installed.")
            sys.exit(1)

    # Check deployment decision for blind tables
    deploy_decision = "UNKNOWN"
    if not args.dry_run:
        deploy_decision = get_deployment_decision(client, args.project, args.dataset)
        print(f"  Deploy decision: {deploy_decision}")
    print()

    # Select tables to download
    if args.only:
        tables_to_download = [(args.only, True, "User-specified")]
    else:
        tables_to_download = list(MANDATORY_TABLES) + list(OPTIONAL_TABLES)
        if deploy_decision == "DEPLOY" or args.dry_run:
            tables_to_download += list(BLIND_TABLES)
        else:
            print(f"  [INFO] Blind tables skipped (deployment_decision={deploy_decision})")
            # Write HOLD placeholder
            hold_path = output_dir / "blind_forecast_NOT_GENERATED_HOLD.csv"
            if not args.dry_run:
                with open(hold_path, "w", newline="", encoding="utf-8") as f:
                    w = csv.DictWriter(f, fieldnames=["deployment_decision", "reason", "failed_gates", "timestamp"])
                    w.writeheader()
                    try:
                        q = "SELECT deployment_decision, failed_gates FROM `{}.{}.gate_verdict_h12_v2` LIMIT 1".format(
                            args.project, args.dataset)
                        rows = list(client.query(q).result())
                        for r in rows:
                            w.writerow({
                                "deployment_decision": r["deployment_decision"],
                                "reason": "Gate(s) failed — blind forecast not approved",
                                "failed_gates": r.get("failed_gates", ""),
                                "timestamp": datetime.now().isoformat(),
                            })
                    except Exception:  # noqa: BLE001
                        w.writerow({
                            "deployment_decision": deploy_decision,
                            "reason": "Gate HOLD",
                            "failed_gates": "",
                            "timestamp": datetime.now().isoformat(),
                        })
                print(f"  Wrote HOLD placeholder: {hold_path.name}")

    # Download loop
    results = {}
    failed_mandatory = []

    for table_name, mandatory, description in tables_to_download:
        out_path = output_dir / f"{table_name}.csv"
        success, n_rows = download_table(
            client, args.project, args.dataset,
            table_name, out_path,
            limit=args.limit, dry_run=args.dry_run,
        )
        results[table_name] = (success, n_rows)
        if not success and mandatory:
            failed_mandatory.append(table_name)

    # Summary
    print()
    print("=" * 65)
    print(f"  DOWNLOAD SUMMARY  ({datetime.now():%H:%M:%S})")
    print("=" * 65)
    ok = sum(1 for s, _ in results.values() if s)
    total = len(results)
    print(f"  {ok}/{total} tables downloaded successfully")

    if failed_mandatory:
        print(f"\n  [ERROR] Missing mandatory tables: {failed_mandatory}")
        print(f"  Run the SQL pipeline first before downloading.")
        sys.exit(1)

    if not args.dry_run:
        print(f"\n  CSV files in: {output_dir.absolute()}")
        for tbl, (success, n_rows) in results.items():
            status = f"OK ({n_rows:,} rows)" if success else "FAIL"
            print(f"    {tbl:<50s}  {status}")

    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
