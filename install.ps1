# Arduino Easy Setup - one-line launcher for Windows.
# Usage (in PowerShell):
#   irm https://raw.githubusercontent.com/A7medAmine/arduino-easy-setup/main/install.ps1 | iex
#
# Downloads the latest setup-windows.ps1 and runs it in a separate Windows PowerShell
# process, so it gets its parameters, execution policy bypass, and cannot close this window.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $url  = 'https://raw.githubusercontent.com/A7medAmine/arduino-easy-setup/main/setup-windows.ps1'
    $dir  = Join-Path $env:LOCALAPPDATA 'ArduinoEasySetup'
    $dest = Join-Path $dir 'setup-windows.ps1'

    Write-Host 'Downloading Arduino Easy Setup...' -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Check your internet connection and try again.'
        return
    }

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dest
}
