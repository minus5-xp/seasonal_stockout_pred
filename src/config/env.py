#!/usr/bin/env python3
"""
Environment variable validation and configuration management.
Ensures all required variables are set before pipeline execution.
"""
import os
import sys
from typing import Optional, Dict, Any
from dataclasses import dataclass
from pathlib import Path


@dataclass
class PipelineConfig:
    """Validated pipeline configuration from environment."""
    
    # Required
    project_id: str
    dataset_id: str
    gcs_bucket: str
    
    # Optional with defaults
    location: str = "EU"
    run_id: Optional[str] = None
    mode: str = "optionB_full"
    
    # Date range
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    
    # Tuning parameters
    topk: int = 100
    n_min: int = 200
    vol_ntiles: int = 3
    coverage_grid: str = "0.90,0.91,0.92,0.93,0.94,0.95,0.96,0.97,0.98"
    
    # Horizon forecasting (NEW - for h1/h4 stockout probabilities)
    base_sales_table: Optional[str] = None  # Fully qualified: project.dataset.table
    horizon_weeks: int = 4  # 1 = near-term (h1), 4 = strategic (h4)
    
    # Execution flags
    dry_run: bool = False
    verbose: bool = False
    skip_registry: bool = False
    
    @property
    def dataset_ref(self) -> str:
        """Fully qualified dataset reference."""
        return f"{self.project_id}.{self.dataset_id}"
    
    @property
    def gcs_bundle_path(self) -> str:
        """Full GCS path for bundle upload."""
        run_suffix = f"_{self.run_id}" if self.run_id else ""
        return f"{self.gcs_bucket}/bundles/cruzber_optionB_bundle{run_suffix}.tar.gz"
    
    @property
    def gcs_reports_path(self) -> str:
        """GCS path for generated reports."""
        run_suffix = f"{self.run_id}/" if self.run_id else "latest/"
        return f"{self.gcs_bucket}/reports/{run_suffix}"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for templating.
        
        Returns both lowercase and uppercase versions for maximum compatibility
        with existing SQL templates.
        """
        result = {
            # Lowercase (Python convention)
            "project_id": self.project_id,
            "dataset_id": self.dataset_id,
            "dataset_ref": self.dataset_ref,
            "location": self.location,
            "run_id": self.run_id,
            "topk": self.topk,
            "n_min": self.n_min,
            "vol_ntiles": self.vol_ntiles,
            "coverage_grid": self.coverage_grid,
            # Uppercase (SQL template convention)
            "PROJECT_ID": self.project_id,
            "BQ_DATASET": self.dataset_id,
            "BQ_LOCATION": self.location,
            "DATASET_REF": self.dataset_ref,
        }
        
        # Add horizon forecasting params if available
        if self.base_sales_table:
            result["BASE_SALES_TABLE"] = self.base_sales_table
            result["base_sales_table"] = self.base_sales_table
        
        if self.horizon_weeks:
            result["HORIZON_WEEKS"] = self.horizon_weeks
            result["horizon_weeks"] = self.horizon_weeks
        
        return result


def load_config(check_gcs: bool = True) -> PipelineConfig:
    """
    Load and validate configuration from environment variables.
    
    Args:
        check_gcs: If True, require GCS_BUCKET to be set
        
    Returns:
        Validated PipelineConfig
        
    Raises:
        SystemExit: If required variables are missing
    """
    errors = []
    
    # Required variables
    project_id = os.getenv("PROJECT_ID")
    if not project_id:
        errors.append("PROJECT_ID is required")
    
    dataset_id = os.getenv("BQ_DATASET", os.getenv("DATASET_ID"))
    if not dataset_id:
        errors.append("BQ_DATASET (or DATASET_ID) is required")
    
    gcs_bucket = os.getenv("GCS_BUCKET", "")
    if check_gcs and not gcs_bucket:
        errors.append("GCS_BUCKET is required (format: gs://bucket/prefix)")
    
    if gcs_bucket and not gcs_bucket.startswith("gs://"):
        errors.append(f"GCS_BUCKET must start with gs:// (got: {gcs_bucket})")
    
    if errors:
        print("❌ Configuration errors:", file=sys.stderr)
        for err in errors:
            print(f"   - {err}", file=sys.stderr)
        print("\nSet environment variables before running:", file=sys.stderr)
        print("  export PROJECT_ID=your-project-id", file=sys.stderr)
        print("  export BQ_DATASET=your_dataset", file=sys.stderr)
        if check_gcs:
            print("  export GCS_BUCKET=gs://your-bucket/prefix", file=sys.stderr)
        sys.exit(1)
    
    # Parse optional parameters
    topk = int(os.getenv("TOPK", "100"))
    n_min = int(os.getenv("N_MIN", "200"))
    vol_ntiles = int(os.getenv("VOL_NTILES", "3"))
    
    # Horizon forecasting parameters
    base_sales_table = os.getenv("BASE_SALES_TABLE")
    horizon_weeks = int(os.getenv("HORIZON_WEEKS", "4"))
    
    # Validate horizon_weeks
    if horizon_weeks not in (1, 4):
        errors.append(f"HORIZON_WEEKS must be 1 or 4 (got: {horizon_weeks})")
    
    # Execution flags
    dry_run = os.getenv("DRY_RUN", "0") in ("1", "true", "True", "yes")
    verbose = os.getenv("VERBOSE", "0") in ("1", "true", "True", "yes")
    skip_registry = os.getenv("SKIP_REGISTRY", "0") in ("1", "true", "True", "yes")
    
    # Auto-generate RUN_ID if not provided
    run_id = os.getenv("RUN_ID")
    if not run_id:
        from datetime import datetime
        run_id = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    
    return PipelineConfig(
        project_id=project_id,
        dataset_id=dataset_id,
        gcs_bucket=gcs_bucket,
        location=os.getenv("BQ_LOCATION", "EU"),
        run_id=run_id,
        mode=os.getenv("MODE", "optionB_full"),
        start_date=os.getenv("START_DATE"),
        end_date=os.getenv("END_DATE"),
        topk=topk,
        n_min=n_min,
        vol_ntiles=vol_ntiles,
        coverage_grid=os.getenv("COVERAGE_GRID", "0.90,0.91,0.92,0.93,0.94,0.95,0.96,0.97,0.98"),
        base_sales_table=base_sales_table,
        horizon_weeks=horizon_weeks,
        dry_run=dry_run,
        verbose=verbose,
        skip_registry=skip_registry,
    )


def print_config(config: PipelineConfig) -> None:
    """Pretty-print configuration."""
    print("\n" + "=" * 60)
    print("Pipeline Configuration")
    print("=" * 60)
    print(f"Project:       {config.project_id}")
    print(f"Dataset:       {config.dataset_id}")
    print(f"Location:      {config.location}")
    print(f"Run ID:        {config.run_id}")
    print(f"Mode:          {config.mode}")
    if config.gcs_bucket:
        print(f"GCS Bucket:    {config.gcs_bucket}")
    if config.base_sales_table:
        print(f"Sales Table:   {config.base_sales_table}")
    if config.mode in ("forecast_quantiles", "forecast_h1", "forecast_h4"):
        print(f"Horizon:       {config.horizon_weeks} weeks ({'h1' if config.horizon_weeks == 1 else 'h4'})")
    print(f"Dry Run:       {config.dry_run}")
    print(f"Verbose:       {config.verbose}")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    # Can be used for healthcheck
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Validate config and exit")
    args = parser.parse_args()
    
    if args.check:
        try:
            config = load_config(check_gcs=False)
            print("✓ Configuration valid")
            sys.exit(0)
        except SystemExit:
            sys.exit(1)
    else:
        config = load_config()
        print_config(config)
