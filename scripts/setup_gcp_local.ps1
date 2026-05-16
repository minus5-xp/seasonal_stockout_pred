# setup_gcp_local.ps1
# Configura autenticacion GCP (Application Default Credentials) en Windows
# para ejecutar el pipeline BQML localmente contra BigQuery.
#
# Uso:
#   .\scripts\setup_gcp_local.ps1
#   .\scripts\setup_gcp_local.ps1 -SkipAuth
#   .\scripts\setup_gcp_local.ps1 -ServiceAccount -KeyFile <ruta_key.json>

param(
    [switch]$SkipAuth,
    [switch]$ServiceAccount,
    [string]$KeyFile = ""
)

$ErrorActionPreference = "Continue"

$PROJECT_ID = "thequantitativeledger"
$DATASET_ID = "cruzber_models_eu"
$LOCATION   = "EU"

$PREREQ_TABLES = @(
    "base_scores_h12_v1",
    "forecast_gated_h12_v3_2_season_state_strict",
    "sku_season_state_h12_v3_2_season_state_strict",
    "sku_week_seasonality_features_h12_v3_2_season_state_strict",
    "forecast_final_h12_v4_2_strict",
    "oos_final_scores_h12_v5_strict",
    "combined_oos_alerts_h12_v5_1_strict"
)

function Write-Step { param($n, $msg) Write-Host "" ; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg)     Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn { param($msg)     Write-Host "  !   $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg)     Write-Host "  x   $msg" -ForegroundColor Red }

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  GCP Local Setup - BQML OOS Pipeline" -ForegroundColor Cyan
Write-Host "  Proyecto : $PROJECT_ID" -ForegroundColor Cyan
Write-Host "  Dataset  : $DATASET_ID  ($LOCATION)" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan

# ----------------------------------------------------------------------------
# PASO 1: Verificar gcloud SDK
# ----------------------------------------------------------------------------
Write-Step "1/6" "Verificando Google Cloud SDK (gcloud)"

$gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
if (-not $gcloudCmd) {
    Write-Fail "gcloud no encontrado."
    Write-Host ""
    Write-Host "  Instala Google Cloud SDK:" -ForegroundColor Yellow
    Write-Host "  https://cloud.google.com/sdk/docs/install-sdk" -ForegroundColor White
    Write-Host ""
    Write-Host "  O ejecuta en PowerShell:" -ForegroundColor Yellow
    Write-Host '  (New-Object Net.WebClient).DownloadFile("https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe","$env:TEMP\gcloud.exe")' -ForegroundColor White
    Write-Host '  Start-Process "$env:TEMP\gcloud.exe"' -ForegroundColor White
    Write-Host ""
    Write-Host "  Luego cierra y reabre PowerShell y vuelve a ejecutar este script." -ForegroundColor Yellow
    exit 1
}

$gcloudVersion = & gcloud version 2>$null | Select-String "Google Cloud SDK" | Select-Object -First 1
Write-OK "gcloud encontrado: $gcloudVersion"

# ----------------------------------------------------------------------------
# PASO 2: Autenticacion
# ----------------------------------------------------------------------------
Write-Step "2/6" "Configurando Application Default Credentials (ADC)"

if ($SkipAuth) {
    Write-Warn "SkipAuth activo - saltando login"
} elseif ($ServiceAccount -and $KeyFile) {
    if (-not (Test-Path $KeyFile)) {
        Write-Fail "Archivo de clave no encontrado: $KeyFile"
        exit 1
    }
    Write-Host "  Usando Service Account key: $KeyFile" -ForegroundColor Gray
    $env:GOOGLE_APPLICATION_CREDENTIALS = (Resolve-Path $KeyFile).Path
    & gcloud auth activate-service-account --key-file=$KeyFile
    Write-OK "Service Account activado"
} else {
    Write-Host "  Abriendo navegador para login con Google..." -ForegroundColor Yellow
    Write-Host "  Usa la cuenta que tiene acceso a $PROJECT_ID" -ForegroundColor Gray
    Write-Host ""
    & gcloud auth application-default login
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Login fallido"
        exit 1
    }
    Write-OK "ADC configurado correctamente"
}

# Alinear el quota-project del ADC con el proyecto activo
& gcloud auth application-default set-quota-project $PROJECT_ID 2>$null | Out-Null
& gcloud config set project $PROJECT_ID 2>$null | Out-Null
Write-OK "Proyecto activo: $PROJECT_ID  (quota-project alineado)"

# ----------------------------------------------------------------------------
# PASO 3: Verificar acceso al dataset
# ----------------------------------------------------------------------------
Write-Step "3/6" "Verificando acceso al dataset $DATASET_ID"

$null = & bq show "${PROJECT_ID}:${DATASET_ID}" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "No se puede acceder a ${PROJECT_ID}:${DATASET_ID}"
    Write-Host ""
    Write-Host "  Verifica que tienes rol bigquery.dataEditor en $PROJECT_ID" -ForegroundColor Yellow
    Write-Host "  Para crear el dataset:" -ForegroundColor Yellow
    Write-Host "    bq mk --location=$LOCATION ${PROJECT_ID}:${DATASET_ID}" -ForegroundColor White
    exit 1
}
Write-OK "Dataset accesible: ${PROJECT_ID}:${DATASET_ID} ($LOCATION)"

# ----------------------------------------------------------------------------
# PASO 4: Verificar Python y dependencias
# ----------------------------------------------------------------------------
Write-Step "4/6" "Verificando Python y google-cloud-bigquery"

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    Write-Fail "Python no encontrado"
    exit 1
}
$pyVersion = python --version 2>&1
Write-OK "Python: $pyVersion"

$bqImport = python -c "import google.cloud.bigquery; print('ok')" 2>$null
if ($bqImport -ne "ok") {
    Write-Warn "google-cloud-bigquery no instalado. Instalando..."
    pip install google-cloud-bigquery
    Write-OK "google-cloud-bigquery instalado"
} else {
    Write-OK "google-cloud-bigquery disponible"
}

# ----------------------------------------------------------------------------
# PASO 5: Verificar tablas prerequisito
# ----------------------------------------------------------------------------
Write-Step "5/6" "Verificando tablas prerequisito para pipeline v5_2"

$missingTables = @()
foreach ($table in $PREREQ_TABLES) {
    $null = & bq show "${PROJECT_ID}:${DATASET_ID}.${table}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $countSql = "SELECT COUNT(*) as cnt FROM ``${PROJECT_ID}.${DATASET_ID}.${table}``"
        $rowCount = & bq --format=csv query --use_legacy_sql=false $countSql 2>$null |
                    Select-Object -Skip 1
        Write-OK "$table  ($rowCount filas)"
    } else {
        Write-Warn "FALTA: $table"
        $missingTables += $table
    }
}

# ----------------------------------------------------------------------------
# PASO 6: Resumen y proximos pasos
# ----------------------------------------------------------------------------
Write-Step "6/6" "Resumen y proximos pasos"

if ($missingTables.Count -eq 0) {
    Write-OK "Todas las tablas prerequisito existen."
    Write-Host ""
    Write-Host "  Listo para ejecutar el pipeline v5_2:" -ForegroundColor Green
    Write-Host '    $env:PYTHONIOENCODING="utf-8"' -ForegroundColor White
    Write-Host "    cd sql\bqml\h12_v5_2_recall_safe_oos_policy_strict" -ForegroundColor White
    Write-Host "    echo y | python run_h12_v5_2_recall_safe_oos_policy_strict_pipeline.py --phase all" -ForegroundColor White
} else {
    Write-Host ""
    Write-Warn "Faltan $($missingTables.Count) tabla(s). Opciones para generarlas:"
    Write-Host ""

    if ($missingTables -contains "base_scores_h12_v1") {
        Write-Host "  [A] Subir datos fuente y ejecutar pipeline v1:" -ForegroundColor Yellow
        Write-Host "      .\scripts\bq_upload_source_table.ps1 -CsvPath <ruta_al_csv>" -ForegroundColor White
        Write-Host '      $env:BASE_SALES_TABLE="' + $PROJECT_ID + '.' + $DATASET_ID + '.fact_lineas_albaran"' -ForegroundColor White
        Write-Host "      python sql\bqml\h12_v1\run_h12_v1_pipeline.py" -ForegroundColor White
        Write-Host ""
    }

    if ($missingTables | Where-Object { $_ -like "*v3_2*" }) {
        Write-Host "  [B] Ejecutar pipeline v3_2 (requiere base_scores_h12_v1):" -ForegroundColor Yellow
        Write-Host "      python sql\bqml\h12_v3_2_season_state_strict\run_h12_v3_2_season_state_strict_pipeline.py" -ForegroundColor White
        Write-Host ""
    }

    if ($missingTables -contains "forecast_final_h12_v4_2_strict") {
        Write-Host "  [C] Ejecutar pipeline v4_2:" -ForegroundColor Yellow
        Write-Host "      python sql\bqml\h12_v4_2_quantile_overlay_on_v3_2_strict\run_h12_v4_2_quantile_overlay_on_v3_2_strict_pipeline.py" -ForegroundColor White
        Write-Host ""
    }

    if ($missingTables -contains "oos_final_scores_h12_v5_strict") {
        Write-Host "  [D] Ejecutar pipeline v5:" -ForegroundColor Yellow
        Write-Host "      python sql\bqml\h12_v5_oos_state_layer_strict\run_h12_v5_oos_state_layer_strict_pipeline.py" -ForegroundColor White
        Write-Host ""
    }

    if ($missingTables -contains "combined_oos_alerts_h12_v5_1_strict") {
        Write-Host "  [E] Ejecutar pipeline v5_1:" -ForegroundColor Yellow
        Write-Host "      python sql\bqml\h12_v5_1_state_specific_oos_policy_strict\run_h12_v5_1_state_specific_oos_policy_strict_pipeline.py" -ForegroundColor White
        Write-Host ""
    }

    Write-Host "  [F] Ejecutar pipeline completo v1 -> v5_2:" -ForegroundColor Yellow
    Write-Host "      .\scripts\run_full_pipeline_v1_to_v5_2.ps1" -ForegroundColor White
    Write-Host ""
}

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Setup completado." -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan
