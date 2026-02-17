#!/usr/bin/env pwsh
# ==============================================================================
# DEPLOYMENT SCRIPT - Cloud Shell Full Pipeline
# ==============================================================================
# Creates a complete deployment package with SQL queries and Python code
# for executing the B3 fix pipeline in Cloud Shell with Docker
# ==============================================================================

$ErrorActionPreference = "Stop"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  PREPARANDO DEPLOYMENT COMPLETO" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Cyan

# Configuration
$TEMP_DIR = "cloudshell_deploy_full"
$OUTPUT_ZIP = "cruzber_b3_pipeline_full.zip"
$PROJECT_ID = "thequantitativeledger"
$DATASET_ID = "cruzber_models_eu"

# Step 1: Create temp directory
Write-Host "[1/10] Creando directorio temporal..." -ForegroundColor White
if (Test-Path $TEMP_DIR) {
    Remove-Item -Recurse -Force $TEMP_DIR
}
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

# Step 2: Copy SQL queries
Write-Host "[2/10] Copiando queries SQL..." -ForegroundColor White
$SQL_DIRS = @("sql/bqml/quantiles_v2", "sql/bqml/quantiles", "sql/bqml/eval")
foreach ($dir in $SQL_DIRS) {
    if (Test-Path $dir) {
        $targetDir = Join-Path $TEMP_DIR $dir
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Copy-Item -Path "$dir\*" -Destination $targetDir -Recurse -Force
        Write-Host "   ✓ $dir -> $targetDir" -ForegroundColor Gray
    }
}

# Step 3: Copy Python source (if exists)
Write-Host "[3/10] Copiando código Python..." -ForegroundColor White
if (Test-Path "src") {
    Copy-Item -Path "src" -Destination "$TEMP_DIR\src" -Recurse -Force
    Write-Host "   ✓ src/ copiado" -ForegroundColor Gray
} else {
    Write-Host "   ⚠ No src/ directory found, creating minimal structure" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path "$TEMP_DIR\src" -Force | Out-Null
}

# Step 4: Create execution script
Write-Host "[4/10] Creando script de ejecución..." -ForegroundColor White
$EXEC_SCRIPT = @"
#!/bin/bash
set -e

PROJECT_ID="${PROJECT_ID}"
DATASET_ID="${DATASET_ID}"

echo "========================================="
echo "  EXECUTING B3 FIX PIPELINE"
echo "========================================="
echo "Project: \$PROJECT_ID"
echo "Dataset: \$DATASET_ID"
echo ""

# Execute SQL queries in order
SQL_FILES=(
    "sql/bqml/quantiles_v2/30_build_volatility_bucket.sql"
    "sql/bqml/quantiles_v2/31_define_calibration_windows.sql"
    "sql/bqml/quantiles_v2/32_nested_threshold_grid.sql"
    "sql/bqml/quantiles_v2/33_mondrian_conformal_quantiles_v2.sql"
    "sql/bqml/quantiles_v2/34_quantiles_with_metadata.sql"
    "sql/bqml/quantiles_v2/35_hierarchy_fallback_logic.sql"
    "sql/bqml/quantiles_v2/36_evaluation_conditional_coverage_v2.sql"
    "sql/bqml/eval/41_b3_fix_summary.sql"
)

for sql_file in "\${SQL_FILES[@]}"; do
    if [ -f "\$sql_file" ]; then
        echo ""
        echo "▶ Executing: \$sql_file"
        bq query --use_legacy_sql=false --project_id=\$PROJECT_ID < "\$sql_file"
        echo "✓ Completed: \$sql_file"
    else
        echo "⚠ File not found: \$sql_file"
    fi
done

echo ""
echo "========================================="
echo "  PIPELINE EXECUTION COMPLETED"
echo "========================================="

# Validate results
echo ""
echo "📊 Validating Gate B3..."
bq query --use_legacy_sql=false --project_id=\$PROJECT_ID --format=pretty \
"SELECT scope, metric_name, observed_value, target_value, status 
FROM \${DATASET_ID}.b3_fix_gate_summary_h4 
ORDER BY scope, metric_name"
"@

$EXEC_SCRIPT | Out-File -FilePath "$TEMP_DIR\execute_b3_pipeline.sh" -Encoding utf8 -NoNewline

# Step 5: Create Dockerfile with embedded SQL execution
Write-Host "[5/10] Creando Dockerfile optimizado..." -ForegroundColor White
$DOCKERFILE = @"
FROM python:3.11-slim

# Install gcloud CLI and bq
RUN apt-get update && apt-get install -y curl gnupg apt-transport-https ca-certificates \
    && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
RUN pip install --no-cache-dir \
    google-cloud-bigquery==3.14.0 \
    google-cloud-storage==2.14.0 \
    click==8.1.7 \
    rich==13.7.0 \
    pyyaml==6.0.1

# Copy SQL queries and scripts
COPY sql/ sql/
COPY src/ src/
COPY execute_b3_pipeline.sh .

RUN chmod +x execute_b3_pipeline.sh

ENV PROJECT_ID=${PROJECT_ID}
ENV BQ_DATASET=${DATASET_ID}
ENV BQ_LOCATION=EU

CMD ["./execute_b3_pipeline.sh"]
"@

$DOCKERFILE | Out-File -FilePath "$TEMP_DIR\Dockerfile" -Encoding utf8 -NoNewline

# Step 6: Create deployment script for Cloud Shell
Write-Host "[6/10] Creando script de deployment..." -ForegroundColor White
$DEPLOY_SCRIPT = @"
#!/bin/bash
set -e

echo "========================================="
echo "  CLOUD SHELL DEPLOYMENT"
echo "========================================="

# Step 1: Build Docker image
echo ""
echo "[1/3] Building Docker image..."
docker build -t cruzber-b3-pipeline:latest .

# Step 2: Run pipeline
echo ""
echo "[2/3] Executing B3 pipeline..."
docker run --rm \
  -v ~/.config/gcloud:/root/.config/gcloud:ro \
  -e GOOGLE_APPLICATION_CREDENTIALS=/root/.config/gcloud/application_default_credentials.json \
  cruzber-b3-pipeline:latest

# Step 3: Validation
echo ""
echo "[3/3] Final validation..."
bq query --use_legacy_sql=false --project_id=${PROJECT_ID} --format=pretty \
"SELECT 
  COUNT(*) as total_checks,
  SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) as passed,
  SUM(CASE WHEN status = 'FAIL' THEN 1 ELSE 0 END) as failed
FROM ${DATASET_ID}.b3_fix_gate_summary_h4"

echo ""
echo "========================================="
echo "  DEPLOYMENT COMPLETED"
echo "========================================="
"@

$DEPLOY_SCRIPT | Out-File -FilePath "$TEMP_DIR\deploy.sh" -Encoding utf8 -NoNewline

# Step 7: Create README
Write-Host "[7/10] Creando documentación..." -ForegroundColor White
$README = @"
# B3 Pipeline Full Deployment

## 📦 Contenido
- \`sql/\`: Queries SQL para B3 fix (30-36, 41)
- \`src/\`: Código Python (si existe)
- \`Dockerfile\`: Contenedor con gcloud CLI + BigQuery
- \`execute_b3_pipeline.sh\`: Script de ejecución de queries
- \`deploy.sh\`: Script completo de deployment

## 🚀 Instrucciones de Uso

### En Cloud Shell:

1. **Subir ZIP**:
   - Menú ⋮ → Upload
   - Seleccionar: ${OUTPUT_ZIP}

2. **Descomprimir**:
   \`\`\`bash
   unzip ${OUTPUT_ZIP} -d b3_pipeline
   cd b3_pipeline
   \`\`\`

3. **Ejecutar deployment completo**:
   \`\`\`bash
   chmod +x deploy.sh execute_b3_pipeline.sh
   ./deploy.sh
   \`\`\`

### Ejecución Alternativa (sin Docker):

Si prefieres ejecutar directamente:
\`\`\`bash
chmod +x execute_b3_pipeline.sh
./execute_b3_pipeline.sh
\`\`\`

## 📊 Validación de Resultados

Después de la ejecución:

\`\`\`bash
# Ver resumen de Gate B3
bq query --use_legacy_sql=false --project_id=${PROJECT_ID} \\
"SELECT * FROM ${DATASET_ID}.b3_fix_gate_summary_h4 
ORDER BY scope, metric_name"

# Contar registros en tabla de evaluación
bq query --use_legacy_sql=false --project_id=${PROJECT_ID} \\
"SELECT 
  COUNT(*) as total_rows,
  COUNT(DISTINCT segment_id) as segments,
  COUNT(DISTINCT horizon) as horizons
FROM ${DATASET_ID}.conditional_coverage_evaluation_v2_h4"
\`\`\`

## ⏱️ Tiempo Estimado
- Build Docker: 2-3 min
- Ejecución queries: 10-15 min
- Total: ~15-20 min

## 🐛 Troubleshooting

### Error: "permission denied"
\`\`\`bash
chmod +x *.sh
\`\`\`

### Error: "No module named src.entrypoint"
→ Normal, usa \`execute_b3_pipeline.sh\` directamente (no define entrypoint Python)

### Error: "table not found"
→ Verifica que existen tablas base:
\`\`\`bash
bq ls ${DATASET_ID} | grep -E 'calibration|volatility|conformal'
\`\`\`
"@

$README | Out-File -FilePath "$TEMP_DIR\README.md" -Encoding utf8

# Step 8: Clean pycache and logs
Write-Host "[8/10] Limpiando archivos temporales..." -ForegroundColor White
Get-ChildItem -Path $TEMP_DIR -Recurse -Include "__pycache__","*.pyc","*.log" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Step 9: Create ZIP
Write-Host "[9/10] Comprimiendo archivos..." -ForegroundColor White
if (Test-Path $OUTPUT_ZIP) {
    Remove-Item $OUTPUT_ZIP -Force
}
Compress-Archive -Path "$TEMP_DIR\*" -DestinationPath $OUTPUT_ZIP -Force

# Step 10: Cleanup
Write-Host "[10/10] Limpiando directorio temporal..." -ForegroundColor White
Remove-Item -Recurse -Force $TEMP_DIR

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DEPLOYMENT PACKAGE CREATED" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
$zipInfo = Get-Item $OUTPUT_ZIP
Write-Host "📦 Archivo: $OUTPUT_ZIP" -ForegroundColor Green
Write-Host "📏 Tamaño: $([math]::Round($zipInfo.Length / 1MB, 2)) MB" -ForegroundColor Green
Write-Host "📅 Fecha: $($zipInfo.LastWriteTime)" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host '1. Subir ZIP a Cloud Shell (menu Upload)' -ForegroundColor White
Write-Host '2. Descomprimir: unzip cruzber_b3_pipeline_full.zip -d b3_pipeline' -ForegroundColor White
Write-Host '3. Ejecutar: cd b3_pipeline' -ForegroundColor White
Write-Host '4. Ejecutar: chmod +x deploy.sh && ./deploy.sh' -ForegroundColor White
Write-Host ""
