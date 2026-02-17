"""
Execute all baseline models and generate comparison report

Usage:
    python src/baselines/run_all_baselines.py --project-id thequantitativeledger --dataset-id cruzber_models_eu
"""
import os
import sys
import argparse
import logging
from pathlib import Path
from datetime import datetime
from google.cloud import bigquery

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


def read_sql_file(sql_path: str, dataset_ref: str) -> str:
    """Read SQL file and substitute parameters"""
    with open(sql_path, 'r', encoding='utf-8') as f:
        sql = f.read()
    return sql.replace('{dataset_ref}', dataset_ref)


def execute_sql(client: bigquery.Client, sql: str, name: str) -> None:
    """Execute SQL query"""
    logger.info(f"\n{'='*60}")
    logger.info(f"Executing: {name}")
    logger.info(f"{'='*60}")
    
    try:
        query_job = client.query(sql)
        result = query_job.result()
        
        logger.info(f"✅ {name} completed")
        logger.info(f"   Bytes processed: {query_job.total_bytes_processed:,}")
        logger.info(f"   Bytes billed: {query_job.total_bytes_billed:,}")
        
        # Show sample results if available
        rows = list(result)
        if rows and len(rows) > 0:
            logger.info(f"   Sample output:")
            for i, row in enumerate(rows[:3]):
                logger.info(f"     Row {i+1}: {dict(row.items())}")
        
    except Exception as e:
        logger.error(f"❌ {name} failed: {e}")
        raise


def main():
    parser = argparse.ArgumentParser(
        description='Execute all baseline models and generate comparison'
    )
    parser.add_argument(
        '--project-id',
        type=str,
        default=os.getenv('GCP_PROJECT_ID'),
        help='GCP project ID'
    )
    parser.add_argument(
        '--dataset-id',
        type=str,
        default=os.getenv('BQ_DATASET_ID'),
        help='BigQuery dataset ID'
    )
    parser.add_argument(
        '--skip-h3',
        action='store_true',
        help='Skip H3 unconstraining baseline (optional)'
    )
    
    args = parser.parse_args()
    
    if not args.project_id or not args.dataset_id:
        logger.error("Missing GCP_PROJECT_ID or BQ_DATASET_ID")
        sys.exit(1)
    
    dataset_ref = f"{args.project_id}.{args.dataset_id}"
    
    # Initialize BigQuery client
    client = bigquery.Client(project=args.project_id)
    logger.info(f"Initialized BigQuery client: {dataset_ref}")
    
    # Define baseline SQL files
    sql_dir = Path(__file__).parent.parent.parent / 'sql' / 'baselines'
    
    baselines = [
        ('01_baseline_h0_heuristic.sql', 'H0: Heuristic Baseline'),
        ('02_baseline_h1_logistic.sql', 'H1: Logistic Regression'),
        ('03_baseline_h2_temporal.sql', 'H2: Temporal Baseline'),
    ]
    
    if not args.skip_h3:
        baselines.append(('04_baseline_h3_unconstraining.sql', 'H3: Unconstraining (Optional)'))
    
    baselines.append(('05_consolidated_comparison.sql', 'Consolidated Comparison'))
    
    # Execute each baseline
    start_time = datetime.now()
    
    for sql_file, name in baselines:
        sql_path = sql_dir / sql_file
        
        if not sql_path.exists():
            logger.warning(f"⚠️ SQL file not found: {sql_path}")
            continue
        
        logger.info(f"\n📄 Reading: {sql_file}")
        sql = read_sql_file(str(sql_path), dataset_ref)
        
        execute_sql(client, sql, name)
    
    # Execution summary
    end_time = datetime.now()
    duration = (end_time - start_time).total_seconds()
    
    logger.info(f"\n{'='*60}")
    logger.info(f"✅ All baselines executed successfully!")
    logger.info(f"{'='*60}")
    logger.info(f"Total duration: {duration:.1f} seconds ({duration/60:.1f} min)")
    logger.info(f"\n📊 Results available in:")
    logger.info(f"   • {dataset_ref}.baselines_comparison")
    logger.info(f"   • {dataset_ref}.precision_at_k_comparison")
    logger.info(f"   • {dataset_ref}.feature_importance_comparison")
    
    # Fetch and display final comparison
    logger.info(f"\n{'='*60}")
    logger.info(f"FINAL BASELINE COMPARISON")
    logger.info(f"{'='*60}\n")
    
    query = f"""
    SELECT
      model_name,
      auc,
      precision,
      recall,
      delta_auc_vs_main,
      verdict
    FROM `{dataset_ref}.baselines_comparison`
    ORDER BY auc DESC
    """
    
    result = client.query(query).result()
    
    for row in result:
        logger.info(
            f"  {row.model_name:20s} | AUC: {row.auc:.4f} | "
            f"Δ vs Main: {row.delta_auc_vs_main:+.4f} | {row.verdict}"
        )
    
    logger.info(f"\n✅ Next step: Generate markdown report with generate_baselines_report.py")


if __name__ == '__main__':
    main()
