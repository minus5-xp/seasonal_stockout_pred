#!/bin/bash
# Run Cruzber pipeline in Docker container
# Supports local ADC mount and environment variables

set -e

# Configuration
IMAGE_NAME="${IMAGE_NAME:-cruzber-optionb-pipeline:latest}"
MODE="${MODE:-optionB_full}"
DRY_RUN="${DRY_RUN:-0}"

# Required environment variables
: "${PROJECT_ID:?ERROR: PROJECT_ID must be set}"
: "${BQ_DATASET:?ERROR: BQ_DATASET must be set}"

# Optional with defaults
BQ_LOCATION="${BQ_LOCATION:-EU}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"

echo "========================================"
echo "Running Cruzber Pipeline in Container"
echo "========================================"
echo "Image:      ${IMAGE_NAME}"
echo "Project:    ${PROJECT_ID}"
echo "Dataset:    ${BQ_DATASET}"
echo "Mode:       ${MODE}"
echo "Run ID:     ${RUN_ID}"
echo ""

# Check for ADC credentials
ADC_PATH="${HOME}/.config/gcloud/application_default_credentials.json"
if [ ! -f "${ADC_PATH}" ]; then
    echo "⚠️  WARNING: ADC credentials not found at ${ADC_PATH}"
    echo "Run: gcloud auth application-default login"
    echo ""
fi

# Prepare volume mounts
VOLUMES=""
if [ -f "${ADC_PATH}" ]; then
    VOLUMES="-v ${ADC_PATH}:/root/.config/gcloud/application_default_credentials.json:ro"
    echo "✓ Mounting ADC credentials"
else
    echo "⚠️  Running without ADC mount (will use workload identity if available)"
fi

# Mount output directory
OUTPUT_DIR="${PWD}/outputs/${RUN_ID}"
mkdir -p "${OUTPUT_DIR}"
VOLUMES="${VOLUMES} -v ${OUTPUT_DIR}:/app/outputs"
echo "✓ Output directory: ${OUTPUT_DIR}"

echo ""
echo "Executing: docker run..."
echo ""

# Run container
docker run \
    --rm \
    --name "cruzber-pipeline-${RUN_ID}" \
    ${VOLUMES} \
    -e PROJECT_ID="${PROJECT_ID}" \
    -e BQ_DATASET="${BQ_DATASET}" \
    -e BQ_LOCATION="${BQ_LOCATION}" \
    -e GCS_BUCKET="${GCS_BUCKET:-}" \
    -e RUN_ID="${RUN_ID}" \
    -e MODE="${MODE}" \
    -e DRY_RUN="${DRY_RUN}" \
    -e TOPK="${TOPK:-100}" \
    -e N_MIN="${N_MIN:-200}" \
    -e VOL_NTILES="${VOL_NTILES:-3}" \
    -e COVERAGE_GRID="${COVERAGE_GRID:-0.90,0.91,0.92,0.93,0.94,0.95,0.96,0.97,0.98}" \
    -e VERBOSE="${VERBOSE:-0}" \
    "${IMAGE_NAME}" \
    run "$@"

echo ""
echo "✓ Pipeline execution complete"
echo "  Outputs: ${OUTPUT_DIR}"
