#!/usr/bin/env python3
"""
Registra un experimento/run en la tabla experiment_registry.runs

Uso:
    python src/bq/register_run.py \\
        --project voltaic-tuner-475510-s4 \\
        --dataset dataset_cruzber_eu \\
        --model m_oos_h4 \\
        --run-name "h4_baseline_audit" \\
        --label-version "y_oos_h4_v2.0_dense_spine" \\
        --split-val-start "2024-01-01" \\
        --split-val-end "2024-12-23" \\
        --auc 0.8455 \\
        --precision-at-100 0.27 \\
        --tags baseline,audit,paper

Dependencias:
    pip install google-cloud-bigquery
    
Autenticación:
    Usa ADC (Application Default Credentials):
    gcloud auth application-default login
"""

import argparse
import hashlib
import json
import uuid
from datetime import datetime
from typing import Optional, List

from google.cloud import bigquery


def generate_run_id(prefix: str = "run") -> str:
    """Generate unique run ID: timestamp + short UUID"""
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    short_uuid = str(uuid.uuid4())[:8]
    return f"{prefix}_{timestamp}_{short_uuid}"


def compute_config_hash(config_dict: dict) -> str:
    """Compute SHA256 hash of config JSON (canonical order)"""
    canonical_json = json.dumps(config_dict, sort_keys=True)
    return hashlib.sha256(canonical_json.encode()).hexdigest()[:16]


def register_run(
    project_id: str,
    dataset_id: str,
    location: str,
    model_name: str,
    run_name: Optional[str] = None,
    label_version: Optional[str] = None,
    horizon: Optional[int] = None,
    feature_view: Optional[str] = None,
    target_column: Optional[str] = None,
    split_train_start: Optional[str] = None,
    split_train_end: Optional[str] = None,
    split_calib_start: Optional[str] = None,
    split_calib_end: Optional[str] = None,
    split_val_start: Optional[str] = None,
    split_val_end: Optional[str] = None,
    code_hash: Optional[str] = None,
    data_hash: Optional[str] = None,
    config_hash: Optional[str] = None,
    auc_val: Optional[float] = None,
    precision_at_100: Optional[float] = None,
    lift_at_100: Optional[float] = None,
    brier_score_calibrated: Optional[float] = None,
    prevalence_val: Optional[float] = None,
    model_type: Optional[str] = None,
    calibration_method: Optional[str] = None,
    notes: Optional[str] = None,
    tags: Optional[List[str]] = None,
    author: Optional[str] = None,
) -> str:
    """
    Register a new run in experiment_registry.runs table
    
    Returns:
        run_id (str): Unique identifier for the registered run
    """
    client = bigquery.Client(project=project_id, location=location)
    
    # Generate run_id if not provided
    run_id = generate_run_id()
    
    # Default run_name to model_name if not provided
    if run_name is None:
        run_name = f"{model_name}_{datetime.utcnow().strftime('%Y%m%d')}"
    
    # Build row to insert
    now_iso = datetime.utcnow().isoformat()
    row_to_insert = {
        "run_id": run_id,
        "run_timestamp": now_iso,
        "run_name": run_name,
        "project_id": project_id,
        "dataset_id": dataset_id,
        "location": location,
        "model_name": model_name,
        "label_version": label_version,
        "horizon": horizon,
        "feature_view": feature_view,
        "target_column": target_column,
        "split_train_start": split_train_start,
        "split_train_end": split_train_end,
        "split_calib_start": split_calib_start,
        "split_calib_end": split_calib_end,
        "split_val_start": split_val_start,
        "split_val_end": split_val_end,
        "code_hash": code_hash,
        "data_hash": data_hash,
        "config_hash": config_hash,
        "auc_val": auc_val,
        "precision_at_100": precision_at_100,
        "lift_at_100": lift_at_100,
        "brier_score_calibrated": brier_score_calibrated,
        "prevalence_val": prevalence_val,
        "model_type": model_type,
        "calibration_method": calibration_method,
        "notes": notes,
        "tags": tags or [],
        "author": author,
        "created_at": now_iso,
    }
    
    # Remove None values
    row_to_insert = {k: v for k, v in row_to_insert.items() if v is not None}
    
    # Insert into BigQuery
    table_id = f"{project_id}.experiment_registry.runs"
    errors = client.insert_rows_json(table_id, [row_to_insert])
    
    if errors:
        raise RuntimeError(f"Failed to insert row: {errors}")
    
    print(f"✅ Run registered successfully:")
    print(f"   Run ID: {run_id}")
    print(f"   Run Name: {run_name}")
    print(f"   Model: {model_name}")
    print(f"   Project: {project_id}")
    print(f"   Dataset: {dataset_id}")
    if auc_val:
        print(f"   AUC VAL: {auc_val:.4f}")
    if precision_at_100:
        print(f"   Precision@100: {precision_at_100:.2%}")
    if tags:
        print(f"   Tags: {', '.join(tags)}")
    
    return run_id


def main():
    parser = argparse.ArgumentParser(description="Register a BQML experiment run")
    
    # Required arguments
    parser.add_argument("--project", required=True, help="GCP project ID")
    parser.add_argument("--dataset", required=True, help="BigQuery dataset ID")
    parser.add_argument("--model", required=True, help="BQML model name")
    
    # Optional metadata
    parser.add_argument("--location", default="EU", help="Dataset location (default: EU)")
    parser.add_argument("--run-name", help="Human-readable run name")
    parser.add_argument("--label-version", help="Label construction version")
    parser.add_argument("--horizon", type=int, help="Forecast horizon (weeks)")
    parser.add_argument("--feature-view", help="Feature view/table name")
    parser.add_argument("--target-column", help="Target column name")
    
    # Splits
    parser.add_argument("--split-train-start", help="TRAIN start date (YYYY-MM-DD)")
    parser.add_argument("--split-train-end", help="TRAIN end date")
    parser.add_argument("--split-calib-start", help="CALIB start date")
    parser.add_argument("--split-calib-end", help="CALIB end date")
    parser.add_argument("--split-val-start", help="VAL start date")
    parser.add_argument("--split-val-end", help="VAL end date")
    
    # Hashes
    parser.add_argument("--code-hash", help="Git commit SHA or SQL hash")
    parser.add_argument("--data-hash", help="Data fingerprint (FARM_FINGERPRINT)")
    parser.add_argument("--config-hash", help="Hyperparameters hash")
    
    # Metrics
    parser.add_argument("--auc", type=float, help="ROC-AUC on VAL split")
    parser.add_argument("--precision-at-100", type=float, help="Precision@100")
    parser.add_argument("--lift-at-100", type=float, help="Lift@100")
    parser.add_argument("--brier", type=float, help="Brier score (calibrated)")
    parser.add_argument("--prevalence", type=float, help="OOS prevalence in VAL")
    
    # Model metadata
    parser.add_argument("--model-type", help="BQML model type")
    parser.add_argument("--calibration", help="Calibration method: platt, isotonic, none")
    parser.add_argument("--notes", help="Free-text notes")
    parser.add_argument("--tags", help="Comma-separated tags: baseline,production")
    parser.add_argument("--author", help="Email or username")
    
    args = parser.parse_args()
    
    # Parse tags
    tags = args.tags.split(",") if args.tags else None
    
    # Register run
    run_id = register_run(
        project_id=args.project,
        dataset_id=args.dataset,
        location=args.location,
        model_name=args.model,
        run_name=args.run_name,
        label_version=args.label_version,
        horizon=args.horizon,
        feature_view=args.feature_view,
        target_column=args.target_column,
        split_train_start=args.split_train_start,
        split_train_end=args.split_train_end,
        split_calib_start=args.split_calib_start,
        split_calib_end=args.split_calib_end,
        split_val_start=args.split_val_start,
        split_val_end=args.split_val_end,
        code_hash=args.code_hash,
        data_hash=args.data_hash,
        config_hash=args.config_hash,
        auc_val=args.auc,
        precision_at_100=args.precision_at_100,
        lift_at_100=args.lift_at_100,
        brier_score_calibrated=args.brier,
        prevalence_val=args.prevalence,
        model_type=args.model_type,
        calibration_method=args.calibration,
        notes=args.notes,
        tags=tags,
        author=args.author,
    )
    
    print(f"\n📄 View run details:")
    print(f"   bq query --project_id={args.project} \\")
    print(f"     'SELECT * FROM experiment_registry.runs WHERE run_id=\"{run_id}\"'")


if __name__ == "__main__":
    main()
