# DS Collar Test Harness - Build and Test Script
# Run this to build and execute all tests

param(
    [switch]$Clean,
    [switch]$BuildOnly,
    [switch]$TestOnly,
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=== DS Collar LSL Test Harness ===" -ForegroundColor Cyan
Write-Host ""

# Check .NET installation
Write-Host "Checking .NET installation..." -ForegroundColor Yellow
$dotnetVersion = dotnet --version 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: .NET SDK not found" -ForegroundColor Red
    Write-Host "Install from: https://dotnet.microsoft.com/download" -ForegroundColor Yellow
    exit 1
}
Write-Host "  ✓ .NET version: $dotnetVersion" -ForegroundColor Green
Write-Host ""

# Clean if requested
if ($Clean) {
    Write-Host "Cleaning build artifacts..." -ForegroundColor Yellow
    dotnet clean LSLTestHarness.csproj --nologo --verbosity quiet
    dotnet clean DSCollarTests.csproj --nologo --verbosity quiet
    Write-Host "  ✓ Clean complete" -ForegroundColor Green
    Write-Host ""
}

# Build harness
if (-not $TestOnly) {
    Write-Host "Building test harness..." -ForegroundColor Yellow
    dotnet build LSLTestHarness.csproj --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ Harness build failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Harness built successfully" -ForegroundColor Green
    Write-Host ""

    Write-Host "Building test project..." -ForegroundColor Yellow
    dotnet build DSCollarTests.csproj --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ Test project build failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Test project built successfully" -ForegroundColor Green
    Write-Host ""
}

# Run tests
if (-not $BuildOnly) {
    Write-Host "Running tests..." -ForegroundColor Yellow
    Write-Host ""

    $testArgs = @("test", "DSCollarTests.csproj", "--no-build", "--nologo")
    
    if ($Filter -ne "") {
        $testArgs += "--filter"
        $testArgs += $Filter
        Write-Host "  Filter: $Filter" -ForegroundColor Cyan
    }

    & dotnet @testArgs
    
    $testExitCode = $LASTEXITCODE
    Write-Host ""

    if ($testExitCode -eq 0) {
        Write-Host "=== ALL TESTS PASSED ===" -ForegroundColor Green
    } else {
        Write-Host "=== SOME TESTS FAILED ===" -ForegroundColor Red
        Write-Host ""
        Write-Host "Common issues:" -ForegroundColor Yellow
        Write-Host "  1. EventInjector pattern matching may need adjustment" -ForegroundColor White
        Write-Host "  2. Script structure differs from expected patterns" -ForegroundColor White
        Write-Host "  3. Mock LSL functions need enhancement" -ForegroundColor White
        Write-Host ""
        Write-Host "To debug:" -ForegroundColor Yellow
        Write-Host "  dotnet test -v detailed --filter TestName" -ForegroundColor White
        exit $testExitCode
    }
}

Write-Host ""
Write-Host "=== Quick Commands ===" -ForegroundColor Cyan
Write-Host "  Build only:         .\run-tests.ps1 -BuildOnly" -ForegroundColor White
Write-Host "  Test only:          .\run-tests.ps1 -TestOnly" -ForegroundColor White
Write-Host "  Clean build:        .\run-tests.ps1 -Clean" -ForegroundColor White
Write-Host "  Filter tests:       .\run-tests.ps1 -Filter 'RoutingTests'" -ForegroundColor White
Write-Host "  Specific test:      .\run-tests.ps1 -Filter 'TestStrictRouting_AcceptsExactMatch'" -ForegroundColor White
Write-Host ""
Write-Host "See QUICKSTART.md for detailed usage" -ForegroundColor Cyan
