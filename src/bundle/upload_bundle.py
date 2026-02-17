#!/usr/bin/env python3
"""
Upload bundle to GCS.
Uses google-cloud-storage library (more reliable than gsutil in containers).
"""
import sys
from pathlib import Path
from typing import Optional
from google.cloud import storage
from google.api_core import exceptions


class BundleUploader:
    """Upload files to Google Cloud Storage."""
    
    def __init__(self, project_id: str):
        try:
            self.client = storage.Client(project=project_id)
        except Exception as e:
            print(f"❌ Failed to create GCS client: {e}", file=sys.stderr)
            print("\nEnsure you have authenticated:", file=sys.stderr)
            print("  gcloud auth application-default login", file=sys.stderr)
            sys.exit(1)
    
    def parse_gcs_url(self, gcs_url: str) -> tuple:
        """
        Parse gs://bucket/path into (bucket, path).
        
        Args:
            gcs_url: GCS URL (gs://bucket/prefix/file)
            
        Returns:
            (bucket_name, object_path) tuple
            
        Raises:
            ValueError: If URL format is invalid
        """
        if not gcs_url.startswith("gs://"):
            raise ValueError(f"GCS URL must start with gs:// (got: {gcs_url})")
        
        parts = gcs_url[5:].split("/", 1)
        
        if len(parts) == 1:
            return parts[0], ""
        else:
            return parts[0], parts[1]
    
    def upload_file(
        self,
        local_path: Path,
        gcs_url: str,
        content_type: Optional[str] = None
    ) -> str:
        """
        Upload file to GCS.
        
        Args:
            local_path: Local file to upload
            gcs_url: Destination GCS URL (gs://bucket/path/to/file)
            content_type: Optional content type
            
        Returns:
            Public GCS URL
            
        Raises:
            SystemExit: If upload fails
        """
        if not local_path.exists():
            print(f"❌ File not found: {local_path}", file=sys.stderr)
            sys.exit(1)
        
        try:
            bucket_name, object_path = self.parse_gcs_url(gcs_url)
        except ValueError as e:
            print(f"❌ Invalid GCS URL: {e}", file=sys.stderr)
            sys.exit(1)
        
        print(f"\nUploading to GCS:")
        print(f"  Local:  {local_path}")
        print(f"  Remote: gs://{bucket_name}/{object_path}")
        
        try:
            # Get bucket
            bucket = self.client.bucket(bucket_name)
            
            # Create blob
            blob = bucket.blob(object_path)
            
            # Set content type
            if content_type:
                blob.content_type = content_type
            elif local_path.suffix == '.gz':
                blob.content_type = 'application/gzip'
            elif local_path.suffix == '.json':
                blob.content_type = 'application/json'
            elif local_path.suffix == '.md':
                blob.content_type = 'text/markdown'
            
            # Upload
            print(f"  Uploading...", end=" ", flush=True)
            blob.upload_from_filename(str(local_path))
            
            file_size_mb = local_path.stat().st_size / 1024 / 1024
            print(f"✓ ({file_size_mb:.1f} MB)")
            
            # Return public URL
            public_url = f"gs://{bucket_name}/{object_path}"
            print(f"  URL: {public_url}")
            
            return public_url
            
        except exceptions.NotFound:
            print(f"\n❌ Bucket not found: {bucket_name}", file=sys.stderr)
            print(f"Create bucket first: gsutil mb -l EU gs://{bucket_name}", file=sys.stderr)
            sys.exit(1)
            
        except exceptions.Forbidden as e:
            print(f"\n❌ Permission denied: {e}", file=sys.stderr)
            print(f"Ensure you have storage.objects.create permission", file=sys.stderr)
            sys.exit(1)
            
        except Exception as e:
            print(f"\n❌ Upload failed: {e}", file=sys.stderr)
            sys.exit(1)
    
    def upload_directory(
        self,
        local_dir: Path,
        gcs_base_url: str
    ) -> list:
        """
        Upload all files in directory to GCS.
        
        Args:
            local_dir: Local directory
            gcs_base_url: Base GCS URL (gs://bucket/prefix/)
            
        Returns:
            List of uploaded URLs
        """
        if not local_dir.exists() or not local_dir.is_dir():
            print(f"❌ Directory not found: {local_dir}", file=sys.stderr)
            sys.exit(1)
        
        uploaded = []
        
        for file_path in sorted(local_dir.rglob("*")):
            if not file_path.is_file():
                continue
            
            # Compute relative path
            rel_path = file_path.relative_to(local_dir)
            gcs_url = f"{gcs_base_url.rstrip('/')}/{str(rel_path).replace(chr(92), '/')}"
            
            try:
                url = self.upload_file(file_path, gcs_url)
                uploaded.append(url)
            except SystemExit:
                # Upload failed for this file, continue with next
                continue
        
        return uploaded


def main():
    """CLI for uploading bundles."""
    import argparse
    from src.config.env import load_config
    
    parser = argparse.ArgumentParser(description="Upload bundle to GCS")
    parser.add_argument(
        "file",
        type=Path,
        help="File or directory to upload"
    )
    parser.add_argument(
        "--destination",
        type=str,
        help="GCS destination (overrides GCS_BUCKET env var)"
    )
    
    args = parser.parse_args()
    
    # Load config
    config = load_config(check_gcs=False)
    
    # Determine destination
    if args.destination:
        gcs_url = args.destination
    elif config.gcs_bucket:
        if args.file.is_dir():
            gcs_url = config.gcs_reports_path
        else:
            gcs_url = config.gcs_bundle_path
    else:
        print("❌ No destination specified and GCS_BUCKET not set", file=sys.stderr)
        print("Use --destination or set GCS_BUCKET environment variable", file=sys.stderr)
        sys.exit(1)
    
    # Upload
    uploader = BundleUploader(config.project_id)
    
    if args.file.is_dir():
        print(f"\nUploading directory: {args.file}")
        urls = uploader.upload_directory(args.file, gcs_url)
        print(f"\n✓ Uploaded {len(urls)} files")
    else:
        uploader.upload_file(args.file, gcs_url)
        print(f"\n✓ Upload complete")


if __name__ == "__main__":
    main()
