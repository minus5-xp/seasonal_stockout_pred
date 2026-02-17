"""
Cruzber Validation Module
==========================
Reusable validators for data quality, PK/FK integrity, and financial auditing.

CRITICAL FINANCIAL LOGIC:
- Margin calculation MUST use BaseImponible (net revenue without VAT)
- MargenBeneficio = BaseImponible - ImporteCoste
- PorMargenBeneficio = 100 × (MargenBeneficio / BaseImponible)
- DO NOT use discount columns or other revenue fields

Author: Senior Data Engineer
Date: 2025-12-20
"""

import pandas as pd
import numpy as np
from typing import Dict, Tuple, Optional, List
import logging

logger = logging.getLogger(__name__)


# ============================================================================
# PRIMARY KEY VALIDATION
# ============================================================================

def validate_pk_uniqueness(
    df: pd.DataFrame,
    pk_cols: List[str],
    table_name: str
) -> Dict[str, any]:
    """
    Validate that primary key columns are unique.
    
    Returns:
        {
            'table': str,
            'pk_cols': List[str],
            'total_rows': int,
            'unique_keys': int,
            'duplicates': int,
            'is_valid': bool,
            'duplicate_keys': List (top 10)
        }
    """
    logger.info(f"Validating PK uniqueness for {table_name}: {pk_cols}")
    
    total_rows = len(df)
    
    # Check if columns exist
    missing_cols = [c for c in pk_cols if c not in df.columns]
    if missing_cols:
        logger.error(f"  Missing PK columns: {missing_cols}")
        return {
            'table': table_name,
            'pk_cols': pk_cols,
            'total_rows': total_rows,
            'unique_keys': 0,
            'duplicates': 0,
            'is_valid': False,
            'error': f"Missing columns: {missing_cols}",
            'duplicate_keys': []
        }
    
    # Count unique keys
    if len(pk_cols) == 1:
        unique_keys = df[pk_cols[0]].nunique()
        duplicates = total_rows - unique_keys
        
        # Find duplicate keys
        if duplicates > 0:
            dup_keys = df[df.duplicated(subset=pk_cols, keep=False)][pk_cols[0]].value_counts().head(10).to_dict()
        else:
            dup_keys = []
    else:
        # Composite key
        key_counts = df.groupby(pk_cols).size()
        unique_keys = len(key_counts)
        duplicates = (key_counts > 1).sum()
        
        # Find duplicate keys
        if duplicates > 0:
            dup_keys = key_counts[key_counts > 1].head(10).to_dict()
        else:
            dup_keys = []
    
    is_valid = (duplicates == 0)
    
    logger.info(f"  Total rows: {total_rows:,}")
    logger.info(f"  Unique keys: {unique_keys:,}")
    logger.info(f"  Duplicates: {duplicates:,}")
    logger.info(f"  Valid: {is_valid}")
    
    return {
        'table': table_name,
        'pk_cols': pk_cols,
        'total_rows': total_rows,
        'unique_keys': unique_keys,
        'duplicates': duplicates,
        'is_valid': is_valid,
        'duplicate_keys': dup_keys
    }


# ============================================================================
# FOREIGN KEY VALIDATION
# ============================================================================

def validate_fk(
    df_child: pd.DataFrame,
    df_parent: pd.DataFrame,
    fk_col: str,
    pk_col: str,
    child_table: str,
    parent_table: str,
    allow_null: bool = True
) -> Dict[str, any]:
    """
    Validate foreign key integrity.
    
    Returns:
        {
            'child_table': str,
            'parent_table': str,
            'fk_col': str,
            'pk_col': str,
            'total_child_rows': int,
            'null_fk_rows': int,
            'orphan_rows': int,
            'orphan_pct': float,
            'is_valid': bool,
            'orphan_values': List (top 10)
        }
    """
    logger.info(f"Validating FK: {child_table}.{fk_col} -> {parent_table}.{pk_col}")
    
    total_rows = len(df_child)
    
    # Check if columns exist
    if fk_col not in df_child.columns:
        logger.error(f"  FK column '{fk_col}' not found in {child_table}")
        return {
            'child_table': child_table,
            'parent_table': parent_table,
            'fk_col': fk_col,
            'pk_col': pk_col,
            'total_child_rows': total_rows,
            'null_fk_rows': 0,
            'orphan_rows': 0,
            'orphan_pct': 0.0,
            'is_valid': False,
            'error': f"FK column not found: {fk_col}",
            'orphan_values': []
        }
    
    if pk_col not in df_parent.columns:
        logger.error(f"  PK column '{pk_col}' not found in {parent_table}")
        return {
            'child_table': child_table,
            'parent_table': parent_table,
            'fk_col': fk_col,
            'pk_col': pk_col,
            'total_child_rows': total_rows,
            'null_fk_rows': 0,
            'orphan_rows': 0,
            'orphan_pct': 0.0,
            'is_valid': False,
            'error': f"PK column not found: {pk_col}",
            'orphan_values': []
        }
    
    # Count nulls in FK
    null_fk_rows = df_child[fk_col].isna().sum()
    
    # Get valid parent keys
    parent_keys = set(df_parent[pk_col].dropna())
    
    # Get child keys (excluding nulls if allowed)
    if allow_null:
        child_keys_to_check = df_child[df_child[fk_col].notna()][fk_col]
    else:
        child_keys_to_check = df_child[fk_col]
    
    # Find orphans
    orphans = child_keys_to_check[~child_keys_to_check.isin(parent_keys)]
    orphan_rows = len(orphans)
    orphan_pct = (orphan_rows / total_rows * 100) if total_rows > 0 else 0.0
    
    # Top orphan values
    if orphan_rows > 0:
        orphan_values = orphans.value_counts().head(10).to_dict()
    else:
        orphan_values = []
    
    is_valid = (orphan_rows == 0) and (allow_null or null_fk_rows == 0)
    
    logger.info(f"  Total child rows: {total_rows:,}")
    logger.info(f"  Null FK rows: {null_fk_rows:,}")
    logger.info(f"  Orphan rows: {orphan_rows:,} ({orphan_pct:.2f}%)")
    logger.info(f"  Valid: {is_valid}")
    
    return {
        'child_table': child_table,
        'parent_table': parent_table,
        'fk_col': fk_col,
        'pk_col': pk_col,
        'total_child_rows': total_rows,
        'null_fk_rows': null_fk_rows,
        'orphan_rows': orphan_rows,
        'orphan_pct': orphan_pct,
        'is_valid': is_valid,
        'orphan_values': orphan_values
    }


# ============================================================================
# NULL RATE VALIDATION
# ============================================================================

def validate_null_rates(
    df: pd.DataFrame,
    table_name: str,
    critical_cols: Optional[List[str]] = None
) -> Dict[str, any]:
    """
    Calculate null rates for all columns.
    
    Returns:
        {
            'table': str,
            'total_rows': int,
            'null_rates': Dict[str, float],
            'critical_nulls': Dict[str, float] (if critical_cols provided)
        }
    """
    logger.info(f"Calculating null rates for {table_name}")
    
    total_rows = len(df)
    null_rates = {}
    
    for col in df.columns:
        null_count = df[col].isna().sum()
        null_pct = (null_count / total_rows * 100) if total_rows > 0 else 0.0
        null_rates[col] = null_pct
    
    result = {
        'table': table_name,
        'total_rows': total_rows,
        'null_rates': null_rates
    }
    
    if critical_cols:
        critical_nulls = {col: null_rates.get(col, 100.0) for col in critical_cols if col in df.columns}
        result['critical_nulls'] = critical_nulls
        
        logger.info(f"  Critical column null rates:")
        for col, pct in critical_nulls.items():
            logger.info(f"    {col}: {pct:.2f}%")
    
    return result


# ============================================================================
# MARGIN VALIDATION (AUTHORITATIVE LOGIC)
# ============================================================================

def validate_margin_from_base_imponible(
    df: pd.DataFrame,
    tolerance_abs: float = 0.01,
    tolerance_pct: float = 0.01
) -> Dict[str, any]:
    """
    Validate margin calculation using AUTHORITATIVE LOGIC:
    
    FINANCIAL RULES (NON-NEGOTIABLE):
    1) MargenBeneficio = BaseImponible - ImporteCoste
    2) PorMargenBeneficio = 100 × (MargenBeneficio / BaseImponible)
    
    BaseImponible is the SOURCE OF TRUTH (net revenue without VAT).
    It already reflects all discounts, pronto pago, and commercial adjustments.
    
    Args:
        df: DataFrame with columns:
            - BaseImponible (required)
            - ImporteCoste (required)
            - MargenBeneficio (optional, will be validated)
            - PorMargenBeneficio (optional, will be validated)
        tolerance_abs: Absolute tolerance for currency amounts
        tolerance_pct: Percentage tolerance for percentage fields
    
    Returns:
        {
            'total_rows': int,
            'evaluable_rows': int,
            'not_evaluable_rows': int,
            'not_evaluable_pct': float,
            
            'margen_ok': int,
            'margen_fail': int,
            'margen_ok_pct': float,
            'margen_fail_pct': float,
            
            'pormargen_ok': int,
            'pormargen_fail': int,
            'pormargen_ok_pct': float,
            'pormargen_fail_pct': float,
            
            'both_ok': int,
            'both_ok_pct': float,
            
            'delta_margen_stats': Dict[str, float],
            'delta_pormargen_stats': Dict[str, float],
            
            'top_margen_deviations': List[Dict],
            'top_pormargen_deviations': List[Dict],
            
            'validation_flags': DataFrame (added columns to input df)
        }
    """
    logger.info("=" * 80)
    logger.info("MARGIN VALIDATION (AUTHORITATIVE LOGIC)")
    logger.info("=" * 80)
    logger.info("Financial Rule: MargenBeneficio = BaseImponible - ImporteCoste")
    logger.info("                PorMargenBeneficio = 100 × (MargenBeneficio / BaseImponible)")
    logger.info(f"Tolerance (absolute): ±{tolerance_abs}")
    logger.info(f"Tolerance (percentage): ±{tolerance_pct}%")
    logger.info("")
    
    # Check required columns
    required_cols = ['BaseImponible', 'ImporteCoste']
    missing_cols = [c for c in required_cols if c not in df.columns]
    
    if missing_cols:
        logger.error(f"Missing required columns: {missing_cols}")
        return {
            'error': f"Missing required columns: {missing_cols}",
            'total_rows': len(df)
        }
    
    # Create working copy
    df_work = df.copy()
    total_rows = len(df_work)
    
    # Identify evaluable rows
    # Not evaluable if: BaseImponible is null, 0, or ImporteCoste is null
    df_work['_evaluable'] = (
        df_work['BaseImponible'].notna() &
        (df_work['BaseImponible'] != 0) &
        df_work['ImporteCoste'].notna()
    )
    
    evaluable_rows = df_work['_evaluable'].sum()
    not_evaluable_rows = total_rows - evaluable_rows
    not_evaluable_pct = (not_evaluable_rows / total_rows * 100) if total_rows > 0 else 0.0
    
    logger.info(f"Total rows: {total_rows:,}")
    logger.info(f"Evaluable rows: {evaluable_rows:,}")
    logger.info(f"Not evaluable: {not_evaluable_rows:,} ({not_evaluable_pct:.2f}%)")
    logger.info("")
    
    # Calculate expected values
    df_work['_expected_margen'] = df_work['BaseImponible'] - df_work['ImporteCoste']
    
    # Calculate expected percentage
    # Avoid division by zero (already filtered in evaluable)
    df_work['_expected_pormargen'] = np.where(
        df_work['_evaluable'],
        100.0 * (df_work['_expected_margen'] / df_work['BaseImponible']),
        np.nan
    )
    
    # Initialize validation flags
    df_work['_margen_ok'] = False
    df_work['_pormargen_ok'] = False
    df_work['_delta_margen'] = np.nan
    df_work['_delta_pormargen'] = np.nan
    
    # Validate MargenBeneficio (if present)
    margen_ok = 0
    margen_fail = 0
    
    if 'MargenBeneficio' in df_work.columns:
        df_eval = df_work[df_work['_evaluable']].copy()
        
        # Calculate delta
        df_eval['_delta_margen'] = df_eval['MargenBeneficio'] - df_eval['_expected_margen']
        df_work.loc[df_work['_evaluable'], '_delta_margen'] = df_eval['_delta_margen']
        
        # Check tolerance
        df_eval['_margen_ok'] = df_eval['_delta_margen'].abs() <= tolerance_abs
        df_work.loc[df_work['_evaluable'], '_margen_ok'] = df_eval['_margen_ok']
        
        margen_ok = df_eval['_margen_ok'].sum()
        margen_fail = len(df_eval) - margen_ok
        
        margen_ok_pct = (margen_ok / evaluable_rows * 100) if evaluable_rows > 0 else 0.0
        margen_fail_pct = (margen_fail / evaluable_rows * 100) if evaluable_rows > 0 else 0.0
        
        logger.info("MargenBeneficio Validation:")
        logger.info(f"  OK: {margen_ok:,} ({margen_ok_pct:.2f}%)")
        logger.info(f"  FAIL: {margen_fail:,} ({margen_fail_pct:.2f}%)")
        
        # Delta statistics
        delta_stats = df_eval['_delta_margen'].describe().to_dict()
        logger.info(f"  Delta stats: mean={delta_stats.get('mean', 0):.4f}, std={delta_stats.get('std', 0):.4f}")
        logger.info(f"               min={delta_stats.get('min', 0):.4f}, max={delta_stats.get('max', 0):.4f}")
        
    else:
        logger.warning("MargenBeneficio column not found, skipping validation")
        margen_ok_pct = 0.0
        margen_fail_pct = 0.0
        delta_stats = {}
    
    logger.info("")
    
    # Validate PorMargenBeneficio (if present)
    pormargen_ok = 0
    pormargen_fail = 0
    
    if 'PorMargenBeneficio' in df_work.columns:
        df_eval = df_work[df_work['_evaluable']].copy()
        
        # Calculate delta
        df_eval['_delta_pormargen'] = df_eval['PorMargenBeneficio'] - df_eval['_expected_pormargen']
        df_work.loc[df_work['_evaluable'], '_delta_pormargen'] = df_eval['_delta_pormargen']
        
        # Check tolerance
        df_eval['_pormargen_ok'] = df_eval['_delta_pormargen'].abs() <= tolerance_pct
        df_work.loc[df_work['_evaluable'], '_pormargen_ok'] = df_eval['_pormargen_ok']
        
        pormargen_ok = df_eval['_pormargen_ok'].sum()
        pormargen_fail = len(df_eval) - pormargen_ok
        
        pormargen_ok_pct = (pormargen_ok / evaluable_rows * 100) if evaluable_rows > 0 else 0.0
        pormargen_fail_pct = (pormargen_fail / evaluable_rows * 100) if evaluable_rows > 0 else 0.0
        
        logger.info("PorMargenBeneficio Validation:")
        logger.info(f"  OK: {pormargen_ok:,} ({pormargen_ok_pct:.2f}%)")
        logger.info(f"  FAIL: {pormargen_fail:,} ({pormargen_fail_pct:.2f}%)")
        
        # Delta statistics
        delta_pormargen_stats = df_eval['_delta_pormargen'].describe().to_dict()
        logger.info(f"  Delta stats: mean={delta_pormargen_stats.get('mean', 0):.4f}%, std={delta_pormargen_stats.get('std', 0):.4f}%")
        logger.info(f"               min={delta_pormargen_stats.get('min', 0):.4f}%, max={delta_pormargen_stats.get('max', 0):.4f}%")
        
    else:
        logger.warning("PorMargenBeneficio column not found, skipping validation")
        pormargen_ok_pct = 0.0
        pormargen_fail_pct = 0.0
        delta_pormargen_stats = {}
    
    logger.info("")
    
    # Combined validation (both OK)
    if 'MargenBeneficio' in df_work.columns and 'PorMargenBeneficio' in df_work.columns:
        both_ok = (df_work['_evaluable'] & df_work['_margen_ok'] & df_work['_pormargen_ok']).sum()
        both_ok_pct = (both_ok / evaluable_rows * 100) if evaluable_rows > 0 else 0.0
        
        logger.info("Combined Validation (Both OK):")
        logger.info(f"  {both_ok:,} ({both_ok_pct:.2f}%)")
    else:
        both_ok = 0
        both_ok_pct = 0.0
    
    logger.info("")
    
    # Top deviations
    top_margen_deviations = []
    if 'MargenBeneficio' in df_work.columns:
        df_deviations = df_work[df_work['_evaluable'] & ~df_work['_margen_ok']].copy()
        df_deviations['_abs_delta_margen'] = df_deviations['_delta_margen'].abs()
        df_deviations = df_deviations.nlargest(10, '_abs_delta_margen')
        
        for _, row in df_deviations.iterrows():
            top_margen_deviations.append({
                'BaseImponible': row.get('BaseImponible'),
                'ImporteCoste': row.get('ImporteCoste'),
                'MargenBeneficio': row.get('MargenBeneficio'),
                'Expected': row.get('_expected_margen'),
                'Delta': row.get('_delta_margen')
            })
        
        if top_margen_deviations:
            logger.info("Top 10 MargenBeneficio deviations:")
            for i, dev in enumerate(top_margen_deviations[:5], 1):
                logger.info(f"  {i}. Delta={dev['Delta']:.4f}, BI={dev['BaseImponible']:.2f}, IC={dev['ImporteCoste']:.2f}")
    
    top_pormargen_deviations = []
    if 'PorMargenBeneficio' in df_work.columns:
        df_deviations = df_work[df_work['_evaluable'] & ~df_work['_pormargen_ok']].copy()
        df_deviations['_abs_delta_pormargen'] = df_deviations['_delta_pormargen'].abs()
        df_deviations = df_deviations.nlargest(10, '_abs_delta_pormargen')
        
        for _, row in df_deviations.iterrows():
            top_pormargen_deviations.append({
                'BaseImponible': row.get('BaseImponible'),
                'MargenBeneficio': row.get('MargenBeneficio'),
                'PorMargenBeneficio': row.get('PorMargenBeneficio'),
                'Expected': row.get('_expected_pormargen'),
                'Delta': row.get('_delta_pormargen')
            })
        
        if top_pormargen_deviations:
            logger.info("Top 10 PorMargenBeneficio deviations:")
            for i, dev in enumerate(top_pormargen_deviations[:5], 1):
                logger.info(f"  {i}. Delta={dev['Delta']:.4f}%, Actual={dev['PorMargenBeneficio']:.2f}%, Expected={dev['Expected']:.2f}%")
    
    logger.info("")
    logger.info("=" * 80)
    
    return {
        'total_rows': total_rows,
        'evaluable_rows': evaluable_rows,
        'not_evaluable_rows': not_evaluable_rows,
        'not_evaluable_pct': not_evaluable_pct,
        
        'margen_ok': margen_ok,
        'margen_fail': margen_fail,
        'margen_ok_pct': margen_ok_pct,
        'margen_fail_pct': margen_fail_pct,
        
        'pormargen_ok': pormargen_ok,
        'pormargen_fail': pormargen_fail,
        'pormargen_ok_pct': pormargen_ok_pct,
        'pormargen_fail_pct': pormargen_fail_pct,
        
        'both_ok': both_ok,
        'both_ok_pct': both_ok_pct,
        
        'delta_margen_stats': delta_stats if 'MargenBeneficio' in df_work.columns else {},
        'delta_pormargen_stats': delta_pormargen_stats if 'PorMargenBeneficio' in df_work.columns else {},
        
        'top_margen_deviations': top_margen_deviations,
        'top_pormargen_deviations': top_pormargen_deviations,
        
        'validation_flags': df_work
    }


# ============================================================================
# OPTIONAL: DISCOUNT RECONSTRUCTION (DIAGNOSTIC ONLY)
# ============================================================================

def reconstruct_descuento2(
    df: pd.DataFrame,
    tolerance_pct: float = 0.01
) -> Dict[str, any]:
    """
    OPTIONAL DIAGNOSTIC: Reconstruct %Descuento2 from ImporteBruto and ImporteNeto.
    
    This is for AUDIT PURPOSES ONLY and does NOT affect margin validation.
    
    Cascade rule:
        ImporteNeto = ImporteBruto × (1 - %Descuento/100) × (1 - %Descuento2/100)
    
    Reconstruction:
        %Descuento2 = 100 × (1 - ImporteNeto / (ImporteBruto × (1 - %Descuento/100)))
    
    Args:
        df: DataFrame with columns:
            - ImporteBruto
            - ImporteNeto
            - %Descuento
            - %Descuento2 (optional, to validate)
        tolerance_pct: Percentage tolerance
    
    Returns:
        {
            'total_rows': int,
            'reconstructable_rows': int,
            'reconstruction_ok': int,
            'reconstruction_fail': int,
            'reconstruction_ok_pct': float,
            'delta_stats': Dict[str, float]
        }
    """
    logger.info("=" * 80)
    logger.info("DISCOUNT RECONSTRUCTION (DIAGNOSTIC ONLY)")
    logger.info("=" * 80)
    logger.info("This is for audit purposes only and does NOT affect margin validation.")
    logger.info("")
    
    required_cols = ['ImporteBruto', 'ImporteNeto', 'PorDescuento']
    missing_cols = [c for c in required_cols if c not in df.columns]
    
    if missing_cols:
        logger.error(f"Missing required columns: {missing_cols}")
        return {'error': f"Missing columns: {missing_cols}"}
    
    df_work = df.copy()
    total_rows = len(df_work)
    
    # Identify reconstructable rows
    df_work['_reconstructable'] = (
        df_work['ImporteBruto'].notna() &
        (df_work['ImporteBruto'] != 0) &
        df_work['ImporteNeto'].notna() &
        df_work['PorDescuento'].notna()
    )
    
    reconstructable_rows = df_work['_reconstructable'].sum()
    
    logger.info(f"Total rows: {total_rows:,}")
    logger.info(f"Reconstructable rows: {reconstructable_rows:,}")
    
    if reconstructable_rows == 0:
        logger.warning("No reconstructable rows found")
        return {
            'total_rows': total_rows,
            'reconstructable_rows': 0,
            'reconstruction_ok': 0,
            'reconstruction_fail': 0
        }
    
    # Reconstruct
    df_eval = df_work[df_work['_reconstructable']].copy()
    
    # Base after first discount
    df_eval['_base_after_d1'] = df_eval['ImporteBruto'] * (1 - df_eval['PorDescuento'] / 100.0)
    
    # Reconstruct %Descuento2
    df_eval['_reconstructed_d2'] = 100.0 * (1 - df_eval['ImporteNeto'] / df_eval['_base_after_d1'])
    
    # Validate if %Descuento2 exists
    if 'PorDescuento2' in df_eval.columns:
        df_eval['_delta_d2'] = df_eval['PorDescuento2'] - df_eval['_reconstructed_d2']
        df_eval['_d2_ok'] = df_eval['_delta_d2'].abs() <= tolerance_pct
        
        reconstruction_ok = df_eval['_d2_ok'].sum()
        reconstruction_fail = len(df_eval) - reconstruction_ok
        reconstruction_ok_pct = (reconstruction_ok / reconstructable_rows * 100)
        
        logger.info(f"Reconstruction OK: {reconstruction_ok:,} ({reconstruction_ok_pct:.2f}%)")
        logger.info(f"Reconstruction FAIL: {reconstruction_fail:,}")
        
        delta_stats = df_eval['_delta_d2'].describe().to_dict()
        logger.info(f"Delta stats: mean={delta_stats.get('mean', 0):.4f}%, std={delta_stats.get('std', 0):.4f}%")
        
    else:
        logger.info("PorDescuento2 column not found, showing reconstructed values only")
        reconstruction_ok = 0
        reconstruction_fail = 0
        reconstruction_ok_pct = 0.0
        delta_stats = {}
        
        logger.info(f"Reconstructed %Descuento2 statistics:")
        recon_stats = df_eval['_reconstructed_d2'].describe().to_dict()
        for k, v in recon_stats.items():
            logger.info(f"  {k}: {v:.4f}%")
    
    logger.info("=" * 80)
    
    return {
        'total_rows': total_rows,
        'reconstructable_rows': reconstructable_rows,
        'reconstruction_ok': reconstruction_ok,
        'reconstruction_fail': reconstruction_fail,
        'reconstruction_ok_pct': reconstruction_ok_pct,
        'delta_stats': delta_stats
    }


if __name__ == "__main__":
    # Test validators
    import sys
    sys.path.append(str(Path(__file__).parent))
    from parser_cruzber import load_all
    
    base_path = Path(r"C:\Users\hugod\OneDrive - Hugo de Val Roig\Documentos\Privado\Formación\ISDI - MDA\Troncal\CRUZBER")
    datasets = load_all(base_path)
    
    # Test margin validation
    if 'LineasAlbaranCliente' in datasets:
        result = validate_margin_from_base_imponible(
            datasets['LineasAlbaranCliente'],
            tolerance_abs=0.01,
            tolerance_pct=0.01
        )
        print("\nMargin Validation Summary:")
        print(f"  Evaluable: {result['evaluable_rows']:,} / {result['total_rows']:,}")
        print(f"  Both OK: {result['both_ok']:,} ({result['both_ok_pct']:.2f}%)")
