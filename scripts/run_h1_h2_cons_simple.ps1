# Simple execution: H1, H2, Consolidated
$ErrorActionPreference = "Stop"
$dataset = "thequantitativeledger.cruzber_models_eu"

Write-Host "`nH1: Logistic Regression..."
(Get-Content "sql\baselines\02_baseline_h1_logistic.sql" -Raw) -replace '\{dataset_ref\}', $dataset | Set-Content "sql\baselines\_h1.sql" -Encoding UTF8
Get-Content "sql\baselines\_h1.sql" -Raw | bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false > logs\h1_out.txt 2>&1
if ($LASTEXITCODE -eq 0) { Write-Host "H1 OK" } else { Write-Host "H1 FAIL"; exit 1 }

Write-Host "`nH2: Temporal Baseline..."
(Get-Content "sql\baselines\03_baseline_h2_temporal.sql" -Raw) -replace '\{dataset_ref\}', $dataset | Set-Content "sql\baselines\_h2.sql" -Encoding UTF8
Get-Content "sql\baselines\_h2.sql" -Raw | bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false > logs\h2_out.txt 2>&1
if ($LASTEXITCODE -eq 0) { Write-Host "H2 OK" } else { Write-Host "H2 FAIL"; exit 1 }

Write-Host "`nConsolidated..."
(Get-Content "sql\baselines\05_consolidated_comparison.sql" -Raw) -replace '\{dataset_ref\}', $dataset | Set-Content "sql\baselines\_cons.sql" -Encoding UTF8
Get-Content "sql\baselines\_cons.sql" -Raw | bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false > logs\cons_out.txt 2>&1
if ($LASTEXITCODE -eq 0) { Write-Host "Consolidated OK" } else { Write-Host "Consolidated FAIL"; exit 1 }

Write-Host "`nALL DONE"
