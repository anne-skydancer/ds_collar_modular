# PowerShell script to extract required OpenSimulator components for LSL test harness
# Run this from the test_harness directory

$ErrorActionPreference = "Stop"

Write-Host "=== OpenSimulator Component Extractor ===" -ForegroundColor Cyan

# Check if opensim_source exists
if (-not (Test-Path "opensim_source")) {
    Write-Host "Cloning OpenSimulator source..." -ForegroundColor Yellow
    git clone --depth 1 https://github.com/opensim/opensim.git opensim_source
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to clone OpenSimulator" -ForegroundColor Red
        exit 1
    }
}

# Create extract directory structure
Write-Host "Creating extract directory structure..." -ForegroundColor Yellow
$extractDir = "extract"
New-Item -ItemType Directory -Force -Path "$extractDir/LSL_Types" | Out-Null
New-Item -ItemType Directory -Force -Path "$extractDir/ScriptEngine" | Out-Null
New-Item -ItemType Directory -Force -Path "$extractDir/Tests" | Out-Null

# List of files to extract from YEngine
$filesToCopy = @(
    # ===== CORE LSL TYPES =====
    @{
        Source = "OpenSim/Region/ScriptEngine/Shared/LSL_Types.cs"
        Dest = "$extractDir/LSL_Types.cs"
        Category = "Core Types"
    },
    
    # ===== YENGINE COMPILER =====
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptCompile.cs"
        Dest = "$extractDir/YEngine/MMRScriptCompile.cs"
        Category = "Compiler"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptCodeGen.cs"
        Dest = "$extractDir/YEngine/MMRScriptCodeGen.cs"
        Category = "Compiler"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptTokenize.cs"
        Dest = "$extractDir/YEngine/MMRScriptTokenize.cs"
        Category = "Compiler"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptReduce.cs"
        Dest = "$extractDir/YEngine/MMRScriptReduce.cs"
        Category = "Compiler"
    },
    
    # ===== YENGINE RUNTIME =====
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/XMRInstance.cs"
        Dest = "$extractDir/YEngine/XMRInstance.cs"
        Category = "Runtime"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/XMRInstCtor.cs"
        Dest = "$extractDir/YEngine/XMRInstCtor.cs"
        Category = "Runtime"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/XMRInstMisc.cs"
        Dest = "$extractDir/YEngine/XMRInstMisc.cs"
        Category = "Runtime"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptObjCode.cs"
        Dest = "$extractDir/YEngine/MMRScriptObjCode.cs"
        Category = "Runtime"
    },
    
    # ===== LSL API INTERFACES =====
    @{
        Source = "OpenSim/Region/ScriptEngine/Shared/Api/Interface/ILSL_Api.cs"
        Dest = "$extractDir/Api/ILSL_Api.cs"
        Category = "API"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/Shared/Api/Runtime/LSL_Stub.cs"
        Dest = "$extractDir/Api/LSL_Stub.cs"
        Category = "API"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/Shared/ScriptBase/ScriptBaseClass.cs"
        Dest = "$extractDir/Api/ScriptBaseClass.cs"
        Category = "API"
    },
    
    # ===== EVENT SYSTEM =====
    @{
        Source = "OpenSim/Region/ScriptEngine/Shared/EventParams.cs"
        Dest = "$extractDir/Events/EventParams.cs"
        Category = "Events"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/Shared/DetectParams.cs"
        Dest = "$extractDir/Events/DetectParams.cs"
        Category = "Events"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRIEventHandlers.cs"
        Dest = "$extractDir/Events/MMRIEventHandlers.cs"
        Category = "Events"
    },
    
    # ===== TYPE SYSTEM =====
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptTypeCast.cs"
        Dest = "$extractDir/YEngine/MMRScriptTypeCast.cs"
        Category = "Types"
    },
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptConsts.cs"
        Dest = "$extractDir/YEngine/MMRScriptConsts.cs"
        Category = "Types"
    },
    
    # ===== INLINE FUNCTIONS =====
    @{
        Source = "OpenSim/Region/ScriptEngine/YEngine/MMRScriptInlines.cs"
        Dest = "$extractDir/YEngine/MMRScriptInlines.cs"
        Category = "Inlines"
    }
)

# Copy files by category
Write-Host "Extracting OpenSimulator YEngine components..." -ForegroundColor Yellow
$copiedCount = 0
$skippedCount = 0
$currentCategory = ""

foreach ($file in $filesToCopy) {
    if ($file.Category -ne $currentCategory) {
        $currentCategory = $file.Category
        Write-Host "`n  [$currentCategory]" -ForegroundColor Cyan
    }
    
    $sourcePath = Join-Path "opensim_source" $file.Source
    $destPath = $file.Dest
    
    # Create directory if needed
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    
    if (Test-Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $destPath -Force
        Write-Host "    âœ“ $([System.IO.Path]::GetFileName($destPath))" -ForegroundColor Green
        $copiedCount++
    } else {
        Write-Host "    âœ— NOT FOUND: $([System.IO.Path]::GetFileName($sourcePath))" -ForegroundColor Red
        $skippedCount++
    }
}  # End foreach

Write-Host "`nExtraction complete!" -ForegroundColor Cyan
Write-Host "  Copied: $copiedCount files" -ForegroundColor Green
if ($skippedCount -gt 0) {
    Write-Host "  Skipped: $skippedCount files (not found)" -ForegroundColor Yellow
}

# Create reference document
Write-Host "`nCreating component reference..." -ForegroundColor Yellow
$commitHash = git -C opensim_source rev-parse HEAD 2>$null
if (-not $commitHash) { $commitHash = "Unknown" }
$extractDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$refPath = Join-Path $extractDir "COMPONENTS.md"
$nl = [Environment]::NewLine
$content = "# Extracted OpenSimulator Components" + $nl + $nl
$content += "This directory contains minimal components extracted from OpenSimulator" + $nl
$content += "to enable standalone LSL script testing without a full simulator." + $nl + $nl
$content += "## Source" + $nl
$content += "OpenSimulator: https://github.com/opensim/opensim" + $nl
$content += "Commit: $commitHash" + $nl
$content += "Extracted: $extractDate" + $nl + $nl
$content += "## Files Extracted" + $nl + $nl
foreach ($file in $filesToCopy) {
    $content += "- $($file.Source) -> $($file.Dest)" + $nl
}
$content += $nl + "## License" + $nl + $nl
$content += "All extracted components are from OpenSimulator and are licensed under" + $nl
$content += "the BSD 3-Clause License. See opensim_source/LICENSE.txt for details." + $nl + $nl
$content += "## Modifications" + $nl + $nl
$content += "These files may be modified to remove dependencies on full OpenSimulator" + $nl
$content += "infrastructure and add mock implementations for testing. All modifications" + $nl
$content += "are clearly marked with comments." + $nl
$content | Out-File -FilePath $refPath -Encoding UTF8

Write-Host "Created component reference: $refPath" -ForegroundColor Green

Write-Host "`n=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. Review extracted files in $extractDir/" -ForegroundColor White
Write-Host "2. Build test harness: dotnet build LSLTestHarness.csproj" -ForegroundColor White
Write-Host "3. Run tests: dotnet test DSCollarTests.csproj" -ForegroundColor White
