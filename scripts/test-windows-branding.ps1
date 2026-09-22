param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [string]$ProductName = 'GameNight'
)
$ErrorActionPreference = 'Stop'
if (!('GameNightBranding.Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace GameNightBranding {
    public static class Native {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
        public static extern uint ExtractIconEx(string path, int index, IntPtr[] large, IntPtr[] small, uint count);
    }
}
"@
}
$file = Get-Item -LiteralPath $Executable
if ($file.VersionInfo.ProductName -ne $ProductName -or $file.VersionInfo.FileDescription -ne $ProductName) {
    throw "Incorrect product name or description in $Executable"
}
if ([GameNightBranding.Native]::ExtractIconEx($file.FullName, -1, $null, $null, 0) -lt 1) {
    throw "No Windows icon resource in $Executable"
}
Write-Host "Verified branding: $($file.Name) ($ProductName)"
