# Small pure predicates used by live testing and executable regression tests.
function Test-AionLive {
    param($Observation)
    if ($null -eq $Observation) { return $false }
    return ($Observation.PingEvents -ge 2 -and $Observation.Observations -ge 2 -and $Observation.PacketCount -ge 2)
}
function Test-AionEligible {
    param([bool]$WinwsStarted,[int]$DiscordOK,[int]$DiscordTotal,$Observation)
    return ($WinwsStarted -and $DiscordOK -eq $DiscordTotal -and (Test-AionLive $Observation))
}
function Get-AionLiveRanking {
    param([object[]]$Rows)
    @($Rows | Sort-Object @{Expression='Eligible';Descending=$true},
        @{Expression={if ($null -eq $_.GameP95Ms){[double]::PositiveInfinity}else{$_.GameP95Ms}};Descending=$false},
        @{Expression={if ($null -eq $_.GameMeanMs){[double]::PositiveInfinity}else{$_.GameMeanMs}};Descending=$false})
}
