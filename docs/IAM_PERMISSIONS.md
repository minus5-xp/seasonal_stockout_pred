# IAM PERMISSIONS GUIDE

**Purpose**: Document required Google Cloud IAM permissions for BQML OOS Alerting Pipeline.  
**Project**: voltaic-tuner-475510-s4  
**Dataset**: dataset_cruzber_eu  

---

## 1. REQUIRED IAM ROLES

### Minimum Required Roles (Per User)

**For Data Scientists / Pipeline Runners**:
- `roles/bigquery.dataEditor` (BigQuery Data Editor)  
  **OR** custom role with specific permissions (see §2)
- `roles/bigquery.jobUser` (BigQuery Job User)

**For Dashboard Users (Read-Only)**:
- `roles/bigquery.dataViewer` (BigQuery Data Viewer)

---

## 2. REQUIRED PERMISSIONS (Custom Role Approach)

If using a custom role instead of predefined roles, grant these specific permissions:

### Core Permissions
```
bigquery.jobs.create          # Required to run queries
bigquery.jobs.get             # Required to check job status

bigquery.tables.create        # Required for CREATE TABLE
bigquery.tables.delete        # Required for CREATE OR REPLACE TABLE
bigquery.tables.get           # Required to read table metadata
bigquery.tables.getData       # Required for SELECT queries
bigquery.tables.list          # Required to list tables in dataset
bigquery.tables.update        # Required for INSERT/UPDATE
bigquery.tables.updateData    # Required for DML operations

bigquery.models.create        # Required for BQML CREATE MODEL
bigquery.models.delete        # Required for CREATE OR REPLACE MODEL
bigquery.models.getData       # Required for ML.PREDICT
bigquery.models.list          # Required to list models
bigquery.models.updateData    # Required for model training

bigquery.datasets.get         # Required to access dataset metadata
```

### Optional Permissions (For Export/Monitoring)
```
bigquery.savedqueries.create  # If using Scheduled Queries
bigquery.savedqueries.update  # If updating Scheduled Queries
bigquery.transfers.get        # If using Data Transfer Service
```

---

## 3. SETUP COMMANDS

### Option A: Grant Predefined Roles (Recommended)

**Grant to User**:
```powershell
# Replace USER_EMAIL with actual email (e.g., hugo@deval.work)
gcloud projects add-iam-policy-binding voltaic-tuner-475510-s4 `
  --member="user:USER_EMAIL" `
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding voltaic-tuner-475510-s4 `
  --member="user:USER_EMAIL" `
  --role="roles/bigquery.jobUser"
```

**Grant to Service Account** (for automated pipelines):
```powershell
# Create service account
gcloud iam service-accounts create bqml-pipeline-sa `
  --display-name="BQML OOS Pipeline Service Account" `
  --project=voltaic-tuner-475510-s4

# Grant permissions
gcloud projects add-iam-policy-binding voltaic-tuner-475510-s4 `
  --member="serviceAccount:bqml-pipeline-sa@voltaic-tuner-475510-s4.iam.gserviceaccount.com" `
  --role="roles/bigquery.dataEditor"

gcloud projects add-iam-policy-binding voltaic-tuner-475510-s4 `
  --member="serviceAccount:bqml-pipeline-sa@voltaic-tuner-475510-s4.iam.gserviceaccount.com" `
  --role="roles/bigquery.jobUser"
```

---

### Option B: Create Custom Role (Advanced)

**Create custom role with minimum permissions**:
```powershell
# Define role in YAML
cat > bqml-pipeline-role.yaml @"
title: "BQML Pipeline Runner"
description: "Minimum permissions for BQML OOS alerting pipeline"
stage: "GA"
includedPermissions:
- bigquery.jobs.create
- bigquery.jobs.get
- bigquery.tables.create
- bigquery.tables.delete
- bigquery.tables.get
- bigquery.tables.getData
- bigquery.tables.list
- bigquery.tables.update
- bigquery.tables.updateData
- bigquery.models.create
- bigquery.models.delete
- bigquery.models.getData
- bigquery.models.list
- bigquery.models.updateData
- bigquery.datasets.get
"@

# Create role
gcloud iam roles create bqmlPipelineRunner `
  --project=voltaic-tuner-475510-s4 `
  --file=bqml-pipeline-role.yaml

# Grant to user
gcloud projects add-iam-policy-binding voltaic-tuner-475510-s4 `
  --member="user:USER_EMAIL" `
  --role="projects/voltaic-tuner-475510-s4/roles/bqmlPipelineRunner"
```

---

## 4. DATASET-LEVEL PERMISSIONS (Optional Fine-Grained Control)

**If you prefer to restrict access to a specific dataset** (dataset_cruzber_eu), use dataset ACLs:

```powershell
# Grant dataset access to user
bq update --dataset `
  --access_role=WRITER `
  --access_user="USER_EMAIL" `
  voltaic-tuner-475510-s4:dataset_cruzber_eu

# Grant dataset access to service account
bq update --dataset `
  --access_role=WRITER `
  --access_service_account="bqml-pipeline-sa@voltaic-tuner-475510-s4.iam.gserviceaccount.com" `
  voltaic-tuner-475510-s4:dataset_cruzber_eu
```

**Access Roles**:
- `READER`: Can query tables/models, cannot create/modify
- `WRITER`: Can create tables/models, run queries, insert data
- `OWNER`: Full control (create/delete dataset)

**Recommendation**: Use `WRITER` for pipeline runners, `READER` for dashboard users.

---

## 5. APPLICATION DEFAULT CREDENTIALS (ADC) SETUP

**For Local Development** (laptop/workstation):
```powershell
# Authenticate with your user account
gcloud auth application-default login

# Verify credentials
gcloud auth application-default print-access-token
```

**For Production/Scheduled Pipelines** (Cloud Run, Compute Engine, etc.):
```powershell
# Use service account attached to compute resource
# No explicit auth needed (automatically uses attached SA)

# OR: Use service account key (NOT RECOMMENDED, prefer attached SA)
# gcloud auth activate-service-account --key-file=path/to/key.json
```

---

## 6. VERIFY PERMISSIONS

**Test BigQuery Access**:
```powershell
# Test query execution
bq query --nouse_legacy_sql `
  "SELECT 'permissions test' AS test_column"

# Test table creation (in your dataset)
bq query --nouse_legacy_sql `
  "CREATE OR REPLACE TABLE \`voltaic-tuner-475510-s4.dataset_cruzber_eu.test_permissions\` AS SELECT 1 AS test_col"

# Test model creation
bq query --nouse_legacy_sql `
  "CREATE OR REPLACE MODEL \`voltaic-tuner-475510-s4.dataset_cruzber_eu.test_model\`
   OPTIONS(model_type='LINEAR_REG', input_label_cols=['test_col'])
   AS SELECT 1 AS test_col"

# Cleanup
bq rm -f voltaic-tuner-475510-s4:dataset_cruzber_eu.test_permissions
bq rm -f voltaic-tuner-475510-s4:dataset_cruzber_eu.test_model
```

**Expected Output**: All commands succeed without errors.

---

## 7. TROUBLESHOOTING

### Error: "Permission denied to create/update table"

**Solution**:
1. Check user has `bigquery.tables.create` and `bigquery.tables.update` permissions
2. Verify ADC is active: `gcloud auth application-default print-access-token`
3. Ensure user has access to dataset: `bq show voltaic-tuner-475510-s4:dataset_cruzber_eu`

### Error: "Caller does not have bigquery.jobs.create permission"

**Solution**:
1. Grant `roles/bigquery.jobUser` role:
   ```powershell
   gcloud projects add-iam-policy-binding voltaic-tuner-475510-s4 `
     --member="user:USER_EMAIL" `
     --role="roles/bigquery.jobUser"
   ```

### Error: "Access denied to dataset dataset_cruzber_eu"

**Solution**:
1. Add user to dataset ACL (see §4):
   ```powershell
   bq update --dataset `
     --access_role=WRITER `
     --access_user="USER_EMAIL" `
     voltaic-tuner-475510-s4:dataset_cruzber_eu
   ```

---

## 8. SECURITY BEST PRACTICES

### 1. Use Service Accounts for Automation
- **DON'T**: Use personal user credentials in production
- **DO**: Create dedicated service account with minimum permissions
- **DO**: Attach service account to compute resource (Cloud Run, Compute Engine)

### 2. Rotate Credentials Regularly
- **IF** using service account keys (not recommended):
  - Rotate every 90 days
  - Store in Secret Manager, not in code

### 3. Audit Access Logs
- **Enable Data Access Logs** in Cloud Audit Logs:
  ```powershell
  gcloud projects set-iam-policy voltaic-tuner-475510-s4 audit-policy.yaml
  ```
  - Monitor: `bigquery.googleapis.com` service
  - Alert on: Unexpected table deletions, model modifications

### 4. Principle of Least Privilege
- **DON'T**: Grant `roles/owner` or `roles/editor` (too broad)
- **DO**: Use `roles/bigquery.dataEditor` (scoped to BigQuery only)
- **DO**: Use dataset-level ACLs (restrict to specific dataset)

---

## 9. IAM POLICY EXAMPLE (YAML)

**Complete policy for project** (for reference):

```yaml
bindings:
- members:
  - user:hugo@deval.work
  role: roles/bigquery.dataEditor
- members:
  - user:hugo@deval.work
  role: roles/bigquery.jobUser
- members:
  - user:ops.lead@example.com
  role: roles/bigquery.dataViewer
- members:
  - serviceAccount:bqml-pipeline-sa@voltaic-tuner-475510-s4.iam.gserviceaccount.com
  role: roles/bigquery.dataEditor
- members:
  - serviceAccount:bqml-pipeline-sa@voltaic-tuner-475510-s4.iam.gserviceaccount.com
  role: roles/bigquery.jobUser
```

**Apply policy**:
```powershell
gcloud projects set-iam-policy voltaic-tuner-475510-s4 iam-policy.yaml
```

---

## 10. CONTACTS

**Issues with permissions**:
- Cloud Admin: cloud.admin@example.com
- Project Owner: hugo@deval.work

**Request access**:
- Email: hugo@deval.work
- Include: Full name, email, reason for access (data scientist, ops, dashboard user)

---

**END OF IAM PERMISSIONS GUIDE**
