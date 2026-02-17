Write-Host "`n" -NoNewline
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                 B3 FIX v2 - FINAL VERDICT" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# Consulta ultra-simple: ¿Cuántos segmentos fallan?
$query = @"
SELECT 
  COUNTIF(gate_status = 'FAIL') as n_fail,
  COUNTIF(gate_status = 'PASS') as n_pass,
  COUNT(*) as n_total
FROM cruzber_models_eu.b3_fix_gate_summary_h4
WHERE segment_level = 'SEG2'
"@

Write-Host "`nChecking Gate B3 status..." -ForegroundColor Yellow
$result = bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=csv $query

Write-Host "`nRaw output:"
Write-Host $result

# Parse resultado
$lines = $result -split "`n"
if ($lines.Count -gt 1) {
    $data = $lines[1] -split ","
    $n_fail = [int]$data[0]
    $n_pass = [int]$data[1]
    $n_total = [int]$data[2]
    
    Write-Host "`n================================================================" -ForegroundColor Cyan
    if ($n_fail -eq 0) {
        Write-Host "   STATUS: ✅ GATE B3 PASSED!" -ForegroundColor Green
        Write-Host "   All $n_total segments meet conditional coverage [8%, 12%]" -ForegroundColor Green
    } else {
        Write-Host "   STATUS: ❌ GATE B3 FAILED" -ForegroundColor Red
        Write-Host "   $n_fail/$n_total segments outside [8%, 12%] range" -ForegroundColor Red
    }
    Write-Host "================================================================" -ForegroundColor Cyan
}

# Mostrar los peores segmentos
Write-Host "`nWorst 5 segments:" -ForegroundColor Yellow
bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false @"
SELECT 
  segment_name as seg2,
  n_active,
  ROUND(viol_rate_p90_cond, 4) as viol_rate,
  ROUND(ABS(viol_rate_p90_cond - 0.10), 4) as deviation,
  gate_status
FROM cruzber_models_eu.b3_fix_gate_summary_h4
WHERE segment_level = 'SEG2'
ORDER BY ABS(viol_rate_p90_cond - 0.10) DESC
LIMIT 5
"@

Write-Host "`n"
