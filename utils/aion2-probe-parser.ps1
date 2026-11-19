# Parser for ArtemNA/AionPingMeter --probe output, Windows PowerShell 5.1.
# The program emits one line per second; game= holds the LAST measured RTT,
# so counting every line would artificially duplicate one game ping ~10 times.
function Read-AionProbe {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing probe output: $Path" }
    $measurements = New-Object System.Collections.Generic.List[double]
    $lastSeen = 0
    $lastPackets = 0
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $countMatch = [regex]::Match($line, '(?:^|\s)pings=\s*(\d+)')
        $gameMatch = [regex]::Match($line, '(?:^|\s)game=(\d+(?:\.\d+)?)')
        $packetsMatch = [regex]::Match($line, '(?:^|\s)packets=\s*(\d+)')
        if ($packetsMatch.Success) { $lastPackets = [int]$packetsMatch.Groups[1].Value }
        if (-not $countMatch.Success) { continue }
        $count = [int]$countMatch.Groups[1].Value
        if ($count -gt $lastSeen -and $gameMatch.Success) {
            $ms = [double]::Parse($gameMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            $measurements.Add($ms)
        }
        if ($count -gt $lastSeen) { $lastSeen = $count }
    }
    $avg = $null
    $p95 = $null
    $minimum = $null
    $maximum = $null
    if ($measurements.Count -gt 0) {
        $values = @($measurements.ToArray() | Sort-Object)
        $avg = [math]::Round(($values | Measure-Object -Average).Average, 1)
        $index = [math]::Max(0, [int][math]::Ceiling($values.Count * 0.95) - 1)
        $p95 = $values[$index]
        $minimum = $values[0]
        $maximum = $values[$values.Count - 1]
    }
    [pscustomobject]@{
        Observations = $measurements.Count
        PingEvents = $lastSeen
        PacketCount = $lastPackets
        MeanMs = $avg
        P95Ms = $p95
        MinMs = $minimum
        MaxMs = $maximum
    }
}
