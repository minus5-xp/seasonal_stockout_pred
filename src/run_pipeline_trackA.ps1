#!/usr/bin/env pwsh
# ============================================================================
# RUN PIPELINE TRACK A: FEATURES → MODELS → EVAL → ALERTING
# ============================================================================
# Purpose: Execute end-to-end BQML pipeline for OOS alerting system
# Usage: .\run_pipeline_trackA.ps1
# Prerequisites:
#   1. gcloud auth login hugo@deval.work
#   2. gcloud auth application-default login
#   3. $env:GCP_PROJECT_ID = "thequantitativeledger"
#   4. $env:BQ_DATASET_ID = "cruzber_models_eu"
# ============================================================================

# Exit on error
$ErrorActionPreference = "Stop"

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "TRACK A PIPELINE: OOS ALERTING (h=4)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Check environment variables
if (-not $env:GCP_PROJECT_ID) {
    Write-Host "❌ ERROR: GCP_PROJECT_ID not set" -ForegroundColor Red
    Write-Host "Run: `$env:GCP_PROJECT_ID = 'voltaic-tuner-475510-s4'" -ForegroundColor Yellow
    exit 1
}

if (-not $env:BQ_DATASET_ID) {
    Write-Host "⚠️  WARNING: BQ_DATASET_ID not set, using default 'dataset_cruzber_eu'" -ForegroundColor Yellow
    $env:BQ_DATASET_ID = "dataset_cruzber_eu"
}

Write-Host "✅ Configuration:" -ForegroundColor Green
Write-Host "   Project: $env:GCP_PROJECT_ID"
Write-Host "   Dataset: $env:BQ_DATASET_ID"
Write-Host ""

# Get script directory
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT_DIR = Split-Path -Parent $SCRIPT_DIR
$SQL_DIR = Join-Path $ROOT_DIR "sql"

# Python runner
$RUNNER = "python"
$RUN_SQL = Join-Path (Join-Path $SCRIPT_DIR "bq") "run_sql.py"

# Phase 1: Features
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "PHASE 1: FEATURES (SPINE + CORE + LABELS)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
& $RUNNER $RUN_SQL --sql-dir (Join-Path $SQL_DIR "features")
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ PHASE 1 FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "✅ PHASE 1 COMPLETE" -ForegroundColor Green
Write-Host ""

# Phase 2: Models
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "PHASE 2: MODELS (TRAIN + SCORE + CALIBRATE)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
& $RUNNER $RUN_SQL --sql-dir (Join-Path $SQL_DIR "models")
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ PHASE 2 FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "✅ PHASE 2 COMPLETE" -ForegroundColor Green
Write-Host ""

# Phase 3: Evaluation
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "PHASE 3: EVALUATION (METRICS + SCORECARD)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
& $RUNNER $RUN_SQL --sql-dir (Join-Path $SQL_DIR "eval")
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ PHASE 3 FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "✅ PHASE 3 COMPLETE" -ForegroundColor Green
Write-Host ""

# Phase 4: Alerting
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "PHASE 4: ALERTING (HHI + TOP-K + FEEDBACK)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
& $RUNNER $RUN_SQL --sql-dir (Join-Path $SQL_DIR "alerting")
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ PHASE 4 FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "✅ PHASE 4 COMPLETE" -ForegroundColor Green
Write-Host ""

# Final summary
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "✅ PIPELINE COMPLETE: TRACK A (OOS ALERTING)" -ForegroundColor Green
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Review scorecard: SELECT * FROM ``$env:GCP_PROJECT_ID.$env:BQ_DATASET_ID.scorecard_go_nogo_h4``"
Write-Host "2. Check alerts: SELECT * FROM ``$env:GCP_PROJECT_ID.$env:BQ_DATASET_ID.alerts_topk_weekly`` ORDER BY week_start_date DESC LIMIT 100"
Write-Host "3. Review metrics: SELECT * FROM ``$env:GCP_PROJECT_ID.$env:BQ_DATASET_ID.metrics_alerting_pooled`` WHERE k=100"
Write-Host ""
Write-Host "Dashboard Views (ready to connect):"
Write-Host "- latest_metrics_weekly"
Write-Host "- latest_scorecard"
Write-Host "- latest_predictions"
Write-Host ""
