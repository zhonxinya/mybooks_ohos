param(
  [ValidateSet("debug", "release", "profile")]
  [string]$Mode = "debug",
  [switch]$Launch,
  [switch]$SkipClean,
  [switch]$CleanData
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HarmonyOS Build and Install" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$buildScript = Join-Path $PSScriptRoot "build.ps1"
$installScript = Join-Path $PSScriptRoot "install.ps1"

Write-Host "Step 1/2: Building app ($Mode)" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkCyan
Write-Host ""

$buildArgs = @{ Mode = $Mode }
if ($SkipClean) {
  $buildArgs.SkipClean = $true
}
& $buildScript @buildArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Build failed, aborting installation" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "Step 2/2: Installing to device" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor DarkCyan
Write-Host ""

& $installScript -Launch:$Launch -CleanData:$CleanData
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Installation failed" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  All Done!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
