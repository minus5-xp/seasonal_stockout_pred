# Script PowerShell para verificar integridad de datos
#=======================================================

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "VERIFICACIÓN DE DATOS - thequantitativeledger" -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan

# Check 1: pred_point_uc_h4 (tabla base)
Write-Host "[1/4] Verificando pred_point_uc_h4..." -ForegroundColor Yellow
bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=csv `
  "SELECT split, COUNT(*) n FROM cruzber_models_eu.pred_point_uc_h4 GROUP BY split ORDER BY split" `
  2>&1 | Tee-Object -Variable output1
if ($?) { 
  Write-Host "✓ pred_point_uc_h4 OK`n" -ForegroundColor Green 
  $output1
} else { 
  Write-Host "✗ pred_point_uc_h4 ERROR`n" -ForegroundColor Red 
}

# Check 2: mondrian_quantiles_v2_h4
Write-Host "`n[2/4] Verificando mondrian_quantiles_v2_h4..." -ForegroundColor Yellow
bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=csv `
  "SELECT split, COUNT(*) n FROM cruzber_models_eu.mondrian_quantiles_v2_h4 GROUP BY split ORDER BY split" `
  2>&1 | Tee-Object -Variable output2
if ($?) { 
  Write-Host "✓ mondrian_quantiles_v2_h4 OK`n" -ForegroundColor Green 
  $output2
} else { 
  Write-Host "✗ mondrian_quantiles_v2_h4 ERROR`n" -ForegroundColor Red 
}

# Check 3: pred_quantiles_v2_h4 (problema sospechoso)
Write-Host "`n[3/4] Verificando pred_quantiles_v2_h4..." -ForegroundColor Yellow
bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=csv `
  "SELECT COUNT(*) n_total, COUNTIF(split='val') n_val, COUNT(DISTINCT seg2) n_seg2 FROM cruzber_models_eu.pred_quantiles_v2_h4" `
  2>&1 | Tee-Object -Variable output3
if ($?) { 
  Write-Host "✓ pred_quantiles_v2_h4 OK`n" -ForegroundColor Green 
  $output3
} else { 
  Write-Host "✗ pred_quantiles_v2_h4 ERROR`n" -ForegroundColor Red 
}

# Check 4: eval_quantiles_conditional_v2_h4
Write-Host "`n[4/4] Verificando eval_quantiles_conditional_v2_h4..." -ForegroundColor Yellow
bq query --project_id=thequantitativeledger --location=EU --use_legacy_sql=false --format=csv `
  "SELECT COUNT(*) n_rows, COUNT(DISTINCT seg2) n_seg2 FROM cruzber_models_eu.eval_quantiles_conditional_v2_h4" `
  2>&1 | Tee-Object -Variable output4
if ($?) { 
  Write-Host "✓ eval_quantiles_conditional_v2_h4 OK`n" -ForegroundColor Green 
  $output4
} else { 
  Write-Host "✗ eval_quantiles_conditional_v2_h4 ERROR`n" -ForegroundColor Red 
}

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "DIAGNÓSTICO COMPLETADO" -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan
