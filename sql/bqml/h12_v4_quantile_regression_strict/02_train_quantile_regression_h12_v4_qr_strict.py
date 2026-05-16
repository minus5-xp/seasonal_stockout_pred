#!/usr/bin/env python3
"""
STEP 02: TRAIN QUANTILE REGRESSION (h=12 v4_quantile_regression_strict)
========================================================================
PURPOSE:
  Train quantile regression models to fix collapsed quantiles from BQML.
  Uses sklearn GradientBoostingRegressor with loss='quantile' to learn
  q50, q80, q90, q95 from feature matrix on DEV_TUNE split.

APPROACH:
  We train THREE candidate configurations:
  
  A) QR_DIRECT: Learn quantiles directly from y_true_12w
     - Train separate models for each quantile: q50, q80, q90, q95
     - Features: full feature matrix (categorical encoded)
     
  B) QR_RESIDUAL: Learn residual from yhat_p50_gated, add to base
     - residual = y_true_12w - yhat_p50_gated
     - Train quantile models on residual
     - Final quantile = yhat_p50_gated + residual_quantile
     
  C) QR_ZERO_AWARE: Hurdle model with separate zero/positive treatment
     - Use p_oos_calibrated for zero probability
     - Learn quantiles only for positive cases
     - Blend using: q_final = (1-p_oos) * q_positive

ANTI-LEAKAGE:
  - Training ONLY on eval_split_v3 = 'DEV_TUNE'
  - DEV_SELECT used for selection (phase 4)
  - LOCKED_TEST never seen during training/selection

MODEL CONFIG:
  GradientBoostingRegressor:
    - n_estimators: 100 (default for robustness)
    - max_depth: 4 (prevent overfitting)
    - learning_rate: 0.05 (conservative)
    - min_samples_leaf: 20 (stability)
    - subsample: 0.8 (stochastic gradient boosting)
    
OUTPUT:
  Saves trained models to outputs/h12_v4_qr/ as pickle files:
    - qr_direct_q50.pkl, qr_direct_q80.pkl, qr_direct_q90.pkl, qr_direct_q95.pkl
    - qr_residual_q50.pkl, qr_residual_q80.pkl, qr_residual_q90.pkl, qr_residual_q95.pkl
    - qr_zero_aware_q50.pkl, qr_zero_aware_q80.pkl, qr_zero_aware_q90.pkl, qr_zero_aware_q95.pkl
    
  Creates BigQuery table: qr_trained_models_metadata_h12_v4_qr_strict
    - model_id, model_type, quantile, n_train, mae_train, feature_importance
"""

import os
import sys
import pickle
from pathlib import Path
from datetime import datetime

import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.preprocessing import LabelEncoder
from google.cloud import bigquery

# ── Config ──────────────────────────────────────────────────────────────────
PROJECT_ID = os.environ.get("PROJECT_ID", "thequantitativeledger")
DATASET_ID = os.environ.get("BQ_DATASET", "cruzber_models_eu")
LOCATION = os.environ.get("BQ_LOCATION", "EU")

OUTPUT_DIR = Path("outputs/h12_v4_qr")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

FEATURE_TABLE = f"{PROJECT_ID}.{DATASET_ID}.qr_feature_matrix_h12_v4_qr_strict"

# Quantile values to predict
QUANTILES = [0.50, 0.80, 0.90, 0.95]

# Model hyperparameters
MODEL_PARAMS = {
    "n_estimators": 100,
    "max_depth": 4,
    "learning_rate": 0.05,
    "min_samples_leaf": 20,
    "subsample": 0.8,
    "random_state": 42,
    "verbose": 0
}

# Feature lists
NUMERIC_FEATURES = [
    "yhat_p50_base", "yhat_p50_gated",
    "q80_base", "q90_base", "q95_base",
    "base_spread_p80", "base_spread_p90", "base_spread_p95",
    "p_oos_raw", "p_oos_calibrated",
    "scale", "log_yhat_p50_base", "log_yhat_p50_gated",
    "hist_avg_units_same_week", "hist_p90_units_same_week",
    "hist_positive_rate_same_week", "seasonal_index_same_week",
    "annual_avg_units_sku", "annual_positive_rate_sku",
    "transition_slope_forward",
    "hist_avg_12w_equiv", "hist_p90_12w_equiv",
    "n_hist_observations",
    "zero_prob_signal", "demand_cv_signal",
    "gate_reduction_abs", "gate_reduction_pct"
]

CATEGORICAL_FEATURES = [
    "season_group", "sku_season_state", "seasonal_strength",
    "hist_confidence", "gate_reason"
]

BINARY_FEATURES = [
    "stockout_event", "gate_applied", "is_transition", "is_off_peak"
]

ALL_FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES + BINARY_FEATURES


# ── Helper functions ────────────────────────────────────────────────────────

def load_data_from_bq(split: str = "DEV_TUNE") -> pd.DataFrame:
    """Load feature matrix from BigQuery for specified split."""
    client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
    
    query = f"""
    SELECT *
    FROM `{FEATURE_TABLE}`
    WHERE eval_split_v3 = '{split}'
      AND has_label = TRUE
    """
    
    print(f"Loading {split} data from BigQuery...")
    df = client.query(query).to_dataframe()
    print(f"  Loaded {len(df):,} rows")
    
    return df


def prepare_features(df: pd.DataFrame) -> tuple:
    """
    Prepare feature matrix with encoding.
    
    Returns:
        X: Feature matrix (numpy array)
        feature_names: List of feature names after encoding
        encoders: Dict of label encoders for categorical features
    """
    df = df.copy()
    
    # Fill missing categoricals with 'UNKNOWN'
    for col in CATEGORICAL_FEATURES:
        if col in df.columns:
            df[col] = df[col].fillna("UNKNOWN")
    
    # Fill missing numerics with 0
    for col in NUMERIC_FEATURES + BINARY_FEATURES:
        if col in df.columns:
            df[col] = df[col].fillna(0.0)
    
    # Encode categoricals
    encoders = {}
    for col in CATEGORICAL_FEATURES:
        if col in df.columns:
            le = LabelEncoder()
            df[col] = le.fit_transform(df[col].astype(str))
            encoders[col] = le
    
    # Select features
    feature_names = [f for f in ALL_FEATURES if f in df.columns]
    X = df[feature_names].values
    
    print(f"  Features prepared: {X.shape[1]} features, {X.shape[0]} samples")
    
    return X, feature_names, encoders


def train_qr_model(X: np.ndarray, y: np.ndarray, alpha: float) -> GradientBoostingRegressor:
    """
    Train a single quantile regression model.
    
    Args:
        X: Feature matrix
        y: Target variable
        alpha: Quantile value (0.50, 0.80, 0.90, 0.95)
    
    Returns:
        Trained GradientBoostingRegressor
    """
    model = GradientBoostingRegressor(
        loss="quantile",
        alpha=alpha,
        **MODEL_PARAMS
    )
    
    model.fit(X, y)
    
    # Calculate training MAE
    y_pred = model.predict(X)
    mae = np.mean(np.abs(y - y_pred))
    
    return model, mae


def get_feature_importance(model: GradientBoostingRegressor, feature_names: list) -> dict:
    """Extract top 10 feature importances."""
    importances = model.feature_importances_
    idx = np.argsort(importances)[::-1][:10]
    
    return {
        feature_names[i]: float(importances[i])
        for i in idx
    }


# ── Main training loop ──────────────────────────────────────────────────────

def main():
    print("="*80)
    print("QUANTILE REGRESSION TRAINING - h12_v4_qr_strict")
    print("="*80)
    print(f"Project: {PROJECT_ID}")
    print(f"Dataset: {DATASET_ID}")
    print(f"Output:  {OUTPUT_DIR}")
    print()
    
    # ── Load training data ──────────────────────────────────────────────────
    df_train = load_data_from_bq("DEV_TUNE")
    
    if len(df_train) == 0:
        print("ERROR: No training data found")
        sys.exit(1)
    
    # Check for label
    if "y_true_12w" not in df_train.columns:
        print("ERROR: y_true_12w not found in feature matrix")
        sys.exit(1)
    
    # ── Prepare features ────────────────────────────────────────────────────
    X_train, feature_names, encoders = prepare_features(df_train)
    y_train = df_train["y_true_12w"].values
    
    # Save encoders for scoring phase
    with open(OUTPUT_DIR / "label_encoders.pkl", "wb") as f:
        pickle.dump(encoders, f)
    print(f"  Saved label encoders to {OUTPUT_DIR / 'label_encoders.pkl'}")
    
    # Save feature names
    with open(OUTPUT_DIR / "feature_names.txt", "w") as f:
        f.write("\n".join(feature_names))
    print(f"  Saved feature names to {OUTPUT_DIR / 'feature_names.txt'}")
    
    print()
    
    # ── A) QR DIRECT: Learn quantiles directly ─────────────────────────────
    print("─" * 80)
    print("A) QR_DIRECT: Training direct quantile models")
    print("─" * 80)
    
    metadata_direct = []
    
    for alpha in QUANTILES:
        q_label = f"q{int(alpha*100)}"
        print(f"  Training {q_label} (alpha={alpha})...")
        
        model, mae = train_qr_model(X_train, y_train, alpha)
        
        # Save model
        model_path = OUTPUT_DIR / f"qr_direct_{q_label}.pkl"
        with open(model_path, "wb") as f:
            pickle.dump(model, f)
        
        # Feature importance
        fi = get_feature_importance(model, feature_names)
        
        metadata_direct.append({
            "model_id": f"qr_direct_{q_label}",
            "model_type": "QR_DIRECT",
            "quantile": alpha,
            "n_train": len(y_train),
            "mae_train": mae,
            "feature_importance": str(fi),
            "model_path": str(model_path),
            "trained_at": datetime.utcnow()
        })
        
        print(f"    MAE (train): {mae:.3f}")
        print(f"    Top 3 features: {list(fi.keys())[:3]}")
    
    print()
    
    # ── B) QR RESIDUAL: Learn residual from yhat_p50_gated ─────────────────
    print("─" * 80)
    print("B) QR_RESIDUAL: Training residual quantile models")
    print("─" * 80)
    
    residual_train = y_train - df_train["yhat_p50_gated"].fillna(df_train["yhat_p50_base"]).values
    
    metadata_residual = []
    
    for alpha in QUANTILES:
        q_label = f"q{int(alpha*100)}"
        print(f"  Training residual {q_label} (alpha={alpha})...")
        
        model, mae = train_qr_model(X_train, residual_train, alpha)
        
        # Save model
        model_path = OUTPUT_DIR / f"qr_residual_{q_label}.pkl"
        with open(model_path, "wb") as f:
            pickle.dump(model, f)
        
        # Feature importance
        fi = get_feature_importance(model, feature_names)
        
        metadata_residual.append({
            "model_id": f"qr_residual_{q_label}",
            "model_type": "QR_RESIDUAL",
            "quantile": alpha,
            "n_train": len(residual_train),
            "mae_train": mae,
            "feature_importance": str(fi),
            "model_path": str(model_path),
            "trained_at": datetime.utcnow()
        })
        
        print(f"    MAE (train): {mae:.3f}")
        print(f"    Top 3 features: {list(fi.keys())[:3]}")
    
    print()
    
    # ── C) QR ZERO_AWARE: Train on positive cases only ─────────────────────
    print("─" * 80)
    print("C) QR_ZERO_AWARE: Training zero-aware quantile models")
    print("─" * 80)
    
    # Filter to positive cases
    mask_positive = y_train > 0
    X_train_pos = X_train[mask_positive]
    y_train_pos = y_train[mask_positive]
    
    print(f"  Positive cases: {len(y_train_pos):,} / {len(y_train):,} ({100*len(y_train_pos)/len(y_train):.1f}%)")
    
    metadata_zero_aware = []
    
    for alpha in QUANTILES:
        q_label = f"q{int(alpha*100)}"
        print(f"  Training positive-only {q_label} (alpha={alpha})...")
        
        model, mae = train_qr_model(X_train_pos, y_train_pos, alpha)
        
        # Save model
        model_path = OUTPUT_DIR / f"qr_zero_aware_{q_label}.pkl"
        with open(model_path, "wb") as f:
            pickle.dump(model, f)
        
        # Feature importance
        fi = get_feature_importance(model, feature_names)
        
        metadata_zero_aware.append({
            "model_id": f"qr_zero_aware_{q_label}",
            "model_type": "QR_ZERO_AWARE",
            "quantile": alpha,
            "n_train": len(y_train_pos),
            "mae_train": mae,
            "feature_importance": str(fi),
            "model_path": str(model_path),
            "trained_at": datetime.utcnow()
        })
        
        print(f"    MAE (train, positive only): {mae:.3f}")
        print(f"    Top 3 features: {list(fi.keys())[:3]}")
    
    print()
    
    # ── Save metadata to BigQuery ───────────────────────────────────────────
    print("─" * 80)
    print("Saving training metadata to BigQuery")
    print("─" * 80)
    
    metadata_all = metadata_direct + metadata_residual + metadata_zero_aware
    df_metadata = pd.DataFrame(metadata_all)
    
    client = bigquery.Client(project=PROJECT_ID, location=LOCATION)
    table_id = f"{PROJECT_ID}.{DATASET_ID}.qr_trained_models_metadata_h12_v4_qr_strict"
    
    job_config = bigquery.LoadJobConfig(
        write_disposition="WRITE_TRUNCATE",
        schema=[
            bigquery.SchemaField("model_id", "STRING"),
            bigquery.SchemaField("model_type", "STRING"),
            bigquery.SchemaField("quantile", "FLOAT"),
            bigquery.SchemaField("n_train", "INTEGER"),
            bigquery.SchemaField("mae_train", "FLOAT"),
            bigquery.SchemaField("feature_importance", "STRING"),
            bigquery.SchemaField("model_path", "STRING"),
            bigquery.SchemaField("trained_at", "TIMESTAMP"),
        ]
    )
    
    job = client.load_table_from_dataframe(df_metadata, table_id, job_config=job_config)
    job.result()
    
    print(f"  Uploaded metadata to {table_id}")
    print(f"  Total models trained: {len(metadata_all)}")
    print()
    print("="*80)
    print("TRAINING COMPLETE")
    print("="*80)
    print(f"  Models saved to: {OUTPUT_DIR}")
    print(f"  Metadata table:  {table_id}")
    print()


if __name__ == "__main__":
    main()
