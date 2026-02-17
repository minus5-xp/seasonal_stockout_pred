# HITO 3: Execute Baselines Directly with bq CLI
# Bypasses Python environment issues by using bq command-line tool

$ErrorActionPreference = "Stop"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "HITO 3: BASELINE EXECUTION (DIRECT BQ)" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Configuration
$PROJECT_ID = "thequantitativeledger"
$DATASET_ID = "cruzber_models_eu"
$LOCATION = "EU"
$DATASET_REF = "$PROJECT_ID.$DATASET_ID"

Write-Host "[CONFIG] Project: $PROJECT_ID" -ForegroundColor Yellow
Write-Host "[CONFIG] Dataset: $DATASET_ID" -ForegroundColor Yellow
Write-Host "[CONFIG] Location: $LOCATION`n" -ForegroundColor Yellow

# Function to execute SQL file
function Invoke-SqlFile {
    param(
        [string]$SqlFile,
        [string]$Name,
        [int]$Step,
        [int]$TotalSteps
    )
    
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "[$Step/$TotalSteps] $Name" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "[FILE] $SqlFile" -ForegroundColor Gray
    
    if (-not (Test-Path $SqlFile)) {
        Write-Host "[ERROR] SQL file not found: $SqlFile" -ForegroundColor Red
        throw "SQL file missing"
    }
    
    # Read and substitute parameters
    $sql = Get-Content $SqlFile -Raw -Encoding UTF8
    $sql = $sql -replace '\{dataset_ref\}', $DATASET_REF
    
    # Save to temp file
    $tempFile = "temp_hito3_$Step.sql"
    Set-Content -Path $tempFile -Value $sql -Encoding UTF8
    
    Write-Host "[EXEC] Executing query..." -ForegroundColor Yellow
    $startTime = Get-Date
    
    try {
        # Execute with bq CLI
        bq --project_id=$PROJECT_ID `
           --location=$LOCATION `
           query `
           --use_legacy_sql=false `
           --format=json `
           --max_rows=10 `
           "$(Get-Content $tempFile -Raw)" `
           2>&1 | Out-File "logs/hito3_step$Step.log" -Encoding UTF8
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Query failed - see logs/hito3_step$Step.log" -ForegroundColor Red
            throw "Query execution failed"
        }
        
        $endTime = Get-Date
        $duration = ($endTime - $startTime).TotalSeconds
        
        Write-Host "[SUCCESS] Completed in $([math]::Round($duration, 1)) seconds`n" -ForegroundColor Green
        
    } finally {
        # Clean up temp file
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -Force
        }
    }
}

# Create logs directory
if (-not (Test-Path "logs")) {
    New-Item -ItemType Directory -Path "logs" | Out-Null
}

# Start execution
$globalStart = Get-Date

Write-Host "[INFO] Expected duration: 15-20 minutes" -ForegroundColor Yellow
Write-Host "[INFO] Progress will be logged to logs/hito3_step*.log`n" -ForegroundColor Yellow

try {
    # Step 1: H0 Heuristic Baseline
    Invoke-SqlFile `
        -SqlFile "sql\baselines\01_baseline_h0_heuristic.sql" `
        -Name "H0: Heuristic Baseline" `
        -Step 1 `
        -TotalSteps 4
    
    # Step 2: H1 Logistic Regression
    Invoke-SqlFile `
        -SqlFile "sql\baselines\02_baseline_h1_logistic.sql" `
        -Name "H1: Logistic Regression (BQML)" `
        -Step 2 `
        -TotalSteps 4
    
    # Step 3: H2 Temporal Baseline
    Invoke-SqlFile `
        -SqlFile "sql\baselines\03_baseline_h2_temporal.sql" `
        -Name "H2: Temporal Baseline" `
        -Step 3 `
        -TotalSteps 4
    
    # Step 4: Consolidated Comparison
    Invoke-SqlFile `
        -SqlFile "sql\baselines\05_consolidated_comparison.sql" `
        -Name "Consolidated Comparison" `
        -Step 4 `
        -TotalSteps 4
    
    $globalEnd = Get-Date
    $totalDuration = ($globalEnd - $globalStart).TotalSeconds
    
    Write-Host "`n============================================" -ForegroundColor Cyan
    Write-Host "EXECUTION COMPLETE!" -ForegroundColor Cyan
    Write-Host "============================================`n" -ForegroundColor Cyan
    
    Write-Host "[SUCCESS] Total duration: $([math]::Round($totalDuration/60, 1)) minutes" -ForegroundColor Green
    Write-Host "[SUCCESS] All baselines executed successfully!`n" -ForegroundColor Green
    
    # Fetch final results
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "FINAL RESULTS" -ForegroundColor Cyan
    Write-Host "============================================`n" -ForegroundColor Cyan
    
    Write-Host "[INFO] Fetching baseline comparison..." -ForegroundColor Yellow
    
    $query = @"
SELECT
  model_name,
  ROUND(auc, 4) as auc,
  ROUND(delta_auc_vs_main, 4) as delta_vs_main,
  verdict
FROM ``$DATASET_REF.baselines_comparison``
ORDER BY auc DESC
"@
    
    bq --project_id=$PROJECT_ID `
       --location=$LOCATION `
       query `
       --use_legacy_sql=false `
       --format=pretty `
       $query
    
    Write-Host "`n[NEXT] Generate markdown report:" -ForegroundColor Yellow
    Write-Host "  Run: python src\baselines\generate_baselines_report.py --project-id $PROJECT_ID --dataset-id $DATASET_ID" -ForegroundColor Gray
    Write-Host "`n[NEXT] Or manually query results:" -ForegroundColor Yellow
    Write-Host "  bq --project_id=$PROJECT_ID query --use_legacy_sql=false 'SELECT * FROM $DATASET_REF.baselines_comparison ORDER BY auc DESC'" -ForegroundColor Gray
    
} catch {
    Write-Host "`n[ERROR] Pipeline failed: $_" -ForegroundColor Red
    Write-Host "[INFO] Check logs in logs/hito3_step*.log for details" -ForegroundColor Yellow
    exit 1
}

Write-Host "`n🎉 HITO 3 complete!" -ForegroundColor Green
