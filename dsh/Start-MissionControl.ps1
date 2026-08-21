# Mission Control launcher -- idempotent, hidden, browser only when serving.
#
# 2026-08-21: the line above was already the stated intent and the code did not
# honour it. The browser opened unconditionally whether or not the server came
# up, there was no log, and stdout/stderr were discarded -- the same defect
# fixed in Start-DSH.ps1 the same day, sitting in its sibling, created by the
# same README step. Readiness was also a TCP listen check, which reports a
# wedged server as healthy. Now: identity-checked HTTP readiness, captured
# output, and a loud failure instead of a browser on a dead port.
# ASCII only: PowerShell 5.1 misparses BOM-less UTF-8 punctuation.

$dshHome = "$env:USERPROFILE\.dsh"
$log     = "$dshHome\mission-control-launcher.log"
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$mcLog   = "$dshHome\logs\mission-control-$stamp.log"
$mcErr   = "$dshHome\logs\mission-control-$stamp.err.log"

New-Item -ItemType Directory -Force -Path $dshHome, "$dshHome\logs" | Out-Null
"=== launch $(Get-Date -Format o) ===" | Out-File -FilePath $log -Encoding utf8

# Serving means OUR console answered, not that something holds the port.
function Test-MCServing {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:3090/api/status" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -ne 200) { return $false }
        return ($r.Content -match '"services"')
    } catch { return $false }
}

if (Test-MCServing) {
    "already serving on :3090 - reusing it" | Add-Content $log
    Start-Process "http://127.0.0.1:3090"
    exit 0
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    "MISSING PREREQUISITE: 'node' is not on PATH. Install Node 22+ (README step 1)." | Add-Content $log
    Start-Process notepad $log
    exit 1
}

$entry = "$dshHome\mission-control\mission-control.mjs"
if (-not (Test-Path $entry)) {
    "MISSION CONTROL NOT DEPLOYED: $entry is missing. Run scripts\Deploy-ToLive.ps1 first." | Add-Content $log
    Start-Process notepad $log
    exit 1
}

$mc = Start-Process -PassThru -WindowStyle Hidden node -ArgumentList "`"$entry`"" `
    -RedirectStandardOutput $mcLog -RedirectStandardError $mcErr
"launched, PID $($mc.Id); output -> $mcLog" | Add-Content $log

$serving = $false
$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 500
    $serving = Test-MCServing
} until ($serving -or (Get-Date) -gt $deadline)

if (-not $serving) {
    "MISSION CONTROL NEVER SERVED after 30s." | Add-Content $log
    if ($mc.HasExited) { "  process exited with code $($mc.ExitCode)" | Add-Content $log }
    foreach ($f in @($mcErr, $mcLog)) {
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
            "--- $(Split-Path $f -Leaf) ---" | Add-Content $log
            Get-Content $f -Tail 40 | Add-Content $log
        }
    }
    "Not opening a browser at a dead port." | Add-Content $log
    Start-Process notepad $log
    exit 1
}

"serving on :3090" | Add-Content $log
Start-Process "http://127.0.0.1:3090"
if ($mc) { Wait-Process -Id $mc.Id }
