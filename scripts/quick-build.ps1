$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "build.ps1") -Mode debug -SkipClean
exit $LASTEXITCODE
