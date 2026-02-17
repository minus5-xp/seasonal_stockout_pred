# Script para crear proyecto limpio OOS h4
$source = "."
$dest = "seasonal_stockout_h4_clean"

Write-Host "`n🔧 Creando proyecto limpio OOS h=4...`n" -ForegroundColor Cyan

# Crear estructura
$dirs = @(
    "reports",
    "sql/registry",
    "sql/repro",
    "sql/experiments",
    "src/bq",
    "docs"
)

foreach($dir in $dirs) {
    New-Item -ItemType Directory -Path "$dest/$dir" -Force | Out-Null
}

# Archivos root
$rootFiles = @(
    "README.md",
    ".gitignore",
    "PAPER_READINESS_CRUZBER_H4.ipynb",
    "00_INDICE_MAESTRO_BQML_h4.md",
    "checklist_status.csv"
)

foreach($file in $rootFiles) {
    if(Test-Path $file) {
        Copy-Item $file "$dest/" -Force
        Write-Host "✅ $file"
    }
}

# Reports
$reportFiles = @(
    "reports/reconciliation_h4_vs_transfer.md",
    "reports/decision_log.md",
    "reports/EXPERIMENTO_R1_RESULTADOS.md",
    "reports/HITO_0_COMANDOS_FINALES.md"
)

foreach($file in $reportFiles) {
    if(Test-Path $file) {
        Copy-Item $file "$dest/$file" -Force
        Write-Host "✅ $file"
    }
}

# SQL completos (registry, repro, experiments)
if(Test-Path "sql/registry") {
    Copy-Item "sql/registry/*" "$dest/sql/registry/" -Force
    Write-Host "✅ sql/registry/*"
}

if(Test-Path "sql/repro") {
    Copy-Item "sql/repro/*" "$dest/sql/repro/" -Force
    Write-Host "✅ sql/repro/*"
}

if(Test-Path "sql/experiments") {
    Copy-Item "sql/experiments/*" "$dest/sql/experiments/" -Force
    Write-Host "✅ sql/experiments/*"
}

# Source code
$srcFiles = @(
    "src/bq/register_run.py",
    "src/bq/setup_registry.py",
    "src/bq/run_sql.py"
)

foreach($file in $srcFiles) {
    if(Test-Path $file) {
        Copy-Item $file "$dest/$file" -Force
        Write-Host "✅ $file"
    }
}

# Docs
$docFiles = @(
    "docs/DICTAMEN_h4_2026-02-12_161946.md",
    "docs/RESULTADOS_TRANSFERIDO.md",
    "docs/AUDITORIA_NOTEBOOK_V5_COMPLETA.md"
)

foreach($file in $docFiles) {
    if(Test-Path $file) {
        Copy-Item $file "$dest/$file" -Force
        Write-Host "✅ $file"
    }
}

Write-Host "`n✅ Proyecto limpio creado en: $dest" -ForegroundColor Green
Write-Host "📊 Total archivos: $((Get-ChildItem -Path $dest -Recurse -File | Measure-Object).Count)" -ForegroundColor Cyan
