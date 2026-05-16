#!/usr/bin/env python3
"""
STEP 03: SCORE QUANTILE REGRESSION (h=12 v4_quantile_regression_strict)
========================================================================
PURPOSE:
  Apply trained quantile regression models to DEV_SELECT and LOCKED_TEST.
  Generates predictions for all three candidate types (DIRECT, RESIDUAL, ZERO_AWARE).

ANTI-LEAKAGE:
  - Scoring on eval_split_v3 IN ('DEV_SELECT', 'LOCKED_TEST')
  - Uses models trained ONLY on DEV_TUNE (phase 02)
  - DEV_SELECT predictions used for selection (phase 04)
  - LOCKED_TEST predictions used ONLY for final evaluation (phase 05)

OUTPUT:
  Creates BigQuery table: qr_predictions_h12_v4_qr_strict
  
  Schema:
    - sku_id, decision_week, eval_split_v3
    - y_true_12w (label if available)
    - yhat_p50_base, yhat_p50_gated (from v3_2)
    - For each model_type (QR_DIRECT, QR_RESIDUAL, QR_ZERO_AWARE):
      - q50_pred, q80_pred, q90_pred, q95_pred
"""

import os
import sys
import pickle
from pathlib import Path

import numpy as np
import pandas as pd
from google.cloud import bigquery

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID = os.environ.get("PROJECT_ID", "thequantitativeledger")
DATASET_ID = os.environ.get("BQ_DATASET", "cruzber_models_eu")
LOCATION = os.environ.get("BQ_LOCATION", "EU")

MODEL_DIR = Path("outputs/h12_v4_qr")
FEATURE_TABLE = f"{PROJECT_ID}.{DATASET_ID}.qr_feature_matrix_h12_v4_qr_strict"

QUANTILES = [0.50, 0.80, 0.90, 0.95]


# ── Helper functions ────────────────────────────────────────────────────────

def load_data_from_bq(splits: list) -> pd.DataFrame:
    """Load feature matrix from BigQuery for specified splits."""
    client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
    
    splits_str = "', '".join(splits)
    query = f"""
    SELECT *
    FROM `{FEATURE_TABLE}`
    WHERE eval_split_v3 IN ('{splits_str}')
    ORDER BY sku_id, decision_week
    """
    
    print(f"Loading data for splits: {splits}")
    df = client.query(query).to_dataframe()
    print(f"  Loaded {len(df):,} rows")
    
    return df


def prepare_features_for_scoring(df: pd.DataFrame, encoders: dict, feature_names: list) -> np.ndarray:
    """
    Prepare feature matrix using saved encoders from training.
    
    Args:
        df: Raw dataframe
        encoders: Label encoders from training phase
        feature_names: Feature names in correct order
    
    Returns:
        X: Feature matrix (numpy array)
    """
    df = df.copy()
    
    # Categorical features
    categorical_features = list(encoders.keys())
    
    # Fill missing categoricals with 'UNKNOWN'
    for col in categorical_features:
        if col in df.columns:
            df[col] = df[col].fillna("UNKNOWN")
    
    # Encode using saved encoders
    for col, le in encoders.items():
        if col in df.columns:
            # Handle unseen labels by mapping to first class
            df[col] = df[col].apply(lambda x: x if x in le.classes_ else le.classes_[0])
            df[col] = le.transform(df[col].astype(str))
    
    # Fill missing numerics with 0
    for col in feature_names:
        if col not in categorical_features and col in df.columns:
            df[col] = df[col].fillna(0.0)
    
    # Select features in correct order
    X = df[feature_names].values
    
    print(f"  Features prepared: {X.shape[1]} features, {X.shape[0]} samples")
    
    return X


def load_models(model_type: str) -> dict:
    """
    Load trained models for a specific model type.
    
    Args:
        model_type: 'qr_direct', 'qr_residual', or 'qr_zero_aware'
    
    Returns:
        Dict mapping quantile label to trained model
    """
    models = {}
    
    for alpha in QUANTILES:
        q_label = f"q{int(alpha*100)}"
        model_path = MODEL_DIR / f"{model_type}_{q_label}.pkl"
        
        if not model_path.exists():
            print(f"  WARNING: Model not found at {model_path}")
            continue
        
        with open(model_path, "rb") as f:
            models[q_label] = pickle.load(f)
    
    print(f"  Loaded {len(models)} models for {model_type}")
    
    return models


def predict_qr_direct(X: np.ndarray, models: dict) -> pd.DataFrame:
    """
    Predict using QR_DIRECT models (direct quantile prediction).
    
    Returns:
        DataFrame with columns: q50_qr_direct, q80_qr_direct, q90_qr_direct, q95_qr_direct
    """
    preds = {}
    
    for q_label, model in models.items():
        preds[f"{q_label}_qr_direct"] = model.predict(X)
    
    return pd.DataFrame(preds)


def predict_qr_residual(X: np.ndarray, base_pred: np.ndarray, models: dict) -> pd.DataFrame:
    """
    Predict using QR_RESIDUAL models (residual + base).
    
    Args:
        X: Feature matrix
        base_pred: yhat_p50_gated (base prediction to add residual to)
        models: Trained residual models
    
    Returns:
        DataFrame with columns: q50_qr_residual, q80_qr_residual, q90_qr_residual, q95_qr_residual
    """
    preds = {}
    
    for q_label, model in models.items():
        residual_pred = model.predict(X)
        preds[f"{q_label}_qr_residual"] = base_pred + residual_pred
    
    return pd.DataFrame(preds)


def predict_qr_zero_aware(X: np.ndarray, p_oos: np.ndarray, models: dict) -> pd.DataFrame:
    """
    Predict using QR_ZERO_AWARE models (hurdle approach).
    
    Args:
        X: Feature matrix
        p_oos: Calibrated OOS probability (for zero inflation)
        models: Trained zero-aware models (positive-only)
    
    Returns:
        DataFrame with columns: q50_qr_zero_aware, q80_qr_zero_aware, q90_qr_zero_aware, q95_qr_zero_aware
    """
    preds = {}
    
    for q_label, model in models.items():
        # Predict on all rows (model trained on positive only)
        q_positive = model.predict(X)
        
        # Apply zero-inflation: q_final = (1 - p_oos) * q_positive
        # This reduces quantiles when OOS probability is high
        q_final = (1.0 - p_oos) * q_positive
        
        preds[f"{q_label}_qr_zero_aware"] = np.maximum(0.0, q_final)
    
    return pd.DataFrame(preds)


# ── Main scoring loop ───────────────────────────────────────────────────────

def main():
    print("="*80)
    print("QUANTILE REGRESSION SCORING - h12_v4_qr_strict")
    print("="*80)
    print(f"Project: {PROJECT_ID}")
    print(f"Dataset: {DATASET_ID}")
    print()
    
    # ── Load saved artifacts ────────────────────────────────────────────────
    print("Loading saved artifacts...")
    
    # Load label encoders
    with open(MODEL_DIR / "label_encoders.pkl", "rb") as f:
        encoders = pickle.load(f)
    print(f"  Loaded label encoders")
    
    # Load feature names
    with open(MODEL_DIR / "feature_names.txt", "r") as f:
        feature_names = [line.strip() for line in f.readlines()]
    print(f"  Loaded {len(feature_names)} feature names")
    
    print()
    
    # ── Load scoring data ───────────────────────────────────────────────────
    df_score = load_data_from_bq(["DEV_SELECT", "LOCKED_TEST"])
    
    if len(df_score) == 0:
        print("ERROR: No scoring data found")
        sys.exit(1)
    
    # ── Prepare features ────────────────────────────────────────────────────
    X_score = prepare_features_for_scoring(df_score, encoders, feature_names)
    
    # Extract base predictions for residual approach
    yhat_p50_gated = df_score["yhat_p50_gated"].fillna(df_score["yhat_p50_base"]).values
    p_oos_calibrated = df_score["p_oos_calibrated"].fillna(0.5).values
    
    print()
    
    # ── A) QR_DIRECT predictions ────────────────────────────────────────────
    print("─" * 80)
    print("A) QR_DIRECT: Scoring direct quantile models")
    print("─" * 80)
    
    models_direct = load_models("qr_direct")
    df_pred_direct = predict_qr_direct(X_score, models_direct)
    
    print(f"  Generated {len(df_pred_direct)} predictions")
    print()
    
    # ── B) QR_RESIDUAL predictions ──────────────────────────────────────────
    print("─" * 80)
    print("B) QR_RESIDUAL: Scoring residual quantile models")
    print("─" * 80)
    
    models_residual = load_models("qr_residual")
    df_pred_residual = predict_qr_residual(X_score, yhat_p50_gated, models_residual)
    
    print(f"  Generated {len(df_pred_residual)} predictions")
    print()
    
    # ── C) QR_ZERO_AWARE predictions ────────────────────────────────────────
    print("─" * 80)
    print("C) QR_ZERO_AWARE: Scoring zero-aware quantile models")
    print("─" * 80)
    
    models_zero_aware = load_models("qr_zero_aware")
    df_pred_zero_aware = predict_qr_zero_aware(X_score, p_oos_calibrated, models_zero_aware)
    
    print(f"  Generated {len(df_pred_zero_aware)} predictions")
    print()
    
    # ── Combine all predictions ─────────────────────────────────────────────
    print("─" * 80)
    print("Combining predictions")
    print("─" * 80)
    
    df_output = pd.concat([
        df_score[["sku_id", "decision_week", "eval_split_v3", "y_true_12w", 
                  "yhat_p50_base", "yhat_p50_gated", "season_group", "sku_season_state",
                  "p_oos_calibrated"]],
        df_pred_direct,
        df_pred_residual,
        df_pred_zero_aware
    ], axis=1)
    
    # Add metadata
    df_output["model_version"] = "h12_v4_quantile_regression_strict"
    df_output["scored_at"] = pd.Timestamp.utcnow()
    
    print(f"  Combined output: {df_output.shape}")
    print()
    
    # ── Upload to BigQuery ──────────────────────────────────────────────────
    print("─" * 80)
    print("Uploading to BigQuery")
    print("─" * 80)
    
    client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
    table_id = f"{PROJECT_ID}.{DATASET_ID}.qr_predictions_h12_v4_qr_strict"
    
    job_config = bigquery.LoadJobConfig(
        write_disposition="WRITE_TRUNCATE",
        schema=[
            bigquery.SchemaField("sku_id", "STRING"),
            bigquery.SchemaField("decision_week", "DATE"),
            bigquery.SchemaField("eval_split_v3", "STRING"),
            bigquery.SchemaField("y_true_12w", "FLOAT"),
            bigquery.SchemaField("yhat_p50_base", "FLOAT"),
            bigquery.SchemaField("yhat_p50_gated", "FLOAT"),
            bigquery.SchemaField("season_group", "STRING"),
            bigquery.SchemaField("sku_season_state", "STRING"),
            bigquery.SchemaField("p_oos_calibrated", "FLOAT"),
            # QR_DIRECT
            bigquery.SchemaField("q50_qr_direct", "FLOAT"),
            bigquery.SchemaField("q80_qr_direct", "FLOAT"),
            bigquery.SchemaField("q90_qr_direct", "FLOAT"),
            bigquery.SchemaField("q95_qr_direct", "FLOAT"),
            # QR_RESIDUAL
            bigquery.SchemaField("q50_qr_residual", "FLOAT"),
            bigquery.SchemaField("q80_qr_residual", "FLOAT"),
            bigquery.SchemaField("q90_qr_residual", "FLOAT"),
            bigquery.SchemaField("q95_qr_residual", "FLOAT"),
            # QR_ZERO_AWARE
            bigquery.SchemaField("q50_qr_zero_aware", "FLOAT"),
            bigquery.SchemaField("q80_qr_zero_aware", "FLOAT"),
            bigquery.SchemaField("q90_qr_zero_aware", "FLOAT"),
            bigquery.SchemaField("q95_qr_zero_aware", "FLOAT"),
            # Metadata
            bigquery.SchemaField("model_version", "STRING"),
            bigquery.SchemaField("scored_at", "TIMESTAMP"),
        ]
    )
    
    job = client.load_table_from_dataframe(df_output, table_id, job_config=job_config)
    job.result()
    
    print(f"  Uploaded {len(df_output):,} rows to {table_id}")
    
    # ── Summary stats ───────────────────────────────────────────────────────
    print()
    print("─" * 80)
    print("Scoring summary by split")
    print("─" * 80)
    
    for split in ["DEV_SELECT", "LOCKED_TEST"]:
        mask = df_output["eval_split_v3"] == split
        n = mask.sum()
        
        if n > 0:
            print(f"\n{split}:")
            print(f"  n_obs: {n:,}")
            
            # QR_DIRECT stats
            q90_direct = df_output.loc[mask, "q90_qr_direct"]
            print(f"  QR_DIRECT q90: mean={q90_direct.mean():.2f}, std={q90_direct.std():.2f}")
            
            # QR_RESIDUAL stats
            q90_residual = df_output.loc[mask, "q90_qr_residual"]
            print(f"  QR_RESIDUAL q90: mean={q90_residual.mean():.2f}, std={q90_residual.std():.2f}")
            
            # QR_ZERO_AWARE stats
            q90_zero = df_output.loc[mask, "q90_qr_zero_aware"]
            print(f"  QR_ZERO_AWARE q90: mean={q90_zero.mean():.2f}, std={q90_zero.std():.2f}")
    
    print()
    print("="*80)
    print("SCORING COMPLETE")
    print("="*80)
    print(f"  Predictions table: {table_id}")
    print()


if __name__ == "__main__":
    main()
