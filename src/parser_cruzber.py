"""
Cruzber XLSX Parser Module
===========================
Comprehensive parser for all Cruzber internal XLSX files.
STRICT REQUIREMENT: Read 100% of all rows and columns (no sampling, no limits).

Author: Senior Data Engineer
Date: 2025-12-20
"""

import pandas as pd
import numpy as np
from pathlib import Path
from typing import Dict, Optional, Tuple, Any
import logging
import re
from datetime import datetime
import warnings

warnings.filterwarnings('ignore', category=UserWarning, module='openpyxl')

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

def normalize_colname(col: str) -> str:
    """
    Normalize column names:
    - Strip whitespace
    - Remove special characters (keep alphanumeric and underscore)
    - Convert to snake_case-like format
    """
    if not isinstance(col, str):
        return str(col)
    
    # Strip whitespace
    col = col.strip()
    
    # Replace spaces and special chars with underscore
    col = re.sub(r'[^\w\s]', '', col)
    col = re.sub(r'\s+', '_', col)
    
    # Remove multiple underscores
    col = re.sub(r'_+', '_', col)
    
    # Remove leading/trailing underscores
    col = col.strip('_')
    
    return col


def drop_unnamed(df: pd.DataFrame) -> pd.DataFrame:
    """
    Drop columns that are unnamed or start with 'Unnamed'.
    """
    cols_to_keep = [c for c in df.columns if not str(c).startswith('Unnamed')]
    return df[cols_to_keep].copy()


def standardize_strings(series: pd.Series) -> pd.Series:
    """
    Standardize string columns:
    - Strip whitespace
    - Replace empty strings with None
    - Uppercase for codes
    """
    # Ensure we have a Series
    if isinstance(series, pd.DataFrame):
        logger.warning("standardize_strings received a DataFrame instead of Series, converting")
        if len(series.columns) == 1:
            series = series.iloc[:, 0]
        else:
            logger.error(f"Cannot standardize DataFrame with multiple columns: {series.columns.tolist()}")
            return series
    
    if series.dtype == 'object':
        result = series.astype(str).str.strip()
        result = result.replace('', None)
        result = result.replace('nan', None)
        result = result.replace('<NA>', None)
        return result
    return series


def coerce_int_nullable(series: pd.Series) -> pd.Series:
    """
    Coerce to nullable integer (Int64).
    Handles NaN and non-numeric gracefully.
    """
    try:
        return pd.to_numeric(series, errors='coerce').astype('Int64')
    except Exception as e:
        logger.warning(f"Could not coerce to Int64: {e}")
        return series


def coerce_float(series: pd.Series) -> pd.Series:
    """
    Coerce to float64.
    Handles NaN and non-numeric gracefully.
    """
    try:
        return pd.to_numeric(series, errors='coerce').astype('float64')
    except Exception as e:
        logger.warning(f"Could not coerce to float64: {e}")
        return series


def parse_fecha_es_larga(series: pd.Series) -> pd.Series:
    """
    Parse Spanish long date format: "01 de enero de 2020"
    Returns datetime64[ns] or None.
    """
    month_map = {
        'enero': 1, 'febrero': 2, 'marzo': 3, 'abril': 4,
        'mayo': 5, 'junio': 6, 'julio': 7, 'agosto': 8,
        'septiembre': 9, 'octubre': 10, 'noviembre': 11, 'diciembre': 12
    }
    
    def parse_single(val):
        if pd.isna(val):
            return None
        try:
            val = str(val).strip().lower()
            # Pattern: "01 de enero de 2020"
            match = re.match(r'(\d{1,2})\s+de\s+(\w+)\s+de\s+(\d{4})', val)
            if match:
                day = int(match.group(1))
                month_name = match.group(2)
                year = int(match.group(3))
                month = month_map.get(month_name)
                if month:
                    return pd.Timestamp(year=year, month=month, day=day)
        except Exception as e:
            logger.debug(f"Could not parse date '{val}': {e}")
        return None
    
    return series.apply(parse_single)


def resolve_sheet(xlsx_path: Path, filename: str) -> Tuple[str, pd.ExcelFile]:
    """
    Automatically resolve which sheet to read from an XLSX file.
    Strategy: Use the sheet with the most rows.
    
    Returns: (sheet_name, ExcelFile object)
    """
    logger.info(f"Resolving sheet for {filename}...")
    xls = pd.ExcelFile(xlsx_path, engine='openpyxl')
    
    if len(xls.sheet_names) == 1:
        sheet_name = xls.sheet_names[0]
        logger.info(f"  Single sheet found: '{sheet_name}'")
        return sheet_name, xls
    
    # Multiple sheets: choose the one with most rows
    max_rows = 0
    best_sheet = xls.sheet_names[0]
    
    for sheet in xls.sheet_names:
        try:
            df_test = pd.read_excel(xls, sheet_name=sheet, nrows=0)
            # Read full sheet to count rows (must read 100%)
            df_full = pd.read_excel(xls, sheet_name=sheet)
            n_rows = len(df_full)
            logger.info(f"  Sheet '{sheet}': {n_rows} rows")
            if n_rows > max_rows:
                max_rows = n_rows
                best_sheet = sheet
        except Exception as e:
            logger.warning(f"  Could not read sheet '{sheet}': {e}")
    
    logger.info(f"  Selected sheet: '{best_sheet}' ({max_rows} rows)")
    return best_sheet, xls


# ============================================================================
# INDIVIDUAL FILE LOADERS
# ============================================================================

def load_maestro_familias(base_path: Path) -> pd.DataFrame:
    """
    Load MaestroFamilias.xlsx
    
    Expected columns:
    - CodigoFamilia (PK, string)
    - DescripcionFamilia (string)
    """
    logger.info("=" * 80)
    logger.info("Loading MaestroFamilias.xlsx")
    
    file_path = base_path / "MaestroFamilias.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "MaestroFamilias.xlsx")
    
    # Read FULL file (no nrows limit)
    df = pd.read_excel(xls, sheet_name=sheet_name, dtype=str)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    # Drop unnamed
    df = drop_unnamed(df)
    
    # Normalize column names
    df.columns = [normalize_colname(c) for c in df.columns]
    
    # Expected columns (flexible matching)
    # Look for 'codigo' and 'descripcion' or 'familia'
    codigo_col = None
    desc_col = None
    
    for col in df.columns:
        col_lower = col.lower()
        # Match CodigoFamilia but NOT CodigoSubfamilia
        if 'codigofamilia' in col_lower.replace('_', '').replace(' ', '') and 'subfamilia' not in col_lower:
            codigo_col = col
        # Match Descripcion but NOT DescripcionSubfamilia
        elif 'descripcion' in col_lower and 'subfamilia' not in col_lower:
            if desc_col is None:  # Take first match
                desc_col = col
    
    if codigo_col is None:
        # Fallback: first column
        codigo_col = df.columns[0]
        logger.warning(f"  Could not identify CodigoFamilia, using: {codigo_col}")
    
    if desc_col is None:
        # Fallback: third column (avoid CodigoSubfamilia at index 1)
        desc_col = df.columns[2] if len(df.columns) > 2 else df.columns[1] if len(df.columns) > 1 else df.columns[0]
        logger.warning(f"  Could not identify DescripcionFamilia, using: {desc_col}")
    
    # Rename (only if needed)
    rename_map = {}
    if codigo_col and codigo_col != 'CodigoFamilia':
        rename_map[codigo_col] = 'CodigoFamilia'
    if desc_col and desc_col != 'DescripcionFamilia':
        rename_map[desc_col] = 'DescripcionFamilia'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    # Keep only relevant columns
    cols_to_keep = ['CodigoFamilia', 'DescripcionFamilia']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    # Ensure no duplicates in column selection
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    # Standardize strings
    for col in list(df.columns):
        df[col] = standardize_strings(df[col])
    
    # Remove duplicates on PK
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoFamilia'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CodigoFamilia")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_maestro_municipios(base_path: Path) -> pd.DataFrame:
    """
    Load MaestroMunicipios.xlsx
    
    Expected columns:
    - CodigoMunicipio (PK, string)
    - DescripcionMunicipio (string)
    - CodigoProvincia (FK, string)
    """
    logger.info("=" * 80)
    logger.info("Loading MaestroMunicipios.xlsx")
    
    file_path = base_path / "MaestroMunicipios.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "MaestroMunicipios.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name, dtype=str)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    # Identify columns
    codigo_mun = None
    desc_mun = None
    codigo_prov = None
    
    for col in df.columns:
        col_lower = col.lower()
        col_normalized = col_lower.replace('_', '').replace(' ', '').replace('-', '')
        
        # Match CodigoMunicipio (exact, avoid variants like CodigoMunicipioResidencia)
        if 'codigomunicipio' in col_normalized and codigo_mun is None:
            codigo_mun = col
        # Match DescripcionMunicipio
        elif 'descripcion' in col_lower and 'municipio' in col_lower and desc_mun is None:
            desc_mun = col
        # Match CodigoProvincia
        elif 'codigoprovincia' in col_normalized and codigo_prov is None:
            codigo_prov = col
    
    # Fallbacks
    if codigo_mun is None:
        codigo_mun = df.columns[0]
    if desc_mun is None:
        desc_mun = df.columns[1] if len(df.columns) > 1 else df.columns[0]
    if codigo_prov is None and len(df.columns) > 2:
        codigo_prov = df.columns[2]
    
    rename_map = {}
    if codigo_mun and codigo_mun != 'CodigoMunicipio':
        rename_map[codigo_mun] = 'CodigoMunicipio'
    if desc_mun and desc_mun != 'DescripcionMunicipio':
        rename_map[desc_mun] = 'DescripcionMunicipio'
    if codigo_prov and codigo_prov != 'CodigoProvincia':
        rename_map[codigo_prov] = 'CodigoProvincia'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CodigoMunicipio', 'DescripcionMunicipio', 'CodigoProvincia']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    for col in list(df.columns):
        df[col] = standardize_strings(df[col])
    
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoMunicipio'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CodigoMunicipio")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_familias_articulos(base_path: Path) -> pd.DataFrame:
    """
    Load Familias Articulos.xlsx
    
    Bridge table linking articles to families.
    Expected columns:
    - CodigoArticulo (FK, string)
    - CodigoFamilia (FK, string)
    """
    logger.info("=" * 80)
    logger.info("Loading Familias Articulos.xlsx")
    
    file_path = base_path / "Familias Articulos.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "Familias Articulos.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name, dtype=str)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    # Identify columns
    codigo_art = None
    codigo_fam = None
    
    for col in df.columns:
        col_lower = col.lower()
        col_normalized = col_lower.replace('_', '').replace(' ', '').replace('-', '')
        
        # Match CodigoArticulo
        if 'codigoarticulo' in col_normalized and codigo_art is None:
            codigo_art = col
        # Match CodigoFamilia (but NOT CodigoSubfamilia)
        elif 'codigofamilia' in col_normalized and 'subfamilia' not in col_lower and codigo_fam is None:
            codigo_fam = col
    
    if codigo_art is None:
        codigo_art = df.columns[0]
    if codigo_fam is None:
        codigo_fam = df.columns[1] if len(df.columns) > 1 else df.columns[0]
    
    rename_map = {}
    if codigo_art and codigo_art != 'CodigoArticulo':
        rename_map[codigo_art] = 'CodigoArticulo'
    if codigo_fam and codigo_fam != 'CodigoFamilia':
        rename_map[codigo_fam] = 'CodigoFamilia'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CodigoArticulo', 'CodigoFamilia']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    for col in list(df.columns):
        df[col] = standardize_strings(df[col])
    
    # Remove duplicates on composite key
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoArticulo', 'CodigoFamilia'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicates")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_maestro_provincias(base_path: Path) -> pd.DataFrame:
    """
    Load MaestroProvincias.xlsx
    
    Expected columns:
    - CodigoProvincia (PK, string)
    - DescripcionProvincia (string)
    - CodigoNacion (FK, string)
    """
    logger.info("=" * 80)
    logger.info("Loading MaestroProvincias.xlsx")
    
    file_path = base_path / "MaestroProvincias.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "MaestroProvincias.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name, dtype=str)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    codigo_prov = None
    desc_prov = None
    codigo_nac = None
    
    for col in df.columns:
        col_lower = col.lower()
        col_normalized = col_lower.replace('_', '').replace(' ', '').replace('-', '')
        
        # Match CodigoProvincia
        if 'codigoprovincia' in col_normalized and codigo_prov is None:
            codigo_prov = col
        # Match DescripcionProvincia
        elif 'descripcion' in col_lower and 'provincia' in col_lower and desc_prov is None:
            desc_prov = col
        # Match CodigoNacion or CodigoPais
        elif 'codigo' in col_lower and ('nacion' in col_lower or 'pais' in col_lower) and codigo_nac is None:
            codigo_nac = col
    
    if codigo_prov is None:
        codigo_prov = df.columns[0]
    if desc_prov is None:
        desc_prov = df.columns[1] if len(df.columns) > 1 else df.columns[0]
    if codigo_nac is None and len(df.columns) > 2:
        codigo_nac = df.columns[2]
    
    rename_map = {}
    if codigo_prov and codigo_prov != 'CodigoProvincia':
        rename_map[codigo_prov] = 'CodigoProvincia'
    if desc_prov and desc_prov != 'DescripcionProvincia':
        rename_map[desc_prov] = 'DescripcionProvincia'
    if codigo_nac and codigo_nac != 'CodigoNacion':
        rename_map[codigo_nac] = 'CodigoNacion'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CodigoProvincia', 'DescripcionProvincia', 'CodigoNacion']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    for col in list(df.columns):
        df[col] = standardize_strings(df[col])
    
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoProvincia'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CodigoProvincia")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_maestro_articulos(base_path: Path) -> pd.DataFrame:
    """
    Load MaestroArticulos.xlsx
    
    Expected columns:
    - CodigoArticulo (PK, string)
    - DescripcionArticulo (string)
    - PrecioVenta (float)
    - CosteEstandar (float)
    """
    logger.info("=" * 80)
    logger.info("Loading MaestroArticulos.xlsx")
    
    file_path = base_path / "MaestroArticulos.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "MaestroArticulos.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    # Identify columns
    codigo_art = None
    desc_art = None
    precio_venta = None
    coste_std = None
    
    for col in df.columns:
        col_lower = col.lower()
        if 'codigo' in col_lower and 'articulo' in col_lower:
            codigo_art = col
        elif 'descripcion' in col_lower and 'articulo' in col_lower:
            desc_art = col
        elif 'precio' in col_lower and 'venta' in col_lower:
            precio_venta = col
        elif 'coste' in col_lower and ('estandar' in col_lower or 'standard' in col_lower or 'escandallo' in col_lower):
            coste_std = col
    
    if codigo_art is None:
        codigo_art = df.columns[0]
    if desc_art is None and len(df.columns) > 1:
        desc_art = df.columns[1]
    
    rename_map = {}
    if codigo_art and codigo_art != 'CodigoArticulo':
        rename_map[codigo_art] = 'CodigoArticulo'
    if desc_art and desc_art != 'DescripcionArticulo':
        rename_map[desc_art] = 'DescripcionArticulo'
    if precio_venta and precio_venta != 'PrecioVenta':
        rename_map[precio_venta] = 'PrecioVenta'
    if coste_std and coste_std != 'CosteEstandar':
        rename_map[coste_std] = 'CosteEstandar'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CodigoArticulo', 'DescripcionArticulo', 'PrecioVenta', 'CosteEstandar']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    df = df[existing_cols].copy()
    
    # Type coercion
    if 'CodigoArticulo' in df.columns:
        df['CodigoArticulo'] = standardize_strings(df['CodigoArticulo'])
    if 'DescripcionArticulo' in df.columns:
        df['DescripcionArticulo'] = standardize_strings(df['DescripcionArticulo'])
    if 'PrecioVenta' in df.columns:
        df['PrecioVenta'] = coerce_float(df['PrecioVenta'])
    if 'CosteEstandar' in df.columns:
        df['CosteEstandar'] = coerce_float(df['CosteEstandar'])
    
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoArticulo'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CodigoArticulo")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_maestro_naciones(base_path: Path) -> pd.DataFrame:
    """
    Load MaestroNaciones.xlsx
    
    Expected columns:
    - CodigoNacion (PK, string)
    - DescripcionNacion (string)
    """
    logger.info("=" * 80)
    logger.info("Loading MaestroNaciones.xlsx")
    
    file_path = base_path / "MaestroNaciones.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "MaestroNaciones.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name, dtype=str)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    codigo_nac = None
    desc_nac = None
    
    for col in df.columns:
        col_lower = col.lower()
        col_normalized = col_lower.replace('_', '').replace(' ', '').replace('-', '')
        
        # Match CodigoNacion or CodigoPais
        if 'codigo' in col_lower and ('nacion' in col_lower or 'pais' in col_lower) and codigo_nac is None:
            codigo_nac = col
        # Match DescripcionNacion or Pais (but not if already has 'codigo')
        elif ('descripcion' in col_lower or 'nacion' in col_lower or 'pais' in col_lower) and 'codigo' not in col_lower and desc_nac is None:
            desc_nac = col
    
    if codigo_nac is None:
        codigo_nac = df.columns[0]
    if desc_nac is None:
        desc_nac = df.columns[1] if len(df.columns) > 1 else df.columns[0]
    
    rename_map = {}
    if codigo_nac and codigo_nac != 'CodigoNacion':
        rename_map[codigo_nac] = 'CodigoNacion'
    if desc_nac and desc_nac != 'DescripcionNacion':
        rename_map[desc_nac] = 'DescripcionNacion'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CodigoNacion', 'DescripcionNacion']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    for col in list(df.columns):
        df[col] = standardize_strings(df[col])
    
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoNacion'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CodigoNacion")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_agrupacion_canales_venta(base_path: Path) -> pd.DataFrame:
    """
    Load Agrupacion Canales venta.xlsx
    
    Expected columns:
    - CanalVenta (string)
    - AgrupacionCanal (string)
    """
    logger.info("=" * 80)
    logger.info("Loading Agrupacion Canales venta.xlsx")
    
    file_path = base_path / "Agrupacion Canales venta.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "Agrupacion Canales venta.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name, dtype=str)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    canal = None
    agrup = None
    
    for col in df.columns:
        col_lower = col.lower()
        
        # Match CanalVenta (but NOT AgrupacionCanal)
        if 'canal' in col_lower and 'venta' in col_lower and 'agrupacion' not in col_lower and canal is None:
            canal = col
        # Match AgrupacionCanal
        elif 'agrupacion' in col_lower and agrup is None:
            agrup = col
    
    if canal is None:
        canal = df.columns[0]
    if agrup is None:
        agrup = df.columns[1] if len(df.columns) > 1 else df.columns[0]
    
    rename_map = {}
    if canal and canal != 'CanalVenta':
        rename_map[canal] = 'CanalVenta'
    if agrup and agrup != 'AgrupacionCanal':
        rename_map[agrup] = 'AgrupacionCanal'
    
    if rename_map:
        df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CanalVenta', 'AgrupacionCanal']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    for col in list(df.columns):
        df[col] = standardize_strings(df[col])
    
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CanalVenta'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CanalVenta")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_maestro_clientes(base_path: Path) -> pd.DataFrame:
    """
    Load MaestroClientes.xlsx
    
    Expected columns:
    - CodigoCliente (PK, string)
    - NombreCliente (string)
    - CodigoMunicipio (FK, string)
    - CanalVenta (string)
    - FechaAlta (date, Spanish long format)
    """
    logger.info("=" * 80)
    logger.info("Loading MaestroClientes.xlsx")
    
    file_path = base_path / "MaestroClientes.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "MaestroClientes.xlsx")
    
    df = pd.read_excel(xls, sheet_name=sheet_name)
    logger.info(f"  Rows read: {len(df)}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    codigo_cli = None
    nombre_cli = None
    codigo_mun = None
    canal = None
    fecha_alta = None
    
    for col in df.columns:
        col_lower = col.lower()
        col_normalized = col_lower.replace('_', '').replace(' ', '').replace('-', '')
        
        # Match CodigoCliente (exact, to avoid variants like CodigoClientePrincipal)
        if 'codigocliente' in col_normalized and codigo_cli is None:
            codigo_cli = col
        # Match NombreCliente or RazonSocial (but NOT if it also contains 'codigo')
        elif ('nombre' in col_lower or 'razon' in col_lower) and 'codigo' not in col_lower and nombre_cli is None:
            nombre_cli = col
        # Match CodigoMunicipio (but NOT CodigoMunicipioResidencia, etc.)
        elif 'codigomunicipio' in col_normalized and 'residencia' not in col_lower and codigo_mun is None:
            codigo_mun = col
        # Match CanalVenta
        elif 'canal' in col_lower and 'venta' in col_lower and canal is None:
            canal = col
        # Match FechaAlta
        elif 'fecha' in col_lower and 'alta' in col_lower and fecha_alta is None:
            fecha_alta = col
    
    if codigo_cli is None:
        codigo_cli = df.columns[0]
    
    rename_map = {}
    if codigo_cli and codigo_cli != 'CodigoCliente':
        rename_map[codigo_cli] = 'CodigoCliente'
    if nombre_cli and nombre_cli != 'NombreCliente':
        rename_map[nombre_cli] = 'NombreCliente'
    if codigo_mun and codigo_mun != 'CodigoMunicipio':
        rename_map[codigo_mun] = 'CodigoMunicipio'
    if canal and canal != 'CanalVenta':
        rename_map[canal] = 'CanalVenta'
    if fecha_alta and fecha_alta != 'FechaAlta':
        rename_map[fecha_alta] = 'FechaAlta'
    
    df = df.rename(columns=rename_map)
    
    cols_to_keep = ['CodigoCliente', 'NombreCliente', 'CodigoMunicipio', 'CanalVenta', 'FechaAlta']
    existing_cols = [c for c in cols_to_keep if c in df.columns]
    existing_cols = list(dict.fromkeys(existing_cols))
    df = df[existing_cols].copy()
    
    # Type coercion
    if 'CodigoCliente' in df.columns:
        df['CodigoCliente'] = standardize_strings(df['CodigoCliente'])
    if 'NombreCliente' in df.columns:
        df['NombreCliente'] = standardize_strings(df['NombreCliente'])
    if 'CodigoMunicipio' in df.columns:
        df['CodigoMunicipio'] = standardize_strings(df['CodigoMunicipio'])
    if 'CanalVenta' in df.columns:
        df['CanalVenta'] = standardize_strings(df['CanalVenta'])
    if 'FechaAlta' in df.columns:
        # Try Spanish long format first
        df['FechaAlta'] = parse_fecha_es_larga(df['FechaAlta'])
        # If still nulls, try standard pandas parsing
        if df['FechaAlta'].isna().all():
            df['FechaAlta'] = pd.to_datetime(df['FechaAlta'], errors='coerce')
    
    initial_rows = len(df)
    df = df.drop_duplicates(subset=['CodigoCliente'], keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df)} duplicate CodigoCliente")
    
    logger.info(f"  Final rows: {len(df)}")
    return df


def load_lineas_albaran_cliente(base_path: Path) -> pd.DataFrame:
    """
    Load LineasAlbaranCliente.xlsx - THE MAIN FACT TABLE
    
    This is the largest and most important file.
    MUST READ 100% OF ROWS (no sampling, no limits).
    
    Expected columns:
    - NumeroAlbaran (string)
    - NumeroLinea (int)
    - FechaAlbaran (date)
    - CodigoCliente (FK, string)
    - CodigoArticulo (FK, string)
    - Unidades (int)
    - ImporteBruto (float)
    - %Descuento (float)
    - %Descuento2 (float)
    - ImporteNeto (float)
    - %ProntoPago (float)
    - ImporteLiquido (float)
    - %IVA (float)
    - BaseImponible (float) ← AUTHORITATIVE for margin
    - ImporteCoste (float)
    - MargenBeneficio (float)
    - PorMargenBeneficio (float)
    """
    logger.info("=" * 80)
    logger.info("Loading LineasAlbaranCliente.xlsx (FACT TABLE)")
    
    file_path = base_path / "LineasAlbaranCliente.xlsx"
    if not file_path.exists():
        logger.error(f"File not found: {file_path}")
        return pd.DataFrame()
    
    sheet_name, xls = resolve_sheet(file_path, "LineasAlbaranCliente.xlsx")
    
    # CRITICAL: Read ALL rows (no nrows parameter)
    logger.info("  Reading FULL file (100% of rows)...")
    df = pd.read_excel(xls, sheet_name=sheet_name)
    logger.info(f"  Rows read: {len(df):,}")
    logger.info(f"  Columns: {list(df.columns)}")
    
    df = drop_unnamed(df)
    df.columns = [normalize_colname(c) for c in df.columns]
    
    # Column identification (flexible)
    col_map = {}
    
    for col in df.columns:
        col_lower = col.lower()
        
        if 'numero' in col_lower and 'albaran' in col_lower:
            col_map['NumeroAlbaran'] = col
        elif 'numero' in col_lower and 'linea' in col_lower:
            col_map['NumeroLinea'] = col
        elif 'fecha' in col_lower and 'albaran' in col_lower:
            col_map['FechaAlbaran'] = col
        elif 'codigo' in col_lower and 'cliente' in col_lower:
            col_map['CodigoCliente'] = col
        elif 'codigo' in col_lower and 'articulo' in col_lower:
            col_map['CodigoArticulo'] = col
        elif 'unidades' in col_lower:
            col_map['Unidades'] = col
        elif 'importe' in col_lower and 'bruto' in col_lower:
            col_map['ImporteBruto'] = col
        elif 'descuento2' in col_lower or 'descuento_2' in col_lower:
            col_map['PorDescuento2'] = col
        elif 'descuento' in col_lower and '%' not in col:
            # Avoid matching '%Descuento' when looking for just 'Descuento'
            if 'PorDescuento' not in col_map:
                col_map['PorDescuento'] = col
        elif 'importe' in col_lower and 'neto' in col_lower:
            col_map['ImporteNeto'] = col
        elif 'pronto' in col_lower and 'pago' in col_lower:
            col_map['PorProntoPago'] = col
        elif 'importe' in col_lower and 'liquido' in col_lower:
            col_map['ImporteLiquido'] = col
        elif 'iva' in col_lower:
            col_map['PorIVA'] = col
        elif 'base' in col_lower and 'imponible' in col_lower:
            col_map['BaseImponible'] = col
        elif 'importe' in col_lower and 'coste' in col_lower:
            col_map['ImporteCoste'] = col
        elif 'margen' in col_lower and 'beneficio' in col_lower and '%' not in col:
            col_map['MargenBeneficio'] = col
        elif 'margen' in col_lower and '%' in col_lower:
            col_map['PorMargenBeneficio'] = col
    
    # Rename
    df = df.rename(columns=col_map)
    
    # Define expected columns
    expected_cols = [
        'NumeroAlbaran', 'NumeroLinea', 'FechaAlbaran', 'CodigoCliente', 'CodigoArticulo',
        'Unidades', 'ImporteBruto', 'PorDescuento', 'PorDescuento2', 'ImporteNeto',
        'PorProntoPago', 'ImporteLiquido', 'PorIVA', 'BaseImponible',
        'ImporteCoste', 'MargenBeneficio', 'PorMargenBeneficio'
    ]
    
    existing_cols = [c for c in expected_cols if c in df.columns]
    df = df[existing_cols].copy()
    
    logger.info(f"  Columns found: {existing_cols}")
    
    # Type coercion
    if 'NumeroAlbaran' in df.columns:
        df['NumeroAlbaran'] = standardize_strings(df['NumeroAlbaran'])
    if 'NumeroLinea' in df.columns:
        df['NumeroLinea'] = coerce_int_nullable(df['NumeroLinea'])
    if 'FechaAlbaran' in df.columns:
        df['FechaAlbaran'] = pd.to_datetime(df['FechaAlbaran'], errors='coerce')
    if 'CodigoCliente' in df.columns:
        df['CodigoCliente'] = standardize_strings(df['CodigoCliente'])
    if 'CodigoArticulo' in df.columns:
        df['CodigoArticulo'] = standardize_strings(df['CodigoArticulo'])
    
    # Numeric columns
    numeric_cols = [
        'Unidades', 'ImporteBruto', 'PorDescuento', 'PorDescuento2', 'ImporteNeto',
        'PorProntoPago', 'ImporteLiquido', 'PorIVA', 'BaseImponible',
        'ImporteCoste', 'MargenBeneficio', 'PorMargenBeneficio'
    ]
    
    for col in numeric_cols:
        if col in df.columns:
            if col == 'Unidades':
                df[col] = coerce_int_nullable(df[col])
            else:
                df[col] = coerce_float(df[col])
    
    # Remove exact duplicates (all columns)
    initial_rows = len(df)
    df = df.drop_duplicates(keep='first')
    if len(df) < initial_rows:
        logger.warning(f"  Dropped {initial_rows - len(df):,} exact duplicate rows")
    
    logger.info(f"  Final rows: {len(df):,}")
    logger.info(f"  Memory usage: {df.memory_usage(deep=True).sum() / 1024**2:.1f} MB")
    
    return df


# ============================================================================
# MAIN LOADER FUNCTION
# ============================================================================

def load_all(base_path: str) -> Dict[str, pd.DataFrame]:
    """
    Load ALL Cruzber XLSX files.
    
    Returns a dictionary mapping table names to DataFrames:
    {
        'MaestroFamilias': DataFrame,
        'MaestroMunicipios': DataFrame,
        'FamiliasArticulos': DataFrame,
        'MaestroProvincias': DataFrame,
        'MaestroArticulos': DataFrame,
        'LineasAlbaranCliente': DataFrame,
        'MaestroNaciones': DataFrame,
        'AgrupacionCanalesVenta': DataFrame,
        'MaestroClientes': DataFrame
    }
    """
    base_path = Path(base_path)
    
    logger.info("")
    logger.info("=" * 80)
    logger.info("CRUZBER XLSX PARSER - FULL LOAD")
    logger.info("=" * 80)
    logger.info(f"Base path: {base_path}")
    logger.info(f"Start time: {datetime.now()}")
    logger.info("")
    
    datasets = {}
    
    try:
        datasets['MaestroFamilias'] = load_maestro_familias(base_path)
        datasets['MaestroMunicipios'] = load_maestro_municipios(base_path)
        datasets['FamiliasArticulos'] = load_familias_articulos(base_path)
        datasets['MaestroProvincias'] = load_maestro_provincias(base_path)
        datasets['MaestroArticulos'] = load_maestro_articulos(base_path)
        datasets['LineasAlbaranCliente'] = load_lineas_albaran_cliente(base_path)
        datasets['MaestroNaciones'] = load_maestro_naciones(base_path)
        datasets['AgrupacionCanalesVenta'] = load_agrupacion_canales_venta(base_path)
        datasets['MaestroClientes'] = load_maestro_clientes(base_path)
        
    except Exception as e:
        logger.error(f"Error during load: {e}", exc_info=True)
        raise
    
    logger.info("")
    logger.info("=" * 80)
    logger.info("LOAD COMPLETE")
    logger.info("=" * 80)
    logger.info(f"End time: {datetime.now()}")
    
    # Summary
    logger.info("")
    logger.info("Dataset Summary:")
    logger.info("-" * 80)
    for name, df in datasets.items():
        logger.info(f"  {name:30s}: {len(df):>10,} rows x {len(df.columns):>3} cols")
    logger.info("")
    
    return datasets


if __name__ == "__main__":
    # Test loader
    base_path = Path(r"C:\Users\hugod\OneDrive - Hugo de Val Roig\Documentos\Privado\Formación\ISDI - MDA\Troncal\CRUZBER")
    datasets = load_all(base_path)
    
    print("\nDatasets loaded:")
    for name in datasets:
        print(f"  - {name}")
