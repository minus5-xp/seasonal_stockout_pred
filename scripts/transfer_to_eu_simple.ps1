# ============================================================================
# TRANSFER BQML Models to thequantitativeledger (EU Region)
# ============================================================================
# This script transfers weekly_features_h4 and trains models in EU region
# to support BOOSTED_TREE_CLASSIFIER (not available in europe-southwest1)
# ============================================================================

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  TRANSFERENCIA COMPLETA A thequantitativeledger (EU)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Copy training data from voltaic-tuner EU to thequantitativeledger EU
Write-Host "[1/4] Copiando weekly_features_h4 (EU to EU)..." -ForegroundColor Yellow
Write-Host "      Source: voltaic-tuner-475510-s4.dataset_cruzber_eu" -ForegroundColor Gray
Write-Host "      Dest:   thequantitativeledger.cruzber_models_eu" -ForegroundColor Gray
Write-Host ""

bq --project_id=voltaic-tuner-475510-s4 cp `
  --location=EU `
  voltaic-tuner-475510-s4:dataset_cruzber_eu.weekly_features_h4 `
  thequantitativeledger:cruzber_models_eu.weekly_features_h4

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to copy table" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Table copied successfully" -ForegroundColor Green
Write-Host ""

# Verify copy
Write-Host "Verificando copia..." -ForegroundColor Gray
$rowCount = bq --project_id=thequantitativeledger --format=csv query --use_legacy_sql=false "SELECT COUNT(*) as cnt FROM thequantitativeledger.cruzber_models_eu.weekly_features_h4" | Select-Object -Skip 1
Write-Host "   [OK] $rowCount filas confirmadas" -ForegroundColor Green
Write-Host ""

# Step 2: Set environment for destination project
$env:GCP_PROJECT_ID = "thequantitativeledger"
$env:BQ_DATASET_ID = "cruzber_models_eu"
$env:BQ_LOCATION = "EU"

# Step 3: Train m_oos_h4 model
Write-Host "[2/4] Entrenando m_oos_h4 (BOOSTED_TREE_CLASSIFIER)..." -ForegroundColor Yellow
Write-Host "      Dataset: $env:BQ_DATASET_ID (EU)" -ForegroundColor Gray
Write-Host "      Tiempo estimado: 10-12 min" -ForegroundColor Gray
Write-Host ""

python src/bq/run_sql.py --sql-file sql/models/10_train_oos_h4.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to train model" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Modelo m_oos_h4 entrenado" -ForegroundColor Green
Write-Host ""

# Step 4: Score validation set
Write-Host "[3/4] Scoring validation set..." -ForegroundColor Yellow
python src/bq/run_sql.py --sql-file sql/models/11_score_oos_h4.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to score" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Validation set scored" -ForegroundColor Green
Write-Host ""

# Step 5: Train calibration model
Write-Host "[4/4] Entrenando calibracion Platt..." -ForegroundColor Yellow
python src/bq/run_sql.py --sql-file sql/models/12_calibrate_platt.sql

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to calibrate" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Modelo m_platt_oos_h4 entrenado" -ForegroundColor Green
Write-Host ""

# Final verification
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "  TRANSFERENCIA COMPLETA" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Models created in: thequantitativeledger.cruzber_models_eu" -ForegroundColor Yellow
Write-Host ""
Write-Host "Verify with:" -ForegroundColor Yellow
Write-Host "  bq --project_id=thequantitativeledger ls --models cruzber_models_eu" -ForegroundColor Gray
Write-Host ""
Write-Host "To test predictions, use ML.PREDICT on the validation set" -ForegroundColor Yellow
Write-Host ""
