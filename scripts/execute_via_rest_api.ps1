# Execute BigQuery SQL via REST API (bypassing broken bq CLI)
param(
    [string]$SqlFile = "bq_stockout_forecast_h4_production.sql",
    [string]$ProjectId = "voltaic-tuner-475510-s4"
)

Write-Host "="*70 -ForegroundColor Cyan
Write-Host "BIGQUERY REST API EXECUTION" -ForegroundColor Cyan
Write-Host "="*70 -ForegroundColor Cyan

# Get OAuth token from gcloud
Write-Host "`nObtaining access token..." -ForegroundColor Yellow
$token = (gcloud auth application-default print-access-token 2>$null)

if (-not $token) {
    Write-Host "ERROR: Failed to get access token" -ForegroundColor Red
    Write-Host "Run: gcloud auth application-default login" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Token obtained" -ForegroundColor Green

# Read SQL file
Write-Host "`nReading SQL file: $SqlFile" -ForegroundColor Yellow
if (-not (Test-Path $SqlFile)) {
    Write-Host "ERROR: File not found: $SqlFile" -ForegroundColor Red
    exit 1
}

$sqlContent = Get-Content $SqlFile -Raw -Encoding UTF8
Write-Host "✓ SQL file loaded ($($sqlContent.Length) characters)" -ForegroundColor Green

# Prepare API request
$apiUrl = "https://bigquery.googleapis.com/bigquery/v2/projects/$ProjectId/queries"

$body = @{
    query = $sqlContent
    useLegacySql = $false
    location = "EU"
    timeoutMs = 600000  # 10 minutes
    maxResults = 0
} | ConvertTo-Json -Depth 10

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# Execute query
Write-Host "`nSubmitting query to BigQuery API..." -ForegroundColor Yellow
Write-Host "URL: $apiUrl" -ForegroundColor DarkGray
Write-Host "Location: EU" -ForegroundColor DarkGray

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $body -TimeoutSec 600
    
    Write-Host "`n" + "="*70 -ForegroundColor Green
    Write-Host "✓ QUERY SUBMITTED SUCCESSFULLY" -ForegroundColor Green
    Write-Host "="*70 -ForegroundColor Green
    
    if ($response.jobReference) {
        $jobId = $response.jobReference.jobId
        Write-Host "`nJob ID: $jobId" -ForegroundColor Cyan
        Write-Host "Job Status: $($response.jobComplete)" -ForegroundColor Cyan
        
        if (-not $response.jobComplete) {
            Write-Host "`n⏳ Job still running. Monitor at:" -ForegroundColor Yellow
            Write-Host "https://console.cloud.google.com/bigquery?project=$ProjectId&j=bq:$($response.jobReference.location):$jobId&page=queryresults" -ForegroundColor Blue
        }
    }
    
    Write-Host "`nFull Response:" -ForegroundColor DarkGray
    $response | ConvertTo-Json -Depth 5 | Write-Host -ForegroundColor DarkGray
    
} catch {
    Write-Host "`n" + "="*70 -ForegroundColor Red
    Write-Host "✗ QUERY FAILED" -ForegroundColor Red
    Write-Host "="*70 -ForegroundColor Red
    
    Write-Host "`nError Message:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    
    if ($_.ErrorDetails.Message) {
        Write-Host "`nAPI Error Details:" -ForegroundColor Red
        $_.ErrorDetails.Message | ConvertFrom-Json | ConvertTo-Json -Depth 5 | Write-Host -ForegroundColor Red
    }
    
    exit 1
}

Write-Host "`n✓ Execution complete" -ForegroundColor Green
