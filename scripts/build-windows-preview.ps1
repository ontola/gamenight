param(
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [ValidateSet("dev", "ci", "release")][string]$Profile = "dev"
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:CARGO_TARGET_DIR = $TargetDir
& cargo build --locked --profile $Profile --manifest-path (Join-Path $repo 'Cargo.toml') -p gamenight-daemon
if ($LASTEXITCODE -ne 0) { throw 'Daemon build failed' }
& cargo build --locked --profile $Profile --manifest-path (Join-Path $repo 'crates\lobby\Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'Lobby build failed' }
if (Test-Path -LiteralPath $OutputDir) { throw 'Choose a new output directory; packages are never overwritten.' }
New-Item -ItemType Directory -Path $OutputDir | Out-Null
function Download-Verified($Url, $Path, $Hash) {
    Invoke-WebRequest -Uri $Url -OutFile $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) { throw "Checksum mismatch: $Url" }
}
$loveZip = Join-Path $OutputDir 'love.zip'
$gameZip = Join-Path $OutputDir 'pinpals.zip'
Download-Verified 'https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip' $loveZip 'BA6E56BE2685E53C817749C4A5007F51137136FE5A3AB64920508BABC2E74369'
Download-Verified 'https://codeload.github.com/joepio/pinpals/zip/95ea42fe544cf3906c90aeb556359180964c1e88' $gameZip 'B574829C2D1FAC531FA73C4B13E7ABA0758BD067F74C4651DE01E75870E6E0F5'
$packageDir = Join-Path $OutputDir 'package'
& python (Join-Path $PSScriptRoot 'package-windows.py') --target $TargetDir --love-zip $loveZip --pinpals-zip $gameZip --output $packageDir --profile $Profile
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed' }
Copy-Item -LiteralPath (Join-Path $packageDir 'gamenight-windows-preview.zip'),(Join-Path $packageDir 'SHA256SUMS.txt') -Destination $OutputDir
