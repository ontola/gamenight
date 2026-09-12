param(
    [ValidateSet('start','restart','stop','build','sync','status')][string]$Action = 'start',
    [ValidateSet('host','lobby','all')][string]$Component = 'all',
    [string]$RuntimeDir = "$env:USERPROFILE\gamenight-windows\dev",
    [string]$TargetDir = "$env:USERPROFILE\gamenight-windows\build",
    [string]$Shelf,
    [string]$PythonExe = 'python',
    [string]$Screenshot,
    [switch]$CleanView,
    [string]$CloudUrl = 'https://gamenight.ontola.io',
    [string]$CatalogDir,
    [int]$Port = 7912
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:CARGO_TARGET_DIR = $TargetDir
$hostExe = Join-Path $TargetDir 'debug\gamenight-daemon.exe'
$lobbyExe = Join-Path $TargetDir 'debug\lobby.exe'
$stateFile = Join-Path $RuntimeDir 'dev-process.json'
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

function Stop-DevSession {
    if (-not (Test-Path -LiteralPath $stateFile)) { return }
    $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $owned = Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
    if ($owned) {
        # PowerShell 7 may deserialize ISO timestamps as DateTime rather than
        # strings. Compare normalized ticks so the ownership guard stays exact.
        $savedStarted = ([datetime]$saved.started).ToUniversalTime()
        if ($owned.StartTime.ToUniversalTime().Ticks -ne $savedStarted.Ticks -or $owned.Path -ne $saved.executable) {
            throw 'Saved PID belongs to another process; refusing to stop it.'
        }
        # Only stop the process tree started by this launcher, verified by
        # executable and creation time. Never kill processes by generic name.
        & taskkill /PID $owned.Id /T /F | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop owned preview' }
        $owned.WaitForExit(5000) | Out-Null
    }
    Remove-Item -LiteralPath $stateFile
}
function Sync-DevAssets {
    & $PythonExe (Join-Path $PSScriptRoot 'sync-dev-assets.py') (Join-Path $repo 'crates\lobby') $RuntimeDir
    if ($LASTEXITCODE -ne 0) { throw 'Asset sync failed' }
}

if ($Action -eq 'status') {
    if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile }
    else { Write-Output 'No managed preview session.' }
    exit
}
if ($Action -eq 'stop') { Stop-DevSession; exit }
if ($Action -eq 'sync') { Sync-DevAssets; exit }
if ($Action -eq 'build') {
    # Explicit build; never package, sync or launch as a side effect.
    if ($Component -in @('host','all')) {
        & cargo rustc --locked --manifest-path (Join-Path $repo 'Cargo.toml') -p gamenight-daemon --bin gamenight-daemon -- -C link-arg=/PDBPAGESIZE:8192
        if ($LASTEXITCODE -ne 0) { throw 'Host build failed; stop the preview if Windows locks its executable.' }
    }
    if ($Component -in @('lobby','all')) {
        # Bevy's debug symbols can exceed the default PDB page limit.
        & cargo rustc --locked --manifest-path (Join-Path $repo 'crates\lobby\Cargo.toml') -- -C link-arg=/PDBPAGESIZE:8192
        if ($LASTEXITCODE -ne 0) { throw 'Lobby build failed; stop the preview if Windows locks its executable.' }
    }
    exit
}
foreach ($binary in @($hostExe,$lobbyExe)) {
    if (-not (Test-Path -LiteralPath $binary)) { throw "Missing $binary. Run -Action build first." }
}
if ($Action -eq 'restart') { Stop-DevSession }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $Port is in use by another session. Close that session first."
}
$timer = [Diagnostics.Stopwatch]::StartNew()
Sync-DevAssets
$library = Join-Path $RuntimeDir 'library.json'
if (-not $Shelf -and (Test-Path -LiteralPath $library)) { $Shelf = $library }
$games = if ($Shelf) { @(Get-Content -LiteralPath $Shelf -Raw | ConvertFrom-Json | Where-Object { $_.id -ne 'lobby' }) } else { @() }
$games += @{
    id='lobby'; title='GameNight'; players='1-4'; min_players=1; max_players=4
    launch=@{command=$lobbyExe; cwd=$RuntimeDir; env=@{BEVY_ASSET_ROOT=$RuntimeDir}}
}
[IO.File]::WriteAllText($library, (ConvertTo-Json -InputObject @($games) -Depth 20), [Text.UTF8Encoding]::new($false))
$env:GAMENIGHT_LIBRARY=$library
$env:GAMENIGHT_ADDR="127.0.0.1:$Port"
$env:GAMENIGHT_WEB='1'
$env:GAMENIGHT_DEV_WEB_DIR=Join-Path $repo 'web'
if ($CatalogDir) { $env:GAMENIGHT_DEV_CATALOG_DIR=$CatalogDir }
if ($games.Count -le 1) { $env:GAMENIGHT_NO_PREWARM='1' }
else { Remove-Item Env:GAMENIGHT_NO_PREWARM -ErrorAction SilentlyContinue }
$env:GAMENIGHT_EXIT_WITH_LOBBY='1'
if ($CloudUrl) { $env:GAMENIGHT_CLOUD_URL=$CloudUrl }
else { Remove-Item Env:GAMENIGHT_CLOUD_URL -ErrorAction SilentlyContinue }
foreach ($key in @('GAMENIGHT','GAMENIGHT_TOKEN','GAMENIGHT_GAME_ID','GAMENIGHT_NO_LOBBY_WATCH','GAMENIGHT_JOIN_URL')) {
    Remove-Item "Env:$key" -ErrorAction SilentlyContinue
}
$env:RUST_LOG='info'
if ($Screenshot) {
    $env:LOBBY_SHOT=[IO.Path]::GetFullPath($Screenshot)
    $env:LOBBY_SHOT_AFTER='10'
    $env:LOBBY_SHOT_CLEAN=if ($CleanView) { '1' } else { '0' }
} else {
    Remove-Item Env:LOBBY_SHOT,Env:LOBBY_SHOT_CLEAN -ErrorAction SilentlyContinue
}
$env:PATH=(Join-Path $TargetDir 'debug\deps') + ';' + (& rustc --print target-libdir) + ';' + $env:PATH
$child = Start-Process -FilePath $hostExe -WorkingDirectory $RuntimeDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $RuntimeDir 'daemon.log') -RedirectStandardError (Join-Path $RuntimeDir 'daemon.err.log')
@{pid=$child.Id; started=$child.StartTime.ToUniversalTime().ToString('o'); executable=$child.Path} | ConvertTo-Json | Set-Content -LiteralPath $stateFile
Write-Output "Launched in $([math]::Round($timer.Elapsed.TotalSeconds,2))s (sync + process launch; see logs for first frame)."
