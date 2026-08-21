# DeepSeek Harness launcher (hardened).
# Order: model first, server second, browser LAST.
#
# Hardening from the 5070Ti port (see TESTER-5070ti-bench.md, branch tester/5070ti):
#   1. Wait for LM Studio's API before loading. On a cold boot the loader ran
#      before the server accepted connections, failed, and Out-Null ate it.
#   2. Ensure the brain is resident even when :3080 is already up.
#   3. Loader output goes to ~\.dsh\launcher.log. Nothing fails silently.
#   4. Brain check requires deviceIdentifier null: on a federated LM Studio a
#      remote box can publish the same identity and satisfy a naive check.
#
# 2026-08-21, from a live "the stack won't load" report plus two clean-context
# adversarial audits. The 2026-08-18 commit that added items 1-4 was titled
# "no silent failures" and left the one process that serves the app failing
# silently. Items 5-13 are that debt, paid:
#   5.  Server stdout/stderr were DISCARDED. Now captured per-run.
#   6.  Readiness was a TCP listen check. rc.7 can deadlock with :3080 held
#       open and every request hanging, so listening != serving. Now HTTP.
#   7.  A missed deadline logged nothing and opened a browser on a dead port.
#       Now loud, and no browser.
#   8.  Serving is now identity-checked (__DSH_BOOT__). An unrelated dev server
#       answering 200 on 3080 was silently adopted as "the cockpit".
#   9.  Single-instance mutex. Two launchers racing (an impatient second
#       double-click during the up-to-240s hidden startup) could force-kill
#       each other's still-starting server and clobber each other's logs.
#       Both were reproduced by audit.
#   10. Stale-process cleanup now also matches the cmd.exe running npx.cmd.
#       Item 6's own text named that wrapper as the orphan, then only ever
#       queried node.exe -- the fix did not target the bug it described.
#   11. Cleanup never kills a process that is serving on some other port, so a
#       second deliberate instance survives.
#   12. Missing lms/node/npx are now detected by name, with a message that says
#       so. Command-discovery failures bypass 2>$null and *>> redirection
#       entirely, so the old code timed out for 60s and blamed the wrong thing.
#   13. The workspace no longer falls back to $env:USERPROFILE. That silently
#       widened a danger-full-access agent to the entire home directory on the
#       exact fresh-machine case where Desktop\Code does not exist yet.
# ASCII only: PowerShell 5.1 misparses BOM-less UTF-8 punctuation.

$dshHome   = "$env:USERPROFILE\.dsh"
$log       = "$dshHome\launcher.log"
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$serverLog = "$dshHome\logs\dsh-server-$stamp.log"
$serverErr = "$dshHome\logs\dsh-server-$stamp.err.log"

# Item 12/6: every log write below assumes these exist. If they do not, even
# Fail-Loud writes nothing and opens Notepad on a file that was never created.
New-Item -ItemType Directory -Force -Path $dshHome, "$dshHome\logs" | Out-Null
"=== launch $(Get-Date -Format o) ===" | Out-File -FilePath $log -Encoding utf8

$mutex = $null
function Release-Mutex {
    if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch { }; $script:mutex.Dispose(); $script:mutex = $null }
}
function Fail-Loud([string]$message) {
    $message | Add-Content $log
    "Server output (if any): $serverLog" | Add-Content $log
    Release-Mutex
    Start-Process notepad $log
    exit 1
}
function Require-Command([string]$name, [string]$why) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Fail-Loud "MISSING PREREQUISITE: '$name' is not on PATH. $why"
    }
}

# Item 9: one launcher at a time. Without this, a second double-click during
# the hidden startup window kills the first run's server as "stale".
$mutex = New-Object System.Threading.Mutex($false, 'Local\HaloStackLauncher')
if (-not $mutex.WaitOne(0)) {
    "another launcher is already starting the stack - exiting quietly" | Add-Content $log
    $mutex.Dispose()
    exit 0
}

# Item 8: serving means OUR cockpit answered, not merely that something did.
function Test-CockpitServing {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:3080/" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -ne 200) { return $false }
        return ($r.Content -match '__DSH_BOOT__')
    } catch { return $false }
}

Require-Command 'node' 'Install Node 22+ (README step 1) and reopen the shortcut.'
# MIGRATION 2026-08-21: the stack installs/runs dsh via `pnpm dlx`, not `npx`.
# npm 11's dependency resolver hangs indefinitely on this Node 25 box for every
# dsh version past rc.7 (measured: rc.8 and 0.1.1-rc.2 both never complete,
# --dry-run included, so it is resolution not build); pnpm's resolver installs
# the same graph in ~50s. dsh's own docs require Node ^22.19 || >=24, and this
# box runs 25 -- so pnpm is the supported install path here, not a workaround.
Require-Command 'pnpm' 'Install pnpm 11 (README step 1: "npm i -g pnpm"). The stack runs dsh via "pnpm dlx" because npm''s resolver hangs on this Node version.'
Require-Command 'lms'  'Install LM Studio, then run its CLI bootstrap so "lms" is on PATH (README step 1).'

# 1) LM Studio server up, and actually answering.
# Item 12: capture this instead of Out-Null. The original defect item 1 blames
# was exactly an Out-Null eating a real failure.
# Capture without *>> : that appends in a different encoding than the UTF-8
# log (producing mojibake) and wraps lms's stderr success banner as a
# PowerShell NativeCommandError, so a healthy start reads as a failure.
$lmsOut = & lms server start 2>&1
if ($lmsOut) { $lmsOut | ForEach-Object { "lms: $_" } | Add-Content $log }
$apiUp = $false
$deadline = (Get-Date).AddSeconds(60)
do {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:1234/v1/models" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) { $apiUp = $true; break }
    } catch { Start-Sleep -Seconds 2 }
} until ((Get-Date) -gt $deadline)
"LM Studio API up: $apiUp" | Add-Content $log
if (-not $apiUp) { Fail-Loud "LM STUDIO API NEVER ANSWERED on 127.0.0.1:1234 after 60s. LM Studio is installed but its local server did not come up - open LM Studio once by hand and check its Developer/Server tab." }

# 2) Brain resident with the stable id, locally? Runs even if :3080 is up.
function Test-BrainLoaded {
    $ps = lms ps --json 2>$null | ConvertFrom-Json
    return [bool]($ps | Where-Object { $_.identifier -eq 'qwen/qwen3.8-27b' -and -not $_.deviceIdentifier })
}
if (-not (Test-BrainLoaded)) {
    foreach ($attempt in 1, 2) {
        "brain load attempt $attempt" | Add-Content $log
        $loaderOut = & node "$env:USERPROFILE\.lmstudio\scripts\Load-OpenCode-Qwen.mjs" 2>&1
        if ($loaderOut) { $loaderOut | ForEach-Object { "  loader: $_" } | Add-Content $log }
        if (Test-BrainLoaded) { break }
        Start-Sleep -Seconds 5
    }
    if (-not (Test-BrainLoaded)) {
        "BRAIN LOAD FAILED TWICE -- see the loader output above in this file." | Add-Content $log
        "The cockpit will still open, but with no local model loaded." | Add-Content $log
        Start-Process notepad $log
        # keep going: the cockpit page is still useful for reading sessions
    }
}

# 3) Harness (pinned) -- only if not already SERVING.
if (Test-CockpitServing) {
    "cockpit already serving on :3080 - reusing it" | Add-Content $log
} else {
    # Items 10/11 (+ MIGRATION): the pnpm dlx process tree has three parts --
    # the `pnpm.mjs dlx @deepseek-ai/dsh@... web` launcher, a `cmd /c dsh web`
    # wrapper, and the `...@deepseek-ai\dsh\...\lib\bin.js web` server. The
    # launcher and server both carry "@deepseek-ai/dsh" + "web"; the cmd wrapper
    # carries only "dsh" + "web". Match all three so no orphan survives, and
    # still leave alone anything genuinely serving on another port (a deliberate
    # second instance).
    $pattern = '(deepseek-ai(/|\\)dsh.*\bweb\b)|(\bdsh\b.*\bweb\b.*(dlx|bin\.js|pnpm))|(\bdsh\b.{0,8}web)'
    # PE-3 (gate 2026-08-21): a deploy validates by running
    # `pnpm dlx @deepseek-ai/dsh@... web --dump-config` and installs plugins via
    # `... plugin ... add` -- both carry "@deepseek-ai/dsh"+"web" and would be
    # force-killed by this sweep if a launch raced a deploy. They serve no port,
    # so the port-guard below does not save them. Exclude those transient
    # non-server invocations explicitly.
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern -and $_.CommandLine -notmatch '(--dump-config|\bplugin\b)' })
    foreach ($c in $candidates) {
        $ports = @(Get-NetTCPConnection -State Listen -OwningProcess $c.ProcessId -ErrorAction SilentlyContinue)
        $otherPort = @($ports | Where-Object { $_.LocalPort -ne 3080 })
        if ($otherPort.Count -gt 0) {
            "leaving PID $($c.ProcessId) alone - it serves on port(s) $(($otherPort.LocalPort | Sort-Object -Unique) -join ',')" | Add-Content $log
            continue
        }
        "clearing stale PID $($c.ProcessId) ($($c.Name)) - alive but not serving" | Add-Content $log
        try { Stop-Process -Id $c.ProcessId -Force -ErrorAction Stop } catch { "  could not stop PID $($c.ProcessId): $_" | Add-Content $log }
    }
    if ($candidates.Count -gt 0) { Start-Sleep -Seconds 3 }

    $env:DSH_PERMISSION_MODE = 'danger-full-access'
    # Item 13: cwd becomes the server's default workspace. NEVER the drive root
    # (rc.7 silently fails to bind one) and NEVER the home directory (that hands
    # a full-access agent every folder the user owns). Create the intended
    # workspace instead of falling back to something broader.
    $workspace = "$env:USERPROFILE\Desktop\Code"
    if (-not (Test-Path $workspace)) {
        "workspace $workspace did not exist - creating it" | Add-Content $log
        New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    }
    Set-Location $workspace
    "workspace (server cwd): $workspace" | Add-Content $log

    # Item 5/9: capture output, to a per-run file so concurrent or successive
    # launches cannot overwrite the evidence. Two files: PowerShell refuses to
    # redirect stdout and stderr to one path.
    # MIGRATION: `pnpm dlx` (not npx) - see the pnpm Require-Command above.
    # pnpm.cmd, NOT bare `pnpm`: on Windows `Get-Command pnpm` resolves to
    # pnpm.ps1 (a script), and Start-Process cannot launch a .ps1 as a process
    # -- it returns a blank PID and nothing serves. The batch shim pnpm.cmd is
    # the launchable entry, exactly as the old code used npx.cmd.
    # --no-open: dsh opens the browser itself on start; suppress it so THIS
    # launcher stays the one that opens the browser LAST, only after the serving
    # check passes (otherwise a browser pops on a not-yet-ready or dead server).
    $dsh = Start-Process -PassThru -WindowStyle Hidden pnpm.cmd `
        -ArgumentList 'dlx','"@deepseek-ai/dsh@0.1.1-rc.2"','web','--no-open' `
        -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr
    "server launched via pnpm dlx, launcher PID $($dsh.Id); output -> $serverLog" | Add-Content $log

    function Dump-ServerOutput {
        foreach ($f in @($serverErr, $serverLog)) {
            if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
                "--- $(Split-Path $f -Leaf) ---" | Add-Content $log
                Get-Content $f -Tail 40 | Add-Content $log
            }
        }
    }

    # 300s covers a cold pnpm dlx download (first run of a new version pulls
    # ~190 packages; ~50s warm, longer cold on a slow connection).
    $serving = $false
    $deadline = (Get-Date).AddSeconds(300)
    do {
        Start-Sleep -Seconds 3
        # NOTE: $dsh is the `pnpm dlx` launcher process, which spawns a cmd
        # wrapper and then the node server (verified: pnpm.mjs -> cmd -> bin.js).
        # Its exit is an early signal but not proof either way, so serving is
        # always decided by the HTTP check below.
        if ($dsh.HasExited -and -not (Test-CockpitServing)) {
            "LAUNCH WRAPPER EXITED (code $($dsh.ExitCode)) and nothing is serving." | Add-Content $log
            Dump-ServerOutput
            Fail-Loud "Startup aborted: the harness never came up. Output captured above."
        }
        $serving = Test-CockpitServing
    } until ($serving -or (Get-Date) -gt $deadline)

    if (-not $serving) {
        $listening = [bool](Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)
        "DSH NEVER SERVED after 300s. Port 3080 listening: $listening" | Add-Content $log
        if ($listening) { "  Port is held but the page does not answer - wedged server (known rc.7 defect with sessions >1MB), or a different app owns 3080." | Add-Content $log }
        Dump-ServerOutput
        Fail-Loud "Startup failed. Not opening a browser at a dead port."
    }
    "cockpit serving on :3080" | Add-Content $log
}

# 4) Browser last -- only ever reached when OUR cockpit answered.
Start-Process "http://127.0.0.1:3080"
Release-Mutex
if ($dsh) { Wait-Process -Id $dsh.Id }
