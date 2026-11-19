# Live AION 2 game-ping sampler; requires game running and AionPingMeter.exe in utils.
# Source implementation: https://github.com/ArtemNA/AionPingMeter (MIT).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aion2-probe-parser.ps1')
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'AionPingMeter.exe'
$probe = Join-Path $env:APPDATA 'AionPingMeter\probe.txt'
$results = Join-Path $PSScriptRoot 'test results'
try {
    if (-not (Test-Path $exe)) { throw 'Copy AionPingMeter.exe to utils first (see github.com/ArtemNA/AionPingMeter).' }
    if (-not (Get-Process -Name AION2 -ErrorAction SilentlyContinue)) { throw 'AION2.exe must be running in the game world.' }
    New-Item -ItemType Directory -Path $results -Force | Out-Null
    Write-Host 'This measures real game packet responses, NOT TCP connection timing.' -ForegroundColor Cyan
    Write-Host 'Leave AION 2 running and ensure the selected zapret ALT is active.' -ForegroundColor Yellow
    $strategy = (Read-Host 'Enter currently active ALT name for the CSV').Trim()
    if (-not $strategy) { throw 'Strategy name is required.' }
    if (Test-Path $probe) { Remove-Item $probe -Force }
    $p = Start-Process -FilePath $exe -ArgumentList '--probe','45' -PassThru -Wait
    if ($p.ExitCode -ne 0 -or -not (Test-Path $probe)) { throw 'Game ping probe failed; see AionPingMeter diagnostics.' }
    $data = Read-AionProbe -Path $probe
    if ($data.PingEvents -lt 2 -or $data.Observations -lt 2) { throw 'Not enough fresh in-game ping replies; cannot rank ALT.' }
    $row = [pscustomobject]@{
        Strategy=$strategy
        GamePingEvents=$data.PingEvents
        Observations=$data.Observations
        MeanMs=$data.MeanMs
        P95Ms=$data.P95Ms
    }
    $csv = Join-Path $results 'aion2-game-ping.csv'
    if (Test-Path $csv) { $row | Export-Csv $csv -Append -NoTypeInformation -Encoding UTF8 }
    else { $row | Export-Csv $csv -NoTypeInformation -Encoding UTF8 }
    $row | Format-List | Out-Host
    Write-Host ('Saved: ' + $csv) -ForegroundColor Green
    Write-Host 'Different from NotMeter 1.0.362 unless its proprietary algorithm is independently verified.' -ForegroundColor Yellow
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    [void](Read-Host 'Press Enter to close')
}
