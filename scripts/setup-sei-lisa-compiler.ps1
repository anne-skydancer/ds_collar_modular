# PowerShell wrapper for Sei-Lisa Compiler setup
# Launches the bash setup script in Git Bash environment

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "Sei-Lisa Compiler Setup (PowerShell)"
Write-Host "========================================"
Write-Host ""

# Find Git Bash
$gitBashPaths = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
)

$gitBash = $null
foreach ($path in $gitBashPaths) {
    if (Test-Path $path) {
        $gitBash = $path
        break
    }
}

if (-not $gitBash) {
    Write-Host "❌ Git Bash not found at standard locations." -ForegroundColor Red
    exit 1
}

Write-Host "✅ Found Git Bash: $gitBash" -ForegroundColor Green
Write-Host ""

# Get the script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupScript = Join-Path $scriptDir "setup-sei-lisa-compiler.sh"

if (-not (Test-Path $setupScript)) {
    Write-Host "❌ Setup script not found: $setupScript" -ForegroundColor Red
    exit 1
}

# Convert Windows path to Git Bash path
$setupScriptBash = $setupScript -replace '\\', '/'
if ($setupScriptBash -match '^([A-Z]):') {
    $drive = $matches[1].ToLower()
    $setupScriptBash = $setupScriptBash -replace '^[A-Z]:', "/$drive"
}

$scriptDirBash = $scriptDir -replace '\\', '/'
if ($scriptDirBash -match '^([A-Z]):') {
    $drive = $matches[1].ToLower()
    $scriptDirBash = $scriptDirBash -replace '^[A-Z]:', "/$drive"
}

Write-Host "Running setup script in Git Bash..." -ForegroundColor Cyan
Write-Host "Script: $setupScriptBash" -ForegroundColor Gray
Write-Host ""
Write-Host "----------------------------------------"
Write-Host ""

# Execute the bash script
& $gitBash -l -c "cd '$scriptDirBash' && bash 'setup-sei-lisa-compiler.sh'"

$exitCode = $LASTEXITCODE

Write-Host ""
Write-Host "----------------------------------------"
Write-Host ""

if ($exitCode -eq 0) {
    Write-Host "✅ Setup completed successfully!" -ForegroundColor Green
} else {
    Write-Host "❌ Setup failed with exit code: $exitCode" -ForegroundColor Red
    Write-Host ""
    Write-Host "Note: This script requires build tools (flex, bison, g++)" -ForegroundColor Yellow
    Write-Host "which may not be present in standard Git Bash." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
