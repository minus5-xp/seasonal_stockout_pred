# Build Docker image for Cruzber Option B pipeline
# Windows PowerShell version

$ErrorActionPreference = "Stop"

# Configuration
$IMAGE_NAME = "cruzber-optionb-pipeline"
$IMAGE_TAG = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "latest" }
$FULL_IMAGE_NAME = "${IMAGE_NAME}:${IMAGE_TAG}"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Building Docker Image" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Image: $FULL_IMAGE_NAME"
Write-Host ""

# Build image
docker build `
  --tag "$FULL_IMAGE_NAME" `
  --build-arg BUILDKIT_INLINE_CACHE=1 `
  --file Dockerfile `
  .

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n❌ Build failed" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Image built successfully: $FULL_IMAGE_NAME" -ForegroundColor Green
Write-Host ""
Write-Host "To run:"
Write-Host "  .\scripts\run_container.ps1"
Write-Host ""
Write-Host "To tag for registry (replace PROJECT_ID with your GCP project):"
Write-Host "  docker tag ${FULL_IMAGE_NAME} gcr.io/PROJECT_ID/${IMAGE_NAME}:${IMAGE_TAG}"
Write-Host "  docker push gcr.io/PROJECT_ID/${IMAGE_NAME}:${IMAGE_TAG}"
