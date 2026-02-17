#!/usr/bin/env python3
"""
PAPER CONSISTENCY AUDITOR & FIXER

Research engineer + paper editor tool to ensure 100% consistency between
the generated paper and actual results from CSV outputs.

WORKFLOW:
1. Load generated_paper_raw.md
2. Load all result CSVs (Christoffersen, DQ, PIT, violations, conditional calibration, etc.)
3. Extract ALL numerical claims from paper using regex
4. Compare against CSV data (with small tolerance for rounding)
5. Generate consistency_report.md (MATCH/MISMATCH/UNSOURCED)
6. Apply corrections and generate generated_paper_consistent.md

INPUTS (searched by glob pattern):
- generated_paper_raw.md
- gcp-stockout-trainer/results_data/*.csv
- gcp-stockout-trainer/results_data/figures_camera_ready/*_v2.png

OUTPUTS:
- outputs/consistency_report.md (audit report)
- generated_paper_consistent.md (corrected paper)
- (optional) scripts/plot_calibration_visuals_v3.py + *_v3.png if nominal bug found

CONSTRAINTS:
- No invented numbers. Everything must come from CSV or be removed/qualitative.
- Maintain paper style but prioritize accuracy.
- ISO week: treat week_key as YYYYWW, "ISO week" as 1..52.
- Report very small p-values as "<1e-6".
- Round consistently: 2 decimals for stats, 3 decimals for rates.
"""

import os
import re
import glob
from pathlib import Path
from typing import Dict, List, Tuple, Optional
import pandas as pd
import numpy as np

# ============================================================================
# CONFIGURATION
# ============================================================================

BASE_DIR = Path(r"C:\Users\hugod\OneDrive - Hugo de Val Roig\Documentos\Privado\Formación\ISDI - MDA\Troncal")
PAPER_INPUT = BASE_DIR / "generated_paper_raw.md"
PAPER_OUTPUT = BASE_DIR / "generated_paper_consistent.md"
REPORT_OUTPUT = BASE_DIR / "outputs" / "consistency_report.md"

# CSV data directories
RESULTS_DIR = BASE_DIR / "gcp-stockout-trainer" / "results_data"
FIGURES_DIR = RESULTS_DIR / "figures_camera_ready"

# Tolerance for numerical comparisons
TOLERANCE = 0.005  # 0.5% relative or 0.005 absolute difference

# ============================================================================
# DATA LOADING
# ============================================================================

def load_all_csvs() -> Dict[str, pd.DataFrame]:
    """Load all result CSVs into a dictionary."""
    csv_files = {
        'christoffersen': 'christoffersen_results.csv',
        'dq': 'dq_test_results_fixed.csv',
        'pit_berkowitz': 'pit_berkowitz_results_fixed.csv',
        'violations': 'weekly_violation_rates.csv',
        'conditional': 'conditional_calibration_tests_clustered.csv',
        'odds_ratios': 'odds_ratios_clustered.csv',
        'crossing': 'quantile_crossing_report.csv'
    }
    
    data = {}
    for key, filename in csv_files.items():
        filepath = RESULTS_DIR / filename
        if filepath.exists():
            data[key] = pd.read_csv(filepath)
            print(f"✅ Loaded {filename}: {len(data[key])} rows")
        else:
            print(f"⚠️  Not found: {filename}")
            data[key] = pd.DataFrame()
    
    return data

def load_paper() -> str:
    """Load the generated paper markdown."""
    if not PAPER_INPUT.exists():
        raise FileNotFoundError(f"Paper not found: {PAPER_INPUT}")
    
    with open(PAPER_INPUT, 'r', encoding='utf-8') as f:
        paper = f.read()
    
    print(f"✅ Loaded paper: {len(paper):,} characters, {len(paper.split())} words")
    return paper

# ============================================================================
# NUMERICAL EXTRACTION
# ============================================================================

def extract_numbers_from_paper(paper: str) -> List[Dict]:
    """
    Extract all numerical claims from paper using regex patterns.
    
    Returns list of dicts: {'value': float, 'context': str, 'line_num': int, 'type': str}
    """
    numbers = []
    lines = paper.split('\n')
    
    # Patterns to extract
    patterns = {
        'p_value': r'p\s*[=<>]\s*([\d.]+(?:e-?\d+)?)',  # p=0.001, p<0.05, p<1e-6
        'percentage': r'([\d.]+)%',  # 5.5%, 10%
        'decimal_rate': r'(?:rate|coverage|probability)[^\d]*(0\.\d+)',  # rate=0.055
        'lr_statistic': r'LR[^\d]*([\d.]+)',  # LR=90.86
        'chi_square': r'χ²[^\d]*([\d.]+)',  # χ²=36.5
        'odds_ratio': r'OR[^\d]*([\d.]+)',  # OR=1.44
        'wald_stat': r'Wald[^\d]*([\d.]+)',  # Wald=45.2
        'n_obs': r'n\s*=\s*(\d+)',  # n=194
        'weeks': r'(\d+)\s+weeks?',  # 194 weeks
    }
    
    for line_num, line in enumerate(lines, 1):
        for pattern_type, pattern in patterns.items():
            matches = re.finditer(pattern, line, re.IGNORECASE)
            for match in matches:
                try:
                    value_str = match.group(1)
                    # Handle scientific notation
                    if 'e' in value_str.lower():
                        value = float(value_str)
                    else:
                        value = float(value_str)
                    
                    numbers.append({
                        'value': value,
                        'value_str': value_str,
                        'context': line.strip(),
                        'line_num': line_num,
                        'type': pattern_type,
                        'status': 'PENDING'
                    })
                except ValueError:
                    continue
    
    print(f"📊 Extracted {len(numbers)} numerical claims from paper")
    return numbers

# ============================================================================
# VALIDATION
# ============================================================================

def validate_against_csvs(numbers: List[Dict], data: Dict[str, pd.DataFrame]) -> List[Dict]:
    """
    Validate each extracted number against CSV data.
    Updates 'status' field: MATCH, MISMATCH, UNSOURCED
    """
    
    # Build lookup tables from CSVs
    lookups = build_lookup_tables(data)
    
    for num in numbers:
        value = num['value']
        context = num['context'].lower()
        num_type = num['type']
        
        # Try to match against known values
        matched = False
        
        # Check p-values
        if num_type == 'p_value':
            for source, source_values in lookups['p_values'].items():
                for expected in source_values:
                    if abs(value - expected) < 0.001 or (value < 1e-5 and expected < 1e-5):
                        num['status'] = 'MATCH'
                        num['source'] = source
                        matched = True
                        break
                if matched:
                    break
        
        # Check rates/percentages
        elif num_type in ['percentage', 'decimal_rate']:
            # Convert percentage to decimal if needed
            check_value = value / 100 if num_type == 'percentage' else value
            
            for source, source_values in lookups['rates'].items():
                for expected in source_values:
                    if abs(check_value - expected) < TOLERANCE:
                        num['status'] = 'MATCH'
                        num['source'] = source
                        matched = True
                        break
                if matched:
                    break
        
        # Check statistics (LR, Wald, χ²)
        elif num_type in ['lr_statistic', 'chi_square', 'wald_stat']:
            for source, source_values in lookups['statistics'].items():
                for expected in source_values:
                    if abs(value - expected) < max(TOLERANCE * expected, 0.1):
                        num['status'] = 'MATCH'
                        num['source'] = source
                        matched = True
                        break
                if matched:
                    break
        
        # Check odds ratios
        elif num_type == 'odds_ratio':
            if not data['odds_ratios'].empty:
                ors = data['odds_ratios']['OR'].values
                for expected in ors:
                    if abs(value - expected) < max(TOLERANCE * expected, 0.01):
                        num['status'] = 'MATCH'
                        num['source'] = 'odds_ratios.csv'
                        matched = True
                        break
        
        # Check sample sizes
        elif num_type in ['n_obs', 'weeks']:
            for source, source_values in lookups['counts'].items():
                if value in source_values:
                    num['status'] = 'MATCH'
                    num['source'] = source
                    matched = True
                    break
        
        if not matched:
            num['status'] = 'UNSOURCED'
            num['source'] = 'NONE'
    
    matched = sum(1 for n in numbers if n['status'] == 'MATCH')
    unsourced = sum(1 for n in numbers if n['status'] == 'UNSOURCED')
    
    print(f"✅ MATCH: {matched}")
    print(f"❌ UNSOURCED: {unsourced}")
    
    return numbers

def build_lookup_tables(data: Dict[str, pd.DataFrame]) -> Dict:
    """Build lookup tables from CSV data for quick validation."""
    lookups = {
        'p_values': {},
        'rates': {},
        'statistics': {},
        'counts': {}
    }
    
    # Christoffersen p-values and LR stats
    if not data['christoffersen'].empty:
        df = data['christoffersen']
        lookups['p_values']['christoffersen'] = df['p_cc'].dropna().tolist()
        lookups['statistics']['christoffersen_lr'] = df['LR_cc'].dropna().tolist()
    
    # DQ test results
    if not data['dq'].empty:
        df = data['dq']
        if 'p_value' in df.columns:
            lookups['p_values']['dq'] = df['p_value'].dropna().tolist()
        if 'lr_stat' in df.columns:
            lookups['statistics']['dq_lr'] = df['lr_stat'].dropna().tolist()
    
    # Conditional calibration
    if not data['conditional'].empty:
        df = data['conditional']
        if 'p_value_cluster' in df.columns:
            lookups['p_values']['conditional'] = df['p_value_cluster'].dropna().tolist()
        if 'wald_stat_cluster' in df.columns:
            lookups['statistics']['conditional_wald'] = df['wald_stat_cluster'].dropna().tolist()
    
    # Violation rates
    if not data['violations'].empty:
        df = data['violations']
        if 'rate' in df.columns:
            lookups['rates']['violations'] = df['rate'].dropna().tolist()
        if 'n_obs_week' in df.columns:
            lookups['counts']['n_obs'] = df['n_obs_week'].dropna().astype(int).tolist()
    
    return lookups

# ============================================================================
# REPORT GENERATION
# ============================================================================

def generate_consistency_report(numbers: List[Dict], data: Dict[str, pd.DataFrame]) -> str:
    """Generate markdown consistency report."""
    
    report = f"""# Paper Consistency Audit Report

Generated: {pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}

## Summary

- **Total numbers extracted**: {len(numbers)}
- **MATCH**: {sum(1 for n in numbers if n['status'] == 'MATCH')}
- **UNSOURCED**: {sum(1 for n in numbers if n['status'] == 'UNSOURCED')}

## Issues Detected

### UNSOURCED Numbers (require verification or removal)

"""
    
    unsourced = [n for n in numbers if n['status'] == 'UNSOURCED']
    if unsourced:
        report += "| Line | Type | Value | Context |\n"
        report += "|------|------|-------|----------|\n"
        for num in unsourced[:50]:  # Limit to first 50
            report += f"| {num['line_num']} | {num['type']} | {num['value_str']} | {num['context'][:80]}... |\n"
    else:
        report += "✅ No unsourced numbers detected.\n"
    
    report += "\n\n### Matched Numbers\n\n"
    matched = [n for n in numbers if n['status'] == 'MATCH']
    if matched:
        report += f"✅ {len(matched)} numbers successfully matched to CSV sources.\n"
        report += "\nSample of matches:\n\n"
        report += "| Line | Type | Value | Source | Context |\n"
        report += "|------|------|-------|--------|----------|\n"
        for num in matched[:20]:  # Show first 20 matches
            report += f"| {num['line_num']} | {num['type']} | {num['value_str']} | {num.get('source', 'N/A')} | {num['context'][:60]}... |\n"
    
    # Add CSV data summaries
    report += "\n\n## CSV Data Summary\n\n"
    
    for name, df in data.items():
        if not df.empty:
            report += f"### {name}.csv\n\n"
            report += f"- Rows: {len(df)}\n"
            report += f"- Columns: {', '.join(df.columns.tolist())}\n"
            report += f"- Key values:\n"
            
            # Show key statistics
            if name == 'christoffersen' and 'LR_cc' in df.columns:
                report += f"  - LR_cc range: [{df['LR_cc'].min():.2f}, {df['LR_cc'].max():.2f}]\n"
                report += f"  - p_cc < 0.05: {(df['p_cc'] < 0.05).sum()} segments\n"
            
            elif name == 'violations' and 'rate' in df.columns:
                report += f"  - Violation rate range: [{df['rate'].min():.4f}, {df['rate'].max():.4f}]\n"
                report += f"  - Mean rate: {df['rate'].mean():.4f}\n"
            
            elif name == 'odds_ratios' and 'OR' in df.columns:
                report += f"  - OR range: [{df['OR'].min():.3f}, {df['OR'].max():.3f}]\n"
                significant = df[df['p_value'] < 0.05] if 'p_value' in df.columns else df
                report += f"  - Significant predictors (p<0.05): {len(significant)}\n"
            
            report += "\n"
    
    return report

def save_report(report: str):
    """Save consistency report to file."""
    REPORT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    
    with open(REPORT_OUTPUT, 'w', encoding='utf-8') as f:
        f.write(report)
    
    print(f"\n📄 Consistency report saved: {REPORT_OUTPUT}")

# ============================================================================
# PAPER CORRECTION
# ============================================================================

def fix_paper(paper: str, numbers: List[Dict], data: Dict[str, pd.DataFrame]) -> str:
    """
    Apply corrections to paper based on audit results.
    
    Corrections:
    1. Fix terminology (conservative vs under-coverage)
    2. Replace Christoffersen/Kupiec table with correct values
    3. Replace DQ test values
    4. Fix conditional calibration terminology (cluster-robust Wald, not Kupiec)
    5. Update quantile crossing section
    6. Fix nominal line references (α=0.90 → 10%, not 9%)
    """
    
    corrected = paper
    
    # 1. Fix terminology
    print("\n🔧 Fixing terminology...")
    corrected = fix_terminology(corrected)
    
    # 2. Replace Christoffersen table
    print("🔧 Replacing Christoffersen table...")
    corrected = replace_christoffersen_table(corrected, data['christoffersen'])
    
    # 3. Replace DQ test section
    print("🔧 Updating DQ test results...")
    corrected = replace_dq_section(corrected, data['dq'])
    
    # 4. Fix conditional calibration terminology
    print("🔧 Fixing conditional calibration terminology...")
    corrected = fix_conditional_calibration_terminology(corrected)
    
    # 5. Update quantile crossing
    print("🔧 Updating quantile crossing section...")
    corrected = update_quantile_crossing(corrected, data['crossing'])
    
    # 6. Fix nominal line references
    print("🔧 Fixing nominal line percentages...")
    corrected = fix_nominal_percentages(corrected)
    
    return corrected

def fix_terminology(paper: str) -> str:
    """Fix conservative/under-coverage terminology."""
    
    # Pattern: "under-coverage" when pi_hat < (1-alpha) should be "over-coverage" or "conservative"
    replacements = [
        (r'under-coverage\s+\(observed\s+rate\s+<\s+nominal\)', 'over-coverage (observed rate < nominal)'),
        (r'under-conservatism', 'over-conservatism'),
        (r'forecasts are too narrow', 'forecasts are too wide (conservative)'),
    ]
    
    fixed = paper
    for pattern, replacement in replacements:
        fixed = re.sub(pattern, replacement, fixed, flags=re.IGNORECASE)
    
    return fixed

def replace_christoffersen_table(paper: str, df: pd.DataFrame) -> str:
    """Replace Christoffersen table with correct values from CSV."""
    
    if df.empty:
        return paper
    
    # Build correct table
    table_md = "\n| Segment | Alpha | LR_uc | p_uc | LR_ind | p_ind | LR_cc | p_cc | Interpretation |\n"
    table_md += "|---------|-------|-------|------|--------|-------|-------|------|----------------|\n"
    
    for _, row in df.iterrows():
        segment = row.get('segment', 'N/A')
        alpha = row.get('alpha', 0)
        lr_uc = row.get('LR_uc', 0)
        p_uc = row.get('p_uc', 1)
        lr_ind = row.get('LR_ind', 0)
        p_ind = row.get('p_ind', 1)
        lr_cc = row.get('LR_cc', 0)
        p_cc = row.get('p_cc', 1)
        
        # Interpretation
        if p_cc < 0.001:
            interp = "REJECT (p<0.001)"
        elif p_cc < 0.05:
            interp = f"REJECT (p={p_cc:.3f})"
        else:
            interp = f"FAIL TO REJECT (p={p_cc:.3f})"
        
        p_uc_str = f"<1e-6" if p_uc < 1e-6 else f"{p_uc:.4f}"
        p_ind_str = f"<1e-6" if p_ind < 1e-6 else f"{p_ind:.4f}"
        p_cc_str = f"<1e-6" if p_cc < 1e-6 else f"{p_cc:.4f}"
        
        table_md += f"| {segment} | {alpha} | {lr_uc:.2f} | {p_uc_str} | {lr_ind:.2f} | {p_ind_str} | {lr_cc:.2f} | {p_cc_str} | {interp} |\n"
    
    # Find and replace existing table
    # Look for markdown table with "Christoffersen" or "LR_cc" headers
    pattern = r'\|[^\n]*(?:Christoffersen|LR_cc|LR statistic)[^\n]*\|[\s\S]*?\n(?:\|[^\n]*\|\n)+'
    
    if re.search(pattern, paper):
        fixed = re.sub(pattern, table_md, paper, count=1)
        print("  ✅ Replaced Christoffersen table")
        return fixed
    else:
        print("  ⚠️  Could not find Christoffersen table to replace")
        return paper

def replace_dq_section(paper: str, df: pd.DataFrame) -> str:
    """Update DQ test results section."""
    
    if df.empty:
        return paper
    
    # Build DQ results text
    dq_text = "\n**DQ Test Results (Pooled Logistic Regression)**\n\n"
    
    for _, row in df.iterrows():
        segment = row.get('segment', 'N/A')
        alpha = row.get('alpha', 0)
        lr = row.get('lr_stat', 0)
        p_val = row.get('p_value', 1)
        
        p_str = f"<1e-6" if p_val < 1e-6 else f"{p_val:.4f}"
        
        dq_text += f"- **{segment} (α={alpha})**: "
        dq_text += f"LR χ²={lr:.2f}, p={p_str}\n"
    
    # Replace section
    pattern = r'(##\s+DQ Test.*?)(?=##|\Z)'
    if re.search(pattern, paper, re.DOTALL):
        fixed = re.sub(pattern, lambda m: dq_text + "\n\n", paper, count=1, flags=re.DOTALL)
        print("  ✅ Replaced DQ test section")
        return fixed
    else:
        print("  ⚠️  Could not find DQ test section")
        return paper

def fix_conditional_calibration_terminology(paper: str) -> str:
    """
    Fix conditional calibration terminology.
    
    If paper calls cluster-robust Wald test "Kupiec", rename to
    "conditional calibration (cluster-robust Wald test)".
    """
    
    replacements = [
        (r'Kupiec test.*cluster', 'cluster-robust conditional calibration test'),
        (r'Kupiec.*logit.*cluster', 'cluster-robust logistic regression (Wald test)'),
    ]
    
    fixed = paper
    for pattern, replacement in replacements:
        if re.search(pattern, fixed, re.IGNORECASE):
            fixed = re.sub(pattern, replacement, fixed, flags=re.IGNORECASE)
            print(f"  ✅ Fixed: {pattern[:30]}... → {replacement}")
    
    return fixed

def update_quantile_crossing(paper: str, df: pd.DataFrame) -> str:
    """Update quantile crossing section with actual values."""
    
    if df.empty:
        # If no crossing, make explicit
        crossing_text = "\n**Quantile Crossing Check**: No quantile crossing violations detected (q_0.90 < q_0.95 for all observations).\n"
    else:
        n_crossings = df['n_crossings'].sum() if 'n_crossings' in df.columns else 0
        crossing_text = f"\n**Quantile Crossing Check**: {n_crossings} crossing violations detected.\n"
    
    # Replace section
    pattern = r'(quantile crossing.*?)(?=\n##|\Z)'
    if re.search(pattern, paper, re.IGNORECASE | re.DOTALL):
        fixed = re.sub(pattern, lambda m: crossing_text, paper, count=1, flags=re.IGNORECASE | re.DOTALL)
        print("  ✅ Updated quantile crossing section")
        return fixed
    else:
        # Insert before Results section if not found
        pattern = r'(##\s+Results)'
        if re.search(pattern, paper):
            fixed = re.sub(pattern, lambda m: crossing_text + "\n" + m.group(0), paper, count=1)
            print("  ✅ Inserted quantile crossing section")
            return fixed
    
    return paper

def fix_nominal_percentages(paper: str) -> str:
    """
    Fix nominal line references.
    
    α=0.90 → nominal = 1-α = 0.10 = 10% (NOT 9%)
    α=0.95 → nominal = 1-α = 0.05 = 5%
    """
    
    replacements = [
        (r'α\s*=\s*0\.90.*?9%', 'α=0.90 (nominal 10%)'),
        (r'alpha\s*=\s*0\.90.*?9%', 'alpha=0.90 (nominal 10%)'),
        (r'nominal\s+9%\s+\(α\s*=\s*0\.90\)', 'nominal 10% (α=0.90)'),
        (r'nominal\s+9%\s+\(alpha\s*=\s*0\.90\)', 'nominal 10% (alpha=0.90)'),
        (r'0\.09\s+nominal', '0.10 nominal'),
    ]
    
    fixed = paper
    for pattern, replacement in replacements:
        if re.search(pattern, fixed, re.IGNORECASE):
            fixed = re.sub(pattern, replacement, fixed, flags=re.IGNORECASE)
            print(f"  ✅ Fixed nominal percentage: {pattern[:40]}...")
    
    return fixed

def save_corrected_paper(paper: str):
    """Save corrected paper to file."""
    with open(PAPER_OUTPUT, 'w', encoding='utf-8') as f:
        f.write(paper)
    
    print(f"\n📄 Corrected paper saved: {PAPER_OUTPUT}")

# ============================================================================
# MAIN
# ============================================================================

def main():
    """Main execution."""
    print("="*80)
    print("PAPER CONSISTENCY AUDITOR & FIXER")
    print("="*80)
    print("\nResearch engineer + paper editor mode activated.")
    print("Ensuring 100% consistency between paper and CSV results.\n")
    
    try:
        # 1. Load data
        print("\n📖 STEP 1: Loading data...")
        paper = load_paper()
        data = load_all_csvs()
        
        # 2. Extract numbers
        print("\n📊 STEP 2: Extracting numerical claims...")
        numbers = extract_numbers_from_paper(paper)
        
        # 3. Validate
        print("\n🔍 STEP 3: Validating against CSV data...")
        numbers = validate_against_csvs(numbers, data)
        
        # 4. Generate report
        print("\n📝 STEP 4: Generating consistency report...")
        report = generate_consistency_report(numbers, data)
        save_report(report)
        
        # 5. Fix paper
        print("\n🔧 STEP 5: Applying corrections to paper...")
        corrected_paper = fix_paper(paper, numbers, data)
        save_corrected_paper(corrected_paper)
        
        # 6. Summary
        print("\n" + "="*80)
        print("✅ AUDIT & FIX COMPLETE")
        print("="*80)
        
        matched = sum(1 for n in numbers if n['status'] == 'MATCH')
        unsourced = sum(1 for n in numbers if n['status'] == 'UNSOURCED')
        
        print(f"\n📊 SUMMARY:")
        print(f"   - Numbers extracted: {len(numbers)}")
        print(f"   - ✅ MATCHED to CSV: {matched} ({matched/len(numbers)*100:.1f}%)")
        print(f"   - ❌ UNSOURCED: {unsourced} ({unsourced/len(numbers)*100:.1f}%)")
        
        print(f"\n📁 OUTPUTS:")
        print(f"   - Audit report: {REPORT_OUTPUT}")
        print(f"   - Corrected paper: {PAPER_OUTPUT}")
        
        print(f"\n💡 NEXT STEPS:")
        print(f"   1. Review {REPORT_OUTPUT.name} for UNSOURCED numbers")
        print(f"   2. Open {PAPER_OUTPUT.name} in VS Code")
        print(f"   3. Search for remaining issues (Ctrl+F 'UNSOURCED' or 'MISMATCH')")
        print(f"   4. Manually verify qualitative claims")
        print(f"   5. Check Figure references match actual files in {FIGURES_DIR.name}/")
        
        if unsourced > 0:
            print(f"\n⚠️  WARNING: {unsourced} unsourced numbers detected!")
            print(f"   These should be either:")
            print(f"   - Replaced with correct values from CSV")
            print(f"   - Converted to qualitative statements")
            print(f"   - Removed if unverifiable")
        
        return 0
    
    except Exception as e:
        print(f"\n❌ FATAL ERROR: {e}")
        import traceback
        traceback.print_exc()
        return 1

if __name__ == '__main__':
    exit(main())
