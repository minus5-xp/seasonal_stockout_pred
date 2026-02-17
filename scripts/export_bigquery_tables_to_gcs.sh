#!/bin/bash
# Export BigQuery tables to GCS (optional utility)

set -e

: "${PROJECT_ID:?ERROR: PROJECT_ID must be set}"
: "${BQ_DATASET:?ERROR: BQ_DATASET must be set}"
: "${GCS_BUCKET:?ERROR: GCS_BUCKET must be set}"

BQ_LOCATION="${BQ_LOCATION:-EU}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"

echo "========================================"
echo "Exporting BigQuery Tables to GCS"
echo "========================================"
echo "Project:  ${PROJECT_ID}"
echo "Dataset:  ${BQ_DATASET}"
echo "Bucket:   ${GCS_BUCKET}"
echo "Run ID:   ${RUN_ID}"
echo ""

# Tables to export (predefined list)
TABLES=(
    "pred_quantiles_v2_h4"
    "eval_quantiles_conditional_v2_h4"
    "b3_fix_gate_summary_h4"
    "policy_simulation_results_h4"
    "experiments_registry"
)

echo "Tables to export: ${#TABLES[@]}"
echo ""

for TABLE in "${TABLES[@]}"; do
    echo "Exporting ${TABLE}..."
    
    GCS_URI="${GCS_BUCKET}/exports/${RUN_ID}/${TABLE}/*.parquet"
    
    bq extract \
        --project_id="${PROJECT_ID}" \
        --location="${BQ_LOCATION}" \
        --destination_format=PARQUET \
        --compression=SNAPPY \
        "${PROJECT_ID}:${BQ_DATASET}.${TABLE}" \
        "${GCS_URI}"
    
    echo "  ✓ Exported to ${GCS_URI}"
done

echo ""
echo "✓ All tables exported"
echo ""
echo "Files available at:"
echo "  ${GCS_BUCKET}/exports/${RUN_ID}/"
