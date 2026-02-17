"""
BigQuery Configuration Module
==============================
Loads BigQuery project settings from environment variables.
Uses Application Default Credentials (ADC) - no hardcoded secrets.

Required Environment Variables:
    GCP_PROJECT_ID: Google Cloud Platform project ID
    BQ_DATASET_ID: BigQuery dataset name (default: dataset_cruzber_eu)
    BQ_LOCATION: BigQuery location (default: europe-southwest1)

Setup Instructions:
    1. gcloud auth login hugo@deval.work
    2. gcloud auth application-default login
    3. gcloud config set project YOUR_PROJECT_ID
    4. export GCP_PROJECT_ID=YOUR_PROJECT_ID (or set in .env)
    5. export BQ_DATASET_ID=dataset_cruzber_eu
"""

import os
from typing import Optional


class BQConfig:
    """BigQuery configuration container."""
    
    def __init__(
        self,
        project_id: Optional[str] = None,
        dataset_id: Optional[str] = None,
        location: Optional[str] = None
    ):
        """
        Initialize BigQuery configuration.
        
        Args:
            project_id: GCP project ID (reads from env if None)
            dataset_id: BigQuery dataset name (reads from env if None)
            location: BigQuery location (reads from env if None)
        
        Raises:
            ValueError: If required configuration is missing
        """
        self.project_id = project_id or os.getenv('GCP_PROJECT_ID')
        self.dataset_id = dataset_id or os.getenv('BQ_DATASET_ID', 'dataset_cruzber_eu')
        self.location = location or os.getenv('BQ_LOCATION', 'europe-southwest1')
        
        # Validate required fields
        if not self.project_id:
            raise ValueError(
                "GCP_PROJECT_ID not set. Please run:\n"
                "  export GCP_PROJECT_ID=your-project-id\n"
                "or pass project_id explicitly to BQConfig()"
            )
        
        # Optional: validate dataset format
        if not self.dataset_id:
            raise ValueError("BQ_DATASET_ID not set")
    
    @property
    def dataset_ref(self) -> str:
        """Full dataset reference: project.dataset"""
        return f"{self.project_id}.{self.dataset_id}"
    
    def table_ref(self, table_name: str) -> str:
        """
        Full table reference: project.dataset.table
        
        Args:
            table_name: Table name (without project/dataset prefix)
        
        Returns:
            Fully qualified table name
        """
        return f"{self.project_id}.{self.dataset_id}.{table_name}"
    
    def __repr__(self) -> str:
        return (
            f"BQConfig(project_id='{self.project_id}', "
            f"dataset_id='{self.dataset_id}', location='{self.location}')"
        )
    
    def __str__(self) -> str:
        return self.dataset_ref


# Default configuration (lazy-loaded)
_default_config: Optional[BQConfig] = None


def get_config() -> BQConfig:
    """
    Get or create default BQConfig instance.
    
    Returns:
        Global BQConfig instance
    
    Raises:
        ValueError: If required env vars not set
    """
    global _default_config
    if _default_config is None:
        _default_config = BQConfig()
    return _default_config


def reset_config():
    """Reset default config (useful for testing)."""
    global _default_config
    _default_config = None


if __name__ == '__main__':
    # Test configuration
    try:
        config = get_config()
        print("✅ Configuration loaded successfully:")
        print(f"   Project: {config.project_id}")
        print(f"   Dataset: {config.dataset_id}")
        print(f"   Location: {config.location}")
        print(f"   Dataset Reference: {config.dataset_ref}")
        print(f"   Example Table: {config.table_ref('weekly_features_h4')}")
    except ValueError as e:
        print("❌ Configuration error:")
        print(f"   {e}")
        print("\nSetup Instructions:")
        print("1. gcloud auth login hugo@deval.work")
        print("2. gcloud auth application-default login")
        print("3. export GCP_PROJECT_ID=thequantitativeledger")
        print("4. export BQ_DATASET_ID=cruzber_models_eu")
        exit(1)
