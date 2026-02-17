#!/usr/bin/env python3
"""
Phase Registry for Multi-Stage Pipeline
========================================
Manages experiment tracking for 3-phase Option B pipeline:
- Phase B1: OOS Risk Model
- Phase B3: Conformal Quantiles
- Phase B4: Inventory Policy

Usage:
    from src.bq.phase_registry import PhaseRegistry
    
    registry = PhaseRegistry(project_id, dataset_id)
    
    # Start run
    run_id = registry.start_run(model_name="m_oos_h4", ...)
    
    # Start phase
    registry.start_phase(run_id, "B1_OOS_RISK")
    
    # Record metrics
    registry.add_metrics(run_id, "B1_OOS_RISK", {"auc": 0.85, "precision_at_100": 0.27})
    
    # Complete phase
    registry.complete_phase(run_id, "B1_OOS_RISK", artifact_tables=["pred_oos_h4"])
    
    # Complete run
    registry.complete_run(run_id, status="SUCCESS")
"""

import json
import uuid
from datetime import datetime
from typing import Dict, List, Optional, Any

from google.cloud import bigquery


class PhaseRegistry:
    """Manages phase-level experiment tracking for multi-stage pipeline."""
    
    # Valid phase identifiers
    VALID_PHASES = ["B1_OOS_RISK", "B3_QUANTILES", "B4_POLICY"]
    
    def __init__(self, project_id: str, dataset_id: str, location: str = "EU"):
        """
        Initialize phase registry.
        
        Args:
            project_id: GCP project ID
            dataset_id: BigQuery dataset ID  
            location: BigQuery location
        """
        self.project_id = project_id
        self.dataset_id = dataset_id
        self.location = location
        self.client = bigquery.Client(project=project_id, location=location)
        
        # Table references
        self.runs_table = f"{project_id}.{dataset_id}.experiment_registry_runs"
        self.phases_table = f"{project_id}.{dataset_id}.experiment_registry_phases"
        self.metrics_table = f"{project_id}.{dataset_id}.experiment_registry_metrics"
    
    def generate_run_id(self) -> str:
        """Generate unique run ID: timestamp + short UUID."""
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        short_uuid = str(uuid.uuid4())[:8]
        return f"run_{timestamp}_{short_uuid}"
    
    def start_run(
        self,
        run_id: Optional[str] = None,
        run_name: Optional[str] = None,
        model_name: Optional[str] = None,
        feature_view: Optional[str] = None,
        label_version: Optional[str] = None,
        horizon: Optional[int] = None,
        split_train: Optional[str] = None,
        split_calib: Optional[str] = None,
        split_val: Optional[str] = None,
        code_hash: Optional[str] = None,
        config: Optional[Dict] = None,
        tags: Optional[List[str]] = None,
        author: Optional[str] = None,
        notes: Optional[str] = None,
    ) -> str:
        """
        Start a new pipeline run.
        
        Returns:
            run_id: Unique identifier for the run
        """
        if run_id is None:
            run_id = self.generate_run_id()
        
        now = datetime.utcnow().isoformat()
        
        row = {
            "run_id": run_id,
            "run_timestamp": now,
            "run_name": run_name or run_id,
            "project_id": self.project_id,
            "dataset_id": self.dataset_id,
            "location": self.location,
            "model_name": model_name,
            "feature_view": feature_view,
            "label_version": label_version,
            "horizon": horizon,
            "split_train": split_train,
            "split_calib": split_calib,
            "split_val": split_val,
            "code_hash": code_hash,
            "config_json": json.dumps(config) if config else None,
            "status": "STARTED",
            "tags": tags or [],
            "author": author,
            "notes": notes,
            "created_at": now,
        }
        
        errors = self.client.insert_rows_json(self.runs_table, [row])
        
        if errors:
            raise RuntimeError(f"Failed to insert run: {errors}")
        
        print(f"✓ Started run: {run_id}")
        return run_id
    
    def start_phase(
        self,
        run_id: str,
        phase: str,
        phase_config: Optional[Dict] = None,
        depends_on: Optional[List[str]] = None,
    ) -> None:
        """
        Start a pipeline phase.
        
        Args:
            run_id: Run identifier
            phase: Phase identifier (B1_OOS_RISK, B3_QUANTILES, B4_POLICY)
            phase_config: Phase-specific configuration
            depends_on: List of parent phase identifiers
        """
        if phase not in self.VALID_PHASES:
            raise ValueError(f"Invalid phase: {phase}. Must be one of {self.VALID_PHASES}")
        
        now = datetime.utcnow().isoformat()
        
        row = {
            "run_id": run_id,
            "phase": phase,
            "phase_status": "STARTED",
            "started_at": now,
            "phase_config_json": json.dumps(phase_config) if phase_config else None,
            "depends_on_phases": depends_on or [],
            "retry_count": 0,
            "created_at": now,
        }
        
        errors = self.client.insert_rows_json(self.phases_table, [row])
        
        if errors:
            raise RuntimeError(f"Failed to start phase {phase}: {errors}")
        
        print(f"✓ Started phase: {run_id} → {phase}")
    
    def complete_phase(
        self,
        run_id: str,
        phase: str,
        status: str = "SUCCESS",
        artifact_tables: Optional[List[str]] = None,
        artifact_gcs_paths: Optional[List[str]] = None,
        error_message: Optional[str] = None,
    ) -> None:
        """
        Mark a phase as complete.
        
        Args:
            run_id: Run identifier
            phase: Phase identifier
            status: SUCCESS or FAILED
            artifact_tables: List of created table names
            artifact_gcs_paths: List of GCS output paths
            error_message: Error details if status=FAILED
        """
        now = datetime.utcnow().isoformat()
        
        # Use MERGE to update existing row
        query = f"""
        MERGE `{self.phases_table}` T
        USING (
            SELECT 
                @run_id AS run_id,
                @phase AS phase,
                @status AS phase_status,
                CURRENT_TIMESTAMP() AS completed_at,
                TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), T.started_at, SECOND) AS duration_seconds,
                @artifact_tables AS artifact_tables,
                @artifact_gcs_paths AS artifact_gcs_paths,
                @error_message AS error_message,
                CURRENT_TIMESTAMP() AS updated_at
            FROM `{self.phases_table}` T
            WHERE T.run_id = @run_id AND T.phase = @phase
        ) S
        ON T.run_id = S.run_id AND T.phase = S.phase
        WHEN MATCHED THEN UPDATE SET
            phase_status = S.phase_status,
            completed_at = S.completed_at,
            duration_seconds = S.duration_seconds,
            artifact_tables = S.artifact_tables,
            artifact_gcs_paths = S.artifact_gcs_paths,
            error_message = S.error_message,
            updated_at = S.updated_at
        """
        
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("run_id", "STRING", run_id),
                bigquery.ScalarQueryParameter("phase", "STRING", phase),
                bigquery.ScalarQueryParameter("status", "STRING", status),
                bigquery.ArrayQueryParameter("artifact_tables", "STRING", artifact_tables or []),
                bigquery.ArrayQueryParameter("artifact_gcs_paths", "STRING", artifact_gcs_paths or []),
                bigquery.ScalarQueryParameter("error_message", "STRING", error_message),
            ]
        )
        
        self.client.query(query, job_config=job_config).result()
        
        icon = "✓" if status == "SUCCESS" else "✗"
        print(f"{icon} Completed phase: {run_id} → {phase} [{status}]")
    
    def add_metrics(
        self,
        run_id: str,
        phase: str,
        metrics: Dict[str, Any],
        split: str = "val",
        segment_key: Optional[str] = None,
        segment_value: Optional[str] = None,
    ) -> None:
        """
        Add metrics for a phase.
        
        Args:
            run_id: Run identifier
            phase: Phase identifier
            metrics: Dictionary of metric_name: value
            split: Data split (train/calib/val/test)
            segment_key: Segment dimension (optional)
            segment_value: Segment value (optional)
        """
        now = datetime.utcnow().isoformat()
        rows = []
        
        for metric_name, metric_value in metrics.items():
            row = {
                "run_id": run_id,
                "phase": phase,
                "metric_name": metric_name,
                "metric_value": float(metric_value) if isinstance(metric_value, (int, float)) else None,
                "metric_value_str": str(metric_value) if not isinstance(metric_value, (int, float)) else None,
                "split": split,
                "segment_key": segment_key,
                "segment_value": segment_value,
                "metric_type": "scalar",
                "created_at": now,
            }
            rows.append(row)
        
        errors = self.client.insert_rows_json(self.metrics_table, rows)
        
        if errors:
            raise RuntimeError(f"Failed to insert metrics: {errors}")
        
        print(f"✓ Recorded {len(metrics)} metrics for {run_id} → {phase}")
    
    def complete_run(
        self,
        run_id: str,
        status: str = "SUCCESS",
        error_message: Optional[str] = None,
    ) -> None:
        """
        Mark a run as complete.
        
        Args:
            run_id: Run identifier
            status: SUCCESS, FAILED, or PARTIAL
            error_message: Error details if status=FAILED
        """
        query = f"""
        UPDATE `{self.runs_table}`
        SET 
            status = @status,
            error_message = @error_message,
            updated_at = CURRENT_TIMESTAMP()
        WHERE run_id = @run_id
        """
        
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("run_id", "STRING", run_id),
                bigquery.ScalarQueryParameter("status", "STRING", status),
                bigquery.ScalarQueryParameter("error_message", "STRING", error_message),
            ]
        )
        
        self.client.query(query, job_config=job_config).result()
        
        icon = "✓" if status == "SUCCESS" else "✗"
        print(f"{icon} Completed run: {run_id} [{status}]")
    
    def get_run_status(self, run_id: str) -> Dict[str, Any]:
        """Get status of a run and all its phases."""
        query = f"""
        SELECT
            r.run_id,
            r.run_name,
            r.status AS run_status,
            r.run_timestamp,
            ARRAY_AGG(STRUCT(
                p.phase,
                p.phase_status,
                p.started_at,
                p.completed_at,
                p.duration_seconds,
                p.artifact_tables
            ) ORDER BY p.started_at) AS phases
        FROM `{self.runs_table}` r
        LEFT JOIN `{self.phases_table}` p USING(run_id)
        WHERE r.run_id = @run_id
        GROUP BY 1, 2, 3, 4
        """
        
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("run_id", "STRING", run_id)
            ]
        )
        
        results = self.client.query(query, job_config=job_config).result()
        
        for row in results:
            return dict(row)
        
        return {}


# Convenience function for quick registration
def register_phase_async(
    run_id: str,
    phase: str,
    project_id: str,
    dataset_id: str,
    **kwargs
) -> None:
    """Fire-and-forget phase registration (non-blocking)."""
    try:
        registry = PhaseRegistry(project_id, dataset_id)
        registry.start_phase(run_id, phase, **kwargs)
    except Exception as e:
        print(f"⚠️  Warning: Failed to register phase {phase}: {e}")

