# ============================================================================
# check_bq_tables.ps1
# ============================================================================
# Verifica el estado de todas las tablas del pipeline en BigQuery.
# Muestra: existe / filas / tamano / ultima modificacion
#
# Uso:
#   .\scripts\check_bq_tables.ps1
#   .\scripts\check_bq_tables.ps1 -Version v5_2    # solo una version
#   .\scripts\check_bq_tables.ps1 -ShowMissing      # solo las que faltan
# ============================================================================

param(
    [ValidateSet("all","v1","v3_2","v4_2","v5","v5_1","v5_2")]
    [string]$Version = "all",

    [switch]$ShowMissing
)

$PROJECT_ID = "thequantitativeledger"
$DATASET_ID = "cruzber_models_eu"

# Tablas por version del pipeline
$TABLES = [ordered]@{
    "v1" = @(
        "weekly_features_h12_v1",
        "train_calib_split_h12_v1",
        "base_scores_h12_v1",
        "score_oos_h12_calibrated_v1"
    )
    "v3_2" = @(
        "sku_season_state_h12_v3_2_season_state_strict",
        "sku_week_seasonality_features_h12_v3_2_season_state_strict",
        "forecast_gated_h12_v3_2_season_state_strict"
    )
    "v4_2" = @(
        "forecast_final_h12_v4_2_strict"
    )
    "v5" = @(
        "oos_state_inputs_h12_v5_strict",
        "oos_feature_matrix_h12_v5_strict",
        "oos_final_scores_h12_v5_strict"
    )
    "v5_1" = @(
        "oos_policy_candidates_h12_v5_1_strict",
        "frozen_oos_policy_h12_v5_1_strict",
        "combined_oos_alerts_h12_v5_1_strict"
    )
    "v5_2" = @(
        "base_scores_h12_v5_2_strict",
        "recall_safe_scored_h12_v5_2_strict",
        "recall_safe_policy_candidates_h12_v5_2_strict",
        "recall_safe_candidate_eval_dev_select_h12_v5_2_strict",
        "frozen_recall_safe_policy_h12_v5_2_strict",
        "combined_oos_alerts_h12_v5_2_strict",
        "final_locked_test_metrics_h12_v5_2_strict",
        "incremental_uplift_analysis_h12_v5_2_strict",
        "top_alerts_combined_h12_v5_2_strict",
        "diagnostics_recall_frontier_h12_v5_2_strict",
        "leakage_audit_h12_v5_2_strict"
    )
}

$checkTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Estado de tablas BQ  |  $checkTime" -ForegroundColor Cyan
Write-Host "  $PROJECT_ID.$DATASET_ID" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan

$totalOk      = 0
$totalMissing = 0

# Filtrar versiones segun parametro
$versionsToCheck = if ($Version -eq "all") { $TABLES.Keys } else { @($Version) }

foreach ($ver in $versionsToCheck) {
    $tables = $TABLES[$ver]
    $verOk  = 0
    $verMis = 0

    Write-Host ""
    Write-Host "  ── $ver ─────────────────────────────────────────────────" -ForegroundColor Yellow

    foreach ($table in $tables) {
        $result = bq show --format=json "${PROJECT_ID}:${DATASET_ID}.${table}" 2>$null

        if ($LASTEXITCODE -eq 0) {
            # Tabla existe — obtener rowCount
            $rowCountRaw = bq --format=csv query --use_legacy_sql=false --quiet `
                "SELECT FORMAT('%\\'d', COUNT(*)) as cnt FROM ``${PROJECT_ID}.${DATASET_ID}.${table}``" 2>$null |
                Select-Object -Last 1

            if (-not $ShowMissing) {
                Write-Host ("  {0,-60} {1,12} filas" -f $table, $rowCountRaw) -ForegroundColor Green
            }
            $verOk++
            $totalOk++
        } else {
            Write-Host ("  {0,-60} FALTA" -f $table) -ForegroundColor Red
            $verMis++
            $totalMissing++
        }
    }

    $status = if ($verMis -eq 0) { "COMPLETO" } else { "$verMis tabla(s) faltante(s)" }
    $color  = if ($verMis -eq 0) { "Green" } else { "Yellow" }
    Write-Host "  Subtotal $ver`: $verOk/$($tables.Count) OK  —  $status" -ForegroundColor $color
}

# ─────────────────────────────────────────────────────────────────────────────
# Resumen
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  TOTAL: $totalOk OK  |  $totalMissing FALTANTES" -ForegroundColor $(if ($totalMissing -eq 0) { "Green" } else { "Yellow" })
Write-Host "============================================================================" -ForegroundColor Cyan

if ($totalMissing -gt 0) {
    Write-Host ""
    Write-Host "  Para generar las tablas faltantes:" -ForegroundColor Yellow
    Write-Host "    .\scripts\run_full_pipeline_v1_to_v5_2.ps1 -StartFrom <version>" -ForegroundColor White
    Write-Host ""
    Write-Host "  Para configurar auth primero:" -ForegroundColor Yellow
    Write-Host "    .\scripts\setup_gcp_local.ps1" -ForegroundColor White
}

if ($totalMissing -eq 0 -and $Version -eq "all") {
    Write-Host ""
    Write-Host "  Todas las tablas presentes." -ForegroundColor Green
    Write-Host "  Para ejecutar v5_2 pipeline:" -ForegroundColor Yellow
    Write-Host "    `$env:PYTHONIOENCODING='utf-8'" -ForegroundColor White
    Write-Host "    echo y | python sql\bqml\h12_v5_2_recall_safe_oos_policy_strict\run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase all" -ForegroundColor White
}
