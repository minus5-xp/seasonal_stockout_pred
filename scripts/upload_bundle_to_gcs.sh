#!/bin/bash
# Upload bundle to GCS bucket

set -e

# Configuration
BUNDLE_FILE="${1}"
GCS_BUCKET="${GCS_BUCKET}"

if [ -z "${BUNDLE_FILE}" ]; then
    echo "Usage: $0 <bundle-file.tar.gz>"
    echo ""
    echo "Environment variables:"
    echo "  GCS_BUCKET    Target GCS bucket (gs://bucket/prefix)"
    exit 1
fi

if [ ! -f "${BUNDLE_FILE}" ]; then
    echo "❌ File not found: ${BUNDLE_FILE}"
    exit 1
fi

if [ -z "${GCS_BUCKET}" ]; then
    echo "❌ GCS_BUCKET environment variable not set"
    echo ""
    echo "Set it to your target bucket:"
    echo "  export GCS_BUCKET=gs://your-bucket/bundles"
    exit 1
fi

echo "========================================"
echo "Uploading Bundle to GCS"
echo "========================================"
echo "File:   ${BUNDLE_FILE}"
echo "Bucket: ${GCS_BUCKET}"
echo ""

# Extract bundle name
BUNDLE_NAME=$(basename "${BUNDLE_FILE}")
GCS_PATH="${GCS_BUCKET}/${BUNDLE_NAME}"

echo "Destination: ${GCS_PATH}"
echo ""

# Check if gsutil is available
if command -v gsutil &> /dev/null; then
    echo "Using gsutil..."
    gsutil -m cp "${BUNDLE_FILE}" "${GCS_PATH}"
else
    echo "gsutil not found, using Python client..."
    python3 -m src.bundle.upload_bundle "${BUNDLE_FILE}" --destination "${GCS_PATH}"
fi

echo ""
echo "✓ Upload complete"
echo ""
echo "To download:"
echo "  gsutil cp ${GCS_PATH} ."
