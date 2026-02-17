#!/bin/bash
# Build Docker image for Cruzber Option B pipeline

set -e  # Exit on error

# Configuration
IMAGE_NAME="cruzber-optionb-pipeline"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

echo "========================================"
echo "Building Docker Image"
echo "========================================"
echo "Image: ${FULL_IMAGE_NAME}"
echo ""

# Build image
docker build \
  --tag "${FULL_IMAGE_NAME}" \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  --file Dockerfile \
  .

echo ""
echo "✓ Image built successfully: ${FULL_IMAGE_NAME}"
echo ""
echo "To run:"
echo "  ./scripts/run_container.sh"
echo ""
echo "To tag for registry:"
echo "  docker tag ${FULL_IMAGE_NAME} gcr.io/PROJECT_ID/${IMAGE_NAME}:${IMAGE_TAG}"
echo "  docker push gcr.io/PROJECT_ID/${IMAGE_NAME}:${IMAGE_TAG}"
