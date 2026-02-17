"""
Run stratified permutation test with multiple seeds (robust T2)

Usage:
    python src/bq/run_permutation_seeds.py --n-seeds 30
"""
import os
import sys
import argparse
import logging
from pathlib import Path
from google.cloud import bigquery
from datetime import datetime

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


def read_sql_template(sql_path: str) -> str:
    """Read SQL file"""
    with open(sql_path, 'r', encoding='utf-8') as f:
        return f.read()


def execute_permutation_seed(
    client: bigquery.Client,
    sql_template: str,
    seed: int,
    dataset_ref: str,
    dry_run: bool = False
) -> dict:
    """Execute permutation test for single seed"""
    
    # Substitute parameters
    sql = sql_template.replace('{seed}', str(seed))
    sql = sql.replace('{dataset_ref}', dataset_ref)
    
    if dry_run:
        logger.info(f"[DRY-RUN] Would execute seed {seed}")
        return {'seed': seed, 'status': 'dry_run'}
    
    # Execute
    logger.info(f"Executing permutation seed {seed}...")
    job_config = bigquery.QueryJobConfig()
    query_job = client.query(sql, job_config=job_config)
    
    # Wait for completion
    result = query_job.result()
    
    # Get metrics
    rows = list(result)
    if rows:
        row = rows[0]
        metrics = {
            'seed': seed,
            'n_samples': row.get('n_samples'),
            'prevalence_permuted': row.get('prevalence_permuted'),
            'roc_auc': row.get('roc_auc'),
            'log_loss': row.get('log_loss'),
            'precision': row.get('precision'),
            'recall': row.get('recall'),
            'verdict': row.get('verdict'),
            'bytes_processed': query_job.total_bytes_processed,
            'bytes_billed': query_job.total_bytes_billed,
            'slot_millis': query_job.slot_millis,
            'status': 'success'
        }
    else:
        metrics = {'seed': seed, 'status': 'no_results'}
    
    logger.info(f"✅ Seed {seed} completed: AUC={metrics.get('roc_auc', 'N/A'):.4f}")
    
    return metrics


def aggregate_results(client: bigquery.Client, dataset_ref: str) -> dict:
    """Aggregate results across all seeds"""
    
    query = f"""
    WITH stats AS (
      SELECT
        COUNT(*) AS n_seeds,
        AVG(roc_auc) AS mean_auc,
        STDDEV(roc_auc) AS std_auc,
        MIN(roc_auc) AS min_auc,
        MAX(roc_auc) AS max_auc,
        APPROX_QUANTILES(roc_auc, 100)[OFFSET(5)] AS p5_auc,
        APPROX_QUANTILES(roc_auc, 100)[OFFSET(50)] AS p50_auc,
        APPROX_QUANTILES(roc_auc, 100)[OFFSET(95)] AS p95_auc,
        AVG(log_loss) AS mean_log_loss,
        AVG(prevalence_permuted) AS mean_prevalence
      FROM `{dataset_ref}.anti_leakage_permutation_runs`
    )
    SELECT
      *,
      -- 95% CI: mean ± 1.96 * SE
      mean_auc - 1.96 * (std_auc / SQRT(n_seeds)) AS ci95_lower,
      mean_auc + 1.96 * (std_auc / SQRT(n_seeds)) AS ci95_upper,
      CASE
        WHEN mean_auc BETWEEN 0.47 AND 0.53 THEN '✅ PASS: Mean AUC ≈ 0.50 (random)'
        WHEN mean_auc BETWEEN 0.45 AND 0.55 THEN '⚠️ MARGINAL: Near-random (acceptable)'
        ELSE '❌ FAIL: Not random'
      END AS verdict
    FROM stats
    """
    
    result = client.query(query).result()
    rows = list(result)
    
    if rows:
        return dict(rows[0].items())
    else:
        return {}


def main():
    parser = argparse.ArgumentParser(
        description='Run stratified permutation test with multiple seeds'
    )
    parser.add_argument(
        '--n-seeds',
        type=int,
        default=30,
        help='Number of seeds to run (default: 30)'
    )
    parser.add_argument(
        '--start-seed',
        type=int,
        default=0,
        help='Starting seed number (default: 0)'
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
        '--dry-run',
        action='store_true',
        help='Dry run mode (preview only)'
    )
    parser.add_argument(
        '--continue-on-error',
        action='store_true',
        help='Continue if a seed fails'
    )
    
    args = parser.parse_args()
    
    # Validate
    if not args.project_id or not args.dataset_id:
        logger.error("Missing GCP_PROJECT_ID or BQ_DATASET_ID")
        sys.exit(1)
    
    dataset_ref = f"{args.project_id}.{args.dataset_id}"
    
    # Initialize BigQuery client
    client = bigquery.Client(project=args.project_id)
    logger.info(f"Initialized BigQuery client: {dataset_ref}")
    
    # Read SQL template
    sql_path = Path(__file__).parent.parent.parent / 'sql' / 'anti_leakage' / '22_permutation_test_stratified.sql'
    if not sql_path.exists():
        logger.error(f"SQL template not found: {sql_path}")
        sys.exit(1)
    
    sql_template = read_sql_template(str(sql_path))
    logger.info(f"Loaded SQL template: {sql_path}")
    
    # Execute seeds
    results = []
    errors = []
    
    logger.info(f"\n{'='*60}")
    logger.info(f"Running {args.n_seeds} permutation seeds...")
    logger.info(f"{'='*60}\n")
    
    for i in range(args.n_seeds):
        seed = args.start_seed + i
        
        try:
            metrics = execute_permutation_seed(
                client, sql_template, seed, dataset_ref, args.dry_run
            )
            results.append(metrics)
            
        except Exception as e:
            logger.error(f"❌ Seed {seed} failed: {e}")
            errors.append({'seed': seed, 'error': str(e)})
            
            if not args.continue_on_error:
                logger.error("Stopping due to error (use --continue-on-error to skip)")
                sys.exit(1)
    
    # Aggregate results
    if not args.dry_run and results:
        logger.info(f"\n{'='*60}")
        logger.info("Aggregating results across seeds...")
        logger.info(f"{'='*60}\n")
        
        agg_stats = aggregate_results(client, dataset_ref)
        
        if agg_stats:
            logger.info("📊 AGGREGATED STATISTICS:")
            logger.info(f"   N seeds:        {agg_stats.get('n_seeds')}")
            logger.info(f"   Mean AUC:       {agg_stats.get('mean_auc'):.4f}")
            logger.info(f"   Std AUC:        {agg_stats.get('std_auc'):.4f}")
            logger.info(f"   95% CI:         [{agg_stats.get('ci95_lower'):.4f}, {agg_stats.get('ci95_upper'):.4f}]")
            logger.info(f"   P5-P50-P95:     {agg_stats.get('p5_auc'):.4f} | {agg_stats.get('p50_auc'):.4f} | {agg_stats.get('p95_auc'):.4f}")
            logger.info(f"   Mean Log Loss:  {agg_stats.get('mean_log_loss'):.4f}")
            logger.info(f"   Verdict:        {agg_stats.get('verdict')}")
    
    # Summary
    logger.info(f"\n{'='*60}")
    logger.info("SUMMARY")
    logger.info(f"{'='*60}")
    logger.info(f"✅ Successful: {len([r for r in results if r.get('status') == 'success'])}")
    logger.info(f"❌ Failed:     {len(errors)}")
    
    if errors:
        logger.warning("\nFailed seeds:")
        for err in errors:
            logger.warning(f"  Seed {err['seed']}: {err['error']}")
    
    logger.info(f"\n✅ Permutation test complete!")
    logger.info(f"Results stored in: {dataset_ref}.anti_leakage_permutation_runs")


if __name__ == '__main__':
    main()
