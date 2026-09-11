# HarmonyOS Hvigor Wrapper for PowerShell
# Using DevEco Studio's bundled hvigor and Java

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$HvigorArgs
)

$DEVECO_ROOT = "C:\Program Files\Huawei\DevEco Studio"
$HVIGOR_BIN = Join-Path $DEVECO_ROOT "tools\hvigor\bin\hvigorw.bat"
$JAVA_HOME_PATH = Join-Path $DEVECO_ROOT "jbr"

if (-not $env:JAVA_HOME -and (Test-Path "$JAVA_HOME_PATH\bin\java.exe")) {
  $env:JAVA_HOME = $JAVA_HOME_PATH
  $env:PATH = "$JAVA_HOME_PATH\bin;$env:PATH"
}

if (-not $env:DEVECO_SDK_HOME) {
  $defaultSdkPath = Join-Path $env:LOCALAPPDATA "Huawei\Sdk"
  if (Test-Path $defaultSdkPath) {
    $env:DEVECO_SDK_HOME = $defaultSdkPath
  }
}

if (-not (Test-Path $HVIGOR_BIN)) {
  Write-Host "Error: hvigor not found at $HVIGOR_BIN" -ForegroundColor Red
  exit 1
}

& $HVIGOR_BIN @HvigorArgs
exit $LASTEXITCODE
