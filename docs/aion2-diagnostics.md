# Discord + AION 2 ALT diagnostics

Run option 13 in service.bat as Administrator on Windows.

## Requirements
- Game Filter TCP or TCP+UDP enabled and includes port 13328.
- Verified game server address must be included in active IPSet (or IPSet mode any).
- Close AION 2 before cycling configs; remove installed zapret service first.
- To discover the correct endpoint while in game: Get-NetTCPConnection -State Established -RemotePort 13328 | Select-Object RemoteAddress,RemotePort,OwningProcess
- Put the confirmed address into utils/targets-aion2.txt or enter it at the prompt.

## Operation
1. Save running winws commands and measure a direct TCP baseline.
2. Run all general*.bat strategies, one at a time.
3. Check four Discord HTTPS endpoints and sample game TCP handshake latency.
4. Export CSV files in utils/test results; show provisional ranking.
5. Restore prior winws processes in a finally block.

Eligible means all four Discord probes succeed, the strategy starts, and every TCP handshake succeeds.
TCP handshake does NOT establish AION 2 login success, DPI bypass success, or true gameplay latency.
These tests also do not measure game packet loss, UDP, or DPS. Real gameplay verification is mandatory.

## Verification
Run powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\aion2-tests.ps1
Tests check PowerShell syntax parsing, known edge cases, 1000 randomized CIDR comparisons, stats, sorting, and legacy menu routing.
GitHub Actions Windows testing is configured, but only a completed green workflow is evidence it ran.

## Safety
Switching strategies interrupts winws traffic. The script tries to restore previous commands, but forced termination can prevent restoration.
It does not intentionally change IPSet or Game Filter configuration files. Do not run other winws managers concurrently.
## Real in-game ping mode (service.bat -> 13 -> 1)

The previous TCP-only mode does NOT measure gameplay latency. For an active
AION 2 session, option 13 -> 1 measures actual AION 2 game ping packet replies
using the open-source AionPingMeter --probe interface.

Requirements:
- Download or build an authentic AionPingMeter.exe from https://github.com/ArtemNA/AionPingMeter
  (MIT-licensed independent tool) and place it in utils/AionPingMeter.exe.
- Install Npcap as required by AionPingMeter.
- Launch AION2.exe, log into the game world and keep it running.
- Disable the installed zapret service using the normal menu first; the test
  temporarily cycles general*.bat processes. It restores previously running winws
  commands when it finishes normally.
- Option 13 -> 1 tests all ALT strategies, 45 seconds each, and saves a CSV
  under utils/test results. If a strategy disconnects the game, reconnect before
  proceeding; that strategy remains ineligible for ranking.
- Option 13 -> 2 measures just the currently active strategy without changing winws.
- Option 13 -> 3 runs the older offline TCP-only checks.

The real-ping parser counts only increases in the game's ping event counter.
Repeating a last known RTT in the one-second probe output is not counted as new data.
No new game RTT events means there is NO measurement; the tester must not invent one.

**Do not claim exact parity with proprietary NotMeter v1.0.362:** its private
algorithm was not found. The probe implementation is publicly inspectable in
ArtemNA/AionPingMeter (src/main.rs, src/probe.rs and src/stats.rs).
The game must be running for real game ping packets to exist.

**Caution:** switching winws while AION 2 is connected can disrupt gameplay;
do this outside combat and be ready to reconnect. Game packet measurements
cannot be fully tested in GitHub CI; they require an actual AION 2 session.