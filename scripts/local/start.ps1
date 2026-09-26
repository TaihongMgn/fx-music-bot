# Start a local Mumble server, the Netease API, and this bot for testing.
# Usage (from the repo root):
#   powershell -ExecutionPolicy Bypass -File scripts\local\start.ps1
#
# Web panel:  http://127.0.0.1:8181    admin / admin123
# Mumble:     127.0.0.1:64738           any username, no server password
# Logs:       .local\logs
#
# Connect to another server instead of starting a local one:
#   powershell -ExecutionPolicy Bypass -File scripts\local\start.ps1 -MumbleHost azraelkaxi.top -SkipLocalMumble

param(
    [string]$MumbleHost = '127.0.0.1',
    [int]$MumblePort = 64738,
    [string]$ServerPassword = '',
    [string]$BotName = 'fx-bot',
    [string]$BotAdmin = 'SuperUser',
    [switch]$SkipLocalMumble
)

$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Local = Join-Path $Root '.local'
$RunDir = Join-Path $Local 'run'
$LogDir = Join-Path $Local 'logs'
$BinDir = Join-Path $Local 'bin'
$MusicDir = Join-Path $Local 'music'
$TmpDir = Join-Path $Local 'tmp'
$MumbleDir = Join-Path $Local 'mumble'
$VenvDir = Join-Path $Root '.venv'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'

$WebUser = 'admin'
$WebPassword = 'admin123'
$WebPort = 8181
$NeteasePort = 3000

function Write-Step($Message) {
    Write-Host ""
    Write-Host "== $Message"
}

function Test-TcpPort($Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(400, $false)
        if (-not $ok) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-TcpPort($Port, $TimeoutSec, $Name) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort $Port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "$Name did not listen on port $Port within ${TimeoutSec}s. See .local\logs"
    return $false
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user;$BinDir"
}

function Find-Python311 {
    try {
        $fromPy = & py.exe -3.11 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $fromPy -and (Test-Path $fromPy.Trim())) {
            return $fromPy.Trim()
        }
    } catch {
    }

    $roots = @(
        (Join-Path $env:APPDATA 'uv\python'),
        (Join-Path $env:LOCALAPPDATA 'uv\python')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Directory -Filter 'cpython-3.11*' |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($hit) {
            $exe = Join-Path $hit.FullName 'python.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    throw 'Python 3.11 was not found. This bot uses the audioop module, which Python 3.13 removed. Install Python 3.11, or keep the uv CPython 3.11 runtime.'
}

function Ensure-WingetPackage($Id, $AlreadyPresent) {
    if ($AlreadyPresent) { return }
    Write-Step "Installing $Id"
    & winget.exe install --id $Id -e --accept-package-agreements --accept-source-agreements --disable-interactivity
    # 0x8A15002B: the package is already installed and no newer version applies.
    if ($LASTEXITCODE -eq -1978335189) {
        Write-Host "$Id is already installed."
        Refresh-Path
        return
    }
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Id (exit $LASTEXITCODE). Run this script from an elevated PowerShell if the installer asked for administrator rights."
    }
    Refresh-Path
}

function Find-MumbleServer {
    $fixed = @(
        "${env:ProgramFiles}\Mumble\server\mumble-server.exe",
        "${env:ProgramFiles}\Mumble\mumble-server.exe",
        "${env:ProgramFiles(x86)}\Mumble\server\mumble-server.exe"
    )
    foreach ($path in $fixed) {
        if (Test-Path $path) { return $path }
    }
    $found = Get-ChildItem "${env:ProgramFiles}\Mumble" -Recurse -Filter 'mumble-server.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Ensure-OpusDll {
    $opusDll = Join-Path $BinDir 'opus.dll'
    $legacyDll = Join-Path $BinDir 'libopus-0.dll'
    if ((Test-Path $opusDll) -and (Test-Path $legacyDll)) {
        return
    }
    # Mumble 1.5 links Opus into the executable, so the client install has no opus.dll.
    $nupkg = Join-Path $Local 'opus.win-x64.nupkg'
    $url = 'https://api.nuget.org/v3-flatcontainer/opusdotnet.opus.win-x64/1.3.1/opusdotnet.opus.win-x64.1.3.1.nupkg'
    Write-Host 'Downloading 64-bit opus.dll'
    $params = @{ Uri = $url; OutFile = $nupkg; UseBasicParsing = $true }
    $proxySettings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($proxySettings.ProxyEnable -eq 1 -and $proxySettings.ProxyServer) {
        $proxy = $proxySettings.ProxyServer
        if ($proxy -notmatch '://') { $proxy = "http://$proxy" }
        $params.Proxy = $proxy
    }
    Invoke-WebRequest @params
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'runtimes/win-x64/native/opus.dll' } | Select-Object -First 1
        if (-not $entry) { throw 'opus.dll was not inside the downloaded package' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $opusDll, $true)
    } finally {
        $zip.Dispose()
    }
    Copy-Item $opusDll $legacyDll -Force
    Write-Host "Opus DLL: $opusDll"
}

function Start-Logged($Name, $FilePath, $ArgumentList, $WorkingDirectory) {
    $stdout = Join-Path $LogDir "$Name.out.log"
    $stderr = Join-Path $LogDir "$Name.err.log"
    foreach ($log in @($stdout, $stderr)) {
        if (Test-Path $log) { Remove-Item $log -Force }
    }
    $startParams = @{
        FilePath = $FilePath
        WorkingDirectory = $WorkingDirectory
        WindowStyle = 'Hidden'
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
        PassThru = $true
    }
    if ($ArgumentList) {
        $startParams.ArgumentList = $ArgumentList
    }
    $proc = Start-Process @startParams
    Set-Content -Path (Join-Path $RunDir "$Name.pid") -Value $proc.Id -Encoding ASCII
    return $proc
}

function Show-LogTail($Name) {
    foreach ($suffix in @('err', 'out')) {
        $path = Join-Path $LogDir "$Name.$suffix.log"
        if (-not (Test-Path $path)) { continue }
        Write-Host "---- $Name $suffix ----"
        Get-Content $path -Tail 40 -ErrorAction SilentlyContinue
    }
}

New-Item -ItemType Directory -Force -Path $RunDir, $LogDir, $BinDir, $MusicDir, $TmpDir, $MumbleDir | Out-Null
Set-Location $Root
Refresh-Path

$alive = @()
foreach ($pidFile in @(Get-ChildItem $RunDir -Filter '*.pid' -ErrorAction SilentlyContinue)) {
    $procId = Get-Content $pidFile.FullName | Select-Object -First 1
    if (-not $procId) { continue }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc) { $alive += $pidFile.BaseName }
}
if ($alive.Count -gt 0) {
    throw ("Already running: " + ($alive -join ', ') + ". Stop it first with scripts\local\stop.ps1")
}

Write-Step 'Python 3.11 virtualenv'
$python = Find-Python311
Write-Host "Using $python"
$needVenv = -not (Test-Path $VenvPython)
if (-not $needVenv) {
    & $VenvPython -c "import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 11) else 1)"
    if ($LASTEXITCODE -ne 0) { $needVenv = $true }
}
if ($needVenv) {
    if (Test-Path $VenvDir) { Remove-Item $VenvDir -Recurse -Force }
    & $python -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the virtualenv' }
}
& $VenvPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed' }
& $VenvPython -m pip install -r (Join-Path $Root 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'pip install requirements.txt failed' }
& $VenvPython -m pip install python-magic-bin jinja2
if ($LASTEXITCODE -ne 0) { throw 'pip install python-magic-bin jinja2 failed' }

Write-Step 'Web panel assets'
# Webpack 5.6 uses MD4. Node 17+ OpenSSL rejects it unless the legacy provider is enabled.
if ($env:NODE_OPTIONS -notmatch 'openssl-legacy-provider') {
    if ($env:NODE_OPTIONS) {
        $env:NODE_OPTIONS = "$env:NODE_OPTIONS --openssl-legacy-provider"
    } else {
        $env:NODE_OPTIONS = '--openssl-legacy-provider'
    }
}
$mainJs = Join-Path $Root 'static\js\main.js'
$mainMjs = Join-Path $Root 'web\js\main.mjs'
$template = Join-Path $Root 'web\templates\index.template.html'
$zhHtml = Join-Path $Root 'web\templates\index.zh_CN.html'
$needBuild = -not (Test-Path $mainJs) -or ((Get-Item $mainMjs).LastWriteTime -gt (Get-Item $mainJs).LastWriteTime)
$needHtml = -not (Test-Path $zhHtml) -or ((Get-Item $template).LastWriteTime -gt (Get-Item $zhHtml).LastWriteTime)
Push-Location (Join-Path $Root 'web')
try {
    if (-not (Test-Path 'node_modules')) {
        & npm.cmd install
        if ($LASTEXITCODE -ne 0) { throw 'web npm install failed' }
        $needBuild = $true
    }
    if ($needBuild) {
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw 'web npm run build failed' }
    } else {
        Write-Host 'Frontend bundle is up to date.'
    }
} finally {
    Pop-Location
}
if ($needHtml -or $needBuild) {
    & $VenvPython (Join-Path $Root 'scripts\translate_templates.py') --lang-dir (Join-Path $Root 'lang') --template-dir (Join-Path $Root 'web\templates')
    if ($LASTEXITCODE -ne 0) { throw 'Template translation failed' }
}

Write-Step 'Netease API dependencies'
$neteaseDir = Join-Path $Root 'netease-api'
if (-not (Test-Path (Join-Path $neteaseDir 'node_modules'))) {
    Push-Location $neteaseDir
    try {
        & npm.cmd install --ignore-scripts
        if ($LASTEXITCODE -ne 0) { throw 'netease-api npm install failed' }
    } finally {
        Pop-Location
    }
}

$logPath = ''
if (-not $SkipLocalMumble) {
Write-Step 'Mumble server'
$mumbleExe = Find-MumbleServer
Ensure-WingetPackage 'Mumble.Mumble.Server' ([bool]$mumbleExe)
$mumbleExe = Find-MumbleServer
if (-not $mumbleExe) {
    throw 'mumble-server.exe was not found after installation. Expected it under C:\Program Files\Mumble\server\'
}
Write-Host "Mumble server: $mumbleExe"

$mumbleIni = Join-Path $MumbleDir 'mumble-server.ini'
$dbPath = (Join-Path $MumbleDir 'mumble-server.sqlite') -replace '\\', '/'
$logPath = (Join-Path $MumbleDir 'mumble-server.log') -replace '\\', '/'
@"
# Generated by scripts/local/start.ps1
port=$MumblePort
host=127.0.0.1
serverpassword=
bandwidth=200000
users=20
welcometext=<b>fx-music-bot local test</b>
registerName=
bonjour=false
sendversion=false
database=$dbPath
logfile=$logPath
"@ | Set-Content -Path $mumbleIni -Encoding ASCII

$appDataMurmur = Join-Path $env:LOCALAPPDATA 'Mumble\Murmur'
New-Item -ItemType Directory -Force -Path $appDataMurmur | Out-Null
Copy-Item $mumbleIni (Join-Path $appDataMurmur 'mumble-server.ini') -Force
}

Write-Step 'ffmpeg and Opus'
Ensure-WingetPackage 'Gyan.FFmpeg' ([bool](Get-Command ffmpeg -ErrorAction SilentlyContinue))
Refresh-Path
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    $ffmpegHit = Get-ChildItem -Path `
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages", `
        "$env:ProgramFiles\ffmpeg", `
        'C:\ffmpeg' `
        -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($ffmpegHit) {
        $env:Path = (Split-Path $ffmpegHit.FullName -Parent) + ';' + $env:Path
    }
}
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw 'ffmpeg is not on PATH. Open a new terminal after the winget install, or add the FFmpeg bin directory to PATH.'
}
Ensure-OpusDll
$env:Path = "$BinDir;" + $env:Path

$botConfig = Join-Path $Local 'configuration.ini'
$musicCfg = ($MusicDir -replace '\\', '/')
$tmpCfg = ($TmpDir -replace '\\', '/')
$cookieCfg = (($(Join-Path $Local 'netease_cookie.txt')) -replace '\\', '/')
$qrCfg = (($(Join-Path $Local 'qr_login.png')) -replace '\\', '/')
$settingsDb = (($(Join-Path $Local 'settings.db')) -replace '\\', '/')
$musicDb = (($(Join-Path $Local 'music.db')) -replace '\\', '/')
@"
[server]
host = $MumbleHost
port = $MumblePort
password = $ServerPassword

[bot]
username = $BotName
language = zh_CN
admin = $BotAdmin
comment = fx-music-bot
volume = 0.4
auto_check_update = False
music_folder = $musicCfg
database_path = $settingsDb
music_database_path = $musicDb
tmp_folder = $tmpCfg
tmp_folder_max_size = 10240

[webinterface]
enabled = True
listening_addr = 127.0.0.1
listening_port = $WebPort
auth_method = session
user = $WebUser
password = $WebPassword
access_address = http://127.0.0.1:$WebPort
session_secret = local-test-session-secret
flask_secret = local-test-flask-secret
is_web_proxified = False
upload_enabled = True

[netease]
api_url = http://127.0.0.1:$NeteasePort
cookie_file = $cookieCfg
qr_image_path = $qrCfg
default_search_limit = 10
"@ | Set-Content -Path $botConfig -Encoding ASCII

Write-Step 'Starting processes'
if (-not $SkipLocalMumble) {
    if (Test-TcpPort $MumblePort) {
        Write-Host "Port $MumblePort is already open. Reusing the existing Mumble server."
    } else {
        # Mumble Server 1.5 on Windows rejects --ini. It reads
        # %LOCALAPPDATA%\Mumble\Murmur\mumble-server.ini, which was copied above.
        Start-Logged 'mumble' $mumbleExe @() $MumbleDir | Out-Null
        if (-not (Wait-TcpPort $MumblePort 25 'Mumble')) {
            Show-LogTail 'mumble'
            if ($logPath -and (Test-Path ($logPath -replace '/', '\'))) {
                Write-Host '---- mumble-server.log ----'
                Get-Content ($logPath -replace '/', '\') -Tail 40
            }
            throw 'Mumble server failed to start'
        }
    }
}

if (Test-TcpPort $NeteasePort) {
    Write-Host "Port $NeteasePort is already open. Reusing the existing Netease API."
} else {
    $node = (Get-Command node.exe).Source
    Start-Logged 'netease' $node @('app.js') $neteaseDir | Out-Null
    if (-not (Wait-TcpPort $NeteasePort 40 'Netease API')) {
        Show-LogTail 'netease'
        throw 'Netease API failed to start'
    }
}

$botProc = Start-Logged 'bot' $VenvPython @('mumbleBot.py', '--config', $botConfig, '-v') $Root
$deadline = (Get-Date).AddSeconds(40)
$webUp = $false
while ((Get-Date) -lt $deadline) {
    if ($botProc.HasExited) {
        Show-LogTail 'bot'
        throw "Bot exited (code $($botProc.ExitCode))"
    }
    if (Test-TcpPort $WebPort) {
        $webUp = $true
        break
    }
    Start-Sleep -Milliseconds 500
}
if (-not $webUp) {
    Show-LogTail 'bot'
    throw 'Bot failed to start'
}

$superUser = $null
$murmurLog = $logPath -replace '/', '\'
if (Test-Path $murmurLog) {
    $match = Select-String -Path $murmurLog -Pattern "SuperUser" | Select-Object -Last 3
    if ($match) { $superUser = ($match | ForEach-Object { $_.Line }) -join "`n" }
}

Write-Host ""
Write-Host 'Bot is up.'
Write-Host "Mumble:    ${MumbleHost}:$MumblePort    bot username $BotName"
Write-Host "Web panel: http://127.0.0.1:$WebPort"
Write-Host "Login:     $WebUser / $WebPassword"
Write-Host "Netease:   http://127.0.0.1:$NeteasePort"
Write-Host "Logs:      $LogDir"
if ($superUser) {
    Write-Host 'Mumble SuperUser:'
    Write-Host $superUser
}
Write-Host 'Stop with: powershell -ExecutionPolicy Bypass -File scripts\local\stop.ps1'
