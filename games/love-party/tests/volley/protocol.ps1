param([string]$LoveExe = "$env:LOCALAPPDATA\GameNight\runtimes\love-11.5-win64\love.exe", [string]$GameDir = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$ErrorActionPreference = 'Stop'
$volleyListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$volleyListener.Start()
$volleyPort = $volleyListener.LocalEndpoint.Port
$volleyOldEnv = @{}
$volleyVars = @{ GAMENIGHT = '1'; GAMENIGHT_ADDR = "127.0.0.1:$volleyPort"; GAMENIGHT_GAME_ID = 'volley-trouble'; GAMENIGHT_TOKEN = 'volley-test-token' }
foreach ($key in $volleyVars.Keys) {
    $volleyOldEnv[$key] = [Environment]::GetEnvironmentVariable($key)
    [Environment]::SetEnvironmentVariable($key, $volleyVars[$key])
}
function Send-Volley($message) {
    $volleyWriter.WriteLine((ConvertTo-Json -InputObject $message -Depth 10 -Compress))
}
function Receive-Volley($type, $seconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $volleyStream.ReadTimeout = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $line = $volleyReader.ReadLine()
        if ($null -eq $line) { throw "Game disconnected while waiting for $type" }
        $message = ConvertFrom-Json $line
        if ($message.type -eq $type) { return $message }
    }
    throw "Timed out waiting for $type"
}
try {
    $volleyProcess = Start-Process -FilePath $LoveExe -ArgumentList ('"' + $GameDir + '"') -WindowStyle Hidden -PassThru
    $volleyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $volleyListener.Pending()) {
        if ([DateTime]::UtcNow -gt $volleyDeadline) { throw 'Game never connected' }
        Start-Sleep -Milliseconds 20
    }
    $volleyClient = $volleyListener.AcceptTcpClient()
    $volleyStream = $volleyClient.GetStream()
    $volleyReader = [IO.StreamReader]::new($volleyStream)
    $volleyWriter = [IO.StreamWriter]::new($volleyStream, [Text.UTF8Encoding]::new($false))
    $volleyWriter.AutoFlush = $true
    $hello = Receive-Volley 'hello'
    if ($hello.token -ne 'volley-test-token' -or $hello.game -ne 'volley-trouble') { throw 'Invalid hello' }
    Send-Volley @{type='welcome'; protocol_version=1}
    $settings = Receive-Volley 'declare_settings'
    if ($settings.settings.Count -ne 4) { throw 'Missing settings' }
    Send-Volley @{type='setting_changed'; key='target'; value=1}
    # Idle human seats make the first point deterministic; AI rallies are covered by simulation tests.
    $volleySeats = @(@{index=0; occupant=@{kind='local'}}, @{index=1; occupant=@{kind='local'}})
    foreach ($session in @('volley-test-one', 'volley-test-two')) {
        Send-Volley @{type='prepare'; game='volley-trouble'; session=$session; seats=$volleySeats; players=@()}
        $ready = Receive-Volley 'ready'
        if ($ready.session -ne $session) { throw 'Incorrect ready session' }
        Send-Volley @{type='future_unknown_message'; ignored=$true}
        Send-Volley @{type='start'; session=$session}
        Start-Sleep -Milliseconds 300
        Send-Volley @{type='pause'; session=$session}
        Start-Sleep -Milliseconds 100
        Send-Volley @{type='resume'; session=$session}
        $finished = Receive-Volley 'finished' 30
        if ($finished.session -ne $session) { throw 'Incorrect finished session' }
        Send-Volley @{type='dispose'; session=$session}
        Write-Output "PASS lifecycle $session"
    }
    $volleyClient.Close()
    if (-not $volleyProcess.WaitForExit(5000)) { throw 'Game failed to exit on disconnect' }
    if ($volleyProcess.ExitCode -ne 0) { throw "Game exited with $($volleyProcess.ExitCode)" }
    Write-Output 'PASS token, settings, prepare, start, pause/resume, finished, dispose/reprepare, disconnect'
} finally {
    if ($volleyClient) { $volleyClient.Close() }
    $volleyListener.Stop()
    if ($volleyProcess -and -not $volleyProcess.HasExited) { $volleyProcess.Kill() }
    foreach ($key in $volleyVars.Keys) { [Environment]::SetEnvironmentVariable($key, $volleyOldEnv[$key]) }
}
