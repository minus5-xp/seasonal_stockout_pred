#!/usr/bin/env pwsh
# ============================================================================
# RUN EVALUATION ONLY: SKIP TRAINING, RE-COMPUTE METRICS
# ============================================================================
# Purpose: Re-run evaluation and alerting phases without retraining models
# Usage: .\run_eval_only.ps1
# Use case: After feedback collection, want to recompute metrics without full pipeline
# ============================================================================

$ErrorActionPreference = "Stop"

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "EVALUATION ONLY: METRICS + SCORECARD + ALERTING" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host ""

# Check environment
if (-not $env:GCP_PROJECT_ID) {
    Write-Host "❌ ERROR: GCP_PROJECT_ID not set" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Project: $env:GCP_PROJECT_ID" -ForegroundColor Green
Write-Host "✅ Dataset: $env:BQ_DATASET_ID" -ForegroundColor Green
Write-Host ""

# Get directories
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ROOT_DIR = Split-Path -Parent $SCRIPT_DIR
$SQL_DIR = Join-Path $ROOT_DIR "sql"

# Python runner
$RUNNER = "python"
$RUN_SQL = Join-Path $SCRIPT_DIR "bq" "run_sql.py"

# Phase 3: Evaluation
Write-Host "Running EVALUATION..." -ForegroundColor Cyan
& $RUNNER $RUN_SQL --sql-dir (Join-Path $SQL_DIR "eval")
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "✅ Evaluation complete" -ForegroundColor Green

# Phase 4: Alerting
Write-Host "Running ALERTING..." -ForegroundColor Cyan
& $RUNNER $RUN_SQL --sql-dir (Join-Path $SQL_DIR "alerting")
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host "✅ Alerting complete" -ForegroundColor Green

Write-Host ""
Write-Host "✅ EVALUATION COMPLETE" -ForegroundColor Green
Write-Host "Check: SELECT * FROM \`$env:GCP_PROJECT_ID.$env:BQ_DATASET_ID.scorecard_go_nogo_h4\`" -ForegroundColor Yellow
