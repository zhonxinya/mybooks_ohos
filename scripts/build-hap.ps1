<#
.SYNOPSIS
    Build the HarmonyOS HAP package with hvigor (ArkTS + C++ NAPI).
#>

param(
  [ValidateSet("debug", "release", "profile")]
  [string]$BuildMode = "debug",
  [switch]$Clean,
  [switch]$Launch
)

$ErrorActionPreference = "Stop"
$buildScript = Join-Path $PSScriptRoot "build.ps1"

$buildArgs = @{
  Mode = $BuildMode
}
if (-not $Clean) {
  $buildArgs.SkipClean = $true
}

& $buildScript @buildArgs
if ($LASTEXITCODE -ne 0) {
  exit 1
}

if ($Launch) {
  & (Join-Path $PSScriptRoot "install.ps1") -Launch
  exit $LASTEXITCODE
}

Write-Host "Done." -ForegroundColor Green
