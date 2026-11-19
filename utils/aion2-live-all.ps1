# Automated AION 2 live ALT diagnostics (Windows PowerShell 5.1)
# Uses game-packet RTT emitted by open-source AionPingMeter --probe.
# No clicks, login automation, or prompts. An unrecoverable disconnect ends the run.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aion2-probe-parser.ps1')
. (Join-Path $PSScriptRoot 'aion2-live-policy.ps1')
$rootDir = Split-Path -Parent $PSScriptRoot
$pingExe = Join-Path $PSScriptRoot 'AionPingMeter.exe'
$probePath = Join-Path $env:APPDATA 'AionPingMeter\probe.txt'
$resultsDir = Join-Path $PSScriptRoot 'test results'
$discordUrls = @('https://discord.com','https://gateway.discord.gg','https://cdn.discordapp.com','https://updates.discord.com')
$originalProcesses = @()
$serviceInitiallyRunning = $false
$changedNetwork = $false
$reportFile = $null
$rows = @()
$env:NO_UPDATE_CHECK = '1'

function Get-WinwsSnapshot {
    @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop |
      Select-Object ExecutablePath, CommandLine)
}
function Stop-TestWinws {
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 700
}
function Restore-WinwsSnapshot([array]$snapshot) {
    $restored = 0
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath -or -not $p.CommandLine) { throw 'Original winws process information is missing.' }
        $exePath = $p.ExecutablePath
        $line = $p.CommandLine.Trim()
        $args = $null
        if ($line -match '^\s*"[^"]+"\s+(.*)$') {
            $args = $matches[1]
        } elseif ($line.StartsWith($exePath,[StringComparison]::OrdinalIgnoreCase)) {
            $args = $line.Substring($exePath.Length).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($args)) { throw 'Cannot parse original winws arguments.' }
        [void](Start-Process -FilePath $exePath -ArgumentList $args -WorkingDirectory (Split-Path $exePath -Parent) -WindowStyle Minimized -PassThru)
        $restored++
    }
    return $restored
}
function Wait-Winws([int]$seconds = 7) {
    for ($i = 0; $i -lt $seconds * 4; $i++) {
        if (Get-Process -Name winws -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
function Set-TestService([bool]$running) {
    $service = Get-Service -Name zapret -ErrorAction SilentlyContinue
    if (-not $service) { return }
    if ($running) {
        if ($service.Status -ne 'Running') {
            Start-Service -Name zapret -ErrorAction Stop
            (Get-Service -Name zapret).WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
        }
    } else {
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name zapret -Force -ErrorAction Stop
            (Get-Service -Name zapret).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
        }
    }
}
function Start-Baseline {
    Stop-TestWinws
    if ($serviceInitiallyRunning) {
        Set-TestService $true
    } else {
        [void](Restore-WinwsSnapshot $originalProcesses)
    }
    if (-not (Wait-Winws)) { throw 'Known-good zapret could not be restarted.' }
}
function Start-Strategy([IO.FileInfo]$file) {
    if ($serviceInitiallyRunning) { Set-TestService $false }
    Stop-TestWinws
    $cmdArgs = '/c ""' + $file.FullName + '""'
    [void](Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WorkingDirectory $rootDir -WindowStyle Minimized -PassThru)
    return (Wait-Winws)
}
function Invoke-GameProbe([int]$seconds) {
    # Every invocation writes its own probe.txt. Do not read a stale previous run.
    if (Test-Path -LiteralPath $probePath) { Remove-Item -LiteralPath $probePath -Force }
    $process = Start-Process -FilePath $pingExe -ArgumentList @('--probe',"$seconds") -PassThru -WindowStyle Hidden
    try {
        $timeoutSeconds = $seconds + 20
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw 'AionPingMeter --probe timed out.'
        }
        if ($process.ExitCode -ne 0) { throw ('AionPingMeter exit code: ' + $process.ExitCode) }
    } finally {
        $process.Dispose()
    }
    return (Read-AionProbe -Path $probePath)
}
function Get-GameState($data) {
    if (-not (Get-Process -Name AION2 -ErrorAction SilentlyContinue)) { return 'ClientExited' }
    if ($null -eq $data) { return 'ProbeFailed' }
    if (-not (Test-AionLive $data)) { return 'NoFreshGamePing' }
    return 'Live'
}
function Get-DiscordSuccess([string]$url) {
    try {
        $response = & curl.exe --silent --location --output NUL --connect-timeout 3 --max-time 6 --write-out '%{http_code}' $url 2>$null
        $code = 0
        [void][int]::TryParse((@($response) -join '').Trim(), [ref]$code)
        return ($LASTEXITCODE -eq 0 -and $code -ge 200 -and $code -lt 500)
    } catch { return $false }
}
function Save-Rows {
    if ($reportFile -and $rows.Count) {
        $rows | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding UTF8
    }
}
function Make-Row([string]$name,[string]$state,[int]$discord,$data) {
    $events=0; $packetCount=0; $avg=$null; $p95=$null
    if ($data) {
        $events=$data.PingEvents
        $packetCount=$data.PacketCount
        $avg=$data.MeanMs
        $p95=$data.P95Ms
    }
    [pscustomobject]@{
        Config=$name
        Status=$state
        Eligible=($state -eq 'Live' -and (Test-AionEligible ($state -eq 'Live') $discord $discordUrls.Count $data))
        DiscordOK=$discord
        PingEvents=$events
        Packets=$packetCount
        GameMeanMs=$avg
        GameP95Ms=$p95
    }
}

try {
    $identity = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run service.bat as Administrator.' }
    if (-not (Test-Path -LiteralPath $pingExe)) { throw 'AionPingMeter.exe is missing from utils.' }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is missing.' }
    if (-not (Get-Process -Name AION2 -ErrorAction SilentlyContinue)) { throw 'Start AION 2 and enter the game world first.' }
    $files = @(Get-ChildItem -LiteralPath $rootDir -Filter 'general*.bat' -File | Sort-Object Name)
    if (-not $files.Count) { throw 'No general*.bat ALT files found.' }

    $originalProcesses = @(Get-WinwsSnapshot)
    if (-not $originalProcesses.Count) { throw 'No active baseline zapret found. Log in with a working ALT first.' }
    if (@($originalProcesses | Where-Object { -not $_.ExecutablePath -or -not $_.CommandLine }).Count) {
        throw 'Cannot restore original winws command line; refusing to switch.'
    }
    $svc = Get-Service -Name zapret -ErrorAction SilentlyContinue
    $serviceInitiallyRunning = ($null -ne $svc -and $svc.Status -eq 'Running')
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $reportFile = Join-Path $resultsDir ('aion2-auto-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    Write-Host 'Preflight: checking live game packets with the CURRENT working ALT...' -ForegroundColor Cyan
    $baseline = Invoke-GameProbe 45
    if ((Get-GameState $baseline) -ne 'Live') {
        throw 'No fresh AION 2 gameplay pings on the current ALT. Nothing was switched.'
    }
    Write-Host ('Baseline P95: {0}ms, events: {1}, packets: {2}' -f $baseline.P95Ms,$baseline.PingEvents,$baseline.PacketCount) -ForegroundColor Green

    $changedNetwork = $true
    foreach ($file in $files) {
        Write-Host ('Testing ' + $file.Name) -ForegroundColor Cyan
        $state = 'StartFailed'
        $data = $null
        $discord = 0
        try {
            $started = Start-Strategy $file
            if ($started) {
                foreach ($url in $discordUrls) { if (Get-DiscordSuccess $url) { $discord++ } }
                $data = Invoke-GameProbe 45
                $state = Get-GameState $data
            }
        } catch {
            $state = 'ProbeOrSwitchError'
            Write-Warning ($file.Name + ': ' + $_.Exception.Message)
        }
        $rows += (Make-Row $file.Name $state $discord $data)
        Save-Rows
        Write-Host ('Result {0}: {1}, game P95={2}, Discord={3}/4' -f $file.Name,$state,$data.P95Ms,$discord)

        if ($state -ne 'Live') {
            Write-Warning 'No fresh game RTT. Automatically restoring known-good zapret and checking recovery.'
            try {
                Start-Baseline
                $recovered = $false
                for ($recoveryAttempt = 1; $recoveryAttempt -le 3; $recoveryAttempt++) {
                    Write-Host ('Recovery check {0}/3...' -f $recoveryAttempt) -ForegroundColor Cyan
                    $recovery = Invoke-GameProbe 35
                    if ((Get-GameState $recovery) -eq 'Live') { $recovered = $true; break }
                }
                if (-not $recovered) {
                    throw 'Game did not automatically recover on known-good ALT.'
                }
                Write-Host 'Automatic recovery succeeded; continuing ALT tests.' -ForegroundColor Green
            } catch {
                Write-Warning ('Automatic game recovery unavailable: ' + $_.Exception.Message)
                Write-Warning 'Stopping remaining ALT tests. Login UI is NOT controlled.'
                break
            }
        }
    }

    Write-Host ''
    Write-Host 'Completed automatic ALT checks. Ineligible or disconnected strategies cannot win.' -ForegroundColor Green
    $ranked = @(Get-AionLiveRanking -Rows $rows)
    $ranked | Format-Table Config,Status,Eligible,DiscordOK,PingEvents,GameMeanMs,GameP95Ms -AutoSize | Out-Host
    Write-Host ('Saved: ' + $reportFile) -ForegroundColor Green
    Write-Host 'WARNING: existing TCP sessions can hide handshake-only DPI differences. Re-login behavior is not proven.' -ForegroundColor Yellow
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor Yellow }
} finally {
    if ($changedNetwork) {
        Write-Host 'Restoring original zapret configuration...' -ForegroundColor Cyan
        try {
            if ($serviceInitiallyRunning) { Set-TestService $false }
            Stop-TestWinws
            if ($serviceInitiallyRunning) {
                Set-TestService $true
            } else {
                [void](Restore-WinwsSnapshot $originalProcesses)
            }
            Write-Host 'Original zapret launch restored.' -ForegroundColor Green
        } catch {
            Write-Host ('RESTORE ERROR: ' + $_.Exception.Message) -ForegroundColor Red
            Write-Host 'Start the original known-good zapret ALT manually if required.' -ForegroundColor Yellow
        }
    }
    Save-Rows
    Write-Host 'Finished. No user interaction was required during the test.'
}
