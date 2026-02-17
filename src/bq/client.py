#!/usr/bin/env python3
"""
BigQuery client factory with ADC support.
Uses Application Default Credentials (no hardcoded keys).
"""
from google.cloud import bigquery
from google.api_core import retry
from typing import Optional
import os
import sys


class BigQueryClientFactory:
    """Factory for creating BigQuery clients with proper authentication."""
    
    @staticmethod
    def create_client(
        project_id: str,
        location: str = "EU",
        credentials: Optional[any] = None
    ) -> bigquery.Client:
        """
        Create BigQuery client using ADC or provided credentials.
        
        Args:
            project_id: GCP project ID
            location: Default location for queries/datasets
            credentials: Optional credentials object (for testing)
            
        Returns:
            Configured BigQuery client
            
        Raises:
            SystemExit: If authentication fails
        """
        try:
            client = bigquery.Client(
                project=project_id,
                location=location,
                credentials=credentials
            )
            
            # Test connection
            client.query("SELECT 1").result()
            
            return client
            
        except Exception as e:
            print(f"❌ Failed to create BigQuery client: {e}", file=sys.stderr)
            print("\nEnsure you have authenticated:", file=sys.stderr)
            print("  Local: gcloud auth application-default login", file=sys.stderr)
            print("  Cloud: Use service account or workload identity", file=sys.stderr)
            sys.exit(1)
    
    @staticmethod
    def ensure_dataset_exists(
        client: bigquery.Client,
        dataset_id: str,
        location: str = "EU"
    ) -> bigquery.Dataset:
        """
        Create dataset if it doesn't exist.
        
        Args:
            client: BigQuery client
            dataset_id: Dataset ID (project.dataset format)
            location: Dataset location
            
        Returns:
            Dataset object
        """
        try:
            dataset = client.get_dataset(dataset_id)
            print(f"✓ Dataset exists: {dataset_id}")
            return dataset
            
        except Exception:
            print(f"Creating dataset: {dataset_id}")
            dataset = bigquery.Dataset(dataset_id)
            dataset.location = location
            dataset = client.create_dataset(dataset, exists_ok=True)
            print(f"✓ Dataset created: {dataset_id}")
            return dataset


def get_default_client(project_id: str, location: str = "EU") -> bigquery.Client:
    """
    Convenience function to get a client with default settings.
    
    Args:
        project_id: GCP project ID
        location: Default query location
        
    Returns:
        BigQuery client
    """
    return BigQueryClientFactory.create_client(project_id, location)


# Retry configuration for transient errors
RETRY_CONFIG = retry.Retry(
    initial=1.0,
    maximum=10.0,
    multiplier=2.0,
    predicate=retry.if_transient_error,
)
