<#
.SYNOPSIS
  d2t - Run D2 with the house font (Arial) and Tala layout engine on Windows.
  Matches the phd / work slide themes.

.EXAMPLE
  d2t figures\pipeline.d2 figures\pipeline.svg
  d2t --watch figures\pipeline.d2 figures\pipeline.svg
#>

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$D2Args
)

$ErrorActionPreference = 'Stop'

# Locate Arial font files in Windows Fonts directory
$fontDir = "$env:SystemRoot\Fonts"
$fontReg = Join-Path $fontDir "arial.ttf"
$fontIta = Join-Path $fontDir "ariali.ttf"
$fontBld = Join-Path $fontDir "arialbd.ttf"

$extraArgs = @()

if ((Test-Path $fontReg) -and (Test-Path $fontIta) -and (Test-Path $fontBld)) {
    $extraArgs += @(
        "--font-regular", $fontReg,
        "--font-italic",  $fontIta,
        "--font-bold",    $fontBld,
        "--font-semibold", $fontBld
    )
} else {
    Write-Warning "d2t: Arial not found in $fontDir; falling back to D2's default font."
}

# Default to Tala layout engine if neither --layout nor D2_LAYOUT is explicitly provided
$hasLayoutArg = $false
foreach ($arg in $D2Args) {
    if ($arg -like "--layout*" -or $arg -like "-l*") {
        $hasLayoutArg = $true
        break
    }
}

if (-not $hasLayoutArg -and -not $env:D2_LAYOUT) {
    $extraArgs += @("--layout", "tala")
}

# Invoke D2
$allArgs = $extraArgs + $D2Args
& d2 $allArgs
exit $LASTEXITCODE
