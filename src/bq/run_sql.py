"""
BigQuery SQL Runner
===================
Execute SQL scripts in BigQuery using Application Default Credentials (ADC).
Supports parameterized queries, logging, error handling, and transaction-like semantics.

Usage:
    python run_sql.py --sql-file path/to/script.sql
    python run_sql.py --sql-dir sql/features --project-id my-project --dataset-id my-dataset

Requirements:
    pip install google-cloud-bigquery
"""

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Optional, Dict, Any

from google.cloud import bigquery
from google.cloud.exceptions import GoogleCloudError

# Local imports
try:
    from .config import BQConfig, get_config
except ImportError:
    from src.bq.config import BQConfig, get_config


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


class SQLRunner:
    """Execute SQL scripts on BigQuery with parameterization and error handling."""
    
    def __init__(self, config: Optional[BQConfig] = None):
        """
        Initialize SQL runner with BigQuery client.
        
        Args:
            config: BQConfig instance (uses default if None)
        """
        self.config = config or get_config()
        self.client = bigquery.Client(
            project=self.config.project_id,
            location=self.config.location
        )
        logger.info(f"Initialized BigQuery client: {self.config}")
    
    def _replace_placeholders(self, sql: str, params: Optional[Dict[str, Any]] = None) -> str:
        """
        Replace {placeholders} in SQL with actual values.
        
        Args:
            sql: SQL string with {placeholder} syntax
            params: Dictionary of parameter values (optional)
        
        Returns:
            SQL string with placeholders replaced
        """
        # Default replacements
        replacements = {
            'project_id': self.config.project_id,
            'dataset_id': self.config.dataset_id,
            'dataset_ref': self.config.dataset_ref,
            'location': self.config.location
        }
        
        # Override with user params
        if params:
            replacements.update(params)
        
        # Replace placeholders
        for key, value in replacements.items():
            sql = sql.replace(f'{{{key}}}', str(value))
        
        return sql
    
    def execute_sql(
        self,
        sql: str,
        params: Optional[Dict[str, Any]] = None,
        dry_run: bool = False
    ) -> Optional[bigquery.table.RowIterator]:
        """
        Execute a SQL query on BigQuery.
        
        Args:
            sql: SQL query string
            params: Optional dictionary of parameters for placeholder replacement
            dry_run: If True, validate SQL without executing
        
        Returns:
            Query results (RowIterator) if query returns rows, None otherwise
        
        Raises:
            GoogleCloudError: If query execution fails
        """
        # Replace placeholders
        sql = self._replace_placeholders(sql, params)
        
        # Configure job
        job_config = bigquery.QueryJobConfig()
        if dry_run:
            job_config.dry_run = True
            job_config.use_query_cache = False
        
        try:
            # Run query
            logger.info(f"Executing SQL ({'DRY RUN' if dry_run else 'LIVE'})...")
            if logger.isEnabledFor(logging.DEBUG):
                logger.debug(f"SQL:\n{sql[:500]}...")
            
            query_job = self.client.query(sql, job_config=job_config)
            
            # Wait for completion
            if not dry_run:
                results = query_job.result()  # Blocks until done
                logger.info(f"✅ Query completed: {query_job.job_id}")
                
                # Log metrics
                if query_job.total_bytes_processed:
                    gb_processed = query_job.total_bytes_processed / (1024 ** 3)
                    logger.info(f"   Bytes processed: {gb_processed:.2f} GB")
                if query_job.total_bytes_billed:
                    gb_billed = query_job.total_bytes_billed / (1024 ** 3)
                    logger.info(f"   Bytes billed: {gb_billed:.2f} GB")
                if query_job.slot_millis:
                    logger.info(f"   Slot-millis: {query_job.slot_millis:,}")
                
                return results
            else:
                gb_processed = query_job.total_bytes_processed / (1024 ** 3)
                logger.info(f"✅ Dry run OK: would process {gb_processed:.2f} GB")
                return None
        
        except GoogleCloudError as e:
            logger.error(f"❌ Query failed: {e}")
            raise
    
    def execute_sql_file(
        self,
        file_path: Path,
        params: Optional[Dict[str, Any]] = None,
        dry_run: bool = False
    ) -> Optional[bigquery.table.RowIterator]:
        """
        Execute a SQL script from file.
        
        Args:
            file_path: Path to .sql file
            params: Optional dictionary of parameters
            dry_run: If True, validate without executing
        
        Returns:
            Query results if query returns rows, None otherwise
        """
        logger.info(f"Reading SQL file: {file_path}")
        
        if not file_path.exists():
            raise FileNotFoundError(f"SQL file not found: {file_path}")
        
        sql = file_path.read_text(encoding='utf-8')
        return self.execute_sql(sql, params=params, dry_run=dry_run)
    
    def execute_sql_dir(
        self,
        dir_path: Path,
        pattern: str = '*.sql',
        params: Optional[Dict[str, Any]] = None,
        dry_run: bool = False,
        stop_on_error: bool = True
    ) -> Dict[str, bool]:
        """
        Execute all SQL files in a directory (sorted by name).
        
        Args:
            dir_path: Path to directory with .sql files
            pattern: Glob pattern for file matching (default: *.sql)
            params: Optional dictionary of parameters
            dry_run: If True, validate without executing
            stop_on_error: If True, stop on first error; if False, continue
        
        Returns:
            Dictionary mapping file paths to success status (True/False)
        """
        logger.info(f"Executing SQL directory: {dir_path}")
        
        if not dir_path.exists():
            raise FileNotFoundError(f"Directory not found: {dir_path}")
        
        # Get sorted list of SQL files
        sql_files = sorted(dir_path.glob(pattern))
        
        if not sql_files:
            logger.warning(f"No SQL files found matching pattern '{pattern}' in {dir_path}")
            return {}
        
        logger.info(f"Found {len(sql_files)} SQL files")
        
        # Execute each file
        results = {}
        for sql_file in sql_files:
            try:
                logger.info(f"\n{'='*80}\nExecuting: {sql_file.name}\n{'='*80}")
                self.execute_sql_file(sql_file, params=params, dry_run=dry_run)
                results[str(sql_file)] = True
            except Exception as e:
                logger.error(f"❌ Failed: {sql_file.name}\n   Error: {e}")
                results[str(sql_file)] = False
                
                if stop_on_error:
                    logger.error("Stopping execution due to error (stop_on_error=True)")
                    break
        
        # Summary
        n_success = sum(results.values())
        n_total = len(results)
        logger.info(f"\n{'='*80}\nSummary: {n_success}/{n_total} scripts succeeded\n{'='*80}")
        
        return results


def main():
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description='Execute SQL scripts on BigQuery with ADC',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    # Input source (file or directory)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--sql-file', type=Path, help='Path to single .sql file')
    group.add_argument('--sql-dir', type=Path, help='Path to directory with .sql files')
    
    # Configuration overrides
    parser.add_argument('--project-id', help='GCP project ID (overrides env var)')
    parser.add_argument('--dataset-id', help='BigQuery dataset ID (overrides env var)')
    parser.add_argument('--location', help='BigQuery location (default: europe-southwest1)')
    
    # Parameters
    parser.add_argument('--params', nargs='*', help='Key=value pairs for parameterization')
    
    # Execution options
    parser.add_argument('--dry-run', action='store_true', help='Validate SQL without executing')
    parser.add_argument('--continue-on-error', action='store_true', 
                        help='Continue executing remaining files on error')
    parser.add_argument('--verbose', action='store_true', help='Enable verbose logging')
    
    args = parser.parse_args()
    
    # Set log level
    if args.verbose:
        logger.setLevel(logging.DEBUG)
    
    # Parse params
    params = {}
    if args.params:
        for param in args.params:
            if '=' not in param:
                logger.error(f"Invalid param format: {param} (expected key=value)")
                sys.exit(1)
            key, value = param.split('=', 1)
            params[key] = value
    
    # Create config
    try:
        config = BQConfig(
            project_id=args.project_id,
            dataset_id=args.dataset_id,
            location=args.location
        )
    except ValueError as e:
        logger.error(f"Configuration error: {e}")
        sys.exit(1)
    
    # Create runner
    runner = SQLRunner(config)
    
    # Execute SQL
    try:
        if args.sql_file:
            runner.execute_sql_file(args.sql_file, params=params, dry_run=args.dry_run)
        else:  # sql_dir
            results = runner.execute_sql_dir(
                args.sql_dir,
                params=params,
                dry_run=args.dry_run,
                stop_on_error=not args.continue_on_error
            )
            
            # Exit with error code if any failures
            if not all(results.values()):
                sys.exit(1)
    
    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
