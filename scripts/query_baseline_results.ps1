# Query baseline results
Write-Host "`n=========================================" -ForegroundColor Cyan  
Write-Host "HITO 3: BASELINE COMPARISON RESULTS" -ForegroundColor Cyan
Write-Host "=========================================`n" -ForegroundColor Cyan

Write-Host "[H0] Heuristic Baseline:" -ForegroundColor Yellow
bq query --use_legacy_sql=false "SELECT ROUND(roc_auc,4) as AUC, ROUND(precision,4) as Precision, ROUND(recall,4) as Recall FROM cruzber_models_eu.auc_h0_heuristic"

Write-Host "`n[H1] Logistic Regression:" -ForegroundColor Yellow   
bq query --use_legacy_sql=false "SELECT ROUND(roc_auc,4) as AUC, ROUND(precision,4) as Precision, ROUND(recall,4) as Recall FROM cruzber_models_eu.eval_h1_logistic"

Write-Host "`n[H2] Temporal Baseline:" -ForegroundColor Yellow
bq query --use_legacy_sql=false "SELECT ROUND(roc_auc,4) as AUC, ROUND(precision,4) as Precision, ROUND(recall,4) as Recall FROM cruzber_models_eu.auc_h2_temporal"

Write-Host "`n[MAIN] BOOSTED_TREE (m_oos_h4):" -ForegroundColor Yellow
bq query --use_legacy_sql=false "SELECT ROUND(roc_auc,4) as AUC, ROUND(precision,4) as Precision, ROUND(recall,4) as Recall FROM cruzber_models_eu.eval_oos_h4"

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "INTERPRETATION:" -ForegroundColor White
Write-Host "  - H0/H1/H2 are baselines to justify model complexity" -ForegroundColor Gray
Write-Host "  - MAIN (BOOSTED_TREE) should have highest AUC" -ForegroundColor Gray
Write-Host "  - AUC gap shows value of tree-based modeling" -ForegroundColor Gray
Write-Host "=========================================`n" -ForegroundColor Cyan
