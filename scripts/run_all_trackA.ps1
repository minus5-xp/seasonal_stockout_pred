#!/usr/bin/env pwsh
# ============================================================================
# RUN ALL TRACK A: COMPLETE REPRODUCIBLE PIPELINE
# ============================================================================
# Purpose: Execute complete end-to-end pipeline with registry and reporting
# Usage: .\run_all_trackA.ps1 [-SkipRegistry] [-SkipPipeline] [-DryRun]
# Prerequisites:
#   1. gcloud auth login hugo@deval.work
#   2. gcloud auth application-default login
#   3. $env:GCP_PROJECT_ID = "voltaic-tuner-475510-s4"
#   4. $env:BQ_DATASET_ID = "dataset_cruzber_eu"
#   5. $env:BQ_LOCATION = "EU"
# ============================================================================

param(
    [switch]$SkipRegistry,
    [switch]$SkipPipeline,
    [switch]$DryRun
)

# Exit on error
$ErrorActionPreference = "Stop"

# Colors
function Write-Header($text) {
    Write-Host "`n$('='*80)" -ForegroundColor Cyan
    Write-Host $text -ForegroundColor Cyan
    Write-Host "$('='*80)`n" -ForegroundColor Cyan
}

function Write-Phase($text) {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] 📍 $text" -ForegroundColor Yellow
}

function Write-Success($text) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✅ $text" -ForegroundColor Green
}

function Write-Error-Message($text) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ $text" -ForegroundColor Red
}

function Write-Info($text) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ℹ️  $text" -ForegroundColor Blue
}

# Start timer
$startTime = Get-Date
Write-Header "RUN ALL TRACK A: COMPLETE REPRODUCIBLE PIPELINE"

# Check environment variables
if (-not $env:GCP_PROJECT_ID) {
    Write-Error-Message "GCP_PROJECT_ID not set"
    Write-Host "Run: `$env:GCP_PROJECT_ID = 'voltaic-tuner-475510-s4'" -ForegroundColor Yellow
    exit 1
}

if (-not $env:BQ_DATASET_ID) {
    Write-Host "⚠️  BQ_DATASET_ID not set, using default 'dataset_cruzber_eu'" -ForegroundColor Yellow
    $env:BQ_DATASET_ID = "dataset_cruzber_eu"
}

if (-not $env:BQ_LOCATION) {
    Write-Host "⚠️  BQ_LOCATION not set, using default 'EU'" -ForegroundColor Yellow
    $env:BQ_LOCATION = "EU"
}

Write-Success "Configuration:"
Write-Host "   Project: $env:GCP_PROJECT_ID"
Write-Host "   Dataset: $env:BQ_DATASET_ID"
Write-Host "   Location: $env:BQ_LOCATION"
Write-Host "   Dry Run: $DryRun"

# Get directories
$SCRIPT_DIR = $PSScriptRoot
$ROOT_DIR = if ($SCRIPT_DIR -like "*\src") { Split-Path -Parent $SCRIPT_DIR } else { $SCRIPT_DIR }
$SQL_DIR = Join-Path $ROOT_DIR "sql"
$SRC_DIR = Join-Path $ROOT_DIR "src"
$BQ_DIR = Join-Path $SRC_DIR "bq"

# Python runner
$PYTHON = "python"
$RUN_SQL = Join-Path $BQ_DIR "run_sql.py"
$RUN_SQL_DIR = Join-Path $BQ_DIR "run_sql_dir.py"
$SETUP_REGISTRY = Join-Path $BQ_DIR "setup_registry.py"
$REGISTER_RUN = Join-Path $BQ_DIR "register_run.py"

# Generate run ID
$RUN_ID = "run_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid().ToString('N').Substring(0,8)))"
Write-Info "Run ID: $RUN_ID"

# ============================================================================
# PHASE 0: Setup Registry
# ============================================================================
if (-not $SkipRegistry) {
    Write-Header "PHASE 0: SETUP EXPERIMENT REGISTRY"
    
    if ($DryRun) {
        Write-Info "[DRY RUN] Would create experiment_registry dataset and table"
    } else {
        Write-Phase "Creating experiment_registry..."
        & $PYTHON $SETUP_REGISTRY
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Message "PHASE 0 FAILED: Registry setup failed"
            exit 1
        }
        Write-Success "Registry setup complete"
    }
} else {
    Write-Info "Skipping registry setup (--SkipRegistry)"
}

# ============================================================================
# PHASE 1-4: Main Pipeline
# ============================================================================
if (-not $SkipPipeline) {
    Write-Header "PHASES 1-4: MAIN PIPELINE"
    
    $pipelineScript = Join-Path $SRC_DIR "run_pipeline_trackA.ps1"
    
    if (Test-Path $pipelineScript) {
        if ($DryRun) {
            Write-Info "[DRY RUN] Would execute pipeline: $pipelineScript"
        } else {
            Write-Phase "Executing pipeline..."
            & $pipelineScript
            if ($LASTEXITCODE -ne 0) {
                Write-Error-Message "PIPELINE FAILED"
                exit 1
            }
            Write-Success "Pipeline complete"
        }
    } else {
        Write-Error-Message "Pipeline script not found: $pipelineScript"
        exit 1
    }
} else {
    Write-Info "Skipping pipeline execution (--SkipPipeline)"
}

# ============================================================================
# PHASE 5: Register Run
# ============================================================================
Write-Header "PHASE 5: REGISTER RUN"

if ($DryRun) {
    Write-Info "[DRY RUN] Would register run: $RUN_ID"
} else {
    Write-Phase "Registering run in experiment_registry..."
    
    # Build registration command
    $registerCmd = @"
{
    "run_id": "$RUN_ID",
    "model_name": "stockout_seasonal_oos_h4",
    "label_version": "oos_4w",
    "horizon": 4,
    "protocol": "segmented",
    "features": "rfm_seasonality_hhi_weather",
    "notes": "Reproducible run via run_all_trackA.ps1"
}
"@
    
    # Save to temp file
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
    $registerCmd | Out-File -FilePath $tempFile -Encoding utf8
    
    # Register
    & $PYTHON $REGISTER_RUN --config $tempFile
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Message "PHASE 5 FAILED: Run registration failed"
        Remove-Item $tempFile -ErrorAction SilentlyContinue
        exit 1
    }
    
    Remove-Item $tempFile -ErrorAction SilentlyContinue
    Write-Success "Run registered: $RUN_ID"
}

# ============================================================================
# PHASE 6: Generate Reports
# ============================================================================
Write-Header "PHASE 6: GENERATE REPORTS"

if ($DryRun) {
    Write-Info "[DRY RUN] Would generate latest_status.md"
} else {
    Write-Phase "Generating latest status report..."
    
    $generateScript = Join-Path $ROOT_DIR "generate_latest_status.py"
    if (Test-Path $generateScript) {
        & $PYTHON $generateScript
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Report generated: reports/latest_status.md"
        } else {
            Write-Host "⚠️  Report generation failed (non-critical)" -ForegroundColor Yellow
        }
    } else {
        Write-Info "Report script not found (skipping)"
    }
}

# ============================================================================
# PHASE 7: Generate Manifest
# ============================================================================
Write-Header "PHASE 7: UPDATE MANIFEST"

if ($DryRun) {
    Write-Info "[DRY RUN] Would update manifest.json"
} else {
    Write-Phase "Updating manifest..."
    
    $manifestScript = Join-Path $ROOT_DIR "generate_manifest.py"
    if (Test-Path $manifestScript) {
        & $PYTHON $manifestScript
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Manifest updated: manifest/manifest.json"
        } else {
            Write-Host "⚠️  Manifest update failed (non-critical)" -ForegroundColor Yellow
        }
    } else {
        Write-Info "Manifest script not found (skipping)"
    }
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Header "✅ COMPLETE: ALL PHASES SUCCESSFUL"
Write-Host "📊 Summary:" -ForegroundColor Cyan
Write-Host "   Run ID: $RUN_ID" -ForegroundColor White
Write-Host "   Duration: $($duration.ToString('mm\:ss'))" -ForegroundColor White
Write-Host "   Project: $env:GCP_PROJECT_ID" -ForegroundColor White
Write-Host "   Dataset: $env:BQ_DATASET_ID" -ForegroundColor White
Write-Host "`n📁 Next steps:" -ForegroundColor Cyan
Write-Host "   1. Review results: reports/latest_status.md" -ForegroundColor White
Write-Host "   2. Check manifest: manifest/manifest.json" -ForegroundColor White
Write-Host "   3. Query registry: SELECT * FROM experiment_registry.runs WHERE run_id='$RUN_ID'" -ForegroundColor White
Write-Host ""

exit 0
