"""
Evaluate quantile quality for Option B.
Outputs CSV + markdown report B3_quantiles_eval.md.
"""

from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path

import pandas as pd
from google.cloud import bigquery


def build_client(project_id: str, location: str) -> bigquery.Client:
    return bigquery.Client(project=project_id, location=location)


def query_quantiles_df(client: bigquery.Client, dataset_ref: str) -> pd.DataFrame:
    sql = f"""
    SELECT
      q.week_start_date,
      q.sku_id,
      q.split,
      q.season_group,
      q.hhi_bucket,
      q.demand_uc_true,
      q.p50,
      q.p90,
      q.p95,
      u.flags.is_demand_active AS is_demand_active
    FROM `{dataset_ref}.pred_quantiles_h4` q
    LEFT JOIN `{dataset_ref}.demand_unconstrained_h4` u
      ON q.sku_id = u.sku_id
     AND q.week_start_date = u.week_start_date
    WHERE q.split = 'VAL'
    """
    return client.query(sql).to_dataframe()


def summarize(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    if df.empty:
        return pd.DataFrame(), pd.DataFrame()

    eval_df = df.copy()
    eval_df["viol_p90"] = (eval_df["demand_uc_true"] > eval_df["p90"]).astype(int)
    eval_df["viol_p95"] = (eval_df["demand_uc_true"] > eval_df["p95"]).astype(int)
    eval_df["pinball_p50"] = (eval_df["demand_uc_true"] - eval_df["p50"]).abs()
    eval_df["pinball_p90"] = (
        0.9 * (eval_df["demand_uc_true"] - eval_df["p90"]).clip(lower=0)
        + 0.1 * (eval_df["p90"] - eval_df["demand_uc_true"]).clip(lower=0)
    )
    eval_df["pinball_p95"] = (
        0.95 * (eval_df["demand_uc_true"] - eval_df["p95"]).clip(lower=0)
        + 0.05 * (eval_df["p95"] - eval_df["demand_uc_true"]).clip(lower=0)
    )
    eval_df["sharpness_p90_p50"] = (eval_df["p90"] - eval_df["p50"]).clip(lower=0)
    eval_df["sharpness_p95_p50"] = (eval_df["p95"] - eval_df["p50"]).clip(lower=0)

    by_segment = (
        eval_df.groupby(["season_group", "hhi_bucket"], dropna=False)
        .agg(
            n_obs=("sku_id", "count"),
            viol_rate_p90=("viol_p90", "mean"),
            viol_rate_p95=("viol_p95", "mean"),
            viol_rate_p90_cond=("viol_p90", lambda s: s[eval_df.loc[s.index, "is_demand_active"] == 1].mean()),
            viol_rate_p95_cond=("viol_p95", lambda s: s[eval_df.loc[s.index, "is_demand_active"] == 1].mean()),
            pinball_p50=("pinball_p50", "mean"),
            pinball_p90=("pinball_p90", "mean"),
            pinball_p95=("pinball_p95", "mean"),
            sharpness_p90_p50=("sharpness_p90_p50", "mean"),
            sharpness_p95_p50=("sharpness_p95_p50", "mean"),
        )
        .reset_index()
    )
    by_segment["deviation_p90_cond"] = (by_segment["viol_rate_p90_cond"] - 0.10).abs()
    by_segment["gate_b3_p90_cond"] = by_segment["viol_rate_p90_cond"].between(0.08, 0.12).map({True: "PASS", False: "FAIL"})

    global_summary = pd.DataFrame(
        {
            "n_obs": [len(eval_df)],
            "viol_rate_p90": [eval_df["viol_p90"].mean()],
            "viol_rate_p95": [eval_df["viol_p95"].mean()],
            "viol_rate_p90_cond": [eval_df.loc[eval_df["is_demand_active"] == 1, "viol_p90"].mean()],
            "viol_rate_p95_cond": [eval_df.loc[eval_df["is_demand_active"] == 1, "viol_p95"].mean()],
            "pinball_p50": [eval_df["pinball_p50"].mean()],
            "pinball_p90": [eval_df["pinball_p90"].mean()],
            "pinball_p95": [eval_df["pinball_p95"].mean()],
            "sharpness_p90_p50": [eval_df["sharpness_p90_p50"].mean()],
            "sharpness_p95_p50": [eval_df["sharpness_p95_p50"].mean()],
        }
    )

    return by_segment, global_summary


def write_report(out_path: Path, global_summary: pd.DataFrame, by_segment: pd.DataFrame) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    gate_fail = 0 if by_segment.empty else int((by_segment["gate_b3_p90_cond"] == "FAIL").sum())
    lines = [
        "# B3 Quantiles Evaluation",
        "",
        f"- Generated at: {ts}",
        "- Scope: VAL split over estimated unconstrained demand",
        "- Claim policy: proxy-OOS (sales-only), no true-OOS assertion",
        "",
        "## Global summary",
        "",
        global_summary.to_markdown(index=False) if not global_summary.empty else "No rows.",
        "",
        "## Segment summary (season x HHI)",
        "",
        by_segment.to_markdown(index=False) if not by_segment.empty else "No rows.",
        "",
        "## Gate B3",
        "",
        (
            "PASS: all/most segment-level P90 conditional violation rates are in [8%, 12%]."
            if gate_fail == 0
            else f"FAIL: {gate_fail} segment(s) outside [8%, 12%] for conditional P90."
        ),
    ]
    out_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate Option B quantiles")
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--dataset-id", required=True)
    parser.add_argument("--location", default="EU")
    args = parser.parse_args()

    dataset_ref = f"{args.project_id}.{args.dataset_id}"
    client = build_client(args.project_id, args.location)
    df = query_quantiles_df(client, dataset_ref)
    by_segment, global_summary = summarize(df)

    root = Path(__file__).resolve().parents[2]
    reports_dir = root / "reports"
    reports_dir.mkdir(exist_ok=True)

    by_segment.to_csv(reports_dir / "B3_quantiles_eval_segments.csv", index=False)
    global_summary.to_csv(reports_dir / "B3_quantiles_eval_global.csv", index=False)
    write_report(reports_dir / "B3_quantiles_eval.md", global_summary, by_segment)

    print("✅ Quantile evaluation artifacts written to reports/")


if __name__ == "__main__":
    main()
