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

    @{ id = 'L3'; defect = 'launcher opens a browser without proving the service serves'
       file = 'dsh\Start-MissionControl.ps1'
       from = 'if (-not $serving) {'
       to   = 'if ($false) {' }

    @{ id = 'C13'; defect = 'Mission Control trusts the harness running flag again (the 4h41m lie)'
       file = 'mission-control\mission-control.mjs'
       from = '        running: !!s.running && !(s.updatedAt && (Date.now() - s.updatedAt) > STALL_MS),'
       to   = '        running: !!s.running,' }

    @{ id = 'B1'; defect = 'an unsupported claim returns to a public surface'
       file = 'site\index.html'
       from = '<h1>Capable local coding agents. No cloud required for local-model work.</h1>'
       to   = '<h1>Frontier-class coding agents. No cloud required.</h1>' }

    @{ id = 'G1'; defect = 'a deployed AGENTS.md loses its SCOPE header (issue #35 prompt injection)'
       file = 'workspace\AGENTS.md'
       from = 'SCOPE: these instructions are for HALO-stack (DeepSeek Harness) sessions only.'
       to   = 'These instructions are for HALO-stack sessions.' }
)

Write-Host "`n=== mutation check: does the suite actually fail closed? ===" -ForegroundColor Cyan
Write-Host "$($mutations.Count) historical defects will be reintroduced, one at a time.`n"

foreach ($m in $mutations) {
    $tmp = Join-Path $env:TEMP ("halo-mutate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        # Scratch copy: the working tree is never modified.
        Copy-Item $repo $tmp -Recurse -Force -Exclude '.git' -ErrorAction Stop
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
