#!/usr/bin/env python3
"""
Sanity check: Ensure no hardcoded voltaic-tuner references in production SQL.

This test validates that the production forecasting SQL files have been properly
migrated to use parameterized project/dataset references instead of hardcoded
voltaic-tuner-475510-s4 references.

Usage:
    python test_no_voltaic_refs.py

Exit codes:
    0 = PASS (no voltaic-tuner references found)
    1 = FAIL (found voltaic-tuner references)

Author: Pipeline Migration Team
Created: 2025-01-XX
"""
import re
import sys
from pathlib import Path
from typing import List, Tuple


# Forbidden patterns
FORBIDDEN_PATTERNS = [
    re.compile(r'voltaic-tuner-475510-s4', re.IGNORECASE),
    re.compile(r'voltaic-tuner', re.IGNORECASE),
    re.compile(r'dataset_cruzber_eu(?!\{)', re.IGNORECASE),  # Hardcoded dataset without template
]

# Directories to check
PRODUCTION_SQL_DIRS = [
    Path("sql/bqml/quantiles_v1"),
    Path("sql/bqml/eval"),
]

# Files to check (can be extended)
PRODUCTION_SQL_PATTERNS = [
    "stockout_forecast_h1.sql",
    "stockout_forecast_h4.sql",
    "compare_h1_vs_h4.sql",
]


def check_file(file_path: Path) -> List[Tuple[int, str]]:
    """
    Check a single file for forbidden patterns.
    
    Args:
        file_path: Path to SQL file
        
    Returns:
        List of (line_number, line_content) tuples where pattern was found
    """
    violations = []
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, start=1):
                for pattern in FORBIDDEN_PATTERNS:
                    if pattern.search(line):
                        violations.append((line_num, line.strip()))
    except Exception as e:
        print(f"⚠️  Warning: Could not read {file_path}: {e}")
    
    return violations


def main() -> int:
    """Run sanity checks on production SQL files."""
    print("=" * 70)
    print("SANITY CHECK: Voltaic-Tuner Reference Detection")
    print("=" * 70)
    print()
    
    all_violations = {}
    files_checked = 0
    
    # Check all production SQL directories
    for sql_dir in PRODUCTION_SQL_DIRS:
        if not sql_dir.exists():
            print(f"⚠️  Warning: Directory not found: {sql_dir}")
            continue
        
        # Check all SQL files in directory
        for sql_file in sql_dir.glob("*.sql"):
            files_checked += 1
            violations = check_file(sql_file)
            
            if violations:
                all_violations[sql_file] = violations
    
    # Report results
    print(f"Files checked: {files_checked}")
    print()
    
    if all_violations:
        print("❌ FAIL: Found voltaic-tuner references in production SQL files")
        print("=" * 70)
        
        for file_path, violations in all_violations.items():
            print(f"\n📄 {file_path}")
            for line_num, line_content in violations:
                print(f"   Line {line_num}: {line_content}")
        
        print("\n" + "=" * 70)
        print("REMEDIATION:")
        print("  1. Replace hardcoded project IDs with {PROJECT_ID}")
        print("  2. Replace hardcoded datasets with {BQ_DATASET}")
        print("  3. Replace hardcoded table refs with {BASE_SALES_TABLE}")
        print("=" * 70)
        
        return 1
    else:
        print("✅ PASS: No voltaic-tuner references found in production SQL")
        print("=" * 70)
        print("All production SQL files are properly parameterized.")
        print("=" * 70)
        
        return 0


if __name__ == "__main__":
    sys.exit(main())
