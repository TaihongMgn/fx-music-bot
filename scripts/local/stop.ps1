# Stop the local test processes started by start.ps1.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\local\stop.ps1

$ErrorActionPreference = 'Continue'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$RunDir = Join-Path $Root '.local\run'

if (-not (Test-Path $RunDir)) {
    Write-Host 'No local test processes are recorded.'
    exit 0
}

Get-ChildItem $RunDir -Filter '*.pid' | ForEach-Object {
    $procId = (Get-Content $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 1)
    $name = $_.BaseName
    if ($procId) {
        Write-Host "Stopping $name (pid $procId)"
        & taskkill.exe /PID $procId /T /F | Out-Null
    }
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
}

Write-Host 'Stopped. Mumble installed as a Windows service is left running.'
