"""
Cruzber XLSX Parser - Main CLI Orchestrator
============================================
Complete ETL pipeline for Cruzber data:
1. Load all XLSX files (100% read)
2. Clean and type
3. Stage to parquet (cache)
4. Validate PK/FK/Margin
5. Generate quality report
6. Export clean data

Author: Senior Data Engineer
Date: 2025-12-20
"""

import argparse
import sys
from pathlib import Path
from datetime import datetime
import logging
import json

# Add src to path
sys.path.append(str(Path(__file__).parent))

from parser_cruzber import load_all
from validation_cruzber import (
    validate_pk_uniqueness,
    validate_fk,
    validate_null_rates,
    validate_margin_from_base_imponible,
    reconstruct_descuento2
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('cruzber_parser.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)


def save_staging(datasets, staging_dir):
    """
    Save datasets to staging directory as parquet (cache).
    """
    logger.info("=" * 80)
    logger.info("SAVING STAGING DATA")
    logger.info("=" * 80)
    
    staging_dir = Path(staging_dir)
    staging_dir.mkdir(parents=True, exist_ok=True)
    
    for name, df in datasets.items():
        if len(df) == 0:
            logger.warning(f"Skipping empty dataset: {name}")
            continue
        
        file_path = staging_dir / f"{name}.parquet"
        df.to_parquet(file_path, index=False, engine='pyarrow')
        logger.info(f"  Saved: {name} → {file_path} ({len(df):,} rows)")
    
    logger.info("")


def run_validations(datasets, tolerance_abs, tolerance_pct):
    """
    Run all validation checks and return results.
    """
    logger.info("=" * 80)
    logger.info("RUNNING VALIDATIONS")
    logger.info("=" * 80)
    logger.info("")
    
    validation_results = {}
    
    # ========================================================================
    # PRIMARY KEY VALIDATIONS
    # ========================================================================
    logger.info("-" * 80)
    logger.info("PRIMARY KEY VALIDATIONS")
    logger.info("-" * 80)
    
    pk_validations = []
    
    if 'MaestroFamilias' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['MaestroFamilias'], ['CodigoFamilia'], 'MaestroFamilias')
        )
    
    if 'MaestroMunicipios' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['MaestroMunicipios'], ['CodigoMunicipio'], 'MaestroMunicipios')
        )
    
    if 'MaestroProvincias' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['MaestroProvincias'], ['CodigoProvincia'], 'MaestroProvincias')
        )
    
    if 'MaestroArticulos' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['MaestroArticulos'], ['CodigoArticulo'], 'MaestroArticulos')
        )
    
    if 'MaestroNaciones' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['MaestroNaciones'], ['CodigoNacion'], 'MaestroNaciones')
        )
    
    if 'AgrupacionCanalesVenta' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['AgrupacionCanalesVenta'], ['CanalVenta'], 'AgrupacionCanalesVenta')
        )
    
    if 'MaestroClientes' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(datasets['MaestroClientes'], ['CodigoCliente'], 'MaestroClientes')
        )
    
    if 'LineasAlbaranCliente' in datasets:
        pk_validations.append(
            validate_pk_uniqueness(
                datasets['LineasAlbaranCliente'],
                ['NumeroAlbaran', 'NumeroLinea'],
                'LineasAlbaranCliente'
            )
        )
    
    validation_results['pk_validations'] = pk_validations
    logger.info("")
    
    # ========================================================================
    # FOREIGN KEY VALIDATIONS
    # ========================================================================
    logger.info("-" * 80)
    logger.info("FOREIGN KEY VALIDATIONS")
    logger.info("-" * 80)
    
    fk_validations = []
    
    # MaestroMunicipios → MaestroProvincias
    if 'MaestroMunicipios' in datasets and 'MaestroProvincias' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['MaestroMunicipios'],
                datasets['MaestroProvincias'],
                'CodigoProvincia',
                'CodigoProvincia',
                'MaestroMunicipios',
                'MaestroProvincias',
                allow_null=True
            )
        )
    
    # MaestroProvincias → MaestroNaciones
    if 'MaestroProvincias' in datasets and 'MaestroNaciones' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['MaestroProvincias'],
                datasets['MaestroNaciones'],
                'CodigoNacion',
                'CodigoNacion',
                'MaestroProvincias',
                'MaestroNaciones',
                allow_null=True
            )
        )
    
    # FamiliasArticulos → MaestroArticulos
    if 'FamiliasArticulos' in datasets and 'MaestroArticulos' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['FamiliasArticulos'],
                datasets['MaestroArticulos'],
                'CodigoArticulo',
                'CodigoArticulo',
                'FamiliasArticulos',
                'MaestroArticulos',
                allow_null=False
            )
        )
    
    # FamiliasArticulos → MaestroFamilias
    if 'FamiliasArticulos' in datasets and 'MaestroFamilias' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['FamiliasArticulos'],
                datasets['MaestroFamilias'],
                'CodigoFamilia',
                'CodigoFamilia',
                'FamiliasArticulos',
                'MaestroFamilias',
                allow_null=False
            )
        )
    
    # MaestroClientes → MaestroMunicipios
    if 'MaestroClientes' in datasets and 'MaestroMunicipios' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['MaestroClientes'],
                datasets['MaestroMunicipios'],
                'CodigoMunicipio',
                'CodigoMunicipio',
                'MaestroClientes',
                'MaestroMunicipios',
                allow_null=True
            )
        )
    
    # MaestroClientes → AgrupacionCanalesVenta
    if 'MaestroClientes' in datasets and 'AgrupacionCanalesVenta' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['MaestroClientes'],
                datasets['AgrupacionCanalesVenta'],
                'CanalVenta',
                'CanalVenta',
                'MaestroClientes',
                'AgrupacionCanalesVenta',
                allow_null=True
            )
        )
    
    # LineasAlbaranCliente → MaestroClientes
    if 'LineasAlbaranCliente' in datasets and 'MaestroClientes' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['LineasAlbaranCliente'],
                datasets['MaestroClientes'],
                'CodigoCliente',
                'CodigoCliente',
                'LineasAlbaranCliente',
                'MaestroClientes',
                allow_null=False
            )
        )
    
    # LineasAlbaranCliente → MaestroArticulos
    if 'LineasAlbaranCliente' in datasets and 'MaestroArticulos' in datasets:
        fk_validations.append(
            validate_fk(
                datasets['LineasAlbaranCliente'],
                datasets['MaestroArticulos'],
                'CodigoArticulo',
                'CodigoArticulo',
                'LineasAlbaranCliente',
                'MaestroArticulos',
                allow_null=False
            )
        )
    
    validation_results['fk_validations'] = fk_validations
    logger.info("")
    
    # ========================================================================
    # NULL RATE VALIDATIONS
    # ========================================================================
    logger.info("-" * 80)
    logger.info("NULL RATE VALIDATIONS")
    logger.info("-" * 80)
    
    null_validations = []
    
    for name, df in datasets.items():
        if len(df) == 0:
            continue
        
        # Define critical columns per table
        critical_cols = None
        if name == 'LineasAlbaranCliente':
            critical_cols = [
                'NumeroAlbaran', 'NumeroLinea', 'FechaAlbaran',
                'CodigoCliente', 'CodigoArticulo',
                'BaseImponible', 'ImporteCoste'
            ]
        elif name == 'MaestroClientes':
            critical_cols = ['CodigoCliente', 'NombreCliente']
        elif name == 'MaestroArticulos':
            critical_cols = ['CodigoArticulo', 'DescripcionArticulo']
        
        result = validate_null_rates(df, name, critical_cols)
        null_validations.append(result)
    
    validation_results['null_validations'] = null_validations
    logger.info("")
    
    # ========================================================================
    # MARGIN VALIDATION (AUTHORITATIVE LOGIC)
    # ========================================================================
    if 'LineasAlbaranCliente' in datasets:
        logger.info("-" * 80)
        logger.info("MARGIN VALIDATION (AUTHORITATIVE LOGIC)")
        logger.info("-" * 80)
        
        margin_result = validate_margin_from_base_imponible(
            datasets['LineasAlbaranCliente'],
            tolerance_abs=tolerance_abs,
            tolerance_pct=tolerance_pct
        )
        validation_results['margin_validation'] = margin_result
        
        # Optional: Discount reconstruction (diagnostic)
        logger.info("")
        discount_result = reconstruct_descuento2(
            datasets['LineasAlbaranCliente'],
            tolerance_pct=tolerance_pct
        )
        validation_results['discount_reconstruction'] = discount_result
    
    logger.info("")
    return validation_results


def generate_report(datasets, validation_results, report_path):
    """
    Generate comprehensive Markdown quality report.
    """
    logger.info("=" * 80)
    logger.info("GENERATING QUALITY REPORT")
    logger.info("=" * 80)
    
    report_path = Path(report_path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write("# Cruzber Parser Quality Report\n\n")
        f.write(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.write("---\n\n")
        
        # ====================================================================
        # TABLE INVENTORY
        # ====================================================================
        f.write("## 1. Table Inventory\n\n")
        f.write("| Table | Rows | Columns |\n")
        f.write("|-------|-----:|--------:|\n")
        
        for name, df in datasets.items():
            f.write(f"| {name} | {len(df):,} | {len(df.columns)} |\n")
        
        f.write("\n---\n\n")
        
        # ====================================================================
        # DATA TYPES
        # ====================================================================
        f.write("## 2. Data Types\n\n")
        
        for name, df in datasets.items():
            if len(df) == 0:
                continue
            
            f.write(f"### {name}\n\n")
            f.write("| Column | Type | Null Count | Null % |\n")
            f.write("|--------|------|------------|--------|\n")
            
            for col in df.columns:
                null_count = df[col].isna().sum()
                null_pct = (null_count / len(df) * 100) if len(df) > 0 else 0
                dtype_str = str(df[col].dtype)
                f.write(f"| {col} | {dtype_str} | {null_count:,} | {null_pct:.2f}% |\n")
            
            f.write("\n")
        
        f.write("---\n\n")
        
        # ====================================================================
        # PRIMARY KEY VALIDATIONS
        # ====================================================================
        f.write("## 3. Primary Key Validations\n\n")
        f.write("| Table | PK Columns | Total Rows | Unique Keys | Duplicates | Valid |\n")
        f.write("|-------|------------|------------|-------------|------------|-------|\n")
        
        for val in validation_results.get('pk_validations', []):
            pk_cols_str = ', '.join(val['pk_cols'])
            valid_icon = "✅" if val['is_valid'] else "❌"
            f.write(
                f"| {val['table']} | {pk_cols_str} | {val['total_rows']:,} | "
                f"{val['unique_keys']:,} | {val['duplicates']:,} | {valid_icon} |\n"
            )
        
        f.write("\n")
        
        # Show duplicate examples if any
        for val in validation_results.get('pk_validations', []):
            if val['duplicates'] > 0 and val['duplicate_keys']:
                f.write(f"**{val['table']} - Duplicate Keys (top 10):**\n\n")
                for key, count in list(val['duplicate_keys'].items())[:10]:
                    f.write(f"- `{key}`: {count} occurrences\n")
                f.write("\n")
        
        f.write("---\n\n")
        
        # ====================================================================
        # FOREIGN KEY VALIDATIONS
        # ====================================================================
        f.write("## 4. Foreign Key Validations\n\n")
        f.write("| Child Table | Parent Table | FK Column | Orphans | Orphan % | Valid |\n")
        f.write("|-------------|--------------|-----------|---------|----------|-------|\n")
        
        for val in validation_results.get('fk_validations', []):
            valid_icon = "✅" if val['is_valid'] else "❌"
            f.write(
                f"| {val['child_table']} | {val['parent_table']} | {val['fk_col']} | "
                f"{val['orphan_rows']:,} | {val['orphan_pct']:.2f}% | {valid_icon} |\n"
            )
        
        f.write("\n")
        
        # Show orphan examples if any
        for val in validation_results.get('fk_validations', []):
            if val['orphan_rows'] > 0 and val['orphan_values']:
                f.write(f"**{val['child_table']}.{val['fk_col']} - Orphan Values (top 10):**\n\n")
                for key, count in list(val['orphan_values'].items())[:10]:
                    f.write(f"- `{key}`: {count} occurrences\n")
                f.write("\n")
        
        f.write("---\n\n")
        
        # ====================================================================
        # NULL RATES
        # ====================================================================
        f.write("## 5. Null Rates (Critical Columns)\n\n")
        
        for val in validation_results.get('null_validations', []):
            if 'critical_nulls' in val:
                f.write(f"### {val['table']}\n\n")
                f.write("| Column | Null % |\n")
                f.write("|--------|--------|\n")
                
                for col, pct in val['critical_nulls'].items():
                    f.write(f"| {col} | {pct:.2f}% |\n")
                
                f.write("\n")
        
        f.write("---\n\n")
        
        # ====================================================================
        # MARGIN VALIDATION (AUTHORITATIVE)
        # ====================================================================
        if 'margin_validation' in validation_results:
            mv = validation_results['margin_validation']
            
            f.write("## 6. Margin Validation (Authoritative Logic)\n\n")
            f.write("**Financial Rule:**\n")
            f.write("- `MargenBeneficio = BaseImponible - ImporteCoste`\n")
            f.write("- `PorMargenBeneficio = 100 × (MargenBeneficio / BaseImponible)`\n\n")
            f.write("**BaseImponible is the SOURCE OF TRUTH** (net revenue without VAT).\n\n")
            
            f.write("### Summary\n\n")
            f.write("| Metric | Value |\n")
            f.write("|--------|-------|\n")
            f.write(f"| Total Rows | {mv['total_rows']:,} |\n")
            f.write(f"| Evaluable Rows | {mv['evaluable_rows']:,} |\n")
            f.write(f"| Not Evaluable | {mv['not_evaluable_rows']:,} ({mv['not_evaluable_pct']:.2f}%) |\n")
            f.write("\n")
            
            f.write("### MargenBeneficio Validation\n\n")
            f.write("| Status | Count | % of Evaluable |\n")
            f.write("|--------|-------|----------------|\n")
            f.write(f"| ✅ OK | {mv['margen_ok']:,} | {mv['margen_ok_pct']:.2f}% |\n")
            f.write(f"| ❌ FAIL | {mv['margen_fail']:,} | {mv['margen_fail_pct']:.2f}% |\n")
            f.write("\n")
            
            if mv['delta_margen_stats']:
                f.write("**Delta Statistics:**\n\n")
                stats = mv['delta_margen_stats']
                f.write(f"- Mean: {stats.get('mean', 0):.4f}\n")
                f.write(f"- Std Dev: {stats.get('std', 0):.4f}\n")
                f.write(f"- Min: {stats.get('min', 0):.4f}\n")
                f.write(f"- Max: {stats.get('max', 0):.4f}\n")
                f.write("\n")
            
            f.write("### PorMargenBeneficio Validation\n\n")
            f.write("| Status | Count | % of Evaluable |\n")
            f.write("|--------|-------|----------------|\n")
            f.write(f"| ✅ OK | {mv['pormargen_ok']:,} | {mv['pormargen_ok_pct']:.2f}% |\n")
            f.write(f"| ❌ FAIL | {mv['pormargen_fail']:,} | {mv['pormargen_fail_pct']:.2f}% |\n")
            f.write("\n")
            
            if mv['delta_pormargen_stats']:
                f.write("**Delta Statistics:**\n\n")
                stats = mv['delta_pormargen_stats']
                f.write(f"- Mean: {stats.get('mean', 0):.4f}%\n")
                f.write(f"- Std Dev: {stats.get('std', 0):.4f}%\n")
                f.write(f"- Min: {stats.get('min', 0):.4f}%\n")
                f.write(f"- Max: {stats.get('max', 0):.4f}%\n")
                f.write("\n")
            
            f.write("### Combined Validation (Both OK)\n\n")
            f.write(f"**{mv['both_ok']:,} rows** ({mv['both_ok_pct']:.2f}%) passed both validations.\n\n")
            
            # Top deviations
            if mv['top_margen_deviations']:
                f.write("### Top MargenBeneficio Deviations\n\n")
                f.write("| BaseImponible | ImporteCoste | MargenBeneficio | Expected | Delta |\n")
                f.write("|---------------|--------------|-----------------|----------|-------|\n")
                
                for dev in mv['top_margen_deviations'][:10]:
                    f.write(
                        f"| {dev.get('BaseImponible', 0):.2f} | {dev.get('ImporteCoste', 0):.2f} | "
                        f"{dev.get('MargenBeneficio', 0):.2f} | {dev.get('Expected', 0):.2f} | "
                        f"{dev.get('Delta', 0):.4f} |\n"
                    )
                f.write("\n")
            
            if mv['top_pormargen_deviations']:
                f.write("### Top PorMargenBeneficio Deviations\n\n")
                f.write("| BaseImponible | MargenBeneficio | PorMargenBeneficio | Expected | Delta |\n")
                f.write("|---------------|-----------------|--------------------|---------:|------:|\n")
                
                for dev in mv['top_pormargen_deviations'][:10]:
                    f.write(
                        f"| {dev.get('BaseImponible', 0):.2f} | {dev.get('MargenBeneficio', 0):.2f} | "
                        f"{dev.get('PorMargenBeneficio', 0):.2f}% | {dev.get('Expected', 0):.2f}% | "
                        f"{dev.get('Delta', 0):.4f}% |\n"
                    )
                f.write("\n")
            
            f.write("---\n\n")
        
        # ====================================================================
        # DISCOUNT RECONSTRUCTION (OPTIONAL)
        # ====================================================================
        if 'discount_reconstruction' in validation_results:
            dr = validation_results['discount_reconstruction']
            
            if 'error' not in dr:
                f.write("## 7. Discount Reconstruction (Diagnostic)\n\n")
                f.write("**Note:** This is for audit purposes only and does NOT affect margin validation.\n\n")
                
                f.write("| Metric | Value |\n")
                f.write("|--------|-------|\n")
                f.write(f"| Total Rows | {dr['total_rows']:,} |\n")
                f.write(f"| Reconstructable Rows | {dr['reconstructable_rows']:,} |\n")
                f.write(f"| Reconstruction OK | {dr.get('reconstruction_ok', 0):,} |\n")
                f.write(f"| Reconstruction FAIL | {dr.get('reconstruction_fail', 0):,} |\n")
                
                if dr.get('reconstruction_ok_pct'):
                    f.write(f"| OK % | {dr['reconstruction_ok_pct']:.2f}% |\n")
                
                f.write("\n---\n\n")
        
        # ====================================================================
        # FOOTER
        # ====================================================================
        f.write("## Conclusion\n\n")
        f.write("All datasets have been parsed, validated, and exported.\n")
        f.write("Review validation results above for data quality issues.\n\n")
        f.write("**Authoritative Margin Logic:**\n")
        f.write("- All margin calculations are based on **BaseImponible** (net revenue without VAT)\n")
        f.write("- Discount columns are NOT used for margin validation\n")
        f.write("- BaseImponible already reflects all discounts, pronto pago, and commercial adjustments\n\n")
        f.write("---\n\n")
        f.write(f"*Report generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*\n")
    
    logger.info(f"Report saved to: {report_path}")
    logger.info("")


def export_clean_data(datasets, out_dir, file_format, partition_lineas):
    """
    Export clean datasets to output directory.
    """
    logger.info("=" * 80)
    logger.info("EXPORTING CLEAN DATA")
    logger.info("=" * 80)
    
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    
    for name, df in datasets.items():
        if len(df) == 0:
            logger.warning(f"Skipping empty dataset: {name}")
            continue
        
        # Special handling for LineasAlbaranCliente partitioning
        if name == 'LineasAlbaranCliente' and partition_lineas and 'FechaAlbaran' in df.columns:
            # Partition by year
            df['_year'] = df['FechaAlbaran'].dt.year
            
            for year, df_year in df.groupby('_year'):
                df_year = df_year.drop(columns=['_year'])
                
                year_dir = out_dir / name / f"year={year}"
                year_dir.mkdir(parents=True, exist_ok=True)
                
                if file_format == 'parquet':
                    file_path = year_dir / f"{name}_{year}.parquet"
                    df_year.to_parquet(file_path, index=False, engine='pyarrow')
                else:
                    file_path = year_dir / f"{name}_{year}.csv"
                    df_year.to_csv(file_path, index=False)
                
                logger.info(f"  Saved: {name} (year={year}) → {file_path} ({len(df_year):,} rows)")
        else:
            # Standard export
            if file_format == 'parquet':
                file_path = out_dir / f"{name}.parquet"
                df.to_parquet(file_path, index=False, engine='pyarrow')
            else:
                file_path = out_dir / f"{name}.csv"
                df.to_csv(file_path, index=False)
            
            logger.info(f"  Saved: {name} → {file_path} ({len(df):,} rows)")
    
    logger.info("")


def main():
    """
    Main CLI orchestrator.
    """
    parser = argparse.ArgumentParser(
        description='Cruzber XLSX Parser - Full ETL Pipeline',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic usage
  python run_parse.py --base-path ../CRUZBER
  
  # With custom output and staging
  python run_parse.py --base-path ../CRUZBER --out-dir ../data/clean --staging-dir ../data/staging
  
  # Export as CSV with partitioning
  python run_parse.py --base-path ../CRUZBER --format csv --partition-lineas-by-year
  
  # Adjust validation tolerances
  python run_parse.py --base-path ../CRUZBER --tolerance-abs 0.05 --tolerance-pct 0.05
        """
    )
    
    parser.add_argument(
        '--base-path',
        type=str,
        required=True,
        help='Base path to CRUZBER directory containing XLSX files'
    )
    
    parser.add_argument(
        '--out-dir',
        type=str,
        default='../data/clean',
        help='Output directory for clean data (default: ../data/clean)'
    )
    
    parser.add_argument(
        '--staging-dir',
        type=str,
        default='../data/staging',
        help='Staging directory for parquet cache (default: ../data/staging)'
    )
    
    parser.add_argument(
        '--report-path',
        type=str,
        default='../reports/parser_quality_report.md',
        help='Path for quality report (default: ../reports/parser_quality_report.md)'
    )
    
    parser.add_argument(
        '--format',
        type=str,
        choices=['parquet', 'csv'],
        default='parquet',
        help='Output file format (default: parquet)'
    )
    
    parser.add_argument(
        '--partition-lineas-by-year',
        action='store_true',
        help='Partition LineasAlbaranCliente by year(FechaAlbaran)'
    )
    
    parser.add_argument(
        '--tolerance-abs',
        type=float,
        default=0.01,
        help='Absolute tolerance for currency validation (default: 0.01)'
    )
    
    parser.add_argument(
        '--tolerance-pct',
        type=float,
        default=0.01,
        help='Percentage tolerance for percentage validation (default: 0.01)'
    )
    
    parser.add_argument(
        '--skip-staging',
        action='store_true',
        help='Skip saving staging parquet files'
    )
    
    args = parser.parse_args()
    
    # ========================================================================
    # EXECUTION
    # ========================================================================
    start_time = datetime.now()
    
    logger.info("")
    logger.info("=" * 80)
    logger.info("CRUZBER XLSX PARSER - FULL PIPELINE")
    logger.info("=" * 80)
    logger.info(f"Start time: {start_time.strftime('%Y-%m-%d %H:%M:%S')}")
    logger.info(f"Base path: {args.base_path}")
    logger.info(f"Output dir: {args.out_dir}")
    logger.info(f"Staging dir: {args.staging_dir}")
    logger.info(f"Report path: {args.report_path}")
    logger.info(f"Format: {args.format}")
    logger.info(f"Partition LineasAlbaranCliente: {args.partition_lineas_by_year}")
    logger.info(f"Tolerance (abs): {args.tolerance_abs}")
    logger.info(f"Tolerance (pct): {args.tolerance_pct}")
    logger.info("")
    
    try:
        # Step 1: Load all XLSX (100% read)
        datasets = load_all(args.base_path)
        
        # Step 2: Save staging (cache)
        if not args.skip_staging:
            save_staging(datasets, args.staging_dir)
        
        # Step 3: Run validations
        validation_results = run_validations(
            datasets,
            args.tolerance_abs,
            args.tolerance_pct
        )
        
        # Step 4: Generate report
        generate_report(datasets, validation_results, args.report_path)
        
        # Step 5: Export clean data
        export_clean_data(
            datasets,
            args.out_dir,
            args.format,
            args.partition_lineas_by_year
        )
        
        # Summary
        end_time = datetime.now()
        duration = (end_time - start_time).total_seconds()
        
        logger.info("=" * 80)
        logger.info("PIPELINE COMPLETE")
        logger.info("=" * 80)
        logger.info(f"End time: {end_time.strftime('%Y-%m-%d %H:%M:%S')}")
        logger.info(f"Duration: {duration:.1f} seconds")
        logger.info("")
        logger.info("Outputs:")
        logger.info(f"  - Clean data: {args.out_dir}")
        logger.info(f"  - Staging cache: {args.staging_dir}")
        logger.info(f"  - Quality report: {args.report_path}")
        logger.info("")
        
        return 0
        
    except Exception as e:
        logger.error(f"Pipeline failed: {e}", exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
