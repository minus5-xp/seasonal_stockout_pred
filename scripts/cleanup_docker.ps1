# ============================================================================
# DOCKER CLEANUP SCRIPT (PowerShell)
# ============================================================================
# Purpose: Clean up Docker images, containers, and results
# Usage: .\cleanup_docker.ps1
# ============================================================================

Write-Host "=" -ForegroundColor Yellow -NoNewline
Write-Host ("=" * 69) -ForegroundColor Yellow
Write-Host "DOCKER CLEANUP UTILITY" -ForegroundColor Yellow
Write-Host "=" -ForegroundColor Yellow -NoNewline
Write-Host ("=" * 69) -ForegroundColor Yellow

# Menu
Write-Host "`nSelect cleanup option:" -ForegroundColor Cyan
Write-Host "  [1] Stop running containers" -ForegroundColor Gray
Write-Host "  [2] Remove Docker image" -ForegroundColor Gray
Write-Host "  [3] Delete results directory" -ForegroundColor Gray
Write-Host "  [4] Full cleanup (all of the above)" -ForegroundColor Gray
Write-Host "  [5] Cancel" -ForegroundColor Gray

$choice = Read-Host "`nEnter choice (1-5)"

switch ($choice) {
    "1" {
        Write-Host "`nStopping containers..." -ForegroundColor Yellow
        docker stop bqml-forecast-runner 2>$null
        docker-compose down 2>$null
        Write-Host "✅ Containers stopped" -ForegroundColor Green
    }
    
    "2" {
        Write-Host "`nRemoving Docker image..." -ForegroundColor Yellow
        docker rmi bqml-stockout-forecast:latest 2>$null
        Write-Host "✅ Image removed" -ForegroundColor Green
    }
    
    "3" {
        Write-Host "`nDeleting results directory..." -ForegroundColor Yellow
        $confirm = Read-Host "⚠️  This will delete all CSV files. Continue? (yes/no)"
        if ($confirm -eq "yes") {
            Remove-Item -Path ".\results_h4" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "✅ Results deleted" -ForegroundColor Green
        } else {
            Write-Host "❌ Cancelled" -ForegroundColor Red
        }
    }
    
    "4" {
        Write-Host "`nFull cleanup..." -ForegroundColor Yellow
        $confirm = Read-Host "⚠️  This will delete containers, images, and results. Continue? (yes/no)"
        if ($confirm -eq "yes") {
            # Stop containers
            Write-Host "  - Stopping containers..." -ForegroundColor Gray
            docker stop bqml-forecast-runner 2>$null
            docker-compose down 2>$null
            
            # Remove image
            Write-Host "  - Removing image..." -ForegroundColor Gray
            docker rmi bqml-stockout-forecast:latest 2>$null
            
            # Delete results
            Write-Host "  - Deleting results..." -ForegroundColor Gray
            Remove-Item -Path ".\results_h4" -Recurse -Force -ErrorAction SilentlyContinue
            
            Write-Host "✅ Full cleanup completed" -ForegroundColor Green
        } else {
            Write-Host "❌ Cancelled" -ForegroundColor Red
        }
    }
    
    "5" {
        Write-Host "`n❌ Cancelled" -ForegroundColor Red
    }
    
    default {
        Write-Host "`n❌ Invalid choice" -ForegroundColor Red
    }
}

Write-Host ""
