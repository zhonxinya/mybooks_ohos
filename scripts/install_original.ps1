param(
  [string]$DeviceId = "",
  [switch]$Launch,
  [switch]$CleanData
)

# ???????????? IPv6
try {
  # ??? .NET ?????DNS ?????? IPv6
  [System.Net.ServicePointManager]::DnsRefreshTimeout = 0
}
catch {
  # ?????????,???????????}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HarmonyOS App Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$PROJECT_ROOT = Split-Path -Parent $PSScriptRoot
$HDC_PATH = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$BUNDLE_NAME = "com.zhongxinya.talebook"
$ABILITY_NAME = "EntryAbility"

if (-not (Test-Path $HDC_PATH)) {
  Write-Host "Error: HDC not found" -ForegroundColor Red
  exit 1
}

$HAP_OUTPUT_DIR = Join-Path $PROJECT_ROOT "build\ohos\hap"
$HAP_FILE = Get-ChildItem -Path $HAP_OUTPUT_DIR -Filter "*.hap" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $HAP_FILE) {
  Write-Host "Error: No HAP file found. Please run build.ps1 first." -ForegroundColor Red
  exit 1
}

Write-Host "HAP Package:" -ForegroundColor Yellow
Write-Host "   File: $($HAP_FILE.Name)" -ForegroundColor Gray
Write-Host "   Size: $([math]::Round($HAP_FILE.Length / 1MB, 2)) MB" -ForegroundColor Gray
Write-Host ""

Write-Host "Checking devices..." -ForegroundColor Yellow
$devicesOutput = & $HDC_PATH list targets 2>&1

if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: Cannot execute HDC command" -ForegroundColor Red
  exit 1
}

$devices = @()
foreach ($line in $devicesOutput) {
  $trimmed = $line.Trim()
  # ??????????????  if ($trimmed -match '^\S+' -and $trimmed -ne '[Empty]' -and $trimmed -notmatch '^$') {
    $devices += $trimmed
  }
}

if ($devices.Count -eq 0) {
  Write-Host "Error: No devices detected" -ForegroundColor Red
  Write-Host ""
  Write-Host "Tips:" -ForegroundColor Cyan
  Write-Host "   1. Connect device via USB" -ForegroundColor Gray
  Write-Host "   2. Enable Developer Mode and USB Debugging" -ForegroundColor Gray
  Write-Host "   3. Authorize HDC debugging" -ForegroundColor Gray
  Write-Host "   4. Run hdc list targets to verify" -ForegroundColor Gray
  Write-Host ""
  exit 1
}

Write-Host "Detected $($devices.Count) device(s):" -ForegroundColor Green
for ($i = 0; $i -lt $devices.Count; $i++) {
  $marker = if ($devices[$i] -eq $DeviceId) { " <-- selected" } else { "" }
  Write-Host "   [$i] $($devices[$i])$marker" -ForegroundColor Gray
}
Write-Host ""

$TARGET_DEVICE = $DeviceId
if (-not $TARGET_DEVICE) {
  if ($devices.Count -eq 1) {
    $TARGET_DEVICE = $devices[0]
    Write-Host "Auto-selected device: $TARGET_DEVICE" -ForegroundColor Yellow
  }
  else {
    $selection = Read-Host "Select device number (default 0)"
    if ([string]::IsNullOrWhiteSpace($selection)) {
      $selection = 0
    }
    $TARGET_DEVICE = $devices[[int]$selection]
    Write-Host "Selected device: $TARGET_DEVICE" -ForegroundColor Yellow
  }
  Write-Host ""
}

if ($CleanData) {
  Write-Host "Clearing app data..." -ForegroundColor Yellow
  & $HDC_PATH -t $TARGET_DEVICE shell bm uninstall -n $BUNDLE_NAME 2>&1 | Out-Null
  Write-Host "Data cleared" -ForegroundColor Green
}
else {
  Write-Host "Installing update (preserving app data)..." -ForegroundColor Yellow
}
Write-Host ""

Write-Host "Installing app to device..." -ForegroundColor Yellow
$installOutput = & $HDC_PATH -t $TARGET_DEVICE app install -r $HAP_FILE.FullName 2>&1

if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Installation failed" -ForegroundColor Red
  Write-Host "Output: $installOutput" -ForegroundColor Gray
  exit 1
}

Write-Host "Installation successful!" -ForegroundColor Green
Write-Host ""

if ($Launch) {
  Write-Host "Launching app..." -ForegroundColor Yellow
  & $HDC_PATH -t $TARGET_DEVICE shell aa start -a $ABILITY_NAME -b $BUNDLE_NAME
    
  if ($LASTEXITCODE -eq 0) {
    Write-Host "App launched" -ForegroundColor Green
  }
  else {
    Write-Host "Failed to launch, please open manually" -ForegroundColor Yellow
    # ???????????????????????? build-and-install ???????????????
    $global:LASTEXITCODE = 0
  }
  Write-Host ""
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "   View logs: hdc -t $TARGET_DEVICE hilog" -ForegroundColor Gray
Write-Host "   Start app: hdc -t $TARGET_DEVICE shell aa start -a $ABILITY_NAME -b $BUNDLE_NAME" -ForegroundColor Gray
Write-Host "   Stop app: hdc -t $TARGET_DEVICE shell aa force-stop $BUNDLE_NAME" -ForegroundColor Gray
Write-Host ""
