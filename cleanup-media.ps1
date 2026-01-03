#!/usr/bin/env pwsh

# Jellyfin Database Cleanup Script (for Jellyfin 10.11+)
# Checks if media files still exist and offers deletion

param(
    [string]$JellyfinDataPath = "/var/lib/jellyfin",
    [switch]$DryRun = $false
)

# Colors for output
$Red = "`e[31m"
$Green = "`e[32m"
$Yellow = "`e[33m"
$Reset = "`e[0m"

Write-Host "${Green}Jellyfin Database Cleanup (10.11+)${Reset}" -ForegroundColor Green
Write-Host "================================================`n"

# Recommend VM/Container snapshot
Write-Host "${Yellow}IMPORTANT RECOMMENDATION:${Reset}" -ForegroundColor Yellow
Write-Host "Before proceeding, it is highly recommended to:"
Write-Host "  1. Create a VM/Container snapshot (if running in VM/Docker/LXC)"
Write-Host "  2. This allows easy rollback in case of issues`n"

if (-not $DryRun)
{
    $response = Read-Host "Have you created a VM/Container snapshot? (y/N)"
    if ($response -ne "y" -and $response -ne "Y")
    {
        Write-Host "${Yellow}Please create a VM/Container snapshot first and run the script again.${Reset}" -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""
}

# Check if Jellyfin is running and warn (skip in DryRun mode)
if (-not $DryRun)
{
    $jellyfinRunning = systemctl is-active jellyfin 2>$null
    if ($jellyfinRunning -eq "active")
    {
        Write-Host "${Yellow}WARNING: Jellyfin is still running!${Reset}" -ForegroundColor Yellow
        Write-Host "It is recommended to stop Jellyfin first:"
        Write-Host "  sudo systemctl stop jellyfin`n"
        
        $response = Read-Host "Continue anyway? (y/N)"
        if ($response -ne "y" -and $response -ne "Y")
        {
            Write-Host "Aborted."
            exit 0
        }
    }
}

# Find Jellyfin database (10.11+ uses jellyfin.db)
$dbPath = Join-Path $JellyfinDataPath "data/jellyfin.db"

if (-not (Test-Path $dbPath))
{
    Write-Host "${Red}Error: Database not found at: $dbPath${Reset}" -ForegroundColor Red
    Write-Host "This script is for Jellyfin 10.11+. For older versions, the database is called 'library.db'"
    Write-Host "Please specify the correct path with -JellyfinDataPath"
    exit 1
}

Write-Host "Database found: $dbPath`n"

# Check for sqlite3
if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue))
{
    Write-Host "${Red}Error: sqlite3 is not installed${Reset}" -ForegroundColor Red
    Write-Host "Install with: sudo apt install sqlite3"
    exit 1
}

# Create backup (skip in DryRun mode)
if (-not $DryRun)
{
    Write-Host "================================================"
    $response = Read-Host "Do you want to create a database backup? (Y/n)"
    
    if ($response -ne "n" -and $response -ne "N")
    {
        $backupPath = "$dbPath.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Write-Host "Creating backup: $backupPath"
        Copy-Item $dbPath $backupPath
        Write-Host "${Green}Backup created!${Reset}`n" -ForegroundColor Green
    }
    else
    {
        Write-Host "${Yellow}Skipping database backup.${Reset}`n" -ForegroundColor Yellow
    }
}
else
{
    Write-Host "${Yellow}DRY RUN mode - Skipping backup${Reset}`n" -ForegroundColor Yellow
}

# Get all media with paths from database (10.11+ structure)
Write-Host "Reading media from database..."

# Only check Episodes and Movies - Jellyfin will clean up empty Seasons/Series automatically
# Type is full .NET class name like MediaBrowser.Controller.Entities.TV.Episode
$query = @"
SELECT 
    Id,
    Type,
    Name,
    Path
FROM BaseItems
WHERE Path IS NOT NULL
    AND Path != ''
    AND Path NOT LIKE '%MetadataPath%'
    AND (
        Type LIKE '%.Episode'
        OR Type LIKE '%.Movie'
    )
ORDER BY Type, Name;
"@

$tempFile = [System.IO.Path]::GetTempFileName()
$query | Out-File -FilePath $tempFile -Encoding UTF8

$results = sqlite3 $dbPath ".read $tempFile" 2>&1
Remove-Item $tempFile

if (-not $results -or $LASTEXITCODE -ne 0)
{
    Write-Host "${Red}Error: Could not read from database.${Reset}" -ForegroundColor Red
    Write-Host "Query error: $results"
    exit 1
}

# Parse results
$missing = @()
$found = 0

foreach ($line in $results)
{
    if ([string]::IsNullOrWhiteSpace($line))
    {
        continue
    }
    
    $parts = $line -split '\|'
    if ($parts.Count -lt 4)
    {
        continue
    }
    
    $id = $parts[0]
    $type = $parts[1]
    $name = $parts[2]
    $path = $parts[3]
    
    if (-not (Test-Path $path))
    {
        $missing += [PSCustomObject]@{
            ID = $id
            Type = $type
            Name = $name
            Path = $path
        }
    }
    else
    {
        $found++
    }
}

Write-Host "`nResult:"
Write-Host "  ${Green}Found: $found${Reset}" -ForegroundColor Green
Write-Host "  ${Red}Missing: $($missing.Count)${Reset}" -ForegroundColor Red

if ($missing.Count -eq 0)
{
    Write-Host "`n${Green}All media files are present!${Reset}" -ForegroundColor Green
    exit 0
}

# Show missing files
Write-Host "`n${Red}Missing media files:${Reset}" -ForegroundColor Red
Write-Host "================================================"

$missing | ForEach-Object {
    Write-Host "`n[$($_.Type)] $($_.Name)"
    Write-Host "  Path: $($_.Path)"
    Write-Host "  ID: $($_.ID)"
}

if ($DryRun)
{
    Write-Host "`n${Yellow}DRY RUN mode - No changes will be made${Reset}" -ForegroundColor Yellow
    Write-Host "${Yellow}Found $($missing.Count) entries that would be deleted.${Reset}" -ForegroundColor Yellow
    exit 0
}

# Ask for deletion
Write-Host "`n================================================"
$response = Read-Host "Do you want to delete these $($missing.Count) entries from the database? (y/N)"

if ($response -ne "y" -and $response -ne "Y")
{
    Write-Host "No changes made."
    exit 0
}

# Delete entries
Write-Host "`nDeleting entries..."
$deleted = 0

foreach ($item in $missing)
{
    $deleteQuery = "DELETE FROM BaseItems WHERE Id = '$($item.ID)';"
    $result = sqlite3 $dbPath "$deleteQuery" 2>&1
    
    if ($LASTEXITCODE -eq 0)
    {
        $deleted++
        Write-Host "  ${Green}✓${Reset} Deleted: [$($item.Type)] $($item.Name)" -ForegroundColor Green
    }
    else
    {
        Write-Host "  ${Red}✗${Reset} Error with: $($item.Name)" -ForegroundColor Red
    }
}

Write-Host "`n${Green}Done! $deleted of $($missing.Count) entries deleted.${Reset}" -ForegroundColor Green
Write-Host "`nPlease restart Jellyfin and run a library scan:"
Write-Host "  sudo systemctl start jellyfin"
Write-Host "`nNote: Jellyfin 10.11+ uses a new database structure."
Write-Host "If you still see duplicates, try a full library rescan in Jellyfin."
