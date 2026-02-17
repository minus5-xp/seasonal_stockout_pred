#!/usr/bin/env python3
"""
Build distributable bundle of the pipeline.
Includes SQL, Python, docs, and manifest with hashes.
"""
import sys
import tarfile
import hashlib
import json
from pathlib import Path
from typing import List, Dict, Any
from datetime import datetime
import xxhash


class BundleBuilder:
    """Create distributable bundles of the pipeline."""
    
    def __init__(self, root_dir: Path, output_dir: Path):
        self.root_dir = root_dir
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        self.manifest = {
            "created_at": datetime.utcnow().isoformat() + "Z",
            "bundle_version": "1.0.0",
            "files": []
        }
    
    def _hash_file(self, file_path: Path) -> Dict[str, str]:
        """Compute multiple hashes for a file."""
        sha256 = hashlib.sha256()
        xxh = xxhash.xxh64()
        
        with open(file_path, 'rb') as f:
            while chunk := f.read(8192):
                sha256.update(chunk)
                xxh.update(chunk)
        
        return {
            "sha256": sha256.hexdigest(),
            "xxh64": xxh.hexdigest()
        }
    
    def _should_include(self, path: Path) -> bool:
        """Check if file should be included in bundle."""
        
        # Exclude patterns
        excludes = [
            '__pycache__',
            '.pytest_cache',
            '.mypy_cache',
            '.git',
            '.vscode',
            'logs',
            'outputs',
            '*.pyc',
            '*.pyo',
            '*.log',
            '*.bak',
            '*.backup',
            '*.tmp',
            '*.swp',
            '.ipynb_checkpoints',
            'node_modules',
            'dist',  # Don't recursively include bundles
        ]
        
        path_str = str(path)
        
        for pattern in excludes:
            if pattern.startswith('*'):
                if path_str.endswith(pattern[1:]):
                    return False
            else:
                if pattern in path_str:
                    return False
        
        return True
    
    def add_directory(self, dir_path: Path, archive_prefix: str = ""):
        """Recursively add directory to bundle."""
        if not dir_path.exists():
            print(f"⚠️  Directory not found: {dir_path}")
            return []
        
        added_files = []
        
        for item in sorted(dir_path.rglob("*")):
            if not item.is_file():
                continue
            
            if not self._should_include(item):
                continue
            
            # Compute relative path
            rel_path = item.relative_to(self.root_dir)
            archive_path = archive_prefix + str(rel_path).replace("\\", "/")
            
            # Hash file
            hashes = self._hash_file(item)
            
            file_info = {
                "path": archive_path,
                "size": item.stat().st_size,
                **hashes
            }
            
            self.manifest["files"].append(file_info)
            added_files.append((item, archive_path))
        
        return added_files
    
    def build(
        self,
        output_name: str,
        include_dirs: List[str] = None
    ) -> Path:
        """
        Build the bundle tarball.
        
        Args:
            output_name: Base name for output file (without extension)
            include_dirs: List of directory names to include (default: standard set)
            
        Returns:
            Path to created bundle
        """
        if include_dirs is None:
            include_dirs = ["sql", "src", "docs", "scripts", "reports"]
        
        print(f"\n{'=' * 60}")
        print(f"Building bundle: {output_name}")
        print(f"{'=' * 60}\n")
        
        # Collect files
        all_files = []
        
        for dir_name in include_dirs:
            dir_path = self.root_dir / dir_name
            print(f"Adding {dir_name}/... ", end="", flush=True)
            
            files = self.add_directory(dir_path)
            all_files.extend(files)
            
            print(f"✓ ({len(files)} files)")
        
        # Add single-file items
        single_files = [
            "README.md",
            "checklist_status.csv",
            "checklist_status_final.csv",
        ]
        
        for filename in single_files:
            file_path = self.root_dir / filename
            if file_path.exists():
                hashes = self._hash_file(file_path)
                file_info = {
                    "path": filename,
                    "size": file_path.stat().st_size,
                    **hashes
                }
                self.manifest["files"].append(file_info)
                all_files.append((file_path, filename))
        
        print(f"\nTotal files: {len(all_files)}")
        
        # Write manifest
        manifest_path = self.output_dir / "manifest.json"
        with open(manifest_path, 'w') as f:
            json.dump(self.manifest, f, indent=2)
        
        print(f"Manifest: {manifest_path}")
        
        # Create tarball
        bundle_path = self.output_dir / f"{output_name}.tar.gz"
        
        print(f"\nCreating tarball: {bundle_path.name}...", end=" ", flush=True)
        
        with tarfile.open(bundle_path, "w:gz") as tar:
            # Add manifest first
            tar.add(manifest_path, arcname="manifest.json")
            
            # Add all files
            for file_path, archive_name in all_files:
                tar.add(file_path, arcname=archive_name)
        
        bundle_size_mb = bundle_path.stat().st_size / 1024 / 1024
        print(f"✓ ({bundle_size_mb:.1f} MB)")
        
        print(f"\n{'=' * 60}")
        print(f"✓ Bundle created: {bundle_path}")
        print(f"{'=' * 60}\n")
        
        return bundle_path


def main():
    """CLI for building bundles."""
    import argparse
    from src.config.env import load_config
    
    parser = argparse.ArgumentParser(description="Build pipeline bundle")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("dist"),
        help="Output directory for bundle"
    )
    parser.add_argument(
        "--name",
        type=str,
        help="Bundle name (default: auto-generated with RUN_ID)"
    )
    
    args = parser.parse_args()
    
    # Load config for RUN_ID
    config = load_config(check_gcs=False)
    
    # Determine bundle name
    if args.name:
        bundle_name = args.name
    else:
        bundle_name = f"cruzber_optionB_bundle_{config.run_id}"
    
    # Build bundle
    root_dir = Path(__file__).parent.parent.parent
    builder = BundleBuilder(root_dir, args.output_dir)
    
    bundle_path = builder.build(bundle_name)
    
    print(f"Bundle ready: {bundle_path}")
    print(f"\nTo upload to GCS:")
    print(f"  gsutil cp {bundle_path} {config.gcs_bundle_path}")


if __name__ == "__main__":
    main()
