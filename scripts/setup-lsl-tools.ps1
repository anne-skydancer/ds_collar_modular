# PowerShell wrapper for LSL tools setup
# Launches the bash setup script in Git Bash environment

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "LSL Development Tools Setup (PowerShell)"
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
    Write-Host ""
    Write-Host "Please install Git for Windows from:" -ForegroundColor Yellow
    Write-Host "  https://git-scm.com/download/win" -ForegroundColor Cyan
    exit 1
}

Write-Host "✅ Found Git Bash: $gitBash" -ForegroundColor Green
Write-Host ""

# Get the script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupScript = Join-Path $scriptDir "setup-lsl-tools.sh"

if (-not (Test-Path $setupScript)) {
    Write-Host "❌ Setup script not found: $setupScript" -ForegroundColor Red
    exit 1
}

# Convert Windows path to Git Bash path
$setupScriptBash = $setupScript -replace '\\', '/' -replace '^([A-Z]):', {param($m) "/$(($m.Groups[1].Value).ToLower())"}

Write-Host "Running setup script in Git Bash..." -ForegroundColor Cyan
Write-Host "Script: $setupScriptBash" -ForegroundColor Gray
Write-Host ""
Write-Host "----------------------------------------"
Write-Host ""

# Execute the bash script
& $gitBash -l -c "cd '$setupScriptBash' && bash '$setupScriptBash'"

$exitCode = $LASTEXITCODE

Write-Host ""
Write-Host "----------------------------------------"
Write-Host ""

if ($exitCode -eq 0) {
    Write-Host "✅ Setup completed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "To use the tools, open Git Bash and run:" -ForegroundColor Yellow
    Write-Host "  lslint <file.lsl>" -ForegroundColor Cyan
    Write-Host "  lslopt <file.lsl>" -ForegroundColor Cyan
} else {
    Write-Host "❌ Setup failed with exit code: $exitCode" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common issues:" -ForegroundColor Yellow
    Write-Host "  - MinGW build tools not installed" -ForegroundColor Gray
    Write-Host "  - Python not installed" -ForegroundColor Gray
    Write-Host "  - Network connectivity issues" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Press any key to continue..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
