param(
  [ValidateSet("debug", "release", "profile")]
  [string]$Mode = "debug",
  [switch]$SkipClean
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string]$Message)
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Initialize-DevEcoEnvironment {
  $devecoRoot = "C:\Program Files\Huawei\DevEco Studio"
  $javaHome = Join-Path $devecoRoot "jbr"
  if (-not $env:JAVA_HOME -and (Test-Path "$javaHome\bin\java.exe")) {
    $env:JAVA_HOME = $javaHome
    $env:PATH = "$javaHome\bin;$env:PATH"
  }
  if (-not $env:DEVECO_SDK_HOME) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA "Huawei\Sdk"
    if (Test-Path $defaultSdk) {
      $env:DEVECO_SDK_HOME = $defaultSdk
    }
  }
  return Join-Path $devecoRoot "tools\hvigor\bin\hvigorw.bat"
}

function Get-ProjectPaths {
  param([string]$ScriptRoot)
  $projectRoot = Split-Path -Parent $ScriptRoot
  [PSCustomObject]@{
    Root = $projectRoot
    Ohos = Join-Path $projectRoot "ohos"
    Hvigor = Initialize-DevEcoEnvironment
    LibCurl = Join-Path $projectRoot "ohos\entry\libs\arm64-v8a\libcurl.so"
    HapDir = Join-Path $projectRoot "ohos\entry\build\default\outputs\default"
  }
}

function Test-NativeBuildPrerequisites {
  param($Paths)
  if (-not (Test-Path $Paths.Ohos)) {
    Write-Host "ERROR: ohos/ directory not found" -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Path $Paths.Hvigor)) {
    Write-Host "ERROR: hvigorw.bat not found at $($Paths.Hvigor)" -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Path $Paths.LibCurl)) {
    Write-Host "ERROR: libcurl.so not found" -ForegroundColor Red
    Write-Host "  Expected: $($Paths.LibCurl)" -ForegroundColor Gray
    Write-Host "  See: ohos/third_party/README.md" -ForegroundColor Gray
    exit 1
  }
}

function Clear-NativeBuildCache {
  param($Paths)
  Write-Step "Cleaning native build cache..."
  $targets = @(
    (Join-Path $Paths.Ohos "entry\build"),
    (Join-Path $Paths.Ohos "entry\.cxx"),
    (Join-Path $Paths.Ohos ".hvigor\outputs")
  )
  foreach ($target in $targets) {
    if (Test-Path $target) {
      Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Write-Host "Clean complete" -ForegroundColor Green
}

function Find-LatestHap {
  param([string]$HapDir)
  if (-not (Test-Path $HapDir)) {
    return $null
  }
  $signed = Get-ChildItem -Path $HapDir -Filter "*-signed.hap" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($signed) {
    return $signed
  }
  return Get-ChildItem -Path $HapDir -Filter "*.hap" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HarmonyOS Native Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$paths = Get-ProjectPaths -ScriptRoot $PSScriptRoot
Test-NativeBuildPrerequisites -Paths $paths

if (-not $SkipClean) {
  Clear-NativeBuildCache -Paths $paths
  Write-Host ""
}

Write-Step "Building HAP ($Mode)..."
Push-Location $paths.Ohos
# hvigor 会把 CMake/ninja 的 WARN 写到 stderr，避免 PowerShell 将其视为终止错误
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
  & $paths.Hvigor assembleHap -p product=default -p "buildMode=$Mode" --no-daemon
  $buildExitCode = $LASTEXITCODE
}
finally {
  $ErrorActionPreference = $previousErrorAction
  Pop-Location
}

if ($buildExitCode -ne 0) {
  Write-Host ""
  Write-Host "Build failed" -ForegroundColor Red
  exit 1
}

$hapFile = Find-LatestHap -HapDir $paths.HapDir
if (-not $hapFile) {
  Write-Host "ERROR: No HAP found in $($paths.HapDir)" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "Build successful!" -ForegroundColor Green
Write-Host "  Path: $($hapFile.FullName)" -ForegroundColor Gray
Write-Host "  Size: $([math]::Round($hapFile.Length / 1MB, 2)) MB" -ForegroundColor Gray
Write-Host "  Time: $($hapFile.LastWriteTime)" -ForegroundColor Gray
Write-Host ""
Write-Host "Install: .\scripts\install.ps1" -ForegroundColor Cyan
Write-Host "Build + install: .\scripts\build-and-install.ps1 -Launch" -ForegroundColor Cyan
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
