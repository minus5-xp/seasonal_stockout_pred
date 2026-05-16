# ============================================================================
# bq_upload_source_table.ps1
# ============================================================================
# Sube un archivo CSV a BigQuery como tabla fuente del pipeline BQML.
#
# Uso:
#   .\scripts\bq_upload_source_table.ps1 -CsvPath <ruta_csv> -TableName <nombre_tabla>
#
# Ejemplos:
#   # Subir fact_lineas_albaran (datos de ventas raw):
#   .\scripts\bq_upload_source_table.ps1 `
#       -CsvPath "C:\datos\fact_lineas_albaran.csv" `
#       -TableName "fact_lineas_albaran"
#
#   # Subir weekly_features_h12_v1 (si ya tienes el CSV exportado de BQ):
#   .\scripts\bq_upload_source_table.ps1 `
#       -CsvPath ".\weekly_features_h12_Cruzber_Coste_oportunidad_H12_BQML.csv" `
#       -TableName "weekly_features_h12_v1"
#
#   # Subir con schema explicito (mas rapido, mas seguro):
#   .\scripts\bq_upload_source_table.ps1 `
#       -CsvPath ".\datos.csv" `
#       -TableName "fact_lineas_albaran" `
#       -SchemaFile ".\scripts\schema_fact_lineas.json"
#
# Notas:
#   - Auto-deteccion de schema (--autodetect) si no se pasa -SchemaFile
#   - Si el archivo supera 5 GB, usa la ruta via GCS (ver -UseGcs)
#   - Encoding esperado: UTF-8
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$CsvPath,

    [Parameter(Mandatory=$false)]
    [string]$TableName = "weekly_features_h12_v1",

    [string]$SchemaFile = "",
    [string]$Project    = "thequantitativeledger",
    [string]$Dataset    = "cruzber_models_eu",
    [string]$Location   = "EU",
    [switch]$UseGcs,
    [string]$GcsBucket  = "gs://thequantitativeledger-cruzber/uploads",
    [switch]$Replace     # CREATE OR REPLACE (default: append if exists)
)

$ErrorActionPreference = "Stop"

function Write-Step { param($n, $msg) Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg)     Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Fail { param($msg)     Write-Host "  x   $msg" -ForegroundColor Red }

$FULL_TABLE = "${Project}:${Dataset}.${TableName}"
$FULL_TABLE_DOTS = "${Project}.${Dataset}.${TableName}"

Write-Host "============================================================================" -ForegroundColor Cyan
Write-Host "  Subida de tabla fuente a BigQuery" -ForegroundColor Cyan
Write-Host "  CSV    : $CsvPath" -ForegroundColor Cyan
Write-Host "  Tabla  : $FULL_TABLE" -ForegroundColor Cyan
Write-Host "  Region : $Location" -ForegroundColor Cyan
Write-Host "============================================================================" -ForegroundColor Cyan

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1: Verificar archivo
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "1/4" "Verificando archivo CSV"

if (-not (Test-Path $CsvPath)) {
    Write-Fail "Archivo no encontrado: $CsvPath"
    exit 1
}

$csvFile    = Get-Item $CsvPath
$fileSizeMB = [math]::Round($csvFile.Length / 1MB, 1)
$fileSizeGB = [math]::Round($csvFile.Length / 1GB, 2)
Write-OK "Archivo: $($csvFile.Name)  ($fileSizeMB MB)"

# Preview columnas (primera linea)
$header = Get-Content $CsvPath -First 1
$columns = ($header -split ',').Count
Write-OK "Columnas detectadas: $columns"
Write-Host "  Cabecera: $header" -ForegroundColor Gray

if ($fileSizeGB -gt 4.5 -and -not $UseGcs) {
    Write-Host ""
    Write-Host "  AVISO: El archivo es mayor de 4.5 GB." -ForegroundColor Yellow
    Write-Host "  Para archivos grandes, usa el parametro -UseGcs para subir via GCS." -ForegroundColor Yellow
    Write-Host "  Ejemplo:" -ForegroundColor Gray
    Write-Host "    .\scripts\bq_upload_source_table.ps1 -CsvPath '$CsvPath' -TableName '$TableName' -UseGcs" -ForegroundColor White
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2: Preparar argumentos bq load
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "2/4" "Preparando comando bq load"

$writeDisposition = if ($Replace) { "WRITE_TRUNCATE" } else { "WRITE_EMPTY" }

$bqArgs = @(
    "load",
    "--location=$Location",
    "--source_format=CSV",
    "--skip_leading_rows=1",
    "--write_disposition=$writeDisposition",
    "--null_marker=",
    "--allow_quoted_newlines"
)

if ($SchemaFile -and (Test-Path $SchemaFile)) {
    $bqArgs += "--schema=$SchemaFile"
    Write-OK "Schema: $SchemaFile"
} else {
    $bqArgs += "--autodetect"
    Write-OK "Auto-deteccion de schema activada"
    Write-Host "  (Para mayor control, especifica -SchemaFile con un JSON de schema)" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3: Subida (directa o via GCS)
# ─────────────────────────────────────────────────────────────────────────────

if ($UseGcs) {
    # ── Via GCS (archivos grandes) ─────────────────────────────────────────
    Write-Step "3/4" "Subida via GCS (archivo grande)"

    $gcsPath = "$GcsBucket/$($csvFile.Name)"
    Write-Host "  Subiendo a GCS: $gcsPath" -ForegroundColor Yellow

    gsutil -m cp $CsvPath $gcsPath
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Error subiendo a GCS"
        exit 1
    }
    Write-OK "CSV subido a GCS: $gcsPath"

    Write-Host "  Cargando desde GCS a BigQuery..." -ForegroundColor Yellow
    $bqArgs += $FULL_TABLE
    $bqArgs += $gcsPath

    & bq @bqArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "bq load desde GCS fallido"
        exit 1
    }
} else {
    # ── Carga directa (archivos < 5 GB) ───────────────────────────────────
    Write-Step "3/4" "Cargando CSV directamente a BigQuery"
    Write-Host "  Esto puede tardar varios minutos segun el tamano..." -ForegroundColor Yellow

    $bqArgs += $FULL_TABLE
    $bqArgs += (Resolve-Path $CsvPath).Path

    & bq @bqArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "bq load fallido"
        Write-Host ""
        Write-Host "  Si el error es de schema, intenta:" -ForegroundColor Yellow
        Write-Host "    1. Exportar el schema desde BQ Console o con:" -ForegroundColor Gray
        Write-Host "       bq show --schema $FULL_TABLE > schema.json" -ForegroundColor White
        Write-Host "    2. Volver a ejecutar con -SchemaFile schema.json" -ForegroundColor Gray
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4: Verificacion
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "4/4" "Verificando carga"

$rowCount = bq --format=csv query --use_legacy_sql=false `
    "SELECT COUNT(*) as cnt FROM ``$FULL_TABLE_DOTS``" 2>$null |
    Select-Object -Skip 1

Write-OK "Tabla cargada: $FULL_TABLE_DOTS"
Write-OK "Filas en BQ : $rowCount"

Write-Host ""
Write-Host "============================================================================" -ForegroundColor Green
Write-Host "  Carga completada." -ForegroundColor Green
Write-Host "  Tabla disponible en:" -ForegroundColor Green
Write-Host "  https://console.cloud.google.com/bigquery?project=$Project" -ForegroundColor White
Write-Host "============================================================================" -ForegroundColor Green
Write-Host ""

# Proximos pasos segun tabla subida
if ($TableName -like "*fact_lineas*" -or $TableName -like "*sales*") {
    Write-Host "  Siguiente paso — ejecutar pipeline v1 (feature engineering):" -ForegroundColor Yellow
    Write-Host "    `$env:BASE_SALES_TABLE = '$FULL_TABLE_DOTS'" -ForegroundColor White
    Write-Host "    python sql\bqml\h12_v1\run_h12_v1_pipeline.py" -ForegroundColor White
} elseif ($TableName -like "*weekly_features_h12*") {
    Write-Host "  Si este es weekly_features_h12_v1 ya puedes saltar al pipeline v3_2:" -ForegroundColor Yellow
    Write-Host "    python sql\bqml\h12_v3_2_season_state_strict\run_h12_v3_2_pipeline.py" -ForegroundColor White
    Write-Host ""
    Write-Host "  O ejecutar todo desde v1 con el orquestador maestro:" -ForegroundColor Yellow
    Write-Host "    .\scripts\run_full_pipeline_v1_to_v5_2.ps1" -ForegroundColor White
}
