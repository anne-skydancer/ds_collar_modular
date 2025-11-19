param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [string]$Distribution = "Ubuntu-24.04",

    [Parameter(Position = 2)]
    [string]$Binary = "/home/anne/.local/bin/lslcomp"
)

function Convert-ToWslPath {
    param([string]$WindowsPath)

    $resolved = $WindowsPath -replace '\\', '/'
    if ($resolved -match '^([A-Za-z]):(.*)$') {
        $drive = $matches[1].ToLower()
        $pathTail = $matches[2]
        if ($pathTail.StartsWith('/')) {
            return "/mnt/$drive$pathTail"
        }
        return "/mnt/$drive/$pathTail"
    }
    return $resolved
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    Write-Error "Input file not found: $InputPath"
    exit 1
}

$fullPath = (Resolve-Path -LiteralPath $InputPath).ProviderPath
if ([System.IO.Path]::GetExtension($fullPath).ToLower() -ne ".lsl") {
    Write-Warning "Input file does not use .lsl extension; continuing anyway."
}

$wslPath = Convert-ToWslPath -WindowsPath $fullPath
$wslBase = [System.IO.Path]::ChangeExtension($wslPath, $null)

if (-not $wslBase) {
    Write-Error "Unable to derive base filename for $InputPath"
    exit 1
}

$commandDescription = "wsl -d $Distribution -- $Binary $wslBase"
Write-Host "Running: $commandDescription"
& wsl -d $Distribution -- $Binary $wslBase
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Error "lslcomp failed with exit code $exitCode"
    exit $exitCode
}
