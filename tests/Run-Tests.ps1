# HALO stack test suite.
#
# WHY THIS EXISTS
# Every defect found on 2026-08-21 was discoverable in seconds by a check
# nobody ran, because the stack worked on the machine where it was written and
# that was accepted as proof it worked. Five releases shipped claiming
# verification while the repository could not load a model on any other
# machine.
#
# So these tests assert the things that were ASSERTED and untrue, not the
# things that were already fine. Each one names the defect it exists to catch.
#
#   .\tests\Run-Tests.ps1              # static + live checks (fast, safe)
#   .\tests\Run-Tests.ps1 -Static      # static only: no running stack needed
#   .\tests\Run-Tests.ps1 -CleanClone  # + full clone-to-temp deploy (slow)
#
# Exit code is the number of failures, so CI and hooks can gate on it.
# ASCII only: PowerShell 5.1 misparses BOM-less UTF-8 punctuation.
[CmdletBinding()]
param(
    [switch]$Static,
    [switch]$CleanClone
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$script:pass = 0; $script:fail = 0; $script:skip = 0
$script:failures = @()

function Test-Case([string]$id, [string]$name, [scriptblock]$body) {
    try {
        $r = & $body
        if ($r -eq $true) { $script:pass++; Write-Host ("  PASS  [{0}] {1}" -f $id, $name) -ForegroundColor Green }
        elseif ($r -eq 'skip') { $script:skip++; Write-Host ("  SKIP  [{0}] {1}" -f $id, $name) -ForegroundColor DarkGray }
        else {
            $script:fail++; $script:failures += "[$id] $name -- $r"
            Write-Host ("  FAIL  [{0}] {1}" -f $id, $name) -ForegroundColor Red
            Write-Host ("        {0}" -f $r) -ForegroundColor Red
        }
    } catch {
        $script:fail++; $script:failures += "[$id] $name -- threw: $_"
        Write-Host ("  FAIL  [{0}] {1} -- threw: {2}" -f $id, $name, $_) -ForegroundColor Red
    }
}

function Get-Text([string]$rel) { Get-Content (Join-Path $repo $rel) -Raw -ErrorAction Stop }

Write-Host "`n=== HALO stack tests ===" -ForegroundColor Cyan
Write-Host "repo: $repo`n"

# ---------------------------------------------------------------- static ----
Write-Host "-- static: repository contents --"

# S1: the defect that made the repo unusable for everyone who downloaded it.
Test-Case 'S1' 'no loader imports a path that is not in the repository' {
    $bad = @()
    foreach ($f in Get-ChildItem (Join-Path $repo 'lmstudio') -Filter *.mjs) {
        # Comment lines describe the OLD defect; only executable imports count.
        $code = (Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*(//|/\*|\*)' }) -join "`n"
        foreach ($m in [regex]::Matches($code, 'from\s+"(\./[^"]+)"')) {
            $spec = $m.Groups[1].Value
            $resolved = Join-Path $f.DirectoryName ($spec -replace '/', '\')
            if (-not (Test-Path $resolved)) { $bad += "$($f.Name) imports '$spec' which does not exist in the repo" }
        }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}

Test-Case 'S1b' 'every bare dependency the loaders import is pinned in lmstudio/package.json' {
    $pkg = (Get-Text 'lmstudio\package.json' | ConvertFrom-Json)
    $deps = @($pkg.dependencies.PSObject.Properties.Name)
    $missing = @()
    foreach ($f in Get-ChildItem (Join-Path $repo 'lmstudio') -Filter *.mjs) {
        $code = (Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*(//|/\*|\*)' }) -join "`n"
        foreach ($m in [regex]::Matches($code, 'from\s+"([^".][^"]*)"')) {
            $spec = $m.Groups[1].Value
            if ($spec -like 'node:*' -or $spec -like './*' -or $spec -like '../*') { continue }
            $root = if ($spec -like '@*') { ($spec -split '/')[0..1] -join '/' } else { ($spec -split '/')[0] }
            if ($deps -notcontains $root) { $missing += "$($f.Name) imports '$root', not in package.json" }
        }
    }
    if ($missing.Count) { return ($missing -join '; ') }
    $true
}

# S2: the author's machine leaking into files that deploy byte-for-byte.
Test-Case 'S2' 'no deployed file hardcodes a specific user profile path' {
    $map = Get-Text 'scripts\Deploy-ToLive.ps1'
    $srcs = [regex]::Matches($map, 'src\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    $bad = @()
    foreach ($s in $srcs) {
        $p = Join-Path $repo $s
        if (-not (Test-Path $p)) { continue }
        foreach ($line in Get-Content $p) {
            # Comments may discuss the path; settings must not contain it.
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*//') { continue }
            if ($line -match 'C:\\Users\\[A-Za-z0-9._-]+\\') { $bad += "$s : $($line.Trim())" }
        }
    }
    if ($bad.Count) { return ("hardcoded profile path in deployed file(s): " + ($bad -join ' | ')) }
    $true
}

# A1/A2/A4: one decode lane. Both doors onto the 2026-08-20 fan-out failure.
Test-Case 'A1' 'workflow engine concurrency is capped (default resolves to CPU count)' {
    $y = Get-Text 'dsh\agent-presets\halo-standard\agent.cordis.yml'
    if ($y -notmatch 'maxConcurrentAgents:\s*1\b') { return 'maxConcurrentAgents is not pinned to 1 on the workflow engine row' }
    if ($y -notmatch 'maxTotalAgents:\s*\d+') { return 'maxTotalAgents has no ceiling (cannot be set from a workflow script)' }
    $true
}
Test-Case 'A2' 'background subagent jobs are capped per owner (default is 10)' {
    $y = Get-Text 'dsh\cordis.patch.yml'
    if ($y -notmatch 'maxConcurrentJobsPerOwner:\s*1\b') { return 'jobs-local has no per-owner cap; one turn could start 10 background children on a 1-slot model' }
    $true
}

# A3: the mechanism behind the 2,396,400-token single turn.
Test-Case 'A3' 'LLM retries are bounded (omitting retryPolicy means five)' {
    $y = Get-Text 'dsh\settings.yaml'
    if ($y -notmatch 'retryPolicy:') { return 'retryPolicy is unset -> 5 retries, each re-prefilling the whole context' }
    if ($y -notmatch 'maxRetries:\s*[01]\b') { return 'maxRetries is not bounded to 0 or 1' }
    $true
}

# F3 (2026-08-20): compaction budgets must be able to converge, on every machine.
Test-Case 'A5' 'compaction can actually converge, and scales to every machine profile' {
    $y = Get-Text 'dsh\settings.yaml'
    # Active settings only: the comment above the block names retainTokens in
    # order to explain why it must not be used.
    $active = (Get-Content (Join-Path $repo 'dsh\settings.yaml') | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($active -match 'retainTokens:') { return 'retainTokens is absolute; it must be a ratio or a smaller box gets retain >= threshold' }
    $th = [double]([regex]::Match($y, 'thresholdRatio:\s*([\d.]+)').Groups[1].Value)
    $re = [double]([regex]::Match($y, 'retainRatio:\s*([\d.]+)').Groups[1].Value)
    $mx = [int]([regex]::Match($y, '(?s)compaction-basic:.*?maxTokens:\s*(\d+)').Groups[1].Value)
    if ($re -ge $th) { return "retainRatio ($re) >= thresholdRatio ($th): compaction can never reduce anything" }
    foreach ($w in 131072, 40448, 32768) {
        $span = [int](($th - $re) * $w)
        $ratio = $span / $mx
        # Inclusive: 8192 against a 131,072 window is exactly 4.0, and that
        # is the value that reproduced the failure. `-gt 4` let it through.
        if ($ratio -ge 4) { return "on a $w window the summarizer must fold $span tokens into $mx ({0:N1}:1) -- at or above 4:1 it truncates, which is the 2026-08-20 treadmill" -f $ratio }
    }
    $true
}

# S3 / L-series: launchers must not hide failure or open a browser on a dead port.
Test-Case 'L1' 'launchers capture the output of the process they start' {
    $bad = @()
    foreach ($f in 'dsh\Start-DSH.ps1', 'dsh\Start-MissionControl.ps1') {
        $t = Get-Text $f
        foreach ($m in [regex]::Matches($t, 'Start-Process[^\r\n]*-PassThru[^\r\n]*')) {
            $line = $m.Value
            if ($line -match 'notepad|http://') { continue }   # opening a viewer, not a server
            if ($line -notmatch 'RedirectStandardOutput' -and $t -notmatch 'RedirectStandardOutput') {
                $bad += "$f starts a process with no output capture"
            }
        }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}
Test-Case 'L2' 'readiness is an HTTP identity check, never a bare TCP listen' {
    $bad = @()
    foreach ($pair in @(@('dsh\Start-DSH.ps1', '__DSH_BOOT__'), @('dsh\Start-MissionControl.ps1', '"services"'))) {
        $t = Get-Text $pair[0]
        if ($t -notmatch 'Invoke-WebRequest') { $bad += "$($pair[0]) has no HTTP readiness check" }
        if ($t -notmatch [regex]::Escape($pair[1])) { $bad += "$($pair[0]) does not identity-check the response (marker $($pair[1]))" }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}
Test-Case 'L3' 'no launcher opens a browser without first proving the service serves' {
    # TE4 (gate 2026-08-21): the earlier "is there an exit within 20 lines"
    # check was defeatable -- keep the real guard, drop its exit, add a dead
    # `if($false){exit 1}` nearby, and the browser opened unconditionally while
    # the test passed. This version is STRUCTURAL: it walks the readiness guard
    # (`if (-not $serving)` / `if (Test-*Serving)`) with brace-depth tracking
    # and requires an exit/Fail-Loud to occur INSIDE that block, before the
    # block closes. A dead `if($false){exit 1}` elsewhere no longer counts,
    # because it is not the readiness guard's own body.
    $bad = @()
    foreach ($f in 'dsh\Start-DSH.ps1', 'dsh\Start-MissionControl.ps1') {
        $lines = Get-Content (Join-Path $repo $f)
        # EVERY browser-open must be covered. Two legitimate shapes:
        #  (a) reuse:  if (Test-*Serving) { open; exit 0 }  -- open INSIDE the
        #      positive-serving block, so it only runs when serving is true.
        #  (b) final:  if (-not $serving) { ...; exit 1 }   then open at depth 0
        #      -- a negative guard that EXITS before the open is reached.
        # TE4 defeats a naive check by dropping the exit from (b)'s block; the
        # brace-depth walk below requires the exit to be inside the guard body.
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch 'Start-Process\s+"http://127\.0\.0\.1:(3080|3090)"') { continue }
            $ok = $false
            # Shape (a): is this open INSIDE an `if (Test-*Serving) {` block that
            # has not yet closed? Walk back tracking brace depth.
            for ($j = $i - 1; $j -ge 0 -and $j -ge $i - 8; $j--) {
                if ($lines[$j] -match 'if\s*\(\s*Test-(CockpitServing|MCServing)\b\s*\)\s*\{') { $ok = $true; break }
                if ($lines[$j] -match '^\S' -and $lines[$j] -notmatch 'Start-Process') { break }
            }
            # Shape (b): a preceding `if (-not $serving) {` whose own block exits
            # before it closes.
            if (-not $ok) {
                for ($j = 0; $j -lt $i; $j++) {
                    if ($lines[$j] -notmatch 'if\s*\(\s*-not\s+\$serving\b') { continue }
                    $depth = 0; $started = $false; $exits = $false
                    for ($k = $j; $k -lt $i; $k++) {
                        $depth += ([regex]::Matches($lines[$k], '\{')).Count - ([regex]::Matches($lines[$k], '\}')).Count
                        if (([regex]::Matches($lines[$k], '\{')).Count -gt 0) { $started = $true }
                        if ($started -and ($lines[$k] -match '\bexit\s+1\b' -or $lines[$k] -match '\bFail-Loud\b')) { $exits = $true }
                        if ($started -and $depth -le 0) { break }
                    }
                    if ($exits) { $ok = $true; break }
                }
            }
            if (-not $ok) { $bad += "$f line $($i+1): browser opens without a serving guard that exits on failure" }
        }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}

Test-Case 'L4' 'launchers parse under PowerShell 5.1 and are ASCII-only' {
    $bad = @()
    foreach ($f in 'dsh\Start-DSH.ps1', 'dsh\Start-MissionControl.ps1', 'scripts\Deploy-ToLive.ps1', 'tests\Run-Tests.ps1') {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$errs)
        if ($errs) { $bad += "$f : $($errs[0].Message)" }
        if ((Get-Content (Join-Path $repo $f) -Raw) -match '[^\x00-\x7F]') { $bad += "$f contains non-ASCII" }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}

# C13: the console that reported a dead run as healthy for 4h41m.
Test-Case 'C13' 'Mission Control corroborates the harness running flag against progress' {
    $t = Get-Text 'mission-control\mission-control.mjs'
    if ($t -notmatch 'STALL_MS') { return 'no stall threshold defined' }
    if ($t -notmatch 'stalled:') { return 'sessions are not marked stalled' }
    # Anchored: 'claimsRunning: !!s.running,' legitimately records the raw
    # claim and must not trip this. Only a bare `running:` may not.
    if ($t -match '(?m)^\s*running:\s*!!s\.running\s*,') { return 'running is still the raw upstream flag, uncorroborated' }
    $true
}
Test-Case 'C14' 'Mission Control can stop a single session without killing the harness' {
    $t = Get-Text 'mission-control\mission-control.mjs'
    if ($t -notmatch 'stop-session') { return 'no per-session stop endpoint' }
    if ($t -notmatch 'session\.cancel') { return 'stop endpoint does not call the harness cancel API' }
    $true
}

# The two escaping traps that produced a blank console twice.
# MC1/MC2: the two escaping traps that produced a blank console twice
# (a swallowed quote, and a Windows path that lost its backslashes). The server
# has boot-time validators for both. Run it and read the real verdict -- an
# earlier version of this suite re-implemented the check with its own regex,
# failed to match, and SKIPped both. A test that opts itself out is not a test.
Test-Case 'MC1' 'Mission Control boot validators pass (UI script parses, paths intact)' {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return 'skip' }
    $out = Join-Path $env:TEMP 'halo-mc-boot.out'
    $err = Join-Path $env:TEMP 'halo-mc-boot.err'
    $p = Start-Process -PassThru -NoNewWindow -FilePath node `
        -ArgumentList (Join-Path $repo 'mission-control\mission-control.mjs') `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }
    $exited = $p.HasExited
    $code = if ($exited) { $p.ExitCode } else { $null }
    if (-not $exited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $stderr = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue

    # A validator trip is always FATAL on stderr, whatever else happens.
    if ($stderr -match 'FATAL') {
        return ("boot validator tripped: " + (($stderr -split "`n" | Where-Object { $_ -match 'FATAL|Invalid|line' } | Select-Object -First 3) -join ' / '))
    }
    # Port already taken means the validators ran and passed before listen().
    if ($stderr -match 'EADDRINUSE') { return $true }
    if (-not $exited) { return $true }
    return "Mission Control exited during boot (code $code): " + ($stderr -split "`n" | Select-Object -First 3 | Out-String)
}

# B: public claims must match what was measured.
Test-Case 'B1' 'no unsupported claim on either public surface' {
    $banned = @(
        @{ p = 'Frontier-class coding agents'; why = 'not established by any benchmark run here' }
        @{ p = 'fan-out work at 4\.3';         why = 'the 4.3x figure is task speed, not fan-out; fan-out failed on one decode lane' }
        @{ p = 'fan-out at 4\.3';              why = 'same claim in the diagram' }
        @{ p = 'proven continuity across forced compaction'; why = 'proven at 65,536, false at 131,072' }
        @{ p = 'whichever silicon is fastest'; why = 'routing is unmeasured (V5/G6 open)' }
        @{ p = 'whichever box is fastest';     why = 'routing is unmeasured (V5/G6 open)' }
        @{ p = 'One screen that tells you the truth'; why = 'disproven by a 4h41m stall shown as healthy' }
        @{ p = '5-tab operator console';       why = 'contradicted "six tabs" on the same page' }
    )
    $bad = @()
    foreach ($f in 'site\index.html', 'docs\index.html', 'README.md') {
        $t = Get-Text $f
        foreach ($b in $banned) { if ($t -match $b.p) { $bad += "$f still claims '$($b.p)' -- $($b.why)" } }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}
Test-Case 'B2' 'the two public surfaces do not disagree with each other' {
    $a = Get-Text 'site\index.html'; $b = Get-Text 'docs\index.html'
    $va = [regex]::Match($a, 'class="pill">v([\d.]+)<').Groups[1].Value
    $vb = [regex]::Match($b, 'class="pill">v([\d.]+)<').Groups[1].Value
    if ($va -ne $vb) { return "version pill differs: site v$va vs docs v$vb" }
    $true
}
Test-Case 'B3' 'the published version pill matches the newest CHANGELOG entry' {
    $pill = [regex]::Match((Get-Text 'site\index.html'), 'class="pill">v([\d.]+)<').Groups[1].Value
    $top = [regex]::Match((Get-Text 'CHANGELOG.md'), '##\s*\[([\d.]+)\]').Groups[1].Value
    if ($pill -ne $top) { return "site says v$pill, newest CHANGELOG entry is $top" }
    $true
}

# README must describe what the code actually requires.
Test-Case 'R1' 'README documents every prerequisite the deploy enforces' {
    $d = Get-Text 'scripts\Deploy-ToLive.ps1'
    $r = Get-Text 'README.md'
    $names = [regex]::Matches($d, "name\s*=\s*'([a-z]+)';\s*why") | ForEach-Object { $_.Groups[1].Value }
    if (-not $names) { return 'could not find the deploy prerequisite list' }
    $missing = @($names | Where-Object { $r -notmatch "\b$_\b" })
    if ($missing.Count) { return ("README never mentions: " + ($missing -join ', ')) }
    $true
}
Test-Case 'R2' 'README tells the user how to make a .ps1 shortcut that actually runs' {
    $r = Get-Text 'README.md'
    if ($r -notmatch 'powershell\.exe.*-File') { return 'shortcut instructions do not specify a powershell.exe Target; a shortcut straight to a .ps1 opens an editor on Windows 11' }
    $true
}

# AGENTS.md deploys into a shared directory (issue #35).
# GATE-2026-08-21: tests for the defects the GauntletGate panel found.
Test-Case 'SEC1' 'Mission Control runs no subprocess with shell:true (PE-1 RCE)' {
    $t = Get-Text 'mission-control\mission-control.mjs'
    # Only executable lines; the fix comment mentions shell:true to explain it.
    $code = (Get-Content (Join-Path $repo 'mission-control\mission-control.mjs') | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    if ($code -match 'shell:\s*true') { return 'a shell:true subprocess remains - args are concatenated, request strings can inject' }
    $true
}
Test-Case 'SEC2' 'every state-changing Mission Control POST requires the action token (PE-1/QA2)' {
    $t = Get-Text 'mission-control\mission-control.mjs'
    if ($t -notmatch 'ACTION_TOKEN' -or $t -notmatch 'function actionAuthorized') { return 'no action-token auth defined' }
    # Each POST action route must call actionAuthorized before doing work.
    $routes = [regex]::Matches($t, "req\.method === 'POST' && url\.pathname(?:\.startsWith\('/api/action/'\)| === '/api/action/[a-z-]+'| === '/api/validate-config')")
    $missing = 0
    foreach ($m in $routes) {
        $after = $t.Substring($m.Index, [Math]::Min(400, $t.Length - $m.Index))
        if ($after -notmatch 'actionAuthorized\(req\)') { $missing++ }
    }
    if ($missing -gt 0) { return "$missing state-changing POST route(s) do not check actionAuthorized" }
    $true
}
Test-Case 'W1T' 'loaders treat an unrunnable verifier as UNVERIFIED, never a failed load (W1)' {
    $bad = @()
    foreach ($f in 'lmstudio\Load-OpenCode-Qwen.mjs', 'lmstudio\Load-Worker-Coder.mjs') {
        $t = Get-Text $f
        # The lms ps call must be inside a try/catch that reports UNVERIFIED,
        # and the loader must verify via the SDK's listLoaded first.
        if ($t -notmatch 'listLoaded') { $bad += "$f does not verify via the SDK (listLoaded)" }
        if ($t -notmatch 'UNVERIFIED') { $bad += "$f has no UNVERIFIED path - a broken verifier still fails the load" }
        # The execSync verify must sit inside a try/catch (the UNVERIFIED
        # path). Detect the OLD unguarded shape: a top-level (2-space indent
        # or less) `const ps = JSON.parse(execSync(...))` with no try before it
        # on the same logical block. The current code indents it inside try{}.
        foreach ($m in [regex]::Matches($t, '(?m)^([ ]*)const ps = JSON\.parse\(execSync\("lms ps --json"\)')) {
            if ($m.Groups[1].Value.Length -lt 4) { $bad += "$f has a top-level (unguarded) execSync verify" }
        }
    }
    if ($bad.Count) { return ($bad -join '; ') }
    $true
}
Test-Case 'PE2T' 'the machine marker is written AFTER post-validation, inside the transaction' {
    $lines = Get-Content (Join-Path $repo 'scripts\Deploy-ToLive.ps1')
    $markerLine = ($lines | Select-String -Pattern 'Set-Content -Path "\$U\\\.dsh\\machine"' | Select-Object -First 1).LineNumber
    $validateLine = ($lines | Select-String -Pattern 'live config composes clean - no unmatched' | Select-Object -First 1).LineNumber
    if (-not $markerLine) { return 'marker write not found' }
    if (-not $validateLine) { return 'post-validate success line not found' }
    if ($markerLine -lt $validateLine) { return "marker written at line $markerLine, BEFORE post-validation at $validateLine - a rolled-back deploy leaves a poisoned identity" }
    $true
}
Test-Case 'W2T' 'the deploy audit checks WHERE the scheduled task points, not just that it exists' {
    $t = Get-Text 'scripts\Deploy-ToLive.ps1'
    if ($t -notmatch 'snapPointsHere') { return 'audit does not compute whether the task points at this home' }
    # The PASS/FAIL must DEPEND on snapPointsHere, not merely mention it. A
    # mutation that drops it from $snapOk must fail here.
    if ($t -notmatch '\$snapOk\s*=\s*\([^\r\n]*\$snapPointsHere') { return 'snapPointsHere is computed but not wired into $snapOk - a repointed task would still PASS' }
    $true
}

Test-Case 'G1' 'every deployed AGENTS.md declares its scope' {
    $bad = @()
    foreach ($f in Get-ChildItem $repo -Recurse -Filter 'AGENTS.md' -File | Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.git\\' }) {
        $head = (Get-Content $f.FullName -TotalCount 10) -join "`n"
        if ($head -notmatch '(?m)^SCOPE:') { $bad += $f.FullName.Replace($repo, '') }
    }
    if ($bad.Count) { return ("no SCOPE header: " + ($bad -join ', ')) }
    $true
}

# ------------------------------------------------------------------ live ----
if (-not $Static) {
    Write-Host "`n-- live: this machine --"

    Test-Case 'V1' 'the deployed loaders resolve THEIR OWN import (not a substitute)' {
        # TE1 (gate 2026-08-21): the old version wrote its own hardcoded probe
        # and ran that, so it passed even when the real loader imported a broken
        # path. Now it extracts and runs the loader's ACTUAL import line, and
        # cross-checks it against the file, so a reintroduced vendor import
        # fails here.
        $s = "$env:USERPROFILE\.lmstudio\scripts"
        $bad = @()
        foreach ($name in 'Load-OpenCode-Qwen.mjs', 'Load-Worker-Coder.mjs', 'Sweep-MTP.mjs') {
            $f = Join-Path $s $name
            if (-not (Test-Path $f)) { continue }
            $line = (Get-Content $f | Where-Object { $_ -match '^\s*import\s' -and $_ -match 'lmstudio' } | Select-Object -First 1)
            if (-not $line) { $bad += "$name has no @lmstudio import line"; continue }
            # Run the loader's real import line, from the loader's own directory,
            # so module resolution matches exactly what the loader gets.
            $probe = Join-Path $s ('halo-test-realimport-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.mjs')
            Set-Content -Path $probe -Encoding utf8 -Value ($line + "`nconsole.log(typeof LMStudioClient === 'function' ? 'ok' : 'bad');")
            $out = (& node $probe 2>&1) -join ' '
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
            if ($out -notmatch '\bok\b') { $bad += "$name import fails to resolve: $out" }
        }
        if (-not (Test-Path (Join-Path $s 'Load-OpenCode-Qwen.mjs'))) { return 'skip' }
        if ($bad.Count) { return ($bad -join '; ') }
        $true
    }

    Test-Case 'V2' 'the deployed loaders do not depend on an uncommitted vendor directory' {
        $s = "$env:USERPROFILE\.lmstudio\scripts"
        if (-not (Test-Path "$s\Load-OpenCode-Qwen.mjs")) { return 'skip' }
        $bad = @()
        foreach ($f in Get-ChildItem $s -Filter *.mjs) {
            $t = Get-Content $f.FullName -Raw
            foreach ($m in [regex]::Matches($t, '^\s*import[^\r\n]*from\s+"(\./vendor/[^"]+)"', 'Multiline')) {
                $bad += "$($f.Name) imports $($m.Groups[1].Value)"
            }
        }
        if ($bad.Count) { return ($bad -join '; ') }
        $true
    }

    Test-Case 'V3' 'live config matches the repository (no undeclared drift)' {
        $d = Get-Text 'scripts\Deploy-ToLive.ps1'
        $bad = @()
        foreach ($m in [regex]::Matches($d, 'src\s*=\s*"([^"]+)";\s*dst\s*=\s*"([^"]+)"')) {
            $src = Join-Path $repo $m.Groups[1].Value
            $dst = $m.Groups[2].Value -replace '\$U', $env:USERPROFILE
            # .env is template-only and deliberately never overwritten, so it
            # is expected to differ from its template. The capture group does
            # not include the trailing skipIfExists flag, so check the line.
            if ($m.Groups[0].Value -match 'skipIfExists' -or $m.Groups[1].Value -match 'dot-env') { continue }
            if (-not (Test-Path $src) -or -not (Test-Path $dst)) { continue }
            if ((Get-FileHash $src).Hash -ne (Get-FileHash $dst).Hash) { $bad += $m.Groups[1].Value }
        }
        if ($bad.Count) { return ("live differs from repo (deploy or sync needed): " + ($bad -join ', ')) }
        $true
    }

    Test-Case 'V4' 'a wedged port is not mistaken for a healthy service' {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 39997)
        $l.Start()
        $healthy = $false
        try { $r = Invoke-WebRequest 'http://127.0.0.1:39997/' -UseBasicParsing -TimeoutSec 4; $healthy = ($r.StatusCode -eq 200) } catch { $healthy = $false }
        $l.Stop()
        if ($healthy) { return 'a listening-but-silent port answered as healthy' }
        $true
    }

    Test-Case 'V5' 'the cockpit, if up, is the harness and not something else on 3080' {
        try { $r = Invoke-WebRequest 'http://127.0.0.1:3080/' -UseBasicParsing -TimeoutSec 5 } catch { return 'skip' }
        if ($r.Content -notmatch '__DSH_BOOT__') { return 'something is serving 3080 but it is not the dsh cockpit' }
        $true
    }
}

# ----------------------------------------------------------- clean clone ----
if ($CleanClone) {
    Write-Host "`n-- clean clone: a stranger's first run --"
    Test-Case 'CC1' 'a fresh clone deploys into an empty home without the author machine' {
        $tmp = Join-Path $env:TEMP ("halo-cleanclone-" + (Get-Date -Format 'yyyyMMddHHmmss'))
        $clone = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            & git clone --quiet --depth 1 "file://$($repo -replace '\\','/')" $clone 2>&1 | Out-Null
            if (-not (Test-Path (Join-Path $clone 'scripts\Deploy-ToLive.ps1'))) { return 'clone failed' }
            # The whole point: nothing outside the clone may be required.
            $bad = @()
            foreach ($f in Get-ChildItem (Join-Path $clone 'lmstudio') -Filter *.mjs) {
                foreach ($m in [regex]::Matches((Get-Content $f.FullName -Raw), 'from\s+"(\./[^"]+)"')) {
                    $p = Join-Path $f.DirectoryName ($m.Groups[1].Value -replace '/', '\')
                    if (-not (Test-Path $p)) { $bad += "$($f.Name) -> $($m.Groups[1].Value)" }
                }
            }
            if ($bad.Count) { return ("fresh clone is missing files its own code imports: " + ($bad -join ', ')) }
            $env:DEPLOY_DRYRUN = '1'
            $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clone 'scripts\Deploy-ToLive.ps1') 2>&1) -join "`n"
            Remove-Item Env:\DEPLOY_DRYRUN -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { return "dry-run deploy from a fresh clone failed: " + ($out -split "`n" | Select-Object -Last 5 | Out-String) }
            $true
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --------------------------------------------------------------- summary ----
Write-Host "`n=== summary ===" -ForegroundColor Cyan
Write-Host ("  {0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skip)
if ($script:fail -gt 0) {
    Write-Host "`nfailures:" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
exit $script:fail
