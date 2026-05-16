#!/usr/bin/env python3
"""
07_independent_local_audit_h12_v2_final.py
==========================================
Audits h12_v2_final CSV files locally (no BigQuery access needed).

USAGE:
    python sql/bqml/h12_v2_final/07_independent_local_audit_h12_v2_final.py
    python sql/bqml/h12_v2_final/07_independent_local_audit_h12_v2_final.py --input-dir outputs/h12_v2_final
"""

import argparse
import csv
import math
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

DEFAULT_INPUT = "outputs/h12_v2_final"
WEIGHT_TOL    = 1e-9
FORECAST_TOL  = 0.001


def read_csv(path: Path) -> list:
    if not path.exists():
        return None
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def check(condition, msg, results):
    status = "PASS" if condition else "FAIL"
    results.append((status, msg))
    return condition


def main():
    parser = argparse.ArgumentParser(description="Local audit of h12_v2_final CSVs")
    parser.add_argument("--input-dir", default=DEFAULT_INPUT)
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    results = []
    warnings = []
    all_pass = True

    print("=" * 65)
    print("  h12_v2_final LOCAL AUDIT")
    print("=" * 65)
    print(f"  Input  : {input_dir.absolute()}")
    print(f"  Started: {datetime.now():%Y-%m-%d %H:%M:%S}")
    print()

    # ---- 1. File existence checks ----
    required_files = [
        "forecast_national_h12_v2_final.csv",
        "forecast_provincial_dirichlet_h12_v2_final.csv",
        "dirichlet_reconciliation_summary_h12_v2_final.csv",
        "probability_selection_h12_v2_final.csv",
        "gate_verdict_h12_v2_final.csv",
        "run_summary_h12_v2_final.csv",
    ]
    for fname in required_files:
        path = input_dir / fname
        ok = check(path.exists() and path.stat().st_size > 0,
                   f"File exists and non-empty: {fname}", results)
        all_pass = all_pass and ok

    # ---- 2. Load key tables ----
    national = read_csv(input_dir / "forecast_national_h12_v2_final.csv")
    provincial = read_csv(input_dir / "forecast_provincial_dirichlet_h12_v2_final.csv")
    dr_summary = read_csv(input_dir / "dirichlet_reconciliation_summary_h12_v2_final.csv")
    prob_sel = read_csv(input_dir / "probability_selection_h12_v2_final.csv")
    gate = read_csv(input_dir / "gate_verdict_h12_v2_final.csv")
    summary = read_csv(input_dir / "run_summary_h12_v2_final.csv")

    # ---- 3. National forecast checks ----
    if national:
        ok = check(len(national) > 0, f"forecast_national has {len(national)} rows", results)
        all_pass = all_pass and ok

    # ---- 4. Provincial Dirichlet checks ----
    if provincial:
        ok = check(len(provincial) > 0, f"forecast_provincial has {len(provincial)} rows", results)
        all_pass = all_pass and ok

        # 4a. SUM(dirichlet_weight_final) = 1 per SKU×week
        weight_sums = defaultdict(float)
        p50_sums    = defaultdict(float)
        q90_sums    = defaultdict(float)
        q95_sums    = defaultdict(float)
        p50_nat     = {}
        q90_nat     = {}
        q95_nat     = {}

        for row in provincial:
            key = (row.get("decision_week",""), row.get("sku_id",""))
            try:
                w = float(row.get("dirichlet_weight_final", 0) or 0)
                weight_sums[key] += w
                p50_sums[key] += float(row.get("yhat_p50_12w_prov_final", 0) or 0)
                q90_sums[key] += float(row.get("q90_12w_prov_final", 0) or 0)
                q95_sums[key] += float(row.get("q95_12w_prov_final", 0) or 0)
                p50_nat[key] = float(row.get("yhat_p50_12w_national", 0) or 0)
                q90_nat[key] = float(row.get("q90_12w_national", 0) or 0)
                q95_nat[key] = float(row.get("q95_12w_national", 0) or 0)
            except (ValueError, TypeError):
                continue

        # Weight sums
        bad_weight = [(k, v) for k, v in weight_sums.items() if abs(v - 1.0) > WEIGHT_TOL]
        ok = check(len(bad_weight) == 0,
                   f"All SKU×week weight sums = 1 ± {WEIGHT_TOL} ({len(bad_weight)} violations)", results)
        all_pass = all_pass and ok
        if bad_weight[:3]:
            warnings.append(f"  Weight violation examples: {bad_weight[:3]}")

        # No duplicate (sum > 1.000001)
        duplicates = [(k, v) for k, v in weight_sums.items() if v > 1.000001]
        ok = check(len(duplicates) == 0,
                   f"No groups with sum_weight > 1.000001 ({len(duplicates)} found)", results)
        all_pass = all_pass and ok

        # P50 reconciliation
        bad_p50 = [(k, abs(p50_sums[k] - p50_nat[k]))
                   for k in p50_sums if abs(p50_sums[k] - p50_nat[k]) > FORECAST_TOL]
        ok = check(len(bad_p50) == 0,
                   f"P50 reconciliation err ≤ {FORECAST_TOL} ({len(bad_p50)} violations)", results)
        all_pass = all_pass and ok

        # Q90 reconciliation
        bad_q90 = [(k, abs(q90_sums[k] - q90_nat[k]))
                   for k in q90_sums if abs(q90_sums[k] - q90_nat[k]) > FORECAST_TOL]
        ok = check(len(bad_q90) == 0,
                   f"Q90 reconciliation err ≤ {FORECAST_TOL} ({len(bad_q90)} violations)", results)
        all_pass = all_pass and ok

    # ---- 5. Dirichlet summary check ----
    if dr_summary and len(dr_summary) > 0:
        row = dr_summary[0]
        n_fail = int(row.get("n_fail", 1))
        ok = check(n_fail == 0, f"Dirichlet n_fail = {n_fail} (must be 0)", results)
        all_pass = all_pass and ok
        ok = check(row.get("status") == "PASS",
                   f"Dirichlet summary status = {row.get('status')}", results)
        all_pass = all_pass and ok

    # ---- 6. Probability selection check ----
    if prob_sel and len(prob_sel) > 0:
        row = prob_sel[0]
        brier_gate = row.get("brier_gate_status", "UNKNOWN")
        ok = check(brier_gate in ("PASS",),
                   f"brier_gate_status = {brier_gate}", results)
        all_pass = all_pass and ok
        # If RAW was selected, this is expected to pass
        choice = row.get("selected_probability_for_reporting", "")
        results.append(("INFO", f"probability_reporting_choice = {choice}"))

    # ---- 7. Blind forecast checks ----
    blind_nat = read_csv(input_dir / "blind_forecast_national_w28_w40_h12_v2_final.csv")
    if blind_nat:
        deploy_rows = [r for r in blind_nat if r.get("forecast_type") == "BLIND_W28_W40_2024_FINAL"]
        if deploy_rows:
            # No labels exposed
            n_y_true = sum(1 for r in deploy_rows if r.get("y_true_12w","") not in ("","None","null","NULL",""))
            ok = check(n_y_true == 0, f"Blind: no y_true_12w exposed ({n_y_true} rows with value)", results)
            all_pass = all_pass and ok

            n_stockout = sum(1 for r in deploy_rows if r.get("stockout_event_12w","") not in ("","None","null","NULL",""))
            ok = check(n_stockout == 0, f"Blind: no stockout_event_12w exposed ({n_stockout})", results)
            all_pass = all_pass and ok

            # Week range
            weeks = [int(r.get("iso_week", 0)) for r in deploy_rows if r.get("iso_week","").isdigit()]
            if weeks:
                ok = check(min(weeks) >= 28 and max(weeks) <= 40,
                           f"Blind weeks: {min(weeks)}-{max(weeks)} (must be 28-40)", results)
                all_pass = all_pass and ok

            # labels_included = FALSE
            n_labels_true = sum(1 for r in deploy_rows
                                if r.get("labels_included","").lower() in ("true","1","yes"))
            ok = check(n_labels_true == 0, f"Blind: labels_included=FALSE for all rows ({n_labels_true} True)", results)
            all_pass = all_pass and ok

    # ---- 8. Gate final checks ----
    if gate and len(gate) > 0:
        row = gate[0]
        deploy = row.get("deployment_decision_final", "UNKNOWN")
        results.append(("INFO", f"deployment_decision_final = {deploy}"))

        # DEPLOY_FULL only if Dirichlet PASS
        d_gate = row.get("gate_d1_dirichlet_reconciliation", "UNKNOWN")
        b5     = row.get("gate_b5_probability", "UNKNOWN")
        if deploy == "DEPLOY_FULL":
            ok = check(d_gate == "PASS", f"DEPLOY_FULL requires D1_dirichlet=PASS (got {d_gate})", results)
            all_pass = all_pass and ok
            ok = check(b5 == "PASS", f"DEPLOY_FULL requires B5_probability=PASS (got {b5})", results)
            all_pass = all_pass and ok

    # ---- 9. Forecast balance checks ----
    guardrails = read_csv(input_dir / "forecast_balance_guardrails_h12_v2_final.csv")
    if guardrails and len(guardrails) > 0:
        row = guardrails[0]
        try:
            cap = float(row.get("q90_cap_rate", 1))
            ok = check(cap <= 0.05, f"q90_cap_rate = {cap} (must be ≤ 0.05)", results)
            all_pass = all_pass and ok
        except (ValueError, TypeError):
            pass
        try:
            over_under = float(row.get("over_under_ratio_q90", 99))
            ok = check(over_under <= 3.0, f"over_under_ratio = {over_under} (must be ≤ 3.0)", results)
            all_pass = all_pass and ok
        except (ValueError, TypeError):
            pass
        ratio_gate = row.get("ratio_gate_final", "UNKNOWN")
        ok = check("FAIL" not in ratio_gate, f"ratio_gate_final = {ratio_gate} (must not be FAIL)", results)
        all_pass = all_pass and ok

    # ---- Print results ----
    print("  AUDIT CHECKS:")
    for status, msg in results:
        icon = "✅" if status == "PASS" else ("❌" if status == "FAIL" else "ℹ️")
        print(f"  {icon} [{status}] {msg}")

    if warnings:
        print("\n  WARNINGS:")
        for w in warnings:
            print(w)

    final_status = "PASS" if all_pass else "FAIL"
    print()
    print(f"  LOCAL AUDIT STATUS: {final_status}")
    print("=" * 65)

    # Write report
    report_path = input_dir / "local_audit_report_h12_v2_final.md"
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(f"# h12_v2_final Local Audit Report\n\n")
        f.write(f"**Run**: {datetime.now():%Y-%m-%d %H:%M:%S}  \n")
        f.write(f"**Status**: {final_status}\n\n")
        f.write("## Checks\n\n")
        for status, msg in results:
            f.write(f"- [{status}] {msg}\n")
        f.write(f"\n## Result\n\n**LOCAL AUDIT STATUS: {final_status}**\n")
    print(f"  Report saved: {report_path.name}")

    # Write summary CSV
    summary_path = input_dir / "local_audit_summary_h12_v2_final.csv"
    with open(summary_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["status", "message"])
        w.writeheader()
        for status, msg in results:
            w.writerow({"status": status, "message": msg})
        w.writerow({"status": "FINAL", "message": f"LOCAL AUDIT STATUS: {final_status}"})
    print(f"  Summary CSV: {summary_path.name}")

    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
