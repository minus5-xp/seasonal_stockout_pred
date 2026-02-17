#!/usr/bin/env python3
"""
Main entrypoint for containerized pipeline.
Provides CLI with subcommands for different operations.
"""
import sys
import click
from pathlib import Path
from typing import Optional

from src.config.env import load_config, print_config
from src.bq.client import BigQueryClientFactory, get_default_client
from src.bq.run_sql_dir import SQLExecutor
from src.bq.phase_registry import PhaseRegistry


@click.group()
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
@click.pass_context
def cli(ctx, verbose):
    """Cruzber Option B Pipeline - Containerized Execution"""
    ctx.ensure_object(dict)
    ctx.obj['verbose'] = verbose


@cli.command()
@click.pass_context
def plan(ctx):
    """Show execution plan without running queries."""
    config = load_config(check_gcs=False)
    print_config(config)
    
    # Load SQL index
    index_path = determine_index_path(config.mode)
    
    print(f"\nExecution plan from: {index_path.name}\n")
    print("This would execute queries in order:")
    print("(Use --dry-run with 'run' command to see detailed plan)")
    
    # TODO: Parse and display query order from index
    print("\n✓ Plan generated")


@cli.command()
@click.option('--dry-run', is_flag=True, help='Show what would be executed without running')
@click.option('--continue-on-error', is_flag=True, help='Continue executing even if queries fail')
@click.option('--no-registry', is_flag=True, help='Disable experiment tracking')
@click.pass_context
def run(ctx, dry_run, continue_on_error, no_registry):
    """Execute the full pipeline."""
    verbose = ctx.obj['verbose']
    config = load_config(check_gcs=False)
    print_config(config)
    
    if dry_run:
        config.dry_run = True
        print("🔍 DRY RUN MODE - No queries will be executed\n")
    
    # Create BigQuery client
    client = get_default_client(config.project_id, config.location)
    
    # Ensure dataset exists
    BigQueryClientFactory.ensure_dataset_exists(
        client,
        config.dataset_ref,
        config.location
    )
    
    # Determine which index to use
    index_path = determine_index_path(config.mode)
    
    if not index_path.exists():
        print(f"❌ Index file not found: {index_path}", file=sys.stderr)
        print(f"   Available modes: optionB_full, trackA_only, b3_fix_only", file=sys.stderr)
        sys.exit(1)
    
    # Initialize experiment tracking
    registry = None
    run_id = None
    
    if not no_registry and not dry_run:
        try:
            registry = PhaseRegistry(
                project_id=config.project_id,
                dataset_id=config.dataset_id,
                location=config.location
            )
            
            # Start experiment run
            run_id = registry.start_run(
                run_name=f"{config.mode}_{config.run_id}",
                model_name="pipeline_optionB",
                config={
                    "mode": config.mode,
                    "topk": config.topk,
                    "n_min": config.n_min,
                    "vol_ntiles": config.vol_ntiles,
                    "coverage_grid": config.coverage_grid,
                },
                tags=[config.mode, "cloud_run", "automated"],
                author="pipeline_automation",
                notes=f"Automated pipeline execution via {index_path.name}"
            )
            
            # Start single phase for full pipeline
            registry.start_phase(run_id, "B1_OOS_RISK", phase_config={
                "pipeline_mode": config.mode,
                "sql_index": str(index_path.name)
            })
            
        except Exception as e:
            print(f"⚠️  Warning: Failed to initialize experiment tracking: {e}")
            registry = None
    
    # Execute queries
    executor = SQLExecutor(
        client=client,
        dry_run=config.dry_run,
        verbose=verbose or config.verbose
    )
    
    try:
        success = executor.execute_index(
            index_path=index_path,
            params=config.to_dict(),
            stop_on_error=not continue_on_error
        )
        
        executor.print_summary()
        
        # Record experiment metrics if tracking enabled
        if registry and run_id:
            try:
                registry.add_metrics(
                    run_id,
                    "B1_OOS_RISK",
                    metrics={
                        "total_queries": len(executor.executed),
                        "successful_queries": executor.success_count,
                        "failed_queries": executor.fail_count,
                        "success_rate": executor.success_count / len(executor.executed) if executor.executed else 0
                    },
                    split="pipeline"
                )
                
                # Complete phase
                registry.complete_phase(
                    run_id,
                    "B1_OOS_RISK",
                    status="SUCCESS" if success else "FAILED",
                    artifact_tables=[],
                    error_message=None if success else "Pipeline execution failed"
                )
                
                # Complete run
                registry.complete_run(
                    run_id,
                    status="SUCCESS" if success else "FAILED",
                    error_message=None if success else "Pipeline execution failed"
                )
                
            except Exception as e:
                print(f"⚠️  Warning: Failed to record experiment metrics: {e}")
        
        if not success and not dry_run:
            print("\n❌ Pipeline execution failed")
            sys.exit(1)
        
        print("\n✓ Pipeline execution complete")
        
    except Exception as e:
        # Mark experiment as failed if tracking enabled
        if registry and run_id:
            try:
                registry.complete_phase(run_id, "B1_OOS_RISK", status="FAILED", error_message=str(e))
                registry.complete_run(run_id, status="FAILED", error_message=str(e))
            except:
                pass
        
        raise


@cli.command()
@click.option('--dry-run', is_flag=True, help='Show what would be executed without running')
@click.option('--no-registry', is_flag=True, help='Disable experiment tracking')
@click.option('--compare', is_flag=True, help='Run comparison after both h1 and h4 forecasts')
@click.pass_context
def forecast(ctx, dry_run, no_registry, compare):
    """Execute probabilistic stockout forecasting (h1 or h4 horizon)."""
    verbose = ctx.obj['verbose']
    config = load_config(check_gcs=False)
    print_config(config)
    
    # Validate BASE_SALES_TABLE is provided
    if not config.base_sales_table:
        print("❌ ERROR: BASE_SALES_TABLE environment variable is required for forecasting", file=sys.stderr)
        print("\nExample:", file=sys.stderr)
        print("  export BASE_SALES_TABLE=thequantitativeledger.cruzber_models_eu.fact_lineas_albaran", file=sys.stderr)
        sys.exit(1)
    
    if dry_run:
        config.dry_run = True
        print("🔍 DRY RUN MODE - No queries will be executed\n")
    
    # Determine which SQL file to execute based on HORIZON_WEEKS
    if config.horizon_weeks == 1:
        sql_file = Path("sql/bqml/quantiles_v1/stockout_forecast_h1.sql")
        horizon_label = "h1"
        model_name = "stockout_forecast_h1"
    elif config.horizon_weeks == 4:
        sql_file = Path("sql/bqml/quantiles_v1/stockout_forecast_h4.sql")
        horizon_label = "h4"
        model_name = "stockout_forecast_h4"
    else:
        print(f"❌ ERROR: HORIZON_WEEKS must be 1 or 4 (got: {config.horizon_weeks})", file=sys.stderr)
        sys.exit(1)
    
    if not sql_file.exists():
        print(f"❌ SQL file not found: {sql_file}", file=sys.stderr)
        sys.exit(1)
    
    print(f"📊 Executing {horizon_label} forecast (horizon = {config.horizon_weeks} weeks)")
    print(f"📄 SQL file: {sql_file.name}\n")
    
    # Create BigQuery client
    client = get_default_client(config.project_id, config.location)
    
    # Ensure dataset exists
    BigQueryClientFactory.ensure_dataset_exists(
        client,
        config.dataset_ref,
        config.location
    )
    
    # Initialize experiment tracking
    registry = None
    run_id = None
    
    if not no_registry and not dry_run:
        try:
            registry = PhaseRegistry(
                project_id=config.project_id,
                dataset_id=config.dataset_id,
                location=config.location
            )
            
            # Start experiment run
            run_id = registry.start_run(
                run_name=f"{model_name}_{config.run_id}",
                model_name=model_name,
                config={
                    "horizon_weeks": config.horizon_weeks,
                    "base_sales_table": config.base_sales_table,
                    "topk": config.topk,
                    "n_min": config.n_min,
                },
                tags=[horizon_label, "quantiles", "probabilistic", "automated"],
                author="pipeline_automation",
                notes=f"Probabilistic stockout forecast with {config.horizon_weeks}-week horizon"
            )
            
            # Start forecasting phase
            registry.start_phase(run_id, "FORECAST", phase_config={
                "horizon": horizon_label,
                "sql_file": str(sql_file.name)
            })
            
        except Exception as e:
            print(f"⚠️  Warning: Failed to initialize experiment tracking: {e}")
            registry = None
    
    # Execute SQL file
    executor = SQLExecutor(
        client=client,
        dry_run=config.dry_run,
        verbose=verbose or config.verbose
    )
    
    try:
        success = executor.execute_file(
            sql_path=sql_file,
            params=config.to_dict()
        )
        
        executor.print_summary()
        
        # Record experiment metrics if tracking enabled
        if registry and run_id:
            try:
                registry.add_metrics(
                    run_id,
                    "FORECAST",
                    metrics={
                        "success": 1 if success else 0,
                        "horizon_weeks": config.horizon_weeks,
                    },
                    split="production"
                )
                
                # Complete phase
                registry.complete_phase(
                    run_id,
                    "FORECAST",
                    status="SUCCESS" if success else "FAILED",
                    artifact_tables=[
                        f"{config.dataset_id}.m_oos_{horizon_label}",
                        f"{config.dataset_id}.m_demand_{horizon_label}",
                        f"{config.dataset_id}.forecast_{horizon_label}",
                        f"{config.dataset_id}.alerts_top100_{horizon_label}",
                    ],
                    error_message=None if success else "Forecast execution failed"
                )
                
                # Complete run
                registry.complete_run(
                    run_id,
                    status="SUCCESS" if success else "FAILED",
                    error_message=None if success else "Forecast execution failed"
                )
                
            except Exception as e:
                print(f"⚠️  Warning: Failed to record experiment metrics: {e}")
        
        if not success and not dry_run:
            print(f"\n❌ {horizon_label} forecast execution failed")
            sys.exit(1)
        
        print(f"\n✓ {horizon_label} forecast execution complete")
        
        # Optionally run comparison if both h1 and h4 exist
        if compare and not dry_run:
            print("\n📊 Running h1 vs h4 comparison...")
            comparison_sql = Path("sql/bqml/eval/compare_h1_vs_h4.sql")
            
            if comparison_sql.exists():
                comparison_success = executor.execute_file(
                    sql_path=comparison_sql,
                    params=config.to_dict()
                )
                
                if comparison_success:
                    print("\n✓ Comparison complete")
                    print(f"\n📈 Results available in:")
                    print(f"   - {config.dataset_id}.compare_run_summary_h1_h4")
                    print(f"   - {config.dataset_id}.compare_scorecard_h1_h4")
                else:
                    print("\n⚠️  Comparison failed (may need both h1 and h4 forecasts)")
            else:
                print(f"⚠️  Comparison SQL not found: {comparison_sql}")
        
    except Exception as e:
        # Mark experiment as failed if tracking enabled
        if registry and run_id:
            try:
                registry.complete_phase(run_id, "FORECAST", status="FAILED", error_message=str(e))
                registry.complete_run(run_id, status="FAILED", error_message=str(e))
            except:
                pass
        
        raise


@cli.command()
@click.pass_context
def eval(ctx):
    """Run evaluation queries only."""
    config = load_config(check_gcs=False)
    print_config(config)
    
    print("Running evaluation queries...")
    
    # Create client
    client = get_default_client(config.project_id, config.location)
    
    # Run evaluation SQL
    eval_index = Path("sql/00_SQL_INDEX_EVAL.yml")
    
    if not eval_index.exists():
        print("⚠️  Evaluation index not found, running baseline eval queries")
        # Fallback to individual eval queries
        eval_queries = [
            "sql/eval/40_eval_quantiles_conditional.sql",
            "sql/eval/41_eval_baselines.sql",
        ]
        
        executor = SQLExecutor(client=client, verbose=ctx.obj['verbose'])
        
        for sql_file in eval_queries:
            sql_path = Path(sql_file)
            if sql_path.exists():
                executor.execute_file(sql_path, config.to_dict())
        
        executor.print_summary()
    else:
        executor = SQLExecutor(client=client, verbose=ctx.obj['verbose'])
        success = executor.execute_index(eval_index, config.to_dict())
        executor.print_summary()
        
        if not success:
            sys.exit(1)
    
    print("\n✓ Evaluation complete")


@cli.command()
@click.option('--name', type=str, help='Bundle name (default: auto-generated)')
@click.option('--output-dir', type=Path, default=Path('dist'), help='Output directory')
@click.pass_context
def bundle(ctx, name, output_dir):
    """Create distributable bundle."""
    from src.bundle.build_bundle import BundleBuilder
    
    config = load_config(check_gcs=False)
    
    bundle_name = name or f"cruzber_optionB_bundle_{config.run_id}"
    
    root_dir = Path(__file__).parent.parent
    builder = BundleBuilder(root_dir, output_dir)
    
    bundle_path = builder.build(bundle_name)
    
    print(f"\n✓ Bundle created: {bundle_path}")
    
    if config.gcs_bucket:
        print(f"\nTo upload:")
        print(f"  python -m src.entrypoint upload {bundle_path}")


@cli.command()
@click.argument('file', type=Path)
@click.option('--destination', type=str, help='GCS destination URL')
@click.pass_context
def upload(ctx, file, destination):
    """Upload file or directory to GCS."""
    from src.bundle.upload_bundle import BundleUploader
    
    config = load_config(check_gcs=True)  # Require GCS_BUCKET
    
    uploader = BundleUploader(config.project_id)
    
    gcs_url = destination or config.gcs_bundle_path
    
    if file.is_dir():
        urls = uploader.upload_directory(file, gcs_url)
        print(f"\n✓ Uploaded {len(urls)} files")
    else:
        uploader.upload_file(file, gcs_url)
        print(f"\n✓ Upload complete")


@cli.command()
@click.pass_context
def finalize(ctx):
    """Generate final reports and paper pack."""
    from src.reports.generate_checklist_final import generate_final_checklist
    from src.reports.generate_paper_pack import generate_paper_pack
    
    config = load_config(check_gcs=False)
    print_config(config)
    
    print("Generating final deliverables...\n")
    
    # Generate final checklist
    print("[1/3] Generating final checklist...")
    generate_final_checklist()
    print("  ✓ checklist_status_final.csv")
    
    # Generate paper pack
    print("\n[2/3] Generating paper pack...")
    generate_paper_pack()
    print("  ✓ paper/")
    
    # Generate final verdict
    print("\n[3/3] Generating final verdict...")
    from src.reports.generate_final_verdict import generate_verdict
    generate_verdict()
    print("  ✓ FINAL_VERDICT.md")
    
    print("\n✓ Finalization complete")
    print("\nDeliverables:")
    print("  - checklist_status_final.csv")
    print("  - FINAL_VERDICT.md")
    print("  - paper/")


def determine_index_path(mode: str) -> Path:
    """Determine which SQL index file to use based on mode."""
    mode_map = {
        "optionB_full": "sql/00_SQL_INDEX_OPTIONB.yml",
        "trackA_only": "sql/00_SQL_INDEX_TRACKA.yml",
        "b3_fix_only": "sql/00_SQL_INDEX_B3_FIX.yml",
        "eval_only": "sql/00_SQL_INDEX_EVAL.yml",
    }
    
    index_file = mode_map.get(mode, "sql/00_SQL_INDEX_OPTIONB.yml")
    return Path(index_file)


if __name__ == "__main__":
    cli(obj={})
