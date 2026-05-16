#!/usr/bin/env python3
"""
06_download_final_csv_h12_v2_final.py
======================================
Downloads h12_v2_final BigQuery tables to local CSV using chunked streaming.

USAGE:
    python sql/bqml/h12_v2_final/06_download_final_csv_h12_v2_final.py
    python sql/bqml/h12_v2_final/06_download_final_csv_h12_v2_final.py --dry-run
    python sql/bqml/h12_v2_final/06_download_final_csv_h12_v2_final.py --only gate_verdict_h12_v2_final
    python sql/bqml/h12_v2_final/06_download_final_csv_h12_v2_final.py --limit 1000
"""

import argparse
import csv
import os
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_PROJECT  = os.environ.get("PROJECT_ID",  "thequantitativeledger")
DEFAULT_DATASET  = os.environ.get("BQ_DATASET",  "cruzber_models_eu")
DEFAULT_LOCATION = os.environ.get("BQ_LOCATION", "EU")
DEFAULT_OUTPUT   = "outputs/h12_v2_final"
PAGE_SIZE        = 50_000

# Table registry: (name, mandatory, description)
MANDATORY = [
    ("forecast_national_h12_v2_final",               True,  "National forecast final"),
    ("forecast_provincial_dirichlet_h12_v2_final",   True,  "Provincial forecast final"),
    ("dirichlet_reconciliation_check_h12_v2_final",  True,  "Dirichlet reconciliation check"),
    ("dirichlet_reconciliation_summary_h12_v2_final",True,  "Dirichlet summary"),
    ("probability_selection_h12_v2_final",           True,  "Probability selection"),
    ("forecast_balance_guardrails_h12_v2_final",     True,  "Balance guardrails"),
    ("forecast_balance_examples_h12_v2_final",       True,  "Balance examples"),
    ("gate_verdict_h12_v2_final",                    True,  "Gate verdict final"),
    ("run_summary_h12_v2_final",                     True,  "Run summary final"),
]

BLIND_TABLES = [
    ("blind_forecast_national_w28_w40_h12_v2_final",      False, "Blind national W28-W40 final"),
    ("blind_forecast_provincial_w28_w40_h12_v2_final",    False, "Blind provincial W28-W40 final"),
    ("blind_alerts_top100_w28_w40_h12_v2_final",          False, "Blind alerts W28-W40 final"),
    ("blind_leakage_check_h12_v2_final",                  False, "Blind leakage check final"),
    ("blind_dirichlet_reconciliation_check_h12_v2_final", False, "Blind Dirichlet reconciliation final"),
]


def get_deployment_decision(client, project, dataset):
    try:
        q = (f"SELECT deployment_decision_final FROM "
             f"`{project}.{dataset}.gate_verdict_h12_v2_final` LIMIT 1")
        rows = list(client.query(q).result())
        if rows:
            return str(rows[0]["deployment_decision_final"])
    except Exception as exc:
        print(f"  [WARN] Could not read gate_verdict_h12_v2_final: {exc}")
    return "UNKNOWN"


def download_table(client, project, dataset, table, out_path, limit=None, dry_run=False):
    limit_clause = f"LIMIT {limit}" if limit else ""
    sql = f"SELECT * FROM `{project}.{dataset}.{table}` {limit_clause}"
    if dry_run:
        print(f"  [DRY-RUN] {table} → {out_path.name}")
        return True, 0
    print(f"  Downloading: {table} ...", end="", flush=True)
    try:
        rows_iter = client.query(sql).result(page_size=PAGE_SIZE)
        n = 0
        header_written = False
        with open(out_path, "w", newline="", encoding="utf-8") as f:
            writer = None
            for page in rows_iter.pages:
                for row in page:
                    d = dict(row)
                    if not header_written:
                        writer = csv.DictWriter(f, fieldnames=list(d.keys()))
                        writer.writeheader()
                        header_written = True
                    writer.writerow(d)
                    n += 1
        if not header_written:
            schema = rows_iter.schema
            with open(out_path, "w", newline="", encoding="utf-8") as f:
                csv.writer(f).writerow([field.name for field in schema])
        print(f" {n:,} rows")
        return True, n
    except Exception as exc:
        print(f"\n  [FAIL] {exc}")
        return False, 0


def main():
    parser = argparse.ArgumentParser(description="Download h12_v2_final tables to CSV")
    parser.add_argument("--project",    default=DEFAULT_PROJECT)
    parser.add_argument("--dataset",    default=DEFAULT_DATASET)
    parser.add_argument("--location",   default=DEFAULT_LOCATION)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT)
    parser.add_argument("--limit",      type=int, default=None)
    parser.add_argument("--only",       default=None)
    parser.add_argument("--dry-run",    action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 65)
    print("  h12_v2_final CSV DOWNLOAD")
    print("=" * 65)
    print(f"  Project : {args.project} | Dataset: {args.dataset}")
    print(f"  Output  : {output_dir.absolute()}")
    print(f"  Mode    : {'DRY RUN' if args.dry_run else 'EXECUTE'}")
    print("=" * 65)

    client = None
    if not args.dry_run:
        try:
            from google.cloud import bigquery
            client = bigquery.Client(project=args.project, location=args.location)
        except ImportError:
            print("[ERROR] pip install google-cloud-bigquery")
            sys.exit(1)

    deploy = "UNKNOWN"
    if not args.dry_run:
        deploy = get_deployment_decision(client, args.project, args.dataset)
    print(f"  Deployment decision final: {deploy}")

    if args.only:
        tables = [(args.only, True, "User-specified")]
    else:
        tables = list(MANDATORY)
        if deploy == "DEPLOY_FULL" or args.dry_run:
            tables += list(BLIND_TABLES)
        else:
            hold_path = output_dir / "blind_forecast_NOT_APPROVED_h12_v2_final.csv"
            if not args.dry_run:
                with open(hold_path, "w", newline="", encoding="utf-8") as f:
                    w = csv.DictWriter(f, fieldnames=["deployment_decision_final","failed_gates_final","reason","run_timestamp"])
                    w.writeheader()
                    try:
                        q = f"SELECT deployment_decision_final, failed_gates_final FROM `{args.project}.{args.dataset}.gate_verdict_h12_v2_final` LIMIT 1"
                        for r in client.query(q).result():
                            w.writerow({"deployment_decision_final": r["deployment_decision_final"],
                                        "failed_gates_final": r.get("failed_gates_final",""),
                                        "reason": "Blind forecast not approved — see failed_gates_final",
                                        "run_timestamp": datetime.now().isoformat()})
                    except Exception:
                        w.writerow({"deployment_decision_final": deploy, "failed_gates_final": "",
                                    "reason": "HOLD", "run_timestamp": datetime.now().isoformat()})
                print(f"  HOLD placeholder: {hold_path.name}")

    results = {}
    failed_mandatory = []
    for name, mandatory, desc in tables:
        out_path = output_dir / f"{name}.csv"
        ok, n = download_table(client, args.project, args.dataset, name, out_path,
                               limit=args.limit, dry_run=args.dry_run)
        results[name] = (ok, n)
        if not ok and mandatory:
            failed_mandatory.append(name)

    print()
    print("=" * 65)
    ok_count = sum(1 for s, _ in results.values() if s)
    print(f"  {ok_count}/{len(results)} tables OK")
    if failed_mandatory:
        print(f"  [ERROR] Missing mandatory: {failed_mandatory}")
        sys.exit(1)
    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
