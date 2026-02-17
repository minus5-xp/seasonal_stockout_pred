# Cruzber Option B - Quick Start Guide

## 🚀 5-Minute Setup

### Step 1: Install Prerequisites

```powershell
# Verify Docker is running
docker --version

# Verify gcloud CLI
gcloud --version
```

### Step 2: Authenticate

```powershell
# Login to Google Cloud
gcloud auth application-default login

# Set your project
$env:PROJECT_ID = "your-project-id"
gcloud config set project $env:PROJECT_ID
```

### Step 3: Configure Environment

```powershell
# Required
$env:PROJECT_ID = "your-project-id"
$env:BQ_DATASET = "cruzber_models_eu"

# Optional
$env:GCS_BUCKET = "gs://your-bucket/cruzber"
$env:BQ_LOCATION = "EU"
```

### Step 4: Build Image

```powershell
.\scripts\build_image.ps1
```

Expected output:
```
========================================
Building Docker Image
========================================
Image: cruzber-optionb-pipeline:latest

...
✓ Image built successfully
```

### Step 5: Run Pipeline

```powershell
# Dry run (preview only)
$env:DRY_RUN = "1"
.\scripts\run_container.ps1

# Full execution
$env:DRY_RUN = "0"
.\scripts\run_container.ps1
```

Expected duration: 15-30 minutes

### Step 6: Check Results

```powershell
# View final verdict
cat FINAL_VERDICT.md

# Check checklist
cat checklist_status_final.csv

# View gate reports
cat reports_generated\B3_GATE_REPORT.md
cat reports_generated\B4_POLICY_REPORT.md
```

## 📦 Create and Upload Bundle

```powershell
# Build bundle
python -m src.entrypoint bundle

# Upload to GCS
$env:GCS_BUCKET = "gs://your-bucket/cruzber"
.\scripts\upload_bundle_to_gcs.ps1 dist\cruzber_optionB_bundle_*.tar.gz
```

## ✅ Success Criteria

Your pipeline is ready when:

```powershell
# Check final verdict
python -m src.entrypoint finalize
cat FINAL_VERDICT.md
```

Look for:
- ✓ PASS - Submit Ready
- All gates PASSED
- All deliverables present

## 🔧 Common Issues

### Issue: "docker: command not found"

**Solution:** Install Docker Desktop for Windows

### Issue: "ADC credentials not found"

**Solution:**
```powershell
gcloud auth application-default login
```

### Issue: "Dataset not found"

**Solution:** Pipeline auto-creates dataset. Ensure you have `bigquery.datasets.create` permission.

### Issue: "Permission denied" on GCS upload

**Solution:**
```powershell
# Create bucket
gsutil mb -l EU gs://your-bucket

# Grant access
gsutil iam ch user:your-email@example.com:roles/storage.objectAdmin gs://your-bucket
```

## 📚 Next Steps

- Read [DOCKER_README.md](DOCKER_README.md) for detailed documentation
- Review [sql/00_SQL_INDEX_OPTIONB.yml](sql/00_SQL_INDEX_OPTIONB.yml) for pipeline structure
- Check [src/entrypoint.py](src/entrypoint.py) for CLI options
- Explore outputs in `outputs/<RUN_ID>/`

## 🆘 Getting Help

1. Enable verbose logging:
   ```powershell
   $env:VERBOSE = "1"
   .\scripts\run_container.ps1
   ```

2. Check status:
   ```powershell
   python -m src.reports.generate_latest_status
   ```

3. Review BigQuery job history in [GCP Console](https://console.cloud.google.com/bigquery)
