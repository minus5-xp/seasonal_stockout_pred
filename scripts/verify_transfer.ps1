# ============================================================================
# VERIFICATION SCRIPT: thequantitativeledger.cruzber_models_eu
# ============================================================================
# Purpose: Verify transferred BQML models and generate metrics
# Requires: bigquery.jobs.create permission in thequantitativeledger
# ============================================================================

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  VERIFICACION DE MODELOS TRANSFERIDOS" -ForegroundColor Cyan
Write-Host "  Proyecto: thequantitativeledger | Dataset: cruzber_models_eu" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Check 1: List tables and models
Write-Host "[1/5] Listando tablas y modelos..." -ForegroundColor Yellow
bq --project_id=thequantitativeledger ls --max_results=100 cruzber_models_eu
Write-Host ""

# Check 2: Count rows in weekly_features_h4
Write-Host "[2/5] Verificando datos base (weekly_features_h4)..." -ForegroundColor Yellow
bq --project_id=thequantitativeledger query --use_legacy_sql=false --format=pretty "
SELECT 
  COUNT(*) AS total_rows,
  COUNT(DISTINCT sku_id) AS unique_skus,
  MIN(week_start_date) AS min_date,
  MAX(week_start_date) AS max_date,
  COUNTIF(split='TRAIN') AS n_train,
  COUNTIF(split='CALIB') AS n_calib,
  COUNTIF(split='VAL') AS n_val
FROM \`thequantitativeledger.cruzber_models_eu.weekly_features_h4\`
"
Write-Host ""

# Check 3: Test prediction on 10 SKUs
Write-Host "[3/5] Testeando predicciones (10 SKUs del split VAL)..." -ForegroundColor Yellow
bq --project_id=thequantitativeledger query --use_legacy_sql=false --format=pretty "
SELECT
  sku_id,
  week_start_date,
  y_oos_h4 AS true_label,
  (SELECT prob FROM UNNEST(predicted_y_oos_h4_probs) WHERE label = 1) AS prob_oos
FROM ML.PREDICT(
  MODEL \`thequantitativeledger.cruzber_models_eu.m_oos_h4\`,
  (SELECT * FROM \`thequantitativeledger.cruzber_models_eu.weekly_features_h4\` WHERE split='VAL' LIMIT 10)
)
ORDER BY prob_oos DESC
"
Write-Host ""

# Check 4: Calibration statistics
Write-Host "[4/5] Verificando calibracion Platt..." -ForegroundColor Yellow
bq --project_id=thequantitativeledger query --use_legacy_sql=false --format=pretty "
SELECT
  split,
  COUNT(*) AS n_rows,
  ROUND(AVG(y_oos_h4), 4) AS true_rate,
  ROUND(AVG(prob_oos_raw), 4) AS avg_prob_raw,
  ROUND(AVG(prob_oos_platt), 4) AS avg_prob_platt,
  ROUND(AVG(POW(prob_oos_raw - y_oos_h4, 2)), 5) AS brier_raw,
  ROUND(AVG(POW(prob_oos_platt - y_oos_h4, 2)), 5) AS brier_platt
FROM \`thequantitativeledger.cruzber_models_eu.score_oos_h4_calibrated\`
GROUP BY split
ORDER BY split
"
Write-Host ""

# Check 5: Model metadata
Write-Host "[5/5] Metadata del modelo m_oos_h4..." -ForegroundColor Yellow
bq --project_id=thequantitativeledger show --format=pretty thequantitativeledger:cruzber_models_eu.m_oos_h4
Write-Host ""

Write-Host "============================================================================" -ForegroundColor Green
Write-Host "  VERIFICACION COMPLETA" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Para ejecutar scorecard completo:" -ForegroundColor Yellow
Write-Host "  cd C:\Users\hugod\OneDrive - Hugo de Val Roig\Documentos\Privado\Formacion\ISDI - MDA\Troncal" -ForegroundColor Gray
Write-Host '  $env:GCP_PROJECT_ID="thequantitativeledger"' -ForegroundColor Gray
Write-Host '  $env:BQ_DATASET_ID="cruzber_models_eu"' -ForegroundColor Gray
Write-Host '  $env:BQ_LOCATION="EU"' -ForegroundColor Gray
Write-Host "  python src/bq/run_scorecard_oos_h4.py --split VAL" -ForegroundColor Gray
Write-Host ""
