# ============================================================================
# Cruzber Option B Pipeline - Production Docker Image
# ============================================================================
# Multi-stage build for optimized image size
# Includes gcloud SDK for BigQuery operations without embedded credentials
# Relies on ADC (Application Default Credentials) for authentication
# ============================================================================

FROM python:3.11-slim AS base

# Install system dependencies + gcloud SDK (using modern keyring method)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    && mkdir -p /usr/share/keyrings \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
       > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-sdk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY sql/ sql/
COPY src/ src/
COPY scripts/ scripts/
COPY docs/ docs/

# Create output directories
RUN mkdir -p outputs reports_generated paper dist logs

# Environment defaults (override at runtime)
ENV PYTHONUNBUFFERED=1
ENV PROJECT_ID=thequantitativeledger
ENV BQ_DATASET=cruzber_models_eu
ENV BQ_LOCATION=EU
ENV GCS_BUCKET=gs://thequantitativeledger-cruzber/bundles
ENV MODE=optionB_full

# Health check: verify environment is configured
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import os; assert os.getenv('PROJECT_ID'), 'PROJECT_ID not set'" || exit 1

# Default entrypoint: run pipeline via CLI
ENTRYPOINT ["python", "-m", "src.entrypoint"]
CMD ["run"]
