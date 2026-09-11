# HarmonyOS 设备管理脚本
param(
  [ValidateSet("list", "info", "log", "start", "stop", "uninstall")]
  [string]$Action = "list",
  [string]$DeviceId = "",
  [switch]$Follow
)

$HDC_PATH = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$BUNDLE_NAME = "com.zhonxinya.talebook"
$ABILITY_NAME = "EntryAbility"

if (-not (Test-Path $HDC_PATH)) {
  Write-Host "Error: HDC not found" -ForegroundColor Red
  exit 1
}

function Get-Devices {
  $output = & $HDC_PATH list targets 2>&1
  $devices = @()
  foreach ($line in $output) {
    if ($line -match '^\S+') {
      $devices += $line.Trim()
    }
  }
  return $devices
}

function Select-Device {
  param([string]$PreferredDeviceId)
  $devices = Get-Devices
  if ($devices.Count -eq 0) {
    Write-Host "No devices found" -ForegroundColor Red
    exit 1
  }
  if ($PreferredDeviceId -and $devices -contains $PreferredDeviceId) {
    return $PreferredDeviceId
  }
  if ($devices.Count -eq 1) {
    return $devices[0]
  }
  Write-Host "Available devices:" -ForegroundColor Cyan
  for ($i = 0; $i -lt $devices.Count; $i++) {
    Write-Host "   [$i] $($devices[$i])" -ForegroundColor Gray
  }
  $selection = Read-Host "Select device (default 0)"
  if ([string]::IsNullOrWhiteSpace($selection)) { $selection = 0 }
  return $devices[[int]$selection]
}

# Execute action
switch ($Action) {
  "list" {
    Write-Host "Connected devices:" -ForegroundColor Cyan
    $devices = Get-Devices
    if ($devices.Count -eq 0) {
      Write-Host "   No devices detected" -ForegroundColor Yellow
    }
    else {
      foreach ($device in $devices) {
        Write-Host "   OK: $device" -ForegroundColor Green
      }
    }
  }
  "info" {
    $device = Select-Device $DeviceId
    Write-Host "Device info: $device" -ForegroundColor Cyan
    $model = & $HDC_PATH -t $device shell getprop ro.product.model 2>&1
    Write-Host "   Model: $model" -ForegroundColor Gray
  }
  "log" {
    $device = Select-Device $DeviceId
    Write-Host "Viewing logs for device: $device" -ForegroundColor Cyan
    if ($Follow) {
      & $HDC_PATH -t $device shell hilog | Select-String $BUNDLE_NAME
    }
    else {
      & $HDC_PATH -t $device shell hilog | Select-String $BUNDLE_NAME | Select-Object -Last 50
    }
  }
  "start" {
    $device = Select-Device $DeviceId
    Write-Host "Starting app on device: $device" -ForegroundColor Cyan
    & $HDC_PATH -t $device shell aa start -a $ABILITY_NAME -b $BUNDLE_NAME
    if ($LASTEXITCODE -eq 0) {
      Write-Host "App started" -ForegroundColor Green
    }
    else {
      Write-Host "Failed to start app" -ForegroundColor Red
    }
  }
  "stop" {
    $device = Select-Device $DeviceId
    Write-Host "Stopping app on device: $device" -ForegroundColor Cyan
    & $HDC_PATH -t $device shell aa force-stop $BUNDLE_NAME
    if ($LASTEXITCODE -eq 0) {
      Write-Host "App stopped" -ForegroundColor Green
    }
    else {
      Write-Host "Failed to stop app" -ForegroundColor Red
    }
  }
  "uninstall" {
    $device = Select-Device $DeviceId
    Write-Host "Uninstalling app from device: $device" -ForegroundColor Cyan
    $confirm = Read-Host "Confirm uninstall? (y/N)"
    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
      & $HDC_PATH -t $device shell bm uninstall -n $BUNDLE_NAME
      if ($LASTEXITCODE -eq 0) {
        Write-Host "App uninstalled" -ForegroundColor Green
      }
      else {
        Write-Host "Failed to uninstall" -ForegroundColor Red
      }
    }
    else {
      Write-Host "Cancelled" -ForegroundColor Yellow
    }
  }
}
