$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'utils\aion2-checks.ps1')
. (Join-Path $root 'utils\aion2-probe-parser.ps1')
. (Join-Path $root 'utils\aion2-live-policy.ps1')
$checks = 0
function Assert-True([bool]$condition,[string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
}
function Assert-Equal($expected,$actual,[string]$message) {
    if ($expected -ne $actual) { throw "FAIL: $message (expected=$expected actual=$actual)" }
    $script:checks++
}
# Parse every new PowerShell file using the actual PowerShell parser.
foreach ($file in @('utils\aion2-checks.ps1','utils\test aion2.ps1','utils\aion2-probe-parser.ps1','utils\aion2-game-ping.ps1','utils\aion2-live-all.ps1','utils\aion2-live-policy.ps1',$MyInvocation.MyCommand.Path)) {
    $filePath = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $root $file }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($filePath,[ref]$tokens,[ref]$errors)
    Assert-Equal 0 $(if ($null -eq $errors) { 0 } else { @($errors).Count }) "PowerShell parse: $file"
}
# Example and edge-case tests
Assert-True (Test-AionIPv4InCidr '193.202.112.122' '193.202.112.0/24') 'inside /24'
Assert-True (-not (Test-AionIPv4InCidr '193.202.113.1' '193.202.112.0/24')) 'outside /24'
Assert-True (Test-AionIPv4InCidr '0.0.0.0' '0.0.0.0/0') '/0 includes everything'
Assert-True (Test-AionIPv4InCidr '255.255.255.255' '255.255.255.255/32') '/32 exact'
Assert-True (-not (Test-AionIPv4InCidr '256.1.1.1' '0.0.0.0/0')) 'invalid ip'
Assert-Equal 'included' (Test-AionIPSet '193.202.112.122' @('193.202.112.0/24','34.117.142.0/24')) 'known range'
Assert-Equal 'excluded' (Test-AionIPSet '1.2.3.4' @('193.202.112.0/24')) 'range exclusion'
Assert-Equal 'any' (Test-AionIPSet '1.2.3.4' @('')) 'empty ipset any'
Assert-Equal 'none' (Test-AionIPSet '1.2.3.4' @('203.0.113.113/32')) 'placeholder none'
Assert-True (Test-AionPortInRange 13328 '13328,443') 'single port'
Assert-True (Test-AionPortInRange 13328 '13000-14000') 'range port'
Assert-True (-not (Test-AionPortInRange 13328 '443,8443')) 'port excluded'
Assert-True (-not (Test-AionPortInRange 13328 '12')) 'disabled game filter'
$stats = Get-AionStats -Measurements @([double]10,[double]20,[double]30,[double]40) -Attempts 5
Assert-Equal 80 $stats.SuccessPct 'loss percentage'
Assert-Equal 25 $stats.AvgMs 'average'
Assert-Equal 25 $stats.MedianMs 'median'
Assert-Equal 40 $stats.P95Ms 'nearest-rank P95'
$none = Get-AionStats -Measurements @() -Attempts 8
Assert-Equal 0 $none.SuccessPct 'no TCP success'
Assert-True ($null -eq $none.P95Ms) 'P95 not fabricated on failure'
$rows = @(
    [pscustomobject]@{Config='fast-fail';Eligible=$false;DiscordOK=3;AionTcpSuccessPct=100;AionTcpP95Ms=1},
    [pscustomobject]@{Config='slow-pass';Eligible=$true;DiscordOK=4;AionTcpSuccessPct=100;AionTcpP95Ms=70},
    [pscustomobject]@{Config='fast-pass';Eligible=$true;DiscordOK=4;AionTcpSuccessPct=100;AionTcpP95Ms=30}
)
$rank = @(Get-AionRank -Rows $rows)
Assert-Equal 'fast-pass' $rank[0].Config 'rank eligibility before speed'
Assert-Equal 'slow-pass' $rank[1].Config 'rank second eligible'
Assert-Equal 'fast-fail' $rank[2].Config 'ineligible goes last'
# Property test: randomized IPv4 prefix equivalence vs explicit bitmask implementation.
$random = New-Object Random 20261119
for ($n=0; $n -lt 1000; $n++) {
    $a = [byte[]]@(0,0,0,0); $b = [byte[]]@(0,0,0,0)
    $random.NextBytes($a); $random.NextBytes($b)
    $prefix = $random.Next(0,33)
    $expected = $true
    for ($bit=0; $bit -lt $prefix; $bit++) {
        $idx = [int][math]::Floor($bit/8)
        $mask = 1 -shl (7 - ($bit % 8))
        if (($a[$idx] -band $mask) -ne ($b[$idx] -band $mask)) { $expected=$false; break }
    }
    $actual = Test-AionIPv4InCidr ($a -join '.') (($b -join '.') + '/' + $prefix)
    Assert-Equal $expected $actual "randomized CIDR iteration $n"
}
# Regression: standard ALT tests and default target list exist; new mode does not edit them.
Assert-True (Test-Path (Join-Path $root 'utils\test zapret.ps1')) 'original test still exists'
Assert-True (Test-Path (Join-Path $root 'utils\targets.txt')) 'original targets still exist'
$service = [IO.File]::ReadAllText((Join-Path $root 'service.bat'))
Assert-True ($service.Contains('if "%menu_choice%"=="12" goto run_tests')) 'original menu route remains'
Assert-True ($service.Contains('if "%menu_choice%"=="13" goto run_aion2_tests')) 'new menu route present'
# Replay test: probe reports the same last ping for several seconds.
# Do not count repeated snapshots as separate in-game RTT events.
$tmp = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllLines($tmp, @(
        '  1s packets=10 pings=0 game=- tcpMin2s=40',
        '  2s packets=20 pings=1 game=90.0 tcpMin2s=40',
        '  3s packets=30 pings=1 game=90.0 tcpMin2s=40',
        '  4s packets=40 pings=1 game=90.0 tcpMin2s=40',
        '  5s packets=50 pings=2 game=110.0 tcpMin2s=40'
    ))
    $probe = Read-AionProbe -Path $tmp
    Assert-Equal 2 $probe.PingEvents 'two actual in-game ping events'
    Assert-Equal 2 $probe.Observations 'stale snapshots discarded'
    Assert-Equal 100 $probe.MeanMs 'event-based game RTT average'
    Assert-Equal 110 $probe.P95Ms 'event-based P95'
    Assert-Equal 50 $probe.PacketCount 'last packet count'
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
# Live-mode verification: success requires actual fresh game replies plus packet flow.
$healthy = [pscustomobject]@{PingEvents=3;Observations=3;PacketCount=400}
$dead = [pscustomobject]@{PingEvents=0;Observations=0;PacketCount=400}
$stale = [pscustomobject]@{PingEvents=1;Observations=1;PacketCount=400}
$noTraffic = [pscustomobject]@{PingEvents=2;Observations=2;PacketCount=0}
Assert-True (Test-AionLive $healthy) 'fresh game replies accepted'
Assert-True (-not (Test-AionLive $dead)) 'disconnected game rejected even with TCP packets'
Assert-True (-not (Test-AionLive $stale)) 'single game ping rejected'
Assert-True (-not (Test-AionLive $noTraffic)) 'no game traffic rejected'
Assert-True (-not (Test-AionLive $null)) 'failed probe rejected'
Assert-True (Test-AionEligible $true 4 4 $healthy) 'all services and live game accepted'
Assert-True (-not (Test-AionEligible $true 3 4 $healthy)) 'Discord partial failure rejected'
Assert-True (-not (Test-AionEligible $false 4 4 $healthy)) 'winws startup failure rejected'
Assert-True (-not (Test-AionEligible $true 4 4 $dead)) 'game disconnect rejected'
$liveRows = @(
    [pscustomobject]@{ Config='broken-fast';Eligible=$false;GameP95Ms=1;GameMeanMs=1 },
    [pscustomobject]@{ Config='good-slow';Eligible=$true;GameP95Ms=120;GameMeanMs=100 },
    [pscustomobject]@{ Config='good-fast';Eligible=$true;GameP95Ms=80;GameMeanMs=70 },
    [pscustomobject]@{ Config='unavailable';Eligible=$false;GameP95Ms=$null;GameMeanMs=$null }
)
$liveRank = @(Get-AionLiveRanking -Rows $liveRows)
Assert-Equal 'good-fast' $liveRank[0].Config 'fastest eligible strategy first'
Assert-Equal 'good-slow' $liveRank[1].Config 'slower eligible strategy second'
Assert-Equal 'broken-fast' $liveRank[2].Config 'ineligible strategies never outrank eligible'
Assert-Equal 'unavailable' $liveRank[3].Config 'missing data ranks last'
$liveSource = [IO.File]::ReadAllText((Join-Path $root 'utils\aion2-live-all.ps1'))
Assert-True (-not $liveSource.Contains('Read-Host')) 'automatic live test has no interactive prompts'
Assert-True ($liveSource.Contains('Start-Baseline')) 'automatic known-good recovery exists'
Assert-True ($liveSource.Contains('Get-WinwsSnapshot')) 'original process snapshot exists'
Assert-True ($liveSource.Contains('finally')) 'cleanup in finally block exists'
Assert-True ($liveSource.Contains('Save-Rows')) 'partial results checkpoint exists'

Write-Host "PASS: $checks checks (including 1000 randomized CIDR properties)." -ForegroundColor Green
