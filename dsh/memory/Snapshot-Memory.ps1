# HALO memory-graph snapshots — compensation for an out-of-boundary location.
# The Cordis paper (§6.1): the memory graph is an "emission" — a write dsh cannot
# revert. This script supplies the compensation path: hourly change-detected
# snapshots with rotation, so any bad write by a session or plugin has an undo.
# Registered as Windows scheduled task "HALO Memory Snapshot" (hourly).

$ErrorActionPreference = 'Stop'
$memFile = "$env:USERPROFILE\.dsh\memory\memory.json"
$snapDir = "$env:USERPROFILE\.dsh\memory\snapshots"
$keep    = 60

if (-not (Test-Path $memFile)) { exit 0 }
if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir | Out-Null }

$currentHash = (Get-FileHash $memFile -Algorithm SHA256).Hash
$latest = Get-ChildItem $snapDir -Filter 'memory-*.json' | Sort-Object Name -Descending | Select-Object -First 1
if ($latest -and (Get-FileHash $latest.FullName -Algorithm SHA256).Hash -eq $currentHash) { exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item $memFile (Join-Path $snapDir "memory-$stamp.json")

Get-ChildItem $snapDir -Filter 'memory-*.json' | Sort-Object Name -Descending |
    Select-Object -Skip $keep | Remove-Item -Force
