# 🚀 Ejecutar Pipeline desde Google Cloud Shell

## ✅ Ventajas de Cloud Shell
- ✓ Docker preinstalado
- ✓ gcloud CLI configurado
- ✓ Python 3.11+ disponible
- ✓ Autenticación automática (ADC)
- ✓ Sin problemas de PowerShell/Windows
- ✓ 50 GB de almacenamiento persistente en $HOME

---

## 📋 PASO 1: Iniciar Cloud Shell

1. Ir a: https://console.cloud.google.com
2. Clic en el icono **>_** (Activate Cloud Shell) en la esquina superior derecha
3. Esperar a que inicie (30-60 segundos)

---

## 📦 PASO 2: Subir el código

### Opción A: Desde tu máquina local (ZIP)

```bash
# En tu máquina local Windows, comprimir el proyecto:
# (Excluir: __pycache__, *.pyc, .git, outputs/, logs/)

# En Cloud Shell, subir el archivo:
# 1. Clic en "⋮" (More) → "Upload"
# 2. Seleccionar cruzber_pipeline.zip
# 3. Descomprimir:

cd ~
unzip cruzber_pipeline.zip -d cruzber_pipeline
cd cruzber_pipeline
```

### Opción B: Usar Cloud Shell Editor

```bash
# 1. Clic en "Open Editor" en Cloud Shell
# 2. Crear estructura de directorios
# 3. Copiar/pegar archivos clave:
#    - Dockerfile
#    - requirements.txt
#    - sql/
#    - src/
#    - scripts/

mkdir -p ~/cruzber_pipeline
cd ~/cruzber_pipeline
```

### Opción C: Desde Git (si tienes repo)

```bash
cd ~
git clone https://github.com/tu-usuario/cruzber-pipeline.git cruzber_pipeline
cd cruzber_pipeline
```

---

## 🔧 PASO 3: Configurar variables de entorno

```bash
# Establecer proyecto
export PROJECT_ID="thequantitativeledger"
export BQ_DATASET="cruzber_models_eu"
export GCS_BUCKET="gs://thequantitativeledger-cruzber/bundles"
export BQ_LOCATION="EU"

# Hacer permanente (opcional)
echo 'export PROJECT_ID="thequantitativeledger"' >> ~/.bashrc
echo 'export BQ_DATASET="cruzber_models_eu"' >> ~/.bashrc
echo 'export GCS_BUCKET="gs://thequantitativeledger-cruzber/bundles"' >> ~/.bashrc
echo 'export BQ_LOCATION="EU"' >> ~/.bashrc

# Configurar gcloud
gcloud config set project thequantitativeledger
```

---

## 🐳 PASO 4: Construir imagen Docker

```bash
cd ~/cruzber_pipeline

# Dar permisos de ejecución a scripts
chmod +x scripts/*.sh

# Construir imagen (2-5 minutos)
./scripts/build_image.sh

# Verificar
docker images | grep cruzber-optionb-pipeline
```

**Salida esperada:**
```
========================================
Building Docker Image
========================================
Image: cruzber-optionb-pipeline:latest

[+] Building 120.5s (15/15) FINISHED
...
✓ Image built successfully
```

---

## ▶️ PASO 5: Ejecutar pipeline

### 5.1 Dry run (preview sin ejecutar)

```bash
export DRY_RUN=1
./scripts/run_container.sh
```

**Verifica:**
- ✓ Muestra las 24 queries en orden
- ✓ Sin errores de autenticación
- ✓ Dataset accesible

### 5.2 Ejecución completa

```bash
export DRY_RUN=0
export MODE="optionB_full"  # Opciones: optionB_full, b3_fix_only, eval_only

# Ejecutar (15-30 minutos)
./scripts/run_container.sh
```

**Salida esperada:**
```
========================================
Running Cruzber Option B Pipeline
========================================
Mode: optionB_full
Project: thequantitativeledger
Dataset: cruzber_models_eu
...
[B0] registry_catalog_codes_h4_v3... ✓ (2.3s)
[B1] features_g453_panel_h4... ✓ (45.1s)
...
[B3] mondrian_conformal_quantiles_v2... ✓ (120.5s)
...
Pipeline completed: 24/24 queries succeeded
Total slot-ms: 1,234,567
Total GB processed: 45.2 GB
```

### 5.3 Solo evaluación (si ya ejecutaste B0-B4)

```bash
export MODE="eval_only"
./scripts/run_container.sh
```

---

## 📊 PASO 6: Generar reportes finales

```bash
# Dentro del contenedor o localmente:
docker run --rm \
  -v ~/.config/gcloud:/root/.config/gcloud:ro \
  -e PROJECT_ID="thequantitativeledger" \
  -e BQ_DATASET="cruzber_models_eu" \
  cruzber-optionb-pipeline:latest \
  finalize

# O usar Python directo:
pip install -r requirements.txt
python -m src.entrypoint finalize
```

**Genera:**
- `FINAL_VERDICT.md` → PASS/FAIL global
- `B3_GATE_REPORT.md` → Conditional coverage
- `B4_POLICY_REPORT.md` → Policy performance  
- `checklist_status_final.csv` → Deliverables
- `paper/` → JSON exports para tablas del paper

---

## 📦 PASO 7: Crear y subir bundle

```bash
# 7.1 Crear bundle
python -m src.entrypoint bundle

# Verifica el archivo creado
ls -lh dist/cruzber_optionB_bundle_*.tar.gz

# 7.2 Subir a GCS
BUNDLE_FILE=$(ls dist/cruzber_optionB_bundle_*.tar.gz | head -1)
./scripts/upload_bundle_to_gcs.sh "$BUNDLE_FILE"
```

**Verifica en GCS:**
```bash
gsutil ls gs://thequantitativeledger-cruzber/bundles/
```

---

## 🔍 PASO 8: Validar resultados

### 8.1 Verificar Gate B3

```bash
bq query --use_legacy_sql=false --project_id=thequantitativeledger \
"SELECT scope, metric_name, status 
FROM cruzber_models_eu.b3_fix_gate_summary_h4 
WHERE status != 'PASS'"
```

**Esperado:** 0 rows (todos PASS)

### 8.2 Verificar Gate B4

```bash
bq query --use_legacy_sql=false --project_id=thequantitativeledger \
"SELECT policy_name, efficiency_score, pass_b4 
FROM cruzber_models_eu.policy_simulation_results_h4 
ORDER BY efficiency_score DESC LIMIT 5"
```

**Esperado:** efficiency_score > 0.80

### 8.3 Descargar reportes localmente

```bash
# Descargar a tu máquina
# 1. En Cloud Shell: clic en "⋮" → "Download"
# 2. Seleccionar: FINAL_VERDICT.md, paper/, dist/

# O vía GCS:
gsutil -m cp -r \
  gs://thequantitativeledger-cruzber/bundles/reports_* \
  ./local_reports/
```

---

## 🛠️ Comandos útiles de mantenimiento

### Ver logs del contenedor
```bash
docker logs $(docker ps -lq)
```

### Entrar al contenedor para debugging
```bash
docker run -it --rm \
  -v ~/.config/gcloud:/root/.config/gcloud:ro \
  -e PROJECT_ID="thequantitativeledger" \
  -e BQ_DATASET="cruzber_models_eu" \
  cruzber-optionb-pipeline:latest \
  /bin/bash
```

### Limpiar imágenes antiguas
```bash
docker system prune -a --volumes
```

### Ver tablas creadas
```bash
bq ls --project_id=thequantitativeledger cruzber_models_eu
```

### Exportar tabla a CSV
```bash
bq extract --destination_format=CSV \
  thequantitativeledger:cruzber_models_eu.pred_quantiles_v2_h4 \
  gs://thequantitativeledger-cruzber/exports/pred_quantiles_v2_h4.csv
```

---

## ⚡ Ejecución rápida (todo en uno)

```bash
# Desde inicio hasta bundle (sin interacción)
cd ~/cruzber_pipeline

export PROJECT_ID="thequantitativeledger"
export BQ_DATASET="cruzber_models_eu"
export GCS_BUCKET="gs://thequantitativeledger-cruzber/bundles"

chmod +x scripts/*.sh

# Build + Run + Finalize + Bundle + Upload
./scripts/build_image.sh && \
export DRY_RUN=0 && \
export MODE="optionB_full" && \
./scripts/run_container.sh && \
python -m src.entrypoint finalize && \
python -m src.entrypoint bundle && \
./scripts/upload_bundle_to_gcs.sh $(ls dist/cruzber_optionB_bundle_*.tar.gz | head -1)

# Ver veredicto final
cat FINAL_VERDICT.md
```

---

## ❌ Troubleshooting común

### Error: "Permission denied" al ejecutar script
```bash
chmod +x scripts/*.sh
```

### Error: "Docker is not running"
```bash
# En Cloud Shell, Docker siempre está activo
# Si falla, reiniciar Cloud Shell
```

### Error: "Application Default Credentials not found"
```bash
# Cloud Shell ya tiene ADC configurado
# Verificar:
gcloud auth application-default print-access-token
```

### Error: "Table not found" en evaluación
```bash
# Ejecutar pipeline completo primero
export MODE="optionB_full"
./scripts/run_container.sh
```

### Error: "Out of memory" en Cloud Shell
```bash
# Cloud Shell tiene 8 GB RAM
# Para queries grandes, usar Compute Engine VM en lugar de contenedor:
# VM recomendada: e2-standard-4 (4 vCPUs, 16 GB)
```

---

## 📤 Transferir resultados a tu máquina local

### Opción A: Descarga directa desde Cloud Shell
```bash
# En Cloud Shell:
tar czf results.tar.gz FINAL_VERDICT.md B3_GATE_REPORT.md B4_POLICY_REPORT.md paper/ dist/

# Descargar: clic en "⋮" → "Download" → results.tar.gz
```

### Opción B: Vía GCS
```bash
# En Cloud Shell: subir a GCS
gsutil -m cp FINAL_VERDICT.md B3_GATE_REPORT.md B4_POLICY_REPORT.md \
  gs://thequantitativeledger-cruzber/reports/

# En tu máquina Windows:
gsutil -m cp -r gs://thequantitativeledger-cruzber/reports/* ./local_results/
```

---

## ⏱️ Tiempos estimados

| Paso | Tiempo | Notas |
|------|--------|-------|
| Subir código | 2-5 min | Depende del tamaño del proyecto |
| Build imagen | 3-5 min | Primera vez descarga Python base |
| Dry run | 10-30 seg | Solo parsing, sin queries |
| Pipeline completo | 15-30 min | 24 queries, depende de volumen de datos |
| Finalize reports | 1-2 min | 6 queries de evaluación |
| Bundle creation | 30 seg | Compresión + hashing |
| Upload to GCS | 1-2 min | Bundle ~50-100 MB |
| **TOTAL** | **25-45 min** | Desde cero hasta bundle en GCS |

---

## ✅ Checklist de éxito

```
[ ] Cloud Shell iniciado
[ ] Código subido (Dockerfile, sql/, src/, scripts/)
[ ] Variables de entorno configuradas ($PROJECT_ID, $BQ_DATASET, $GCS_BUCKET)
[ ] Imagen Docker construida (cruzber-optionb-pipeline:latest)
[ ] Dry run completado sin errores
[ ] Pipeline ejecutado (24/24 queries ✓)
[ ] Reportes generados (FINAL_VERDICT.md, B3_GATE_REPORT.md, B4_POLICY_REPORT.md)
[ ] Bundle creado (dist/cruzber_optionB_bundle_*.tar.gz)
[ ] Bundle subido a GCS
[ ] Gate B3: PASS (todos los segmentos en [8%, 12%])
[ ] Gate B4: PASS (efficiency_score > 0.80)
[ ] Paper pack exportado (paper/*.json)
[ ] Resultados descargados localmente
```

---

## 🎯 Siguiente paso inmediato

```bash
# Copiar y pegar en Cloud Shell:

cd ~
mkdir -p cruzber_pipeline
cd cruzber_pipeline

# ESPERAR: Ahora sube los archivos desde tu máquina
# (Usa "Upload" del menú ⋮ de Cloud Shell)
# Archivos necesarios:
# - Dockerfile
# - requirements.txt
# - .dockerignore
# - sql/ (completo)
# - src/ (completo)
# - scripts/ (completo)

echo "✓ Workspace preparado. Ahora sube los archivos."
```

**¿Necesitas ayuda para empaquetar los archivos localmente antes de subirlos?**
