param(
  [string]$DeviceId = "",
  [switch]$Launch,
  [switch]$CleanData
)

$PROJECT_ROOT = Split-Path -Parent $PSScriptRoot
$LOG_FILE = Join-Path $PROJECT_ROOT "build\install.log"
$HDC_PATH = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$BUNDLE_NAME = "com.zhonxinya.talebook"
$ABILITY_NAME = "EntryAbility"

# 创建日志目录并清空上次日�?
$logDir = Split-Path -Parent $LOG_FILE
if (-not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
"" | Set-Content -Path $LOG_FILE

function Write-Log {
  param([string]$Message, [string]$Color = "Gray")
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$timestamp] $Message"
  Add-Content -Path $LOG_FILE -Value $line
  Write-Host $line -ForegroundColor $Color
}

# 配置网络优先使用 IPv6
try {
  # 配置 .NET 网络�?DNS 解析优先 IPv6
  [System.Net.ServicePointManager]::DnsRefreshTimeout = 0
}
catch {
  # 忽略配置错误,不影响安装流�?
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  HarmonyOS App Installer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Script root: $PROJECT_ROOT"
Write-Log "Log file: $LOG_FILE"

if (-not (Test-Path $HDC_PATH)) {
  Write-Host "Error: HDC not found" -ForegroundColor Red
  exit 1
}

function Test-InstallSucceeded {
  param(
    [int]$ExitCode,
    [string]$Output
  )
  if ($Output -match 'failed to install bundle') {
    return $false
  }
  if ($Output -match 'error:\s*no signature file') {
    return $false
  }
  if ($Output -match 'install bundle failed') {
    return $false
  }
  return ($ExitCode -eq 0)
}

function Find-InstallHap {
  param([string]$ProjectRoot)
  $searchDirs = @(
    (Join-Path $ProjectRoot "ohos\entry\build\default\outputs\default"),
    (Join-Path $ProjectRoot "build\ohos\hap")
  )
  foreach ($dir in $searchDirs) {
    if (-not (Test-Path $dir)) {
      continue
    }
    $signed = Get-ChildItem -Path $dir -Filter "*-signed.hap" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($signed) {
      return $signed
    }
    $hap = Get-ChildItem -Path $dir -Filter "*.hap" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($hap) {
      return $hap
    }
  }
  return $null
}

$HAP_FILE = Find-InstallHap -ProjectRoot $PROJECT_ROOT

if (-not $HAP_FILE) {
  Write-Host "Error: No HAP file found" -ForegroundColor Red
  Write-Host "   Expected: ohos\entry\build\default\outputs\default\*.hap" -ForegroundColor Gray
  Write-Host "   Run: .\scripts\build.ps1" -ForegroundColor Gray
  exit 1
}

Write-Host "HAP Package:" -ForegroundColor Yellow
Write-Host "   File: $($HAP_FILE.Name)" -ForegroundColor Gray
Write-Host "   Size: $([math]::Round($HAP_FILE.Length / 1MB, 2)) MB" -ForegroundColor Gray
Write-Host ""
Write-Log "HAP: $($HAP_FILE.Name), Size: $([math]::Round($HAP_FILE.Length / 1MB, 2)) MB, Modified: $($HAP_FILE.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"

Write-Host "Checking devices..." -ForegroundColor Yellow
$devicesOutput = & $HDC_PATH list targets 2>&1

if ($LASTEXITCODE -ne 0) {
  Write-Host "Error: Cannot execute HDC command" -ForegroundColor Red
  exit 1
}

$devices = @()
foreach ($line in $devicesOutput) {
  $trimmed = $line.Trim()
  # 过滤空设备和无效�?
  if ($trimmed -match '^\S+' -and $trimmed -ne '[Empty]' -and $trimmed -notmatch '^$') {
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
Write-Log "Target device: $TARGET_DEVICE"

# 获取设备信息和已安装版本
try {
  $osVer = & $HDC_PATH -t $TARGET_DEVICE shell param get const.product.software.version 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Log "Device OS: $osVer"
  }
} catch {
  Write-Log "Device OS: 获取失败"
}
try {
  $dumpOutput = & $HDC_PATH -t $TARGET_DEVICE shell bm dump -n $BUNDLE_NAME 2>&1
  $verLine = $dumpOutput | Select-String -Pattern "versionName" -SimpleMatch | Select-Object -First 1
  if ($verLine) {
    Write-Log "Installed: $($verLine.ToString().Trim())"
  } else {
    Write-Log "Installed: none"
  }
} catch {
  Write-Log "Installed: check failed"
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
$installStart = Get-Date
$installOutput = & $HDC_PATH -t $TARGET_DEVICE app install -r $HAP_FILE.FullName 2>&1
$installDuration = [math]::Round(((Get-Date) - $installStart).TotalSeconds, 1)
$installText = ($installOutput | Out-String)

if (-not (Test-InstallSucceeded -ExitCode $LASTEXITCODE -Output $installText)) {
  Write-Host ""
  Write-Log ("Update install FAILED (exit: " + $LASTEXITCODE + ", " + $installDuration + "s)") Red
  Write-Log "Raw output: $installText" Red
  Write-Host ""
  Write-Host "Retrying with clean install..." -ForegroundColor Yellow
  & $HDC_PATH -t $TARGET_DEVICE shell bm uninstall -n $BUNDLE_NAME 2>&1 | Out-Null
  $installStart = Get-Date
  $installOutput = & $HDC_PATH -t $TARGET_DEVICE app install $HAP_FILE.FullName 2>&1
  $installDuration = [math]::Round(((Get-Date) - $installStart).TotalSeconds, 1)
  $installText = ($installOutput | Out-String)

  if (-not (Test-InstallSucceeded -ExitCode $LASTEXITCODE -Output $installText)) {
    Write-Log ("Clean install FAILED (exit: " + $LASTEXITCODE + ", " + $installDuration + "s)") Red
    Write-Log "Raw output: $installText" Red
    Write-Log "Log saved to: $LOG_FILE"
    exit 1
  }

  Write-Log ("Clean install succeeded (" + $installDuration + "s)") Green
  Write-Host "Clean install succeeded" -ForegroundColor Green
}

Write-Log ("Installation succeeded (" + $installDuration + "s)") Green

Write-Host "Installation successful!" -ForegroundColor Green
Write-Host ""
Write-Log "Log saved to: $LOG_FILE"

if ($Launch) {
  Write-Host "Launching app..." -ForegroundColor Yellow
  $launchOutput = & $HDC_PATH -t $TARGET_DEVICE shell aa start -a $ABILITY_NAME -b $BUNDLE_NAME 2>&1
  $launchText = ($launchOutput | Out-String)

  $isLaunchFailed = ($LASTEXITCODE -ne 0) -or
    ($launchText -match "failed to start ability") -or
    ($launchText -match "Error Code:\s*10106102")

  if (-not $isLaunchFailed) {
    Write-Host "App launched" -ForegroundColor Green
  } else {
    if ($launchText -match "10106102") {
      Write-Host "App launch skipped: device screen is locked (10106102)" -ForegroundColor Yellow
      Write-Host "Please unlock the device and launch again." -ForegroundColor Yellow
    } else {
      Write-Host "Failed to launch, please open manually" -ForegroundColor Yellow
    }

    if ($launchText.Trim().Length -gt 0) {
      Write-Log "Launch output: $($launchText.Trim())" "Yellow"
    }

    # 启动失败不影响安装结果，避免外层 build-and-install 误判为构建或安装失败
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
