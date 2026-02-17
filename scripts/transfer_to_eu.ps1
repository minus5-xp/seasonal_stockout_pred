#!/usr/bin/env pwsh
# ============================================================================
# TRANSFER TO EU - COMPLETE PIPELINE
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  TRANSFERENCIA COMPLETA A thequantitativeledger (EU)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Copy training data
Write-Host "[1/4] Copiando weekly_features_h4 (EU to EU)..." -ForegroundColor Yellow
Write-Host "      Source: voltaic-tuner-475510-s4.dataset_cruzber_eu" -ForegroundColor Gray
Write-Host "      Dest:   thequantitativeledger.cruzber_models_eu" -ForegroundColor Gray
Write-Host ""

bq --project_id=voltaic-tuner-475510-s4 cp `
    --location=EU `
    voltaic-tuner-475510-s4:dataset_cruzber_eu.weekly_features_h4 `
    thequantitativeledger:cruzber_models_eu.weekly_features_h4

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Error copiando datos" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Datos copiados" -ForegroundColor Green
Write-Host ""

# Verify copy
Write-Host "   Verificando copia..." -ForegroundColor Gray
$rowCount = bq --project_id=thequantitativeledger query --use_legacy_sql=false --format=csv "SELECT COUNT(*) FROM \`thequantitativeledger.cruzber_models_eu.weekly_features_h4\`" | Select-Object -Skip 1
Write-Host "   ✅ $rowCount filas confirmadas" -ForegroundColor Green
Write-Host ""

# Step 2: Set environment for destination project
$env:GCP_PROJECT_ID = "thequantitativeledger"
$env:BQ_DATASET_ID = "cruzber_models_eu"
$env:BQ_LOCATION = "EU"

# Step 3: Train m_oos_h4 model
Write-Host "[2/4] 🤖 Entrenando m_oos_h4 (BOOSTED_TREE_CLASSIFIER)..." -ForegroundColor Yellow
Write-Host "      Dataset: $env:BQ_DATASET_ID (EU)" -ForegroundColor Gray
Write-Host "      Tiempo estimado: 10-12 min" -ForegroundColor Gray
Write-Host ""

python src/bq/run_sql.py --sql-file sql/models/10_train_oos_h4.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Error entrenando modelo" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Modelo m_oos_h4 entrenado" -ForegroundColor Green
Write-Host ""

# Step 4: Score validation set
Write-Host "[3/4] 📊 Scoring validation set..." -ForegroundColor Yellow
python src/bq/run_sql.py --sql-file sql/models/11_score_oos_h4.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Error scoring" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Validation set scored" -ForegroundColor Green
Write-Host ""

# Step 5: Train calibration model
Write-Host "[4/4] 🎯 Entrenando calibración Platt..." -ForegroundColor Yellow
python src/bq/run_sql.py --sql-file sql/models/12_calibrate_platt.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Error calibrando" -ForegroundColor Red
    exit 1
}
Write-Host "✅ Modelo m_platt_oos_h4 entrenado" -ForegroundColor Green
Write-Host ""

# Final summary
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  ✅ TRANSFERENCIA COMPLETA" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Modelos disponibles en:" -ForegroundColor Yellow
Write-Host "  • thequantitativeledger.cruzber_models_eu.m_oos_h4" -ForegroundColor White
Write-Host "  • thequantitativeledger.cruzber_models_eu.m_platt_oos_h4" -ForegroundColor White
Write-Host ""
Write-Host "Verificar modelos:" -ForegroundColor Yellow
Write-Host "  bq --project_id=thequantitativeledger ls --models cruzber_models_eu" -ForegroundColor Gray
Write-Host ""
Write-Host "To test predictions, use ML.PREDICT on the validation set" -ForegroundColor Yellow
Write-Host ""
