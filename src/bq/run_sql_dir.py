"""
Execute all SQL files in a directory in lexical order
Usage: python run_sql_dir.py --sql-dir sql/experiments --params '{"dataset":"dataset_cruzber_eu"}'
"""
import argparse
import json
import os
import sys
from pathlib import Path
from google.cloud import bigquery
from datetime import datetime

def substitute_params(sql_text, params):
    """Replace ${param} placeholders in SQL text"""
    for key, value in params.items():
        sql_text = sql_text.replace(f"${{{key}}}", str(value))
    return sql_text

def run_sql_file(client, filepath, params, dry_run=False):
    """Execute a single SQL file"""
    print(f"\n{'='*80}")
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Executing: {filepath.name}")
    print(f"{'='*80}")
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            sql_text = f.read()
        
        # Substitute parameters
        sql_text = substitute_params(sql_text, params)
        
        if dry_run:
            print("\n[DRY RUN] Would execute:")
            print(sql_text[:500] + "..." if len(sql_text) > 500 else sql_text)
            return True
        
        # Execute query
        query_job = client.query(sql_text)
        
        # Wait for completion
        results = query_job.result()
        
        # Print statistics
        print(f"✅ Query completed successfully")
        print(f"   Bytes processed: {query_job.total_bytes_processed:,}")
        print(f"   Bytes billed: {query_job.total_bytes_billed:,}")
        print(f"   Cache hit: {query_job.cache_hit}")
        
        # If query returns results, show sample
        if query_job.destination:
            row_count = query_job.total_rows or 0
            print(f"   Rows returned: {row_count:,}")
            
            if row_count > 0 and row_count <= 10:
                print("\n   Sample results:")
                for i, row in enumerate(results):
                    if i >= 5:  # Limit to 5 rows
                        break
                    print(f"     {dict(row)}")
        
        return True
        
    except Exception as e:
        print(f"❌ Error executing {filepath.name}")
        print(f"   {str(e)}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Execute SQL files in a directory')
    parser.add_argument('--sql-dir', required=True, help='Directory containing SQL files')
    parser.add_argument('--params', default='{}', help='JSON string with parameters')
    parser.add_argument('--pattern', default='*.sql', help='File pattern to match')
    parser.add_argument('--dry-run', action='store_true', help='Print SQL without executing')
    parser.add_argument('--stop-on-error', action='store_true', help='Stop if a query fails')
    parser.add_argument('--project', help='GCP project ID (overrides env)')
    
    args = parser.parse_args()
    
    # Parse parameters
    try:
        params = json.loads(args.params)
    except json.JSONDecodeError as e:
        print(f"❌ Invalid JSON in --params: {e}")
        sys.exit(1)
    
    # Add environment variables to params
    params.setdefault('project_id', os.getenv('GCP_PROJECT_ID', 'thequantitativeledger'))
    params.setdefault('dataset_id', os.getenv('BQ_DATASET_ID', 'cruzber_models_eu'))
    params.setdefault('location', os.getenv('BQ_LOCATION', 'EU'))
    
    # Override with command line
    if args.project:
        params['project_id'] = args.project
    
    # Initialize BigQuery client
    if not args.dry_run:
        try:
            client = bigquery.Client(project=params['project_id'])
            print(f"✅ Connected to BigQuery project: {params['project_id']}")
        except Exception as e:
            print(f"❌ Failed to connect to BigQuery: {e}")
            sys.exit(1)
    else:
        client = None
        print("🔍 DRY RUN MODE - No queries will be executed")
    
    # Find SQL files
    sql_dir = Path(args.sql_dir)
    if not sql_dir.exists():
        print(f"❌ Directory not found: {sql_dir}")
        sys.exit(1)
    
    sql_files = sorted(sql_dir.glob(args.pattern))
    
    if not sql_files:
        print(f"⚠️  No {args.pattern} files found in {sql_dir}")
        sys.exit(0)
    
    print(f"\n📁 Found {len(sql_files)} SQL files in {sql_dir}")
    print(f"📋 Parameters: {json.dumps(params, indent=2)}\n")
    
    # Execute files in order
    success_count = 0
    fail_count = 0
    
    for sql_file in sql_files:
        success = run_sql_file(client, sql_file, params, args.dry_run)
        
        if success:
            success_count += 1
        else:
            fail_count += 1
            if args.stop_on_error:
                print(f"\n❌ Stopping due to error (--stop-on-error)")
                break
    
    # Summary
    print(f"\n{'='*80}")
    print(f"SUMMARY")
    print(f"{'='*80}")
    print(f"✅ Successful: {success_count}/{len(sql_files)}")
    if fail_count > 0:
        print(f"❌ Failed: {fail_count}/{len(sql_files)}")
    
    sys.exit(0 if fail_count == 0 else 1)

if __name__ == '__main__':
    main()
