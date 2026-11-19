# AION 2 LIVE ALT comparison using real in-game ping replies.
# Uses MIT-licensed AionPingMeter --probe, NOT proprietary NotMeter internals.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aion2-probe-parser.ps1')
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'AionPingMeter.exe'
$probeFile = Join-Path $env:APPDATA 'AionPingMeter\probe.txt'
$resultsDir = Join-Path $PSScriptRoot 'test results'
$original = @()
$altered = $false

function Snapshot-Winws {
    @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" | Select-Object ExecutablePath,CommandLine)
}
function Stop-Winws {
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
}
function Restore-Winws([array]$items) {
    foreach ($p in $items) {
        $exePath = $p.ExecutablePath
        $command = $p.CommandLine
        if (-not $exePath -or -not $command) { Write-Warning 'Could not restore a winws process without its command line'; continue }
        $arguments = $null
        if ($command -match '^\s*"[^"]+"\s+(.*)$') {
            $arguments = $matches[1]
        } elseif ($command.StartsWith($exePath, [StringComparison]::OrdinalIgnoreCase)) {
            $arguments = $command.Substring($exePath.Length).Trim()
        }
        if (-not $arguments) { Write-Warning 'Original winws arguments could not be parsed'; continue }
        try {
            Start-Process -FilePath $exePath -ArgumentList $arguments -WorkingDirectory (Split-Path $exePath -Parent) -WindowStyle Minimized | Out-Null
        } catch { Write-Warning "Failed to restore original winws: $_" }
    }
}
function Discord-OK([string]$url) {
    try {
        $response = & curl.exe --silent --location --output NUL --connect-timeout 4 --max-time 7 --write-out '%{http_code}' $url 2>$null
        $code = 0
        [void][int]::TryParse((@($response) -join '').Trim(),[ref]$code)
        return ($LASTEXITCODE -eq 0 -and $code -ge 200 -and $code -lt 500)
    } catch { return $false }
}
try {
    $identity = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges required.' }
    if (-not (Test-Path $exe)) { throw 'Place the official AionPingMeter.exe inside utils first.' }
    if (-not (Get-Process -Name AION2 -ErrorAction SilentlyContinue)) { throw 'Open AION 2 and enter the game world before starting.' }
    if (Get-Service -Name zapret -ErrorAction SilentlyContinue) { throw 'Remove the installed zapret Windows service before ALT cycling.' }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe not found.' }
    $files = @(Get-ChildItem -Path $root -Filter 'general*.bat' -File | Sort-Object Name)
    if (-not $files.Count) { throw 'No general*.bat found.' }
    $original = @(Snapshot-Winws)
    if (@($original | Where-Object { -not $_.ExecutablePath -or -not $_.CommandLine }).Count) {
        throw 'Current winws cannot be restored reliably; stop it manually and retry.'
    }
    $urls = @('https://discord.com','https://gateway.discord.gg','https://cdn.discordapp.com','https://updates.discord.com')
    $duration = 45
    Write-Host "Live AION 2 ALT test: $($files.Count) strategies, $duration seconds of real game traffic each." -ForegroundColor Cyan
    Write-Host 'WARNING: restarting winws may disconnect AION 2. In that case reconnect in game when prompted.' -ForegroundColor Yellow
    Write-Host 'The existing Game Filter and IPSet are preserved; no game memory is read or modified.' -ForegroundColor Yellow
    if ((Read-Host 'Type YES to begin') -ne 'YES') { throw 'Cancelled.' }
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $rows = @()
    $reportPath = Join-Path $resultsDir ('aion2-live-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    $env:NO_UPDATE_CHECK = '1'
    $altered = $true
    foreach ($file in $files) {
        if (-not (Get-Process -Name AION2 -ErrorAction SilentlyContinue)) { throw 'Game client exited.' }
        Write-Host ("Testing: " + $file.Name) -ForegroundColor Cyan
        Stop-Winws
        $arg = '/c ""' + $file.FullName + '""'
        [void](Start-Process -FilePath cmd.exe -ArgumentList $arg -WorkingDirectory $root -WindowStyle Minimized -PassThru)
        $running = $false
        for ($i=0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            if (Get-Process -Name winws -ErrorAction SilentlyContinue) { $running = $true; break }
        }
        $discord = 0
        $data = $null
        if ($running) {
            foreach ($url in $urls) { if (Discord-OK $url) { $discord++ } }
            if (Test-Path $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
            $process = Start-Process -FilePath $exe -ArgumentList @('--probe',"$duration") -WorkingDirectory $PSScriptRoot -Wait -PassThru
            if ($process.ExitCode -eq 0 -and (Test-Path $probeFile)) {
                $data = Read-AionProbe -Path $probeFile
            }
        }
        $events = 0; $observations = 0; $avg = $null; $p95 = $null; $packets = 0
        if ($null -ne $data) {
            $events = $data.PingEvents
            $observations = $data.Observations
            $avg = $data.MeanMs
            $p95 = $data.P95Ms
            $packets = $data.PacketCount
        }
        $eligible = $running -and $discord -eq $urls.Count -and $observations -ge 2 -and $events -ge 2
        $rows += [pscustomobject]@{
            Config=$file.Name
            Eligible=$eligible
            DiscordOK=$discord
            GamePingEvents=$events
            GameObservations=$observations
            PacketCount=$packets
            GameMeanMs=$avg
            GameP95Ms=$p95
        }
        $rows | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
        Write-Host ("Discord: $discord/4; game ping events: $events; P95: $p95; eligible: $eligible")
        if (-not $eligible -and (Get-Process -Name AION2 -ErrorAction SilentlyContinue)) {
            Write-Host 'No valid game ping response. The game may have disconnected.' -ForegroundColor Yellow
            Write-Host 'Reconnect to the world before testing the next strategy, if needed.' -ForegroundColor Yellow
            [void](Read-Host 'Press Enter to continue')
        }
    }
    $path = $reportPath
    $rank = @($rows | Sort-Object @{Expression='Eligible';Descending=$true}, @{Expression={if ($null -eq $_.GameP95Ms){[double]::PositiveInfinity}else{$_.GameP95Ms}};Descending=$false})
    $rank | Format-Table -AutoSize | Out-Host
    Write-Host ('Results saved: ' + $path) -ForegroundColor Green
    Write-Host 'These are genuine AionPingMeter game-packet observations, not verified NotMeter parity.' -ForegroundColor Yellow
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor Yellow }
} finally {
    if ($altered) { Stop-Winws; Restore-Winws $original }
    [void](Read-Host 'Press Enter to close')
}
