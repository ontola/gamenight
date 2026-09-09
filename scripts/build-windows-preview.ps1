param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [ValidateSet("dev", "ci", "release")][string]$BuildProfile = "dev"
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
& python (Join-Path $PSScriptRoot 'package-windows.py') --target $TargetDir --output $packageDir --profile $BuildProfile
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
Copy-Item -LiteralPath (Join-Path $packageDir 'gamenight-windows-preview.zip'),(Join-Path $packageDir 'SHA256SUMS.txt') -Destination $OutputDir
