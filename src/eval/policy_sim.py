"""
Backtest inventory policies for Option B with fill-rate constraints.
Writes CSV outputs and markdown report for B4.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd
from google.cloud import bigquery


def fetch_inputs(client: bigquery.Client, dataset_ref: str) -> pd.DataFrame:
    sql = f"""
    SELECT
      week_start_date,
      sku_id,
      season_group,
      hhi_bucket,
      demand_proxy,
      p50,
      p90,
      p95,
      demand_uc_naive,
      demand_uc_u1,
      demand_uc_u2,
      lead_time_weeks,
      beta_target
    FROM `{dataset_ref}.policy_sim_inputs_h4`
    """
    return client.query(sql).to_dataframe()


def simulate_group(group: pd.DataFrame, policy: str) -> dict:
    group = group.sort_values("week_start_date")
    inventory = 0.0
    total_demand = 0.0
    total_served = 0.0
    total_lost = 0.0
    total_hold = 0.0

    for _, row in group.iterrows():
        if policy == "P0_naive_sales":
            rop = float(row["demand_uc_naive"])
        elif policy == "P1_point_no_conformal":
            rop = float(row["p50"])
        elif policy == "P2_no_unconstraining":
            rop = float(row["p90"])
        else:
            rop = float(row["p95"] if row["beta_target"] >= 0.95 else row["p90"])

        inventory = max(inventory, rop)
        demand = max(0.0, float(row["demand_proxy"]))

        served = min(inventory, demand)
        lost = max(0.0, demand - served)
        inventory = max(0.0, inventory - served)

        total_demand += demand
        total_served += served
        total_lost += lost
        total_hold += inventory

    fill_rate = total_served / total_demand if total_demand > 0 else 1.0
    return {
        "n_periods": int(len(group)),
        "fill_rate": fill_rate,
        "lost_sales_proxy": total_lost,
        "holding_proxy": total_hold,
        "total_cost_proxy": total_lost + 0.1 * total_hold,
    }


def run_simulation(df: pd.DataFrame) -> pd.DataFrame:
    policies = ["P0_naive_sales", "P1_point_no_conformal", "P2_no_unconstraining", "P3_optionB_quantile_policy"]
    rows = []

    for policy in policies:
        for (sku_id, lt, beta), group in df.groupby(["sku_id", "lead_time_weeks", "beta_target"], dropna=False):
            metrics = simulate_group(group, policy)
            rows.append(
                {
                    "policy_name": policy,
                    "sku_id": sku_id,
                    "lead_time_weeks": int(lt),
                    "beta_target": float(beta),
                    **metrics,
                }
            )

    result = pd.DataFrame(rows)
    return result


def write_report(report_path: Path, result: pd.DataFrame) -> None:
    if result.empty:
        report_path.write_text("# B4 Policy Simulation\n\nNo rows.", encoding="utf-8")
        return

    summary = (
        result.groupby(["policy_name", "lead_time_weeks", "beta_target"], as_index=False)
        .agg(
            fill_rate=("fill_rate", "mean"),
            lost_sales_proxy=("lost_sales_proxy", "mean"),
            holding_proxy=("holding_proxy", "mean"),
            total_cost_proxy=("total_cost_proxy", "mean"),
            n_sku=("sku_id", "nunique"),
        )
        .sort_values(["beta_target", "lead_time_weeks", "policy_name"])
    )

    lines = [
        "# B4 Policy Simulation",
        "",
        "- Policies: P0 naive, P1 point, P2 no-unconstraining, P3 Option-B quantile policy",
        "- Objective: fill-rate constrained comparison under LT scenarios",
        "",
        "## Summary",
        "",
        summary.to_markdown(index=False),
        "",
        "## Gate B4",
        "",
    ]

    p3 = summary[summary["policy_name"] == "P3_optionB_quantile_policy"]
    p0 = summary[summary["policy_name"] == "P0_naive_sales"]
    if not p3.empty and not p0.empty:
        merged = p3.merge(
            p0,
            on=["lead_time_weeks", "beta_target"],
            suffixes=("_p3", "_p0"),
            how="left",
        )
        merged["improves_fill"] = merged["fill_rate_p3"] >= merged["fill_rate_p0"]
        merged["improves_lost"] = merged["lost_sales_proxy_p3"] <= merged["lost_sales_proxy_p0"]
        pass_rate = ((merged["improves_fill"] & merged["improves_lost"]).mean() if not merged.empty else 0.0)
        lines.append(f"Trade-off robust pass ratio vs naive: {pass_rate:.2%}")
        lines.append("PASS" if pass_rate >= 0.5 else "FAIL")
    else:
        lines.append("Insufficient rows to evaluate B4 gate.")

    report_path.write_text("\n".join(lines), encoding="utf-8")


def upload_results(client: bigquery.Client, dataset_ref: str, result: pd.DataFrame) -> None:
    table_id = f"{dataset_ref}.policy_sim_results_h4"
    job_config = bigquery.LoadJobConfig(write_disposition="WRITE_TRUNCATE")
    client.load_table_from_dataframe(result, table_id, job_config=job_config).result()


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Option B policy simulation")
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--dataset-id", required=True)
    parser.add_argument("--location", default="EU")
    args = parser.parse_args()

    dataset_ref = f"{args.project_id}.{args.dataset_id}"
    client = bigquery.Client(project=args.project_id, location=args.location)

    df = fetch_inputs(client, dataset_ref)
    result = run_simulation(df)

    root = Path(__file__).resolve().parents[2]
    reports_dir = root / "reports"
    reports_dir.mkdir(exist_ok=True)

    result.to_csv(reports_dir / "B4_policy_sim_results.csv", index=False)
    write_report(reports_dir / "B4_policy_simulation.md", result)
    upload_results(client, dataset_ref, result)

    print("✅ Policy simulation completed and uploaded to BigQuery")


if __name__ == "__main__":
    main()
