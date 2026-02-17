# B3 FIX v2 - Verification Script
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "B3 FIX v2 - RESULTS VERIFICATION" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# 1. Gate Summary
Write-Host "[1] GATE SUMMARY" -ForegroundColor Yellow
bq query --project_id=thequantitativeledger `
    --location=EU `
    --use_legacy_sql=false `
    "SELECT segment_level, segment_name, n_active, ROUND(viol_rate_p90_cond,4) as viol_rate, gate_status FROM cruzber_models_eu.b3_fix_gate_summary_h4 ORDER BY segment_level, gate_status DESC"

Write-Host "`n[2] OVERALL GATE STATUS" -ForegroundColor Yellow  
bq query --project_id=thequantitativeledger `
    --location=EU `
    --use_legacy_sql=false `
    "SELECT CASE WHEN COUNTIF(gate_status='FAIL' AND segment_level='SEG2')=0 THEN 'PASS' ELSE 'FAIL' END as overall_status, COUNT(*) as total_segments, COUNTIF(gate_status='PASS') as n_pass, COUNTIF(gate_status='FAIL') as n_fail FROM cruzber_models_eu.b3_fix_gate_summary_h4 WHERE segment_level='SEG2'"

Write-Host "`n[3] SEGMENT-LEVEL DETAILS (worst segments)" -ForegroundColor Yellow  
bq query --project_id=thequantitativeledger `
    --location=EU `
    --use_legacy_sql=false `
    "SELECT seg2, n_active, ROUND(viol_rate_p90_cond,4) as viol_rate, ROUND(ABS(viol_rate_p90_cond - 0.10),4) as deviation, ROUND(sharpness_p90_p50,2) as sharpness FROM cruzber_models_eu.eval_quantiles_conditional_v2_h4 WHERE scope='seg2' ORDER BY ABS(viol_rate_p90_cond - 0.10) DESC LIMIT 10"

Write-Host "`n[4] FALLBACK DISTRIBUTION" -ForegroundColor Yellow
bq query --project_id=thequantitativeledger `
    --location=EU `
    --use_legacy_sql=false `
    "SELECT fallback_level, COUNT(*) as n_rows, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(),2) as pct FROM cruzber_models_eu.mondrian_quantiles_v2_h4 WHERE split='val' GROUP BY fallback_level ORDER BY n_rows DESC"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "END OF VERIFICATION" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
