# Execute remaining baselines (H1, H2, Consolidated)
# Started after H0 success

$ErrorActionPreference = "Continue"
$dataset_ref = "thequantitativeledger.cruzber_models_eu"

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "BASELINES EXECUTION: H1 → H2 → Consolidated" -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan

# ============================================
# H1: Logistic Regression (BQML)
# ============================================
Write-Host "[2/4] H1: Logistic Regression (BQML training ~5-7 min)..." -ForegroundColor Yellow
$start_h1 = Get-Date

# Generate SQL
(Get-Content "sql\baselines\02_baseline_h1_logistic.sql" -Raw) -replace '\{dataset_ref\}', $dataset_ref | 
  Set-Content "sql\baselines\_temp_h1.sql" -Encoding UTF8

# Execute
Get-Content "sql\baselines\_temp_h1.sql" -Raw | 
  bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=json --max_rows=0 `
  2>&1 | Out-File "logs\h1_execution.log"

$duration_h1 = ((Get-Date) - $start_h1).TotalSeconds

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ H1 completed in $([math]::Round($duration_h1,1))s" -ForegroundColor Green
    
    # Verify model created
    Write-Host "  Verifying model..." -ForegroundColor Gray
    bq ls --project_id=thequantitativeledger cruzber_models_eu | Select-String "m_baseline_h1"
} else {
    Write-Host "❌ H1 FAILED after $([math]::Round($duration_h1,1))s" -ForegroundColor Red
    Write-Host "  Check logs\h1_execution.log for details" -ForegroundColor Yellow
    exit 1
}

# ============================================
# H2: Temporal Baseline
# ============================================
Write-Host "`n[3/4] H2: Temporal Baseline (~3-4 min)..." -ForegroundColor Yellow
$start_h2 = Get-Date

# Generate SQL
(Get-Content "sql\baselines\03_baseline_h2_temporal.sql" -Raw) -replace '\{dataset_ref\}', $dataset_ref | 
  Set-Content "sql\baselines\_temp_h2.sql" -Encoding UTF8

# Execute
Get-Content "sql\baselines\_temp_h2.sql" -Raw | 
  bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=json --max_rows=0 `
  2>&1 | Out-File "logs\h2_execution.log"

$duration_h2 = ((Get-Date) - $start_h2).TotalSeconds

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ H2 completed in $([math]::Round($duration_h2,1))s" -ForegroundColor Green
    
    # Verify tables
    Write-Host "  Verifying tables..." -ForegroundColor Gray
    bq ls --project_id=thequantitativeledger cruzber_models_eu | Select-String "h2_temporal"
} else {
    Write-Host "❌ H2 FAILED after $([math]::Round($duration_h2,1))s" -ForegroundColor Red
    Write-Host "  Check logs\h2_execution.log for details" -ForegroundColor Yellow
    exit 1
}

# ============================================
# Consolidated Comparison
# ============================================
Write-Host "`n[4/4] Consolidated Comparison (~2-3 min)..." -ForegroundColor Yellow
$start_cons = Get-Date

# Generate SQL
(Get-Content "sql\baselines\05_consolidated_comparison.sql" -Raw) -replace '\{dataset_ref\}', $dataset_ref | 
  Set-Content "sql\baselines\_temp_consolidated.sql" -Encoding UTF8

# Execute
Get-Content "sql\baselines\_temp_consolidated.sql" -Raw | 
  bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=json --max_rows=0 `
  2>&1 | Out-File "logs\consolidated_execution.log"

$duration_cons = ((Get-Date) - $start_cons).TotalSeconds

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Consolidated completed in $([math]::Round($duration_cons,1))s" -ForegroundColor Green
} else {
    Write-Host "❌ Consolidated FAILED after $([math]::Round($duration_cons,1))s" -ForegroundColor Red
    Write-Host "  Check logs\consolidated_execution.log for details" -ForegroundColor Yellow
    exit 1
}

# ============================================
# Final Summary
# ============================================
$total_duration = $duration_h1 + $duration_h2 + $duration_cons

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "EXECUTION COMPLETE" -ForegroundColor Green
Write-Host "=========================================`n" -ForegroundColor Cyan
Write-Host "  H1 Logistic:  $([math]::Round($duration_h1,1))s" -ForegroundColor White
Write-Host "  H2 Temporal:  $([math]::Round($duration_h2,1))s" -ForegroundColor White
Write-Host "  Consolidated: $([math]::Round($duration_cons,1))s" -ForegroundColor White
Write-Host "  TOTAL:        $([math]::Round($total_duration,1))s`n" -ForegroundColor White

Write-Host "Next: Query results with:`n" -ForegroundColor Yellow
Write-Host '  bq query --use_legacy_sql=false "SELECT * FROM cruzber_models_eu.baselines_comparison ORDER BY auc DESC"' -ForegroundColor Gray
Write-Host ""
