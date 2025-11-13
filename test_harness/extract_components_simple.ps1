# PowerShell script to extract required OpenSimulator components for LSL test harness

Write-Host "=== OpenSimulator Component Extractor ===" -ForegroundColor Cyan

# Check if opensim_source exists
if (-not (Test-Path "opensim_source")) {
    Write-Host "Cloning OpenSimulator source..." -ForegroundColor Yellow
    git clone --depth 1 https://github.com/opensim/opensim.git opensim_source
}

# Create extract directory structure
Write-Host "Creating extract directory structure..." -ForegroundColor Yellow
$extractDir = "extract"
New-Item -ItemType Directory -Force -Path "$extractDir" | Out-Null
New-Item -ItemType Directory -Force -Path "$extractDir/YEngine" | Out-Null
New-Item -ItemType Directory -Force -Path "$extractDir/Api" | Out-Null
New-Item -ItemType Directory -Force -Path "$extractDir/Events" | Out-Null

# Define files to extract
$filesToExtract = @{
    # Core Types
    "OpenSim/Region/ScriptEngine/Shared/LSL_Types.cs" = "$extractDir/LSL_Types.cs"
    
    # YEngine Compiler
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptCompile.cs" = "$extractDir/YEngine/MMRScriptCompile.cs"
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptCodeGen.cs" = "$extractDir/YEngine/MMRScriptCodeGen.cs"
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptTokenize.cs" = "$extractDir/YEngine/MMRScriptTokenize.cs"
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptReduce.cs" = "$extractDir/YEngine/MMRScriptReduce.cs"
    
    # YEngine Runtime
    "OpenSim/Region/ScriptEngine/YEngine/XMRInstance.cs" = "$extractDir/YEngine/XMRInstance.cs"
    "OpenSim/Region/ScriptEngine/YEngine/XMRInstCtor.cs" = "$extractDir/YEngine/XMRInstCtor.cs"
    "OpenSim/Region/ScriptEngine/YEngine/XMRInstMisc.cs" = "$extractDir/YEngine/XMRInstMisc.cs"
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptObjCode.cs" = "$extractDir/YEngine/MMRScriptObjCode.cs"
    
    # API
    "OpenSim/Region/ScriptEngine/Shared/Api/Interface/ILSL_Api.cs" = "$extractDir/Api/ILSL_Api.cs"
    "OpenSim/Region/ScriptEngine/Shared/Api/Runtime/LSL_Stub.cs" = "$extractDir/Api/LSL_Stub.cs"
    "OpenSim/Region/ScriptEngine/Shared/ScriptBase/ScriptBaseClass.cs" = "$extractDir/Api/ScriptBaseClass.cs"
    
    # Events
    "OpenSim/Region/ScriptEngine/Shared/EventParams.cs" = "$extractDir/Events/EventParams.cs"
    "OpenSim/Region/ScriptEngine/Shared/DetectParams.cs" = "$extractDir/Events/DetectParams.cs"
    "OpenSim/Region/ScriptEngine/YEngine/MMRIEventHandlers.cs" = "$extractDir/Events/MMRIEventHandlers.cs"
    
    # Type System
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptTypeCast.cs" = "$extractDir/YEngine/MMRScriptTypeCast.cs"
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptConsts.cs" = "$extractDir/YEngine/MMRScriptConsts.cs"
    
    # Inlines
    "OpenSim/Region/ScriptEngine/YEngine/MMRScriptInlines.cs" = "$extractDir/YEngine/MMRScriptInlines.cs"
}

# Copy files
Write-Host "Extracting OpenSimulator YEngine components..." -ForegroundColor Yellow
$copiedCount = 0
$skippedCount = 0

foreach ($source in $filesToExtract.Keys) {
    $sourcePath = Join-Path "opensim_source" $source
    $destPath = $filesToExtract[$source]
    
    if (Test-Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $destPath -Force
        $fileName = Split-Path $destPath -Leaf
        Write-Host "  ✓ $fileName" -ForegroundColor Green
        $copiedCount++
    }
    else {
        $fileName = Split-Path $sourcePath -Leaf
        Write-Host "  ✗ NOT FOUND: $fileName" -ForegroundColor Red
        $skippedCount++
    }
}

Write-Host ""
Write-Host "Extraction complete!" -ForegroundColor Cyan
Write-Host "  Copied: $copiedCount files" -ForegroundColor Green
if ($skippedCount -gt 0) {
    Write-Host "  Skipped: $skippedCount files (not found)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. Review extracted files in $extractDir/" -ForegroundColor White
Write-Host "2. See YENGINE_INTEGRATION.md for integration guide" -ForegroundColor White
