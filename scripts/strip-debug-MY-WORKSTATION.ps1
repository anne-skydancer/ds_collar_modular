# Strip all debug infrastructure from stable branch
# This removes DEBUG/PRODUCTION flags, logd() functions, and all debug calls

$stableFiles = Get-ChildItem "src\stable\*.lsl"

foreach ($file in $stableFiles) {
    Write-Host "Processing: $($file.Name)"
    
    $content = Get-Content $file.FullName -Raw
    
    # Remove DEBUG and PRODUCTION flag lines
    $content = $content -replace '(?m)^integer DEBUG = (TRUE|FALSE);.*$\r?\n', ''
    $content = $content -replace '(?m)^integer PRODUCTION = (TRUE|FALSE);.*$\r?\n', ''
    
    # Remove logd() function definitions (multi-line)
    # Pattern: integer logd(string msg) { ... return ...; }
    $content = $content -replace '(?s)integer logd\(string msg\) \{[^}]+return[^}]+\}', ''
    # Also catch version without integer return type
    $content = $content -replace '(?s)logd\(string msg\) \{[^}]+\}', ''
    
    # Remove all logd() calls
    $content = $content -replace '(?m)^\s+logd\([^)]+\);.*$\r?\n', ''
    
    # Remove DEBUG-gated blocks: if (DEBUG && !PRODUCTION) { ... }
    # This is tricky - need to handle nested braces
    # Simpler approach: remove single-line debug checks
    $content = $content -replace '(?m)^\s+if \(DEBUG && !PRODUCTION\).*$\r?\n', ''
    
    # Remove orphaned closing braces that were part of debug blocks
    # This is imperfect - may need manual cleanup
    
    # Clean up multiple consecutive blank lines
    $content = $content -replace '(?m)^\r?\n\r?\n\r?\n+', "`r`n`r`n"
    
    # Save back
    Set-Content $file.FullName $content -NoNewline
    
    Write-Host "  Cleaned: $($file.Name)"
}

Write-Host "`nDone! Processed $($stableFiles.Count) files."
Write-Host "IMPORTANT: Review files for syntax errors, especially around removed debug blocks."
