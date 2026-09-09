param(
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [ValidateSet('preview', 'stable')][string]$Channel = 'preview',
    [ValidateSet('dev', 'ci', 'release')][string]$Profile = 'release',
    [string]$SigningMetadata,
    [string]$Vpk = 'vpk'
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { throw 'Invalid release version' }
if ($Channel -eq 'stable' -and ($Version.Contains('-') -or !$SigningMetadata)) {
    throw 'Stable installers require a stable version and code signing.'
}
& (Join-Path $PSScriptRoot 'build-windows-preview.ps1') -OutputDir $OutputDir -TargetDir $TargetDir -Profile $Profile
if ($LASTEXITCODE -ne 0) { throw 'Preview staging failed' }
$stage = Join-Path $OutputDir 'package/gamenight-windows-preview'
$releaseDir = Join-Path $OutputDir 'releases'
$packId = if ($Channel -eq 'stable') { 'Ontola.GameNight' } else { 'Ontola.GameNight.Preview' }
$title = if ($Channel -eq 'stable') { 'GameNight' } else { 'GameNight Preview' }
$vpkArgs = @('pack', '--packId', $packId, '--packVersion', $Version, '--packDir', $stage,
    '--mainExe', 'GameNight.exe', '--packTitle', $title, '--packAuthors', 'Ontola',
    '--channel', "win-$Channel", '--runtime', 'win-x64', '--outputDir', $releaseDir)
if ($SigningMetadata) { $vpkArgs += @('--azureTrustedSignFile', $SigningMetadata) }
& $Vpk @vpkArgs
if ($LASTEXITCODE -ne 0) { throw 'Velopack packaging failed' }
if ($SigningMetadata) {
    foreach ($file in Get-ChildItem -LiteralPath $releaseDir -Filter '*Setup.exe') {
        if ((Get-AuthenticodeSignature -LiteralPath $file.FullName).Status -ne 'Valid') { throw 'Installer signature is invalid' }
    }
}
$hashes = Get-ChildItem -LiteralPath $releaseDir -File | Sort-Object Name | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
}
$hashes | Set-Content -LiteralPath (Join-Path $releaseDir 'SHA256SUMS.txt') -Encoding utf8
Write-Host "Installer and update feed: $releaseDir"
