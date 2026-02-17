# Preparar archivos para subir a Cloud Shell
# Este script crea un ZIP con solo lo necesario

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Preparando archivos para Cloud Shell" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Crear directorio temporal
$tempDir = "cloudshell_upload_temp"
if (Test-Path $tempDir) {
    Remove-Item $tempDir -Recurse -Force
}
New-Item -ItemType Directory -Path $tempDir | Out-Null

# Archivos esenciales en raíz
Write-Host "[1/8] Copiando archivos de configuración..." -ForegroundColor Yellow
Copy-Item "Dockerfile" "$tempDir/"
Copy-Item "requirements.txt" "$tempDir/"
Copy-Item ".dockerignore" "$tempDir/"
Copy-Item "CLOUD_SHELL_SETUP.md" "$tempDir/"
Copy-Item "QUICKSTART.md" "$tempDir/"
Copy-Item "EXACT_COMMANDS.md" "$tempDir/"
Copy-Item "cloudshell_quickstart.sh" "$tempDir/"

# Directorio SQL completo
Write-Host "[2/8] Copiando queries SQL..." -ForegroundColor Yellow
Copy-Item "sql" "$tempDir/" -Recurse

# Directorio src completo
Write-Host "[3/8] Copiando código Python..." -ForegroundColor Yellow
Copy-Item "src" "$tempDir/" -Recurse

# Scripts
Write-Host "[4/8] Copiando scripts..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path "$tempDir/scripts" | Out-Null
Copy-Item "scripts/build_image.sh" "$tempDir/scripts/"
Copy-Item "scripts/run_container.sh" "$tempDir/scripts/"
Copy-Item "scripts/upload_bundle_to_gcs.sh" "$tempDir/scripts/"
Copy-Item "scripts/export_bigquery_tables_to_gcs.sh" "$tempDir/scripts/"

# Documentación
Write-Host "[5/8] Copiando documentación..." -ForegroundColor Yellow
if (Test-Path "docs") {
    Copy-Item "docs" "$tempDir/" -Recurse
}

# Limpiar archivos innecesarios
Write-Host "[6/8] Limpiando archivos temporales..." -ForegroundColor Yellow
Get-ChildItem "$tempDir" -Recurse -Include "__pycache__","*.pyc","*.pyo" | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
Get-ChildItem "$tempDir" -Recurse -Include "*.log" | Remove-Item -Force -ErrorAction SilentlyContinue

# Crear ZIP
Write-Host "[7/8] Comprimiendo archivos..." -ForegroundColor Yellow
$zipFile = "cruzber_pipeline_cloudshell.zip"
if (Test-Path $zipFile) {
    Remove-Item $zipFile -Force
}

Compress-Archive -Path "$tempDir/*" -DestinationPath $zipFile -CompressionLevel Optimal

# Limpiar directorio temporal
Write-Host "[8/8] Limpiando directorio temporal..." -ForegroundColor Yellow
Remove-Item $tempDir -Recurse -Force

# Estadísticas
$zipSize = (Get-Item $zipFile).Length / 1MB
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Archivo preparado exitosamente" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Archivo: $zipFile"
Write-Host "Tamaño: $([math]::Round($zipSize, 2)) MB"
Write-Host ""
Write-Host "SIGUIENTES PASOS:" -ForegroundColor Cyan
Write-Host "1. Ir a https://console.cloud.google.com" -ForegroundColor White
Write-Host "2. Activar Cloud Shell (icono >_ arriba a la derecha)" -ForegroundColor White
Write-Host "3. Clic en menu '...' → 'Upload' → Seleccionar $zipFile" -ForegroundColor White
Write-Host "4. En Cloud Shell, ejecutar:" -ForegroundColor White
Write-Host ""
Write-Host "   unzip $zipFile -d cruzber_pipeline" -ForegroundColor Yellow
Write-Host "   cd cruzber_pipeline" -ForegroundColor Yellow
Write-Host "   chmod +x cloudshell_quickstart.sh" -ForegroundColor Yellow
Write-Host "   ./cloudshell_quickstart.sh" -ForegroundColor Yellow
Write-Host ""
Write-Host "El script de quickstart configurará todo automáticamente." -ForegroundColor Green
Write-Host ""
