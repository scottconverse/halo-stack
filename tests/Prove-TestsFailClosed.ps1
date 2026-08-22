# Mutation check: reintroduce each real defect and confirm the suite CATCHES it.
#
# A green suite proves nothing on its own -- it may simply be unable to fail.
# Every check below puts a specific historical bug back into a scratch copy of
# the repository, runs the suite against that copy, and asserts the matching
# test goes red. The scratch copy is deleted afterwards; nothing here touches
# the working tree or the live machine.
#
#   .\tests\Prove-TestsFailClosed.ps1
#
# Exit code is the number of mutations the suite FAILED to catch.
# ASCII only: PowerShell 5.1 misparses BOM-less UTF-8 punctuation.

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$missed = 0

# Each mutation names the defect it restores and the test that must catch it.
$mutations = @(
    @{ id = 'S1'; defect = 'loader imports the uncommitted vendor SDK again (the defect that made the repo unusable)'
       file = 'lmstudio\Load-OpenCode-Qwen.mjs'
       from = 'import { LMStudioClient } from "@lmstudio/sdk";'
       to   = 'import { LMStudioClient } from "./vendor/node_modules/@lmstudio/sdk/dist/index.mjs";' }

    @{ id = 'S2'; defect = 'a deployed config hardcodes the author user profile again'
       file = 'dsh\cordis.patch.yml'
       from = "MEMORY_FILE_PATH: !!js `"process.env.USERPROFILE + '/.dsh/memory/memory.json'`""
       to   = "MEMORY_FILE_PATH: 'C:\Users\scott\.dsh\memory\memory.json'" }

    @{ id = 'A1'; defect = 'workflow concurrency uncapped -> engine resolves it to CPU count (the 2026-08-20 fan-out failure)'
       file = 'dsh\agent-presets\halo-standard\agent.cordis.yml'
       from = '        maxConcurrentAgents: 1'
       to   = '        maxConcurrentAgents: 0' }

    @{ id = 'A2'; defect = 'background jobs uncapped -> 10 children on a one-slot model'
       file = 'dsh\cordis.patch.yml'
       from = '    maxConcurrentJobsPerOwner: 1'
       to   = '    maxConcurrentJobsPerOwner: 10' }

    @{ id = 'A3'; defect = 'retries unbounded -> the 2,396,400-token single turn'
       file = 'dsh\settings.yaml'
       from = '        maxRetries: 1'
       to   = '        maxRetries: 5' }

    @{ id = 'A5'; defect = 'compaction budgets that cannot converge (the 10:1 treadmill)'
       file = 'dsh\settings.yaml'
       from = '  maxTokens: 12288'
       to   = '  maxTokens: 8192' }

    @{ id = 'L3'; defect = 'launcher opens a browser without proving the service serves (TE4 bypass: guard kept, its exit removed)'
       file = 'dsh\Start-MissionControl.ps1'
       from = '    "Not opening a browser at a dead port." | Add-Content $log
    Start-Process notepad $log
    exit 1
}'
       to   = '    "Not opening a browser at a dead port." | Add-Content $log
    Start-Process notepad $log
}
if ($false) { exit 1 }' }

    @{ id = 'C13'; defect = 'Mission Control trusts the harness running flag again (the 4h41m lie)'
       file = 'mission-control\mission-control.mjs'
       from = '        running: !!s.running && !(s.updatedAt && (Date.now() - s.updatedAt) > STALL_MS),'
       to   = '        running: !!s.running,' }

    @{ id = 'B1'; defect = 'an unsupported claim returns to a public surface'
       file = 'site\index.html'
       from = '<h1>Capable local coding agents. No cloud required for local-model work.</h1>'
       to   = '<h1>Frontier-class coding agents. No cloud required.</h1>' }

    # MIGRATION 2026-08-21 defects.
    @{ id = 'MIG1'; defect = 'a functional file goes back to installing dsh via npx (hangs on Node 25)'
       file = 'scripts\Sync-FromLive.ps1'
       from = '$dump = pnpm dlx "@deepseek-ai/dsh@0.1.1-rc.2" web --dump-config 2>&1'
       to   = '$dump = npx "@deepseek-ai/dsh@0.1.1-rc.2" web --dump-config 2>&1' }

    @{ id = 'MIG2'; defect = 'a partial version bump leaves one file pinned to an older dsh'
       file = 'scripts\Sync-FromLive.ps1'
       from = 'pnpm dlx "@deepseek-ai/dsh@0.1.1-rc.2" web --dump-config'
       to   = 'pnpm dlx "@deepseek-ai/dsh@0.1.0-rc.7" web --dump-config' }

    @{ id = 'MIG3'; defect = 'the launcher starts bare pnpm (pnpm.ps1) instead of pnpm.cmd -> blank PID, nothing serves'
       file = 'dsh\Start-DSH.ps1'
       from = 'Start-Process -PassThru -WindowStyle Hidden pnpm.cmd `'
       to   = 'Start-Process -PassThru -WindowStyle Hidden pnpm `' }

    # TE-5 (gate 2026-08-21): the MIG1/MIG2 mutations above only touched
    # Sync-FromLive.ps1 -- the one file where neither blind spot existed. These
    # target the files that DID have the gaps: Deploy's $dshPkg-mediated npx
    # call, and MC's DSH_VERSION_PIN constant.
    @{ id = 'MIG1'; defect = 'TE-1: Deploy reverts a $dshPkg-mediated call back to npx (variable, not literal)'
       file = 'scripts\Deploy-ToLive.ps1'
       from = '$dump = pnpm dlx $dshPkg web --dump-config 2>&1'
       to   = '$dump = npx $dshPkg web --dump-config 2>&1' }

    @{ id = 'MIG2'; defect = 'TE-2: mission-control DSH_VERSION_PIN regresses to an older dsh'
       file = 'mission-control\mission-control.mjs'
       from = "const DSH_VERSION_PIN = '0.1.1-rc.2';"
       to   = "const DSH_VERSION_PIN = '0.1.0-rc.7';" }

    @{ id = 'A2'; defect = 'PE-M1: the job cap is put under the wrong patch id (jobs-local) so it never attaches'
       file = 'dsh\cordis.patch.yml'
       from = "- id: jobs`r`n  config:"
       to   = "- id: jobs-local`r`n  config:" }

    @{ id = 'G1'; defect = 'a deployed AGENTS.md loses its SCOPE header (issue #35 prompt injection)'
       file = 'workspace\AGENTS.md'
       from = 'SCOPE: these instructions are for HALO-stack (DeepSeek Harness) sessions only.'
       to   = 'These instructions are for HALO-stack sessions.' }

    # GATE-2026-08-21: the defects the GauntletGate panel reproduced.
    @{ id = 'SEC1'; defect = 'PE-1 RCE returns: a shell:true subprocess in Mission Control'
       file = 'mission-control\mission-control.mjs'
       from = "const { stdout } = await safeExecFile('lms', ['ps', '--json'], { timeout: 8000 });"
       to   = "const { stdout } = await execFileP('lms', ['ps', '--json'], { shell: true, timeout: 8000 });" }

    @{ id = 'SEC2'; defect = 'a state-changing endpoint drops its auth check'
       file = 'mission-control\mission-control.mjs'
       from = "if (!actionAuthorized(req)) { res.writeHead(403); res.end('unauthorized: missing or invalid action token'); return; }"
       to   = "if (false) { }" }

    @{ id = 'W1T'; defect = 'W1 returns: loader verifies with an unguarded top-level execSync'
       file = 'lmstudio\Load-Worker-Coder.mjs'
       from = "let live = null, verifiedBy = null;"
       to   = "const ps = JSON.parse(execSync(`"lms ps --json`").toString());`nlet live = null, verifiedBy = null;" }

    @{ id = 'PE2T'; defect = 'PE-2 returns: machine marker written before post-validation'
       file = 'scripts\Deploy-ToLive.ps1'
       from = "Write-Host `"live config composes clean - no unmatched patch targets`""
       to   = "Set-Content -Path `"`$U\.dsh\machine`" -Value `$machine -Encoding ascii`nWrite-Host `"live config composes clean - no unmatched patch targets`"" }

    @{ id = 'W2T'; defect = 'W2 returns: audit stops checking where the task points'
       file = 'scripts\Deploy-ToLive.ps1'
       from = '$snapOk = ($null -ne $snapTask -and $snapTask.State -in @(''Ready'', ''Running'') -and $snapPointsHere)'
       to   = '$snapOk = ($null -ne $snapTask -and $snapTask.State -in @(''Ready'', ''Running''))' }

    # WP1 (HALO 2.0 scripts). Each breaks one script; the matching H-check reddens.
    @{ id = 'H1'; defect = 'halo-size drops node_modules from the skip list -> vendored trees get sized'
       file = 'scripts\halo\Halo-Size.ps1'
       from = "'.git', 'node_modules', 'dist', 'build', 'out', 'vendor', 'bin', 'obj',"
       to   = "'.git', 'dist', 'build', 'out', 'vendor', 'bin', 'obj'," }

    @{ id = 'H2'; defect = 'halo-plan grouping loses the ceil(sqrt(n)) rule -> one group per unit'
       file = 'scripts\halo\Halo-Plan.ps1'
       from = '$groupCount = [int][math]::Ceiling([math]::Sqrt($UnitCount))'
       to   = '$groupCount = [int][math]::Ceiling($UnitCount)' }

    @{ id = 'H3'; defect = 'halo-coverage stops failing on a hidden gap -> a report can hide missing units'
       file = 'scripts\halo\Halo-Coverage.ps1'
       from = 'if ($gapHidden) { exit 4 }'
       to   = 'if ($false) { exit 4 }' }

    @{ id = 'H4'; defect = 'halo-coverage stops flagging a containment breach -> E5 tripwire disarmed'
       file = 'scripts\halo\Halo-Coverage.ps1'
       from = 'if ($containmentBreached) { exit 5 }'
       to   = 'if ($false) { exit 5 }' }
)

Write-Host "`n=== mutation check: does the suite actually fail closed? ===" -ForegroundColor Cyan
Write-Host "$($mutations.Count) historical defects will be reintroduced, one at a time.`n"

foreach ($m in $mutations) {
    $tmp = Join-Path $env:TEMP ("halo-mutate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        # Scratch copy: the working tree is never modified.
        # TE6 (gate 2026-08-21): Copy-Item -Exclude '.git' does NOT exclude
        # .git on a recursive copy (the exclude is only honored when -Path is
        # wildcarded, and even then not at nested depth). Use robocopy with a
        # real directory exclude, which works at every level. Falls back to a
        # plain copy if robocopy is unavailable (non-Windows CI).
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $rc = Get-Command robocopy -ErrorAction SilentlyContinue
        if ($rc) {
            # robocopy exit codes 0-7 are success; 8+ are real errors.
            & robocopy $repo $tmp /E /XD "$repo\.git" /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)" }
            $global:LASTEXITCODE = 0
        } else {
            Copy-Item "$repo\*" $tmp -Recurse -Force -Exclude '.git' -ErrorAction Stop
        }
        $target = Join-Path $tmp $m.file
        $text = Get-Content $target -Raw
        if ($text -notmatch [regex]::Escape($m.from)) {
            Write-Host ("  ERROR [{0}] cannot apply mutation - anchor text not found in {1}" -f $m.id, $m.file) -ForegroundColor Yellow
            Write-Host ("        the test may be checking something that has moved") -ForegroundColor Yellow
            $missed++
            continue
        }
        Set-Content -Path $target -Value ($text.Replace($m.from, $m.to)) -NoNewline -Encoding utf8

        # Static only: the mutant is a scratch copy, so live checks are noise.
        $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'tests\Run-Tests.ps1') -Static 2>&1) -join "`n"
        $caughtByRightTest = $out -match ("FAIL\s+\[" + [regex]::Escape($m.id) + "\]")
        $anyFailure = $out -match 'FAIL\s+\['

        if ($caughtByRightTest) {
            Write-Host ("  CAUGHT  [{0}] {1}" -f $m.id, $m.defect) -ForegroundColor Green
        } elseif ($anyFailure) {
            $who = ([regex]::Matches($out, 'FAIL\s+\[(\w+)\]') | ForEach-Object { $_.Groups[1].Value }) -join ','
            Write-Host ("  PARTIAL [{0}] caught, but by [{1}] not [{0}] - the mapping is wrong" -f $m.id, $who) -ForegroundColor Yellow
            $missed++
        } else {
            Write-Host ("  MISSED  [{0}] {1}" -f $m.id, $m.defect) -ForegroundColor Red
            Write-Host ("          the suite stayed GREEN with this defect present") -ForegroundColor Red
            $missed++
        }
    } catch {
        Write-Host ("  ERROR   [{0}] {1}" -f $m.id, $_) -ForegroundColor Yellow
        $missed++
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($missed -eq 0) {
    Write-Host ("  all {0} mutations caught by their own test - the suite fails closed" -f $mutations.Count) -ForegroundColor Green
} else {
    Write-Host ("  {0} of {1} mutations NOT caught correctly" -f $missed, $mutations.Count) -ForegroundColor Red
}
exit $missed
