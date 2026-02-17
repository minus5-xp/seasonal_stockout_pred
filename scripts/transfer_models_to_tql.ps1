#!/usr/bin/env pwsh
# ============================================================================
# TRANSFER BQML MODELS TO thequantitativeledger
# ============================================================================
# Purpose: Copy training data and retrain models in destination project
# Source: voltaic-tuner-475510-s4.dataset_cruzber_eu (EU)
# Destination: thequantitativeledger.cruzber_models (europe-southwest1)
# ============================================================================

$ErrorActionPreference = "Stop"

$SOURCE_PROJECT = "voltaic-tuner-475510-s4"
$SOURCE_DATASET = "dataset_cruzber_eu"
$DEST_PROJECT = "thequantitativeledger"
$DEST_DATASET = "cruzber_models"
$DEST_LOCATION = "europe-southwest1"

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "TRANSFER BQML MODELS TO thequantitativeledger" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "Source: $SOURCE_PROJECT.$SOURCE_DATASET (EU)" -ForegroundColor Yellow
Write-Host "Dest:   $DEST_PROJECT.$DEST_DATASET (europe-southwest1)" -ForegroundColor Yellow
Write-Host ""

# Step 1: Copy weekly_features_h4 (training data)
Write-Host "[1/4] Copying weekly_features_h4..." -ForegroundColor Cyan
bq --project_id=$SOURCE_PROJECT cp `
    --destination_project_id=$DEST_PROJECT `
    --location=EU `
    $SOURCE_PROJECT`:$SOURCE_DATASET.weekly_features_h4 `
    $DEST_PROJECT`:$DEST_DATASET.weekly_features_h4

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to copy weekly_features_h4" -ForegroundColor Red
    exit 1
}
Write-Host "✅ weekly_features_h4 copied" -ForegroundColor Green
Write-Host ""

# Step 2: Train m_oos_h4 model
Write-Host "[2/4] Training m_oos_h4 model..." -ForegroundColor Cyan
$env:GCP_PROJECT_ID = $DEST_PROJECT
$env:BQ_DATASET_ID = $DEST_DATASET
$env:BQ_LOCATION = $DEST_LOCATION

python src/bq/run_sql.py --sql-file sql/models/10_train_oos_h4.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to train m_oos_h4" -ForegroundColor Red
    exit 1
}
Write-Host "✅ m_oos_h4 trained" -ForegroundColor Green
Write-Host ""

# Step 3: Score validation set
Write-Host "[3/4] Scoring validation set..." -ForegroundColor Cyan
python src/bq/run_sql.py --sql-file sql/models/11_score_oos_h4.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to score" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Scored" -ForegroundColor Green
Write-Host ""

# Step 4: Train calibration model (Platt scaling)
Write-Host "[4/4] Training m_platt_oos_h4 calibration..." -ForegroundColor Cyan
python src/bq/run_sql.py --sql-file sql/models/12_calibrate_platt.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Failed to calibrate" -ForegroundColor Red
    exit 1
}
Write-Host "✅ m_platt_oos_h4 calibrated" -ForegroundColor Green
Write-Host ""

# Final verification
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "✅ TRANSFER COMPLETE" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Verify models:" -ForegroundColor Yellow
Write-Host "  bq --project_id=$DEST_PROJECT ls --models $DEST_DATASET"
Write-Host ""
Write-Host "Test prediction:" -ForegroundColor Yellow
Write-Host "  SELECT sku_id, predicted_y_oos_h4_probs" -ForegroundColor White
Write-Host "  FROM ML.PREDICT(MODEL ``$DEST_PROJECT.$DEST_DATASET.m_oos_h4``," -ForegroundColor White
Write-Host "    (SELECT * FROM ``$DEST_PROJECT.$DEST_DATASET.weekly_features_h4``" -ForegroundColor White
Write-Host "     WHERE split = 'VAL' LIMIT 10))" -ForegroundColor White
Write-Host ""
