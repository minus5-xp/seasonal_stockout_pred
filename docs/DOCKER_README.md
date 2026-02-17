# Cruzber Option B - Containerized Pipeline

Complete containerized pipeline for reproducible execution of the Cruzber Option B stockout prediction system.

## Quick Start

### Prerequisites

- Docker installed and running
- Google Cloud SDK (for authentication)
- GCP project with BigQuery enabled
- GCS bucket for uploads (optional)

### Authentication (Local Development)

```powershell
# Authenticate with Google Cloud
gcloud auth application-default login

# Set your project
gcloud config set project YOUR_PROJECT_ID
```

### Build and Run

```powershell
# 1. Set environment variables
$env:PROJECT_ID = "your-project-id"
$env:BQ_DATASET = "cruzber_models_eu"
$env:GCS_BUCKET = "gs://your-bucket/cruzber"  # Optional

# 2. Build Docker image
.\scripts\build_image.ps1

# 3. Run pipeline
.\scripts\run_container.ps1
```

## Environment Variables

### Required

- `PROJECT_ID`: GCP project ID
- `BQ_DATASET`: BigQuery dataset name

### Optional

- `GCS_BUCKET`: GCS bucket for uploads (format: `gs://bucket/prefix`)
- `BQ_LOCATION`: BigQuery location (default: `EU`)
- `RUN_ID`: Unique run identifier (default: auto-generated timestamp)
- `MODE`: Execution mode (default: `optionB_full`)
  - `optionB_full`: Complete Option B pipeline
  - `trackA_only`: Track A only
  - `b3_fix_only`: B3 gate fix only
  - `eval_only`: Evaluation queries only
- `DRY_RUN`: Set to `1` for dry run (default: `0`)
- `VERBOSE`: Verbose logging (default: `0`)

### Pipeline Parameters

- `TOPK`: Top-K threshold for predictions (default: `100`)
- `N_MIN`: Minimum samples for conformal calibration (default: `200`)
- `VOL_NTILES`: Number of volatility buckets (default: `3`)
- `COVERAGE_GRID`: Coverage targets to test (default: `0.90,0.91,...,0.98`)

## Pipeline Modes

### Full Pipeline (`optionB_full`)

Executes complete pipeline:
1. **B0:** Registry & infrastructure
2. **B1:** Features & labels  
3. **B2:** Model training (BQML)
4. **B3:** Unconstraining & quantiles
5. **B4:** Policy simulation
6. **B5:** Evaluation & gates

```powershell
$env:MODE = "optionB_full"
.\scripts\run_container.ps1
```

### Dry Run

Preview what would be executed:

```powershell
$env:DRY_RUN = "1"
.\scripts\run_container.ps1
```

## CLI Commands

The container supports multiple subcommands:

### Plan

Show execution plan:

```powershell
docker run --rm cruzber-optionb-pipeline:latest plan
```

### Run

Execute pipeline:

```powershell
.\scripts\run_container.ps1  # Uses run command by default
```

### Eval

Run evaluation only:

```powershell
docker run --rm `
  -e PROJECT_ID=$env:PROJECT_ID `
  -e BQ_DATASET=$env:BQ_DATASET `
  cruzber-optionb-pipeline:latest eval
```

### Bundle

Create distributable bundle:

```powershell
docker run --rm `
  -v ${PWD}/dist:/app/dist `
  -e PROJECT_ID=$env:PROJECT_ID `
  -e BQ_DATASET=$env:BQ_DATASET `
  cruzber-optionb-pipeline:latest bundle
```

### Upload

Upload bundle to GCS:

```powershell
# First create bundle
python -m src.bundle.build_bundle

# Then upload
.\scripts\upload_bundle_to_gcs.ps1 dist/cruzber_optionB_bundle_*.tar.gz
```

### Finalize

Generate final reports:

```powershell
python -m src.entrypoint finalize
```

## Directory Structure

```
.
├── Dockerfile                   # Container definition
├── requirements.txt             # Python dependencies
├── src/
│   ├── entrypoint.py           # Main CLI
│   ├── config/
│   │   └── env.py              # Environment validation
│   ├── bq/
│   │   ├── client.py           # BigQuery client factory
│   │   └── run_sql_dir.py      # SQL executor
│   ├── bundle/
│   │   ├── build_bundle.py     # Bundle builder
│   │   └── upload_bundle.py    # GCS uploader
│   └── reports/
│       ├── generate_b3_report.py
│       ├── generate_b4_policy_report.py
│       ├── generate_checklist_final.py
│       ├── generate_paper_pack.py
│       └── generate_final_verdict.py
├── sql/
│   ├── 00_SQL_INDEX_OPTIONB.yml  # Query execution order
│   ├── features/                 # Feature engineering
│   ├── models/                   # BQML models
│   ├── unconstraining/           # U1/U2/U3
│   ├── quantiles_v2/             # Conformal prediction
│   ├── policy/                   # Policy simulation
│   └── eval/                     # Evaluation & gates
├── scripts/
│   ├── build_image.ps1
│   ├── run_container.ps1
│   ├── upload_bundle_to_gcs.ps1
│   └── export_bigquery_tables_to_gcs.sh
└── outputs/                      # Generated outputs

```

## Outputs

Generated outputs are saved to `outputs/<RUN_ID>/`:

- **reports_generated/**: Markdown reports
  - `B3_GATE_REPORT.md`: Gate B3 conditional coverage
  - `B4_POLICY_REPORT.md`: Policy performance
  - `LATEST_STATUS.md`: Pipeline status
- **paper/**: Paper pack for publication
  - JSON exports for figures/tables
  - `paper_pack_manifest.json`
- **dist/**: Distributable bundles
  - `cruzber_optionB_bundle_<RUN_ID>.tar.gz`
- **FINAL_VERDICT.md**: Overall pass/fail verdict
- **checklist_status_final.csv**: Deliverables checklist

## Bundle Structure

The bundle (`*.tar.gz`) includes:

- `manifest.json`: File hashes and metadata
- `sql/`: All SQL queries
- `src/`: Python source code
- `docs/`: Documentation
- `scripts/`: Execution scripts
- `reports/`: Report templates

Upload to GCS for archival:

```powershell
.\scripts\upload_bundle_to_gcs.ps1 dist/cruzber_optionB_bundle_20260215_143022.tar.gz
```

## Cloud Execution

### Cloud Build

```yaml
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/cruzber-pipeline', '.']
  
  - name: 'gcr.io/$PROJECT_ID/cruzber-pipeline'
    env:
      - 'PROJECT_ID=$PROJECT_ID'
      - 'BQ_DATASET=cruzber_models_eu'
      - 'GCS_BUCKET=gs://$PROJECT_ID-cruzber'
    args: ['run']

images:
  - 'gcr.io/$PROJECT_ID/cruzber-pipeline'
```

### Cloud Run Jobs

```powershell
# Deploy
gcloud run jobs create cruzber-pipeline `
  --image gcr.io/$env:PROJECT_ID/cruzber-pipeline `
  --region us-central1 `
  --set-env-vars PROJECT_ID=$env:PROJECT_ID,BQ_DATASET=cruzber_models_eu `
  --max-retries 0

# Execute
gcloud run jobs execute cruzber-pipeline --region us-central1
```

## Troubleshooting

### Authentication Errors

```
❌ Failed to create BigQuery client
```

**Solution:** Authenticate locally:
```powershell
gcloud auth application-default login
```

### Missing Credentials in Container

**Local:** Ensure ADC file exists at `%APPDATA%\gcloud\application_default_credentials.json`

**Cloud:** Use service account or workload identity

### Empty Evaluation Results

Check:
1. Base tables exist (`pred_point_uc_h4`)
2. Calibration data has sufficient samples
3. Segment thresholds aren't too restrictive

Run diagnostics:
```powershell
python diagnose_complete_b3.py
```

### Bundle Upload Fails

Ensure bucket exists:
```powershell
gsutil mb -l EU gs://your-bucket
```

Grant permissions:
```powershell
gsutil iam ch user:your-email@example.com:roles/storage.objectAdmin gs://your-bucket
```

## Definition of Done

Pipeline is submit-ready when:

- [ ] All queries execute without errors
- [ ] Gate B3 PASS (conditional coverage ∈ [8%, 12%])
- [ ] Gate B4 PASS (policy efficiency > 0.8)
- [ ] Bundle created and uploaded to GCS
- [ ] `FINAL_VERDICT.md` shows PASS
- [ ] Paper pack generated
- [ ] Final checklist complete

Check status:
```powershell
python -m src.entrypoint finalize
cat FINAL_VERDICT.md
```

## Support

For issues:
1. Check `reports_generated/LATEST_STATUS.md`
2. Review BigQuery job logs
3. Run with `$env:VERBOSE = "1"`
4. Check `outputs/<RUN_ID>/` for detailed logs

## License

Internal research project - not for public distribution.
