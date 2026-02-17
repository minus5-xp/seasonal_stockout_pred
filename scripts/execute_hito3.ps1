# HITO 3: Execute All Baselines and Generate Report
# Usage: .\execute_hito3.ps1

$ErrorActionPreference = "Stop"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "HITO 3: BASELINE EXECUTION & COMPARISON" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Set environment variables
$env:GCP_PROJECT_ID = "thequantitativeledger"
$env:BQ_DATASET_ID = "cruzber_models_eu"
$env:BQ_LOCATION = "EU"

Write-Host "[INFO] Environment configured:" -ForegroundColor Yellow
Write-Host "  Project: $env:GCP_PROJECT_ID" -ForegroundColor Gray
Write-Host "  Dataset: $env:BQ_DATASET_ID" -ForegroundColor Gray
Write-Host "  Location: $env:BQ_LOCATION`n" -ForegroundColor Gray

# Check prerequisites
if (-not (Test-Path "src\baselines\run_all_baselines.py")) {
    Write-Host "[ERROR] Missing src\baselines\run_all_baselines.py" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "src\baselines\generate_baselines_report.py")) {
    Write-Host "[ERROR] Missing src\baselines\generate_baselines_report.py" -ForegroundColor Red
    exit 1
}

# Create reports directory if missing
if (-not (Test-Path "reports")) {
    New-Item -ItemType Directory -Path "reports" | Out-Null
    Write-Host "[INFO] Created reports directory`n" -ForegroundColor Yellow
}

# Step 1: Execute all baselines
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "STEP 1: EXECUTING BASELINES" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Host "[INFO] Expected duration: 15-20 minutes" -ForegroundColor Yellow
Write-Host "[INFO] This will execute:" -ForegroundColor Yellow
Write-Host "  • H0: Heuristic baseline (~2-3 min)" -ForegroundColor Gray
Write-Host "  • H1: Logistic regression (~5-7 min)" -ForegroundColor Gray
Write-Host "  • H2: Temporal baseline (~2-3 min)" -ForegroundColor Gray
Write-Host "  • Consolidated comparison (~1-2 min)`n" -ForegroundColor Gray

$startTime = Get-Date

try {
    python src\baselines\run_all_baselines.py `
        --project-id thequantitativeledger `
        --dataset-id cruzber_models_eu `
        --skip-h3
    
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Baseline execution failed with exit code $exitCode"
    }
    
    Write-Host "`n✅ Baselines executed successfully!" -ForegroundColor Green
    
} catch {
    Write-Host "`n❌ Baseline execution failed: $_" -ForegroundColor Red
    exit 1
}

$endTime = Get-Date
$duration = ($endTime - $startTime).TotalSeconds

Write-Host "[INFO] Total execution time: $($duration -as [int]) seconds ($([math]::Round($duration/60, 1)) min)`n" -ForegroundColor Yellow

# Step 2: Generate report
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "STEP 2: GENERATING MARKDOWN REPORT" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

try {
    python src\baselines\generate_baselines_report.py `
        --project-id thequantitativeledger `
        --dataset-id cruzber_models_eu `
        --output reports\baselines_report.md
    
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Report generation failed with exit code $exitCode"
    }
    
    Write-Host "`n✅ Report generated successfully!" -ForegroundColor Green
    
} catch {
    Write-Host "`n❌ Report generation failed: $_" -ForegroundColor Red
    exit 1
}

# Step 3: Summary
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "HITO 3 COMPLETE!" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

Write-Host "[SUCCESS] Generated files:" -ForegroundColor Green
Write-Host "  ✅ reports\baselines_report.md" -ForegroundColor Gray
Write-Host "`n[SUCCESS] BigQuery tables created:" -ForegroundColor Green
Write-Host "  ✅ cruzber_models_eu.baselines_comparison" -ForegroundColor Gray
Write-Host "  ✅ cruzber_models_eu.precision_at_k_comparison" -ForegroundColor Gray
Write-Host "  ✅ cruzber_models_eu.feature_importance_comparison`n" -ForegroundColor Gray

Write-Host "[NEXT STEPS]" -ForegroundColor Yellow
Write-Host "  1. Review reports\baselines_report.md" -ForegroundColor Gray
Write-Host "  2. Update PAPER_READINESS notebook with results" -ForegroundColor Gray
Write-Host "  3. Write 'Baseline Comparison' section for paper" -ForegroundColor Gray
Write-Host "  4. Create comparison figures (bar chart, precision@K curves)`n" -ForegroundColor Gray

Write-Host "🎉 HITO 3 execution pipeline complete!" -ForegroundColor Green
Write-Host ""
