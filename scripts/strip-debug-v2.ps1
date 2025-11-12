# Aggressive debug stripping - handles multi-line logd() calls and nested blocks

$stableFiles = Get-ChildItem "src\stable\*.lsl"

foreach ($file in $stableFiles) {
    Write-Host "Processing: $($file.Name)"
    
    $lines = Get-Content $file.FullName
    $output = @()
    $skipUntilBrace = 0
    $inDebugBlock = $false
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Skip DEBUG/PRODUCTION declarations
        if ($line -match '^\s*integer (DEBUG|PRODUCTION) =') {
            continue
        }
        
        # Skip logd() function definition start
        if ($line -match '^\s*(integer\s+)?logd\(') {
            # Skip until we find the closing brace
            $braceCount = ($line -split '\{').Count - ($line -split '\}').Count
            while ($braceCount -gt 0 -and $i -lt $lines.Count - 1) {
                $i++
                $braceCount += ($lines[$i] -split '\{').Count - ($lines[$i] -split '\}').Count
            }
            continue
        }
        
        # Skip logd() calls (may span multiple lines)
        if ($line -match '\s+logd\(') {
            # Count parentheses to find end of call
            $parenCount = ($line -split '\(').Count - ($line -split '\)').Count
            while ($parenCount -gt 0 -and $i -lt $lines.Count - 1) {
                $i++
                $parenCount += ($lines[$i] -split '\(').Count - ($lines[$i] -split '\)').Count
            }
            continue
        }
        
        # Skip DEBUG-gated blocks
        if ($line -match 'if \(DEBUG && !PRODUCTION\)') {
            # Skip the opening brace line if on same line or next line
            $braceCount = ($line -split '\{').Count - ($line -split '\}').Count
            if ($braceCount -eq 0 -and $i -lt $lines.Count - 1 -and $lines[$i+1] -match '^\s*\{') {
                $i++
                $braceCount = 1
            }
            # Skip until matching closing brace
            while ($braceCount -gt 0 -and $i -lt $lines.Count - 1) {
                $i++
                $braceCount += ($lines[$i] -split '\{').Count - ($lines[$i] -split '\}').Count
            }
            continue
        }
        
        # Keep this line
        $output += $line
    }
    
    # Write back
    $output | Set-Content $file.FullName
    
    Write-Host "  Cleaned: $($file.Name) ($($lines.Count) -> $($output.Count) lines)"
}

Write-Host "`nDone! Processed $($stableFiles.Count) files."
