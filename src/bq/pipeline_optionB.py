"""
Option B pipeline orchestrator (B0 -> B5)
Lost-sales unconstraining -> conformal quantiles -> fill-rate policy evaluation.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from src.bq.config import BQConfig
from src.bq.run_sql import SQLRunner


def run_sql_file(runner: SQLRunner, stage_name: str, sql_file: Path, dry_run: bool) -> None:
    print(f"\n{'=' * 88}\nExecuting: {sql_file.name}\n{'=' * 88}")
    result = runner.execute_sql_file(
        sql_file,
        params=None,
        dry_run=dry_run,
    )
    if not result:
        raise RuntimeError(f"Stage failed: {stage_name}")


def run_sql_stage(runner: SQLRunner, stage_name: str, sql_dir: Path, dry_run: bool) -> None:
    print(f"\n{'=' * 88}\n[{stage_name}] {sql_dir}\n{'=' * 88}")
    results = runner.execute_sql_dir(
        sql_dir,
        params=None,
        dry_run=dry_run,
        stop_on_error=True,
    )
    if not results or not all(results.values()):
        raise RuntimeError(f"Stage failed: {stage_name}")


def run_python_script(script: Path, args: list[str]) -> None:
    cmd = [sys.executable, str(script), *args]
    print(f"\n[PY] {' '.join(cmd)}")
    subprocess.run(cmd, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Option B paper pipeline (B0-B5)")
    parser.add_argument("--project-id", help="GCP project id override")
    parser.add_argument("--dataset-id", help="BigQuery dataset id override")
    parser.add_argument("--location", help="BigQuery location override")
    parser.add_argument("--skip-eval", action="store_true", help="Skip Python eval scripts")
    parser.add_argument("--dry-run", action="store_true", help="Validate SQL only")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    config = BQConfig(
        project_id=args.project_id,
        dataset_id=args.dataset_id,
        location=args.location,
    )
    project_id = str(config.project_id)
    dataset_id = str(config.dataset_id)
    location = str(config.location)
    print(f"Using dataset: {config.dataset_ref} | location={location}")

    runner = SQLRunner(config)

    # B0-B1: Features (canonical spine + proxy OOS)
    run_sql_stage(runner, "B0-B1 Features", root / "sql/bqml/features", args.dry_run)

    # B2: Unconstraining methods
    run_sql_stage(runner, "B2 Unconstraining", root / "sql/bqml/unconstraining", args.dry_run)

    # B3: Quantiles (point model + conformal + gate)
    run_sql_stage(runner, "B3 Quantiles", root / "sql/bqml/quantiles", args.dry_run)

    # B3 Python: Evaluate quantiles quality
    if not args.skip_eval and not args.dry_run:
        run_python_script(
            root / "src/eval/quantiles_eval.py",
            ["--project-id", project_id, "--dataset-id", dataset_id, "--location", location],
        )

    # B4a: Policy simulation inputs
    run_sql_file(runner, "B4 Policy Inputs", root / "sql/bqml/policy/30_b4_policy_inputs.sql", args.dry_run)

    # B4 Python: Run policy simulation
    if not args.skip_eval and not args.dry_run:
        run_python_script(
            root / "src/eval/policy_sim.py",
            ["--project-id", project_id, "--dataset-id", dataset_id, "--location", location],
        )

    # B4b: Policy gate (evaluate simulation results)
    run_sql_file(runner, "B4 Policy Gate", root / "sql/bqml/policy/31_b4_policy_gate.sql", args.dry_run)

    # B5: Final evaluation and readiness verdict
    run_sql_stage(runner, "B5 Eval", root / "sql/bqml/eval", args.dry_run)

    print("\n✅ Option B pipeline finished.")


if __name__ == "__main__":
    main()
