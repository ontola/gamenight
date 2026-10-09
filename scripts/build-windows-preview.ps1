param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [ValidateSet("dev", "ci", "release")][string]$BuildProfile = "dev",
    # Godot 4.5 console editor; without it the package ships only the Clubhouse lobby.
    [string]$Godot
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:CARGO_TARGET_DIR = $TargetDir
& cargo build --locked --profile $BuildProfile --manifest-path (Join-Path $repo 'Cargo.toml') -p gamenight-daemon
if ($LASTEXITCODE -ne 0) { throw 'Daemon build failed' }
& cargo build --locked --profile $BuildProfile --manifest-path (Join-Path $repo 'crates\lobby\Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'Lobby build failed' }
if (Test-Path -LiteralPath $OutputDir) { throw 'Choose a new output directory; packages are never overwritten.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
$packageDir = Join-Path $OutputDir 'package'
$packageArgs = @('--target', $TargetDir, '--output', $packageDir, '--profile', $BuildProfile)
if ($Godot) {
    # The editor runs a same-named PCK next to it, so no export templates are needed.
    $room = Join-Path $repo 'lobbies/game-room'
    $roomOut = Join-Path $OutputDir 'game-room'
    New-Item -ItemType Directory -Path $roomOut | Out-Null
    & $Godot --headless --path $room --editor --import --quit
    if ($LASTEXITCODE -ne 0) { throw 'Game Room import failed' }
    & $Godot --headless --path $room --export-pack 'Windows Desktop' (Join-Path $roomOut 'GameRoom.pck')
    if ($LASTEXITCODE -ne 0) { throw 'Game Room export failed' }
    Copy-Item -LiteralPath $Godot.Replace('_console.exe', '.exe') -Destination (Join-Path $roomOut 'GameRoom.exe')
    $packageArgs += @('--game-room', $roomOut)
}
& python (Join-Path $PSScriptRoot 'package-windows.py') @packageArgs
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
Copy-Item -LiteralPath (Join-Path $packageDir 'gamenight-windows-preview.zip'),(Join-Path $packageDir 'SHA256SUMS.txt') -Destination $OutputDir
