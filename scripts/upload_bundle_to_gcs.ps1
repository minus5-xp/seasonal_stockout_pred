# Upload bundle to GCS bucket
# Windows PowerShell version

$ErrorActionPreference = "Stop"

# Parse arguments
if ($args.Count -eq 0) {
    Write-Host "Usage: .\upload_bundle_to_gcs.ps1 <bundle-file.tar.gz>"
    Write-Host ""
    Write-Host "Environment variables:"
    Write-Host "  GCS_BUCKET    Target GCS bucket (gs://bucket/prefix)"
    exit 1
}

$BUNDLE_FILE = $args[0]

if (-not (Test-Path $BUNDLE_FILE)) {
    Write-Host "❌ File not found: $BUNDLE_FILE" -ForegroundColor Red
    exit 1
}

if (-not $env:GCS_BUCKET) {
    Write-Host "❌ GCS_BUCKET environment variable not set" -ForegroundColor Red
    Write-Host ""
    Write-Host "Set it to your target bucket:"
    Write-Host '  $env:GCS_BUCKET="gs://your-bucket/bundles"'
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Uploading Bundle to GCS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "File:   $BUNDLE_FILE"
Write-Host "Bucket: $env:GCS_BUCKET"
Write-Host ""

# Extract bundle name
$BUNDLE_NAME = Split-Path -Leaf $BUNDLE_FILE
$GCS_PATH = "$env:GCS_BUCKET/$BUNDLE_NAME"

Write-Host "Destination: $GCS_PATH"
Write-Host ""

# Check if gsutil is available
$gsutilAvailable = Get-Command gsutil -ErrorAction SilentlyContinue

if ($gsutilAvailable) {
    Write-Host "Using gsutil..." -ForegroundColor Cyan
    gsutil -m cp $BUNDLE_FILE $GCS_PATH
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n❌ Upload failed" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "gsutil not found, using Python client..." -ForegroundColor Cyan
    python -m src.bundle.upload_bundle $BUNDLE_FILE --destination $GCS_PATH
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n❌ Upload failed" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "✓ Upload complete" -ForegroundColor Green
Write-Host ""
Write-Host "To download:"
Write-Host "  gsutil cp $GCS_PATH ."
