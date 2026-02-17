# 🚀 Migración a Google Cloud Shell - Guía Rápida

## ¿Por qué Cloud Shell?

✅ **Evita problemas de PowerShell** (encoding, sintaxis, compatibilidad)  
✅ **Docker + gcloud + Python preinstalados**  
✅ **Autenticación automática** (ADC)  
✅ **50 GB de almacenamiento persistente**  
✅ **Gratis** (5 GB RAM, sin cargos por uso de Cloud Shell)

---

## 📋 Proceso completo (3 pasos principales)

### PASO 1: Preparar archivos en Windows (1 minuto)

```powershell
# Desde PowerShell en tu máquina local:
.\prepare_for_cloudshell.ps1
```

**Resultado:** Crea `cruzber_pipeline_cloudshell.zip` (~10-50 MB)

---

### PASO 2: Subir a Cloud Shell (2 minutos)

1. Ir a: https://console.cloud.google.com
2. Clic en icono **`>_`** (Activate Cloud Shell) arriba a la derecha
3. Esperar a que inicie Cloud Shell (~30 seg)
4. Clic en menú **`⋮`** → **`Upload`**
5. Seleccionar `cruzber_pipeline_cloudshell.zip`
6. Esperar subida (~1-2 min)

---

### PASO 3: Ejecutar en Cloud Shell (30 minutos)

```bash
# Descomprimir
unzip cruzber_pipeline_cloudshell.zip -d cruzber_pipeline
cd cruzber_pipeline

# Setup automático (configura todo)
chmod +x cloudshell_quickstart.sh
./cloudshell_quickstart.sh

# Build imagen Docker (3-5 min)
./scripts/build_image.sh

# Ejecutar pipeline completo (15-30 min)
export DRY_RUN=0
export MODE="optionB_full"
./scripts/run_container.sh

# Generar reportes finales (1-2 min)
pip install -r requirements.txt
python -m src.entrypoint finalize

# Ver veredicto
cat FINAL_VERDICT.md
```

---

## 📊 Comandos uno por uno explicados

### 1️⃣ Configuración inicial

```bash
# Ya lo hace cloudshell_quickstart.sh automáticamente:
export PROJECT_ID="thequantitativeledger"
export BQ_DATASET="cruzber_models_eu"
export GCS_BUCKET="gs://thequantitativeledger-cruzber/bundles"
gcloud config set project thequantitativeledger
```

### 2️⃣ Build Docker

```bash
chmod +x scripts/*.sh
./scripts/build_image.sh
```

**Salida esperada:**
```
Building Docker Image
[+] Building 120.5s (15/15) FINISHED
✓ Image built successfully: cruzber-optionb-pipeline:latest
```

### 3️⃣ Test con dry run (opcional pero recomendado)

```bash
export DRY_RUN=1
./scripts/run_container.sh
```

**Verifica:**
- Muestra las 24 queries sin ejecutarlas
- Sin errores de autenticación
- Dataset accesible

### 4️⃣ Ejecución completa

```bash
export DRY_RUN=0
export MODE="optionB_full"  
# Opciones: optionB_full | b3_fix_only | eval_only
./scripts/run_container.sh
```

**Progreso esperado:**
```
[B0] registry_catalog_codes_h4_v3... ✓ (2.3s)
[B1] features_g453_panel_h4... ✓ (45.1s)
[B1] features_meteo_tourism_h4... ✓ (12.4s)
[B1] features_parks_holidays_h4... ✓ (8.2s)
[B2] model_h1_logistic... ✓ (120.5s)
[B2] model_h2_dnn... ✓ (89.3s)
[B2] model_h4_xgboost... ✓ (156.7s)
[B3] calibration_windows_v2... ✓ (34.2s)
[B3] volatility_profile_seg2... ✓ (45.8s)
...
Pipeline completed: 24/24 queries succeeded
```

### 5️⃣ Generar reportes

```bash
# Instalar dependencias (primera vez)
pip install -r requirements.txt

# Generar todos los reportes
python -m src.entrypoint finalize
```

**Archivos generados:**
- `FINAL_VERDICT.md` → PASS/FAIL con summary
- `B3_GATE_REPORT.md` → Conditional coverage detallado
- `B4_POLICY_REPORT.md` → Policy performance
- `checklist_status_final.csv` → Deliverables checklist
- `paper/*.json` → Exportaciones para tablas del paper

### 6️⃣ Crear bundle

```bash
python -m src.entrypoint bundle
```

**Resultado:** `dist/cruzber_optionB_bundle_YYYYMMDD_HHMMSS.tar.gz`

### 7️⃣ Subir a GCS

```bash
BUNDLE_FILE=$(ls dist/cruzber_optionB_bundle_*.tar.gz | head -1)
./scripts/upload_bundle_to_gcs.sh "$BUNDLE_FILE"
```

**Verificar:**
```bash
gsutil ls gs://thequantitativeledger-cruzber/bundles/
```

---

## 📥 Descargar resultados a tu máquina

### Opción A: Descarga directa desde Cloud Shell

```bash
# En Cloud Shell: comprimir resultados
tar czf results.tar.gz \
  FINAL_VERDICT.md \
  B3_GATE_REPORT.md \
  B4_POLICY_REPORT.md \
  checklist_status_final.csv \
  paper/ \
  dist/

# Descargar: Clic en menú "⋮" → "Download" → results.tar.gz
```

### Opción B: Vía GCS (recomendado)

```bash
# En Cloud Shell: subir a GCS
gsutil -m cp -r \
  FINAL_VERDICT.md \
  B3_GATE_REPORT.md \
  B4_POLICY_REPORT.md \
  paper/ \
  dist/ \
  gs://thequantitativeledger-cruzber/reports/$(date +%Y%m%d)/

# En tu Windows (PowerShell):
New-Item -ItemType Directory -Path "local_results" -Force
gsutil -m cp -r gs://thequantitativeledger-cruzber/reports/* ./local_results/
```

---

## ⚡ Script todo-en-uno (avanzado)

```bash
# Ejecuta todo el pipeline de inicio a fin sin paradas
cd ~/cruzber_pipeline

export PROJECT_ID="thequantitativeledger"
export BQ_DATASET="cruzber_models_eu"
export GCS_BUCKET="gs://thequantitativeledger-cruzber/bundles"

./cloudshell_quickstart.sh && \
./scripts/build_image.sh && \
export DRY_RUN=0 && export MODE="optionB_full" && \
./scripts/run_container.sh && \
pip install -r requirements.txt && \
python -m src.entrypoint finalize && \
python -m src.entrypoint bundle && \
./scripts/upload_bundle_to_gcs.sh $(ls dist/cruzber_optionB_bundle_*.tar.gz | head -1) && \
echo "" && \
echo "========================================" && \
echo "✓ PIPELINE COMPLETADO" && \
echo "========================================" && \
cat FINAL_VERDICT.md
```

---

## 🔍 Validación de resultados

### Gate B3 (conditional coverage)

```bash
bq query --use_legacy_sql=false --project_id=thequantitativeledger \
"SELECT scope, metric_name, metric_value, status 
FROM cruzber_models_eu.b3_fix_gate_summary_h4 
ORDER BY scope, metric_name"
```

**Esperado:** Todas las filas con `status = 'PASS'`

### Gate B4 (policy performance)

```bash
bq query --use_legacy_sql=false --project_id=thequantitativeledger \
"SELECT policy_name, efficiency_score, pass_b4 
FROM cruzber_models_eu.policy_simulation_results_h4 
ORDER BY efficiency_score DESC LIMIT 3"
```

**Esperado:** `efficiency_score > 0.80`

---

## ⏱️ Tiempos estimados

| Paso | Tiempo | 
|------|--------|
| Preparar ZIP en Windows | 1 min |
| Subir a Cloud Shell | 2 min |
| Setup inicial (cloudshell_quickstart.sh) | 30 seg |
| Build Docker | 3-5 min |
| Dry run | 15 seg |
| Pipeline completo (24 queries) | 15-30 min |
| Generar reportes | 2 min |
| Crear bundle | 30 seg |
| Upload a GCS | 1 min |
| **TOTAL** | **25-45 min** |

---

## ❌ Troubleshooting

### "Cannot access BigQuery dataset"
```bash
# Verificar permisos
gcloud projects get-iam-policy thequantitativeledger \
  --flatten="bindings[].members" \
  --filter="bindings.members:$(gcloud config get-value account)"

# Debe tener: roles/bigquery.dataEditor o roles/bigquery.admin
```

### "Table not found" en evaluación
```bash
# Ejecutar pipeline completo primero
export MODE="optionB_full"
./scripts/run_container.sh
```

### "Out of memory" en Cloud Shell
```bash
# Cloud Shell tiene límite de 8 GB RAM
# Opción 1: Usar Compute Engine VM
# Opción 2: Ejecutar en lotes (b3_fix_only, luego eval_only)
export MODE="b3_fix_only"
./scripts/run_container.sh
export MODE="eval_only"
./scripts/run_container.sh
```

### Docker build falla
```bash
# Cloud Shell reinicia cada ~20 min de inactividad
# Si falla, verificar que Docker esté activo:
docker ps
# Si no responde, abrir nueva sesión de Cloud Shell
```

---

## 📚 Documentación adicional

- **Guía completa:** `CLOUD_SHELL_SETUP.md` (500+ líneas, todos los detalles)
- **Comandos rápidos:** `EXACT_COMMANDS.md` (copy-paste)
- **Quickstart:** `QUICKSTART.md` (5 minutos al grano)

---

## ✅ Checklist de éxito

```
Windows (local):
[ ] .\prepare_for_cloudshell.ps1 ejecutado
[ ] cruzber_pipeline_cloudshell.zip creado

Cloud Shell:
[ ] Archivo ZIP subido
[ ] Descomprimido en ~/cruzber_pipeline
[ ] cloudshell_quickstart.sh ejecutado (setup)
[ ] Imagen Docker construida
[ ] Dry run completado sin errores
[ ] Pipeline ejecutado (24/24 queries ✓)
[ ] Reportes generados (FINAL_VERDICT.md existe)
[ ] Gate B3: PASS
[ ] Gate B4: PASS
[ ] Bundle creado y subido a GCS
[ ] Resultados descargados localmente

Paper ready:
[ ] paper/*.json exportados
[ ] B3_GATE_REPORT.md completo
[ ] B4_POLICY_REPORT.md completo
[ ] FINAL_VERDICT.md = PASS
```

---

## 🎯 INICIO RÁPIDO (copiar y pegar)

### En tu Windows:

```powershell
.\prepare_for_cloudshell.ps1
```

### En Cloud Shell (después de subir ZIP):

```bash
unzip cruzber_pipeline_cloudshell.zip -d cruzber_pipeline
cd cruzber_pipeline
chmod +x cloudshell_quickstart.sh
./cloudshell_quickstart.sh
./scripts/build_image.sh
export DRY_RUN=0 && export MODE="optionB_full"
./scripts/run_container.sh
pip install -r requirements.txt
python -m src.entrypoint finalize
cat FINAL_VERDICT.md
```

**¡Listo! Pipeline ejecutado en ~30 minutos sin problemas de PowerShell.**
