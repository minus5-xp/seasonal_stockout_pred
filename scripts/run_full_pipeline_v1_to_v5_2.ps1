# ============================================================================
# run_full_pipeline_v1_to_v5_2.ps1
# ============================================================================
# Orquestador maestro: ejecuta el stack completo v1 -> v5_2 en BigQuery.
#
# Cadena de dependencias:
#   [RAW]  fact_lineas_albaran (CSV -> BQ via bq_upload_source_table.ps1)
#     |
#     v
#   [V1]   h12_v1   : Feature engineering + BQML training + base_scores_h12_v1
#     |              (20-60 min — incluye entrenamiento BOOSTED_TREE)
#     v
#   [V3_2] h12_v3_2 : Forecast estacional + sku_season_state (15-30 min)
#     |
#     v
#   [V4_2] h12_v4_2 : Quantile overlay sobre v3_2 (5-15 min)
#     |
#     v
#   [V5]   h12_v5   : OOS state layer (15-25 min)
#     |
#     v
#   [V5_1] h12_v5_1 : Difficult state policy — GATE_C_P3_Q3 (10-20 min)
#     |
#     v
#   [V5_2] h12_v5_2 : Recall-safe policy (10-20 min)
#
# Uso:
#   # Ejecutar todo desde cero (requiere BASE_SALES_TABLE):
#   $env:BASE_SALES_TABLE = "thequantitativeledger.cruzber_models_eu.fact_lineas_albaran"
#   .\scripts\run_full_pipeline_v1_to_v5_2.ps1
#
#   # Saltar fases ya completadas (ej: v1 y v3_2 ya estan):
#   .\scripts\run_full_pipeline_v1_to_v5_2.ps1 -StartFrom v4_2
#
#   # Solo verificar (dry-run):
#   .\scripts\run_full_pipeline_v1_to_v5_2.ps1 -DryRun
#
#   # Saltar entrenamiento BQML si los modelos ya existen:
#   .\scripts\run_full_pipeline_v1_to_v5_2.ps1 -SkipTraining
# ============================================================================

param(
    [ValidateSet("v1","v3_2","v4_2","v5","v5_1","v5_2")]
    [string]$StartFrom = "v1",

    [switch]$DryRun,
    [switch]$SkipTraining
)

$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"

$PROJECT_ID = "thequantitativeledger"
$DATASET_ID = "cruzber_models_eu"
$ROOT       = $PSScriptRoot | Split-Path -Parent  # raiz del proyecto

# Mapeo de versiones a rutas de runner
$RUNNERS = [ordered]@{
    "v1"   = "sql\bqml\h12_v1\run_h12_v1_pipeline.py"
    "v3_2" = "sql\bqml\h12_v3_2_season_state_strict\run_h12_v3_2_season_state_strict_pipeline.py"
    "v4_2" = "sql\bqml\h12_v4_2_quantile_overlay_on_v3_2_strict\run_h12_v4_2_quantile_overlay_on_v3_2_strict_pipeline.py"
    "v5"   = "sql\bqml\h12_v5_oos_state_layer_strict\run_h12_v5_oos_state_layer_strict_pipeline.py"
    "v5_1" = "sql\bqml\h12_v5_1_state_specific_oos_policy_strict\run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py"
    "v5_2" = "sql\bqml\h12_v5_2_recall_safe_oos_policy_strict\run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py"
}

# Tabla de salida clave por version (para verificacion)
$KEY_TABLES = @{
    "v1"   = "base_scores_h12_v1"
    "v3_2" = "forecast_gated_h12_v3_2_season_state_strict"
    "v4_2" = "forecast_final_h12_v4_2_strict"
    "v5"   = "oos_final_scores_h12_v5_strict"
    "v5_1" = "combined_oos_alerts_h12_v5_1_strict"
    "v5_2" = "incremental_uplift_analysis_h12_v5_2_strict"
}

# Tiempo estimado por version
$EST_TIMES = @{
    "v1"   = "20-60 min (incluye BQML training)"
    "v3_2" = "15-30 min"
    "v4_2" = "5-15 min"
    "v5"   = "15-25 min"
    "v5_1" = "10-20 min"
    "v5_2" = "10-20 min"
}

function Write-Phase { param($v, $msg) Write-Host "`n$('='*70)`n  PIPELINE $v — $msg`n$('='*70)" -ForegroundColor Cyan }
function Write-OK    { param($msg)     Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Fail  { param($msg)     Write-Host "  x   $msg" -ForegroundColor Red }
function Write-Skip  { param($msg)     Write-Host "  >>  $msg" -ForegroundColor Gray }

function Table-Exists {
    param($table)
    $result = bq show --format=json "${PROJECT_ID}:${DATASET_ID}.${table}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

# Timestamp de inicio
$startTime = Get-Date
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Pipeline Maestro v1 -> v5_2  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "  Proyecto : $PROJECT_ID" -ForegroundColor Cyan
Write-Host "  Dataset  : $DATASET_ID" -ForegroundColor Cyan
Write-Host "  Inicio   : $StartFrom" -ForegroundColor Cyan
if ($DryRun) { Write-Host "  MODO     : DRY-RUN (no se ejecutan queries)" -ForegroundColor Yellow }
Write-Host "============================================================================" -ForegroundColor Cyan

# Validar BASE_SALES_TABLE si se empieza desde v1
if ($StartFrom -eq "v1" -and -not $env:BASE_SALES_TABLE -and -not $DryRun) {
    Write-Host ""
    Write-Fail "BASE_SALES_TABLE no definida."
    Write-Host ""
    Write-Host "  Opciones:" -ForegroundColor Yellow
    Write-Host "    1. Subir CSV y definir la tabla:" -ForegroundColor Gray
    Write-Host "       .\scripts\bq_upload_source_table.ps1 -CsvPath '.\datos.csv' -TableName 'fact_lineas_albaran'" -ForegroundColor White
    Write-Host "       `$env:BASE_SALES_TABLE = '$PROJECT_ID.$DATASET_ID.fact_lineas_albaran'" -ForegroundColor White
    Write-Host ""
    Write-Host "    2. Si ya tienes base_scores_h12_v1 en BQ, salta v1:" -ForegroundColor Gray
    Write-Host "       .\scripts\run_full_pipeline_v1_to_v5_2.ps1 -StartFrom v3_2" -ForegroundColor White
    exit 1
}

# Determinar versiones a ejecutar
$versionsToRun = @()
$active = $false
foreach ($v in $RUNNERS.Keys) {
    if ($v -eq $StartFrom) { $active = $true }
    if ($active) { $versionsToRun += $v }
}

Write-Host ""
Write-Host "  Versiones a ejecutar: $($versionsToRun -join ' -> ')" -ForegroundColor White
Write-Host "  Tiempo estimado total:" -ForegroundColor White
foreach ($v in $versionsToRun) {
    Write-Host "    $v : $($EST_TIMES[$v])" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# Ejecutar cada version
# ─────────────────────────────────────────────────────────────────────────────
$completedVersions = @()
$failedVersion     = $null

foreach ($version in $versionsToRun) {
    $runnerRelPath = $RUNNERS[$version]
    $runnerPath    = Join-Path $ROOT $runnerRelPath
    $keyTable      = $KEY_TABLES[$version]

    Write-Phase $version "$(Get-Date -Format 'HH:mm:ss')  —  Est: $($EST_TIMES[$version])"

    # Verificar si la tabla clave ya existe (skip si no es DryRun)
    if (-not $DryRun -and (Table-Exists $keyTable)) {
        Write-Skip "Tabla $keyTable ya existe en BQ."
        Write-Host "  Para re-ejecutar, borra la tabla o usa --replace en el runner." -ForegroundColor Gray
        $completedVersions += $version
        continue
    }

    if (-not (Test-Path $runnerPath)) {
        Write-Fail "Runner no encontrado: $runnerPath"
        $failedVersion = $version
        break
    }

    # Construir argumentos del runner
    $runnerArgs = @("--phase", "all")
    if ($DryRun) { $runnerArgs += "--dry-run" }
    if ($SkipTraining -and ($version -eq "v1")) { $runnerArgs += "--skip-training" }

    Write-Host "  Ejecutando: python $runnerRelPath $($runnerArgs -join ' ')" -ForegroundColor Yellow

    if ($DryRun) {
        Write-Skip "[DRY-RUN] Saltando ejecucion"
        $completedVersions += $version
        continue
    }

    # Ejecutar (bypass prompt de confirmacion con echo y |)
    $versionStart = Get-Date
    $env:BASE_SALES_TABLE = $env:BASE_SALES_TABLE  # pass-through
    echo y | python $runnerPath @runnerArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Pipeline $version FALLIDO (exit code $LASTEXITCODE)"
        $failedVersion = $version
        break
    }

    $elapsed = (Get-Date) - $versionStart
    Write-OK "$version completado en $([math]::Round($elapsed.TotalMinutes, 1)) min"
    $completedVersions += $version

    # Verificar tabla clave post-ejecucion
    if (Table-Exists $keyTable) {
        $rowCount = bq --format=csv query --use_legacy_sql=false `
            "SELECT COUNT(*) as cnt FROM ``$PROJECT_ID.$DATASET_ID.$keyTable``" 2>$null |
            Select-Object -Skip 1
        Write-OK "Tabla verificada: $keyTable ($rowCount filas)"
    } else {
        Write-Fail "Tabla $keyTable NO encontrada tras ejecucion"
        $failedVersion = $version
        break
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Resumen final
# ─────────────────────────────────────────────────────────────────────────────
$totalElapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  RESUMEN FINAL  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  Total: $([math]::Round($totalElapsed.TotalMinutes, 1)) min" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan

foreach ($v in $versionsToRun) {
    if ($completedVersions -contains $v) {
        Write-Host "  OK  $v — $($KEY_TABLES[$v])" -ForegroundColor Green
    } elseif ($failedVersion -eq $v) {
        Write-Host "  x   $v — FALLIDO" -ForegroundColor Red
    } else {
        Write-Host "  --  $v — no ejecutado" -ForegroundColor Gray
    }
}

if ($failedVersion) {
    Write-Host ""
    Write-Fail "Pipeline fallido en: $failedVersion"
    Write-Host ""
    Write-Host "  Para continuar desde donde fallo:" -ForegroundColor Yellow
    Write-Host "    .\scripts\run_full_pipeline_v1_to_v5_2.ps1 -StartFrom $failedVersion" -ForegroundColor White
    exit 1
} else {
    Write-Host ""
    Write-Host "  PIPELINE COMPLETO v1 -> v5_2" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Consulta el veredicto final:" -ForegroundColor Yellow
    Write-Host "    bq query --use_legacy_sql=false \" -ForegroundColor White
    Write-Host "      ""SELECT final_verdict, methodological_caveat" -ForegroundColor White
    Write-Host "         FROM ``$PROJECT_ID.$DATASET_ID.incremental_uplift_analysis_h12_v5_2_strict``""" -ForegroundColor White
    Write-Host ""
    Write-Host "  Consulta el audit:" -ForegroundColor Yellow
    Write-Host "    bq query --use_legacy_sql=false \" -ForegroundColor White
    Write-Host "      ""SELECT check_id, check_name, check_status" -ForegroundColor White
    Write-Host "         FROM ``$PROJECT_ID.$DATASET_ID.leakage_audit_h12_v5_2_strict``" -ForegroundColor White
    Write-Host "         ORDER BY check_id""" -ForegroundColor White
}
