param([Parameter(Mandatory=$true)][string]$AudioPath)
# Local Windows dictation only. This helper makes no network requests.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$recognizer = $null
try {
    Add-Type -AssemblyName System.Speech
    $installed = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
    if ($installed.Count -eq 0) { throw 'Install a Windows speech language to use voice.' }
    $preferred = $installed | Where-Object { $_.Culture.Name -eq [System.Globalization.CultureInfo]::CurrentUICulture.Name } | Select-Object -First 1
    if ($null -eq $preferred) { $preferred = $installed[0] }
    $recognizer = [System.Speech.Recognition.SpeechRecognitionEngine]::new($preferred)
    $recognizer.LoadGrammar([System.Speech.Recognition.DictationGrammar]::new())
    $recognizer.SetInputToWaveFile($AudioPath)
    $parts = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        # SAPI clears its input at EOF; a subsequent Recognize may throw
        # instead of returning null, including after a successful final phrase.
        try { $result = $recognizer.Recognize() }
        catch [System.InvalidOperationException] { break }
        if ($null -eq $result) { break }
        if ($result.Confidence -ge 0.35) { $parts.Add($result.Text) }
    }
    @{text=($parts -join ' ')} | ConvertTo-Json -Compress
} catch {
    @{error='Speech could not be transcribed. Check that a Windows speech language is installed.'} | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($null -ne $recognizer) { $recognizer.Dispose() }
}
