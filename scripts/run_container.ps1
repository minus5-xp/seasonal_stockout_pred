# Run Cruzber pipeline in Docker container
# Windows PowerShell version

$ErrorActionPreference = "Stop"

# Configuration
$IMAGE_NAME = if ($env:IMAGE_NAME) { $env:IMAGE_NAME } else { "cruzber-optionb-pipeline:latest" }
$MODE = if ($env:MODE) { $env:MODE } else { "optionB_full" }
$DRY_RUN = if ($env:DRY_RUN) { $env:DRY_RUN } else { "0" }

# Required environment variables
if (-not $env:PROJECT_ID) {
    Write-Host "❌ ERROR: PROJECT_ID must be set" -ForegroundColor Red
    exit 1
}

if (-not $env:BQ_DATASET) {
    Write-Host "❌ ERROR: BQ_DATASET must be set" -ForegroundColor Red
    exit 1
}

# Optional with defaults
$BQ_LOCATION = if ($env:BQ_LOCATION) { $env:BQ_LOCATION } else { "EU" }
$RUN_ID = if ($env:RUN_ID) { $env:RUN_ID } else { Get-Date -Format "yyyyMMdd_HHmmss" }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Running Cruzber Pipeline in Container" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Image:      $IMAGE_NAME"
Write-Host "Project:    $env:PROJECT_ID"
Write-Host "Dataset:    $env:BQ_DATASET"
Write-Host "Mode:       $MODE"
Write-Host "Run ID:     $RUN_ID"
Write-Host ""

# Check for ADC credentials
$ADC_PATH = "$env:APPDATA\gcloud\application_default_credentials.json"
if (-not (Test-Path $ADC_PATH)) {
    Write-Host "⚠️  WARNING: ADC credentials not found at $ADC_PATH" -ForegroundColor Yellow
    Write-Host "Run: gcloud auth application-default login"
    Write-Host ""
}

# Prepare volume mounts
$VOLUMES = @()
if (Test-Path $ADC_PATH) {
    $VOLUMES += "-v"
    $VOLUMES += "${ADC_PATH}:/root/.config/gcloud/application_default_credentials.json:ro"
    Write-Host "✓ Mounting ADC credentials" -ForegroundColor Green
} else {
    Write-Host "⚠️  Running without ADC mount (will use workload identity if available)" -ForegroundColor Yellow
}

# Mount output directory
$OUTPUT_DIR = "$PWD\outputs\$RUN_ID"
New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
$VOLUMES += "-v"
$VOLUMES += "${OUTPUT_DIR}:/app/outputs"
Write-Host "✓ Output directory: $OUTPUT_DIR" -ForegroundColor Green

Write-Host ""
Write-Host "Executing: docker run..." -ForegroundColor Cyan
Write-Host ""

# Build docker run command
$dockerArgs = @(
    "run"
    "--rm"
    "--name", "cruzber-pipeline-$RUN_ID"
) + $VOLUMES + @(
    "-e", "PROJECT_ID=$env:PROJECT_ID"
    "-e", "BQ_DATASET=$env:BQ_DATASET"
    "-e", "BQ_LOCATION=$BQ_LOCATION"
    "-e", "GCS_BUCKET=$env:GCS_BUCKET"
    "-e", "RUN_ID=$RUN_ID"
    "-e", "MODE=$MODE"
    "-e", "DRY_RUN=$DRY_RUN"
    "-e", "TOPK=$(if ($env:TOPK) { $env:TOPK } else { '100' })"
    "-e", "N_MIN=$(if ($env:N_MIN) { $env:N_MIN } else { '200' })"
    "-e", "VOL_NTILES=$(if ($env:VOL_NTILES) { $env:VOL_NTILES } else { '3' })"
    "-e", "COVERAGE_GRID=$(if ($env:COVERAGE_GRID) { $env:COVERAGE_GRID } else { '0.90,0.91,0.92,0.93,0.94,0.95,0.96,0.97,0.98' })"
    "-e", "VERBOSE=$(if ($env:VERBOSE) { $env:VERBOSE } else { '0' })"
    $IMAGE_NAME
    "run"
) + $args

# Run container
& docker @dockerArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n❌ Pipeline execution failed" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "✓ Pipeline execution complete" -ForegroundColor Green
Write-Host "  Outputs: $OUTPUT_DIR"
