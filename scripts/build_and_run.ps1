# ============================================================================
# DOCKER BUILD AND TEST SCRIPT (PowerShell)
# ============================================================================
# Purpose: Build Docker image and run test container
# Usage: .\build_and_run.ps1
# ============================================================================

Write-Host "=" -ForegroundColor Cyan -NoNewline
Write-Host ("=" * 69) -ForegroundColor Cyan
Write-Host "BQML STOCKOUT FORECAST PIPELINE - DOCKER BUILD" -ForegroundColor Cyan
Write-Host "=" -ForegroundColor Cyan -NoNewline
Write-Host ("=" * 69) -ForegroundColor Cyan

# Step 1: Check Docker is running
Write-Host "`n[1/5] Checking Docker..." -ForegroundColor Yellow
try {
    $dockerVersion = docker --version
    Write-Host "✅ Docker found: $dockerVersion" -ForegroundColor Green
} catch {
    Write-Host "❌ Docker not found. Please install Docker Desktop." -ForegroundColor Red
    exit 1
}

# Step 2: Check Google Cloud credentials
Write-Host "`n[2/5] Checking Google Cloud credentials..." -ForegroundColor Yellow
$credPath = "$env:USERPROFILE\.config\gcloud\application_default_credentials.json"
if (Test-Path $credPath) {
    Write-Host "✅ Credentials found: $credPath" -ForegroundColor Green
} else {
    Write-Host "⚠️  Credentials not found. Run: gcloud auth application-default login" -ForegroundColor Yellow
    $continue = Read-Host "Continue anyway? (y/n)"
    if ($continue -ne "y") {
        exit 1
    }
}

# Step 3: Create output directory
Write-Host "`n[3/5] Creating output directory..." -ForegroundColor Yellow
$outputDir = ".\results_h4"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
    Write-Host "✅ Created: $outputDir" -ForegroundColor Green
} else {
    Write-Host "✅ Directory exists: $outputDir" -ForegroundColor Green
}

# Step 4: Build Docker image
Write-Host "`n[4/5] Building Docker image..." -ForegroundColor Yellow
Write-Host "This may take 5-10 minutes on first build..." -ForegroundColor Gray

$buildStart = Get-Date
docker build -t bqml-stockout-forecast:latest .

if ($LASTEXITCODE -eq 0) {
    $buildDuration = (Get-Date) - $buildStart
    Write-Host "✅ Image built successfully (duration: $($buildDuration.TotalSeconds.ToString('0.0'))s)" -ForegroundColor Green
} else {
    Write-Host "❌ Build failed. Check errors above." -ForegroundColor Red
    exit 1
}

# Step 5: Run container
Write-Host "`n[5/5] Running container..." -ForegroundColor Yellow
Write-Host "Pipeline will execute BQML script and download results." -ForegroundColor Gray
Write-Host "This can take 15-30 minutes depending on dataset size.`n" -ForegroundColor Gray

# Ask user if they want to run now or later
$runNow = Read-Host "Run pipeline now? (y/n)"

if ($runNow -eq "y") {
    Write-Host "`nStarting container..." -ForegroundColor Cyan
    Write-Host "Use Ctrl+C to view logs in background mode`n" -ForegroundColor Gray
    
    docker run `
        --name bqml-forecast-runner `
        --rm `
        -v "${PWD}\results_h4:/app/results" `
        -v "${env:USERPROFILE}\.config\gcloud:/root/.config/gcloud:ro" `
        -e GOOGLE_CLOUD_PROJECT=voltaic-tuner-475510-s4 `
        -e GOOGLE_CLOUD_LOCATION=EU `
        bqml-stockout-forecast:latest
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n" -NoNewline
        Write-Host "=" -ForegroundColor Green -NoNewline
        Write-Host ("=" * 69) -ForegroundColor Green
        Write-Host "✅ PIPELINE EXECUTION COMPLETED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "=" -ForegroundColor Green -NoNewline
        Write-Host ("=" * 69) -ForegroundColor Green
        Write-Host "`nResults saved to: $outputDir" -ForegroundColor Cyan
        
        # List generated files
        $csvFiles = Get-ChildItem -Path $outputDir -Filter "*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 15
        Write-Host "`nGenerated files:" -ForegroundColor Cyan
        $csvFiles | ForEach-Object {
            $sizeMB = [math]::Round($_.Length / 1MB, 2)
            Write-Host "  - $($_.Name) ($sizeMB MB)" -ForegroundColor Gray
        }
        
    } else {
        Write-Host "`n❌ Pipeline failed. Check logs above." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "`n✅ Image built successfully!" -ForegroundColor Green
    Write-Host "`nTo run later, use:" -ForegroundColor Cyan
    Write-Host "  docker-compose up" -ForegroundColor Gray
    Write-Host "`nOr:" -ForegroundColor Cyan
    Write-Host "  docker run --rm -v `"${PWD}\results_h4:/app/results`" -v `"${env:USERPROFILE}\.config\gcloud:/root/.config/gcloud:ro`" bqml-stockout-forecast:latest" -ForegroundColor Gray
}

Write-Host "`n" -NoNewline
Write-Host "=" -ForegroundColor Cyan -NoNewline
Write-Host ("=" * 69) -ForegroundColor Cyan
Write-Host "BUILD SCRIPT COMPLETED" -ForegroundColor Cyan
Write-Host "=" -ForegroundColor Cyan -NoNewline
Write-Host ("=" * 69) -ForegroundColor Cyan
