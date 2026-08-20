# Publication gate. This repo is PUBLIC: every push is an act of publishing.
#
# Blocks a push that adds or modifies anything the operator has marked
# "restricted" in publication-policy.json, and reports anything marked
# "published" so a deliberate past decision is re-stated rather than forgotten.
#
# Exit 0 = safe to push. Exit 1 = stop.
# ASCII only (PowerShell 5.1 misparses BOM-less UTF-8 punctuation).
param(
    [string]$Range = $null,   # e.g. origin/master..HEAD ; auto-detected if omitted
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

try {
    $policyPath = Join-Path $repo 'publication-policy.json'
    if (-not (Test-Path $policyPath)) { Write-Error "no publication-policy.json - the gate cannot run"; exit 1 }
    $policy = Get-Content $policyPath -Raw | ConvertFrom-Json

    if (-not $Range) {
        git rev-parse --verify --quiet origin/master *> $null
        $Range = if ($LASTEXITCODE -eq 0) { 'origin/master..HEAD' } else { 'HEAD' }
    }
    $files = @(git diff --name-only $Range 2>$null | Where-Object { $_ })
    if (-not $files) { if (-not $Quiet) { Write-Host "publication gate: nothing to publish in $Range" }; exit 0 }

    # Glob matching via -like (wildcards, NOT regex). An earlier version built a
    # regex by escaping and re-substituting, which produced nested quantifiers and
    # threw at match time - and the gate then exited 0, failing OPEN. Never again:
    # see the try/catch around the whole body.
    function Test-GlobMatch([string]$path, [string]$glob) {
        $p = $glob -replace '\*\*', '*'
        if ($path -like $p) { return $true }
        if ($p.StartsWith('*/')) { return ($path -like $p.Substring(2)) }
        return $false
    }

    $blocked = @(); $noted = @()
    foreach ($e in $policy.entries) {
        foreach ($p in $e.patterns) {
            foreach ($f in $files) {
                if (Test-GlobMatch $f $p) {
                    if ($e.status -eq 'restricted') { $blocked += [pscustomobject]@{ File = $f; Entry = $e } }
                    else { $noted += [pscustomobject]@{ File = $f; Entry = $e } }
                }
            }
        }
    }

    if (-not $Quiet) { Write-Host "publication gate: $($files.Count) file(s) in $Range" }

    foreach ($n in ($noted | Sort-Object File -Unique)) {
        Write-Host ""
        Write-Warning "PUBLISHING (allowed by a recorded decision): $($n.File)"
        Write-Host "  policy: $($n.Entry.id) - decided $($n.Entry.decided)"
        Write-Host "  $($n.Entry.decision)"
        if ($n.Entry.concern) { Write-Host "  concern: $($n.Entry.concern)" }
    }

    if ($blocked.Count -gt 0) {
        Write-Host ""
        foreach ($b in ($blocked | Sort-Object File -Unique)) {
            Write-Warning "RESTRICTED - this push would publish: $($b.File)"
            Write-Host "  policy: $($b.Entry.id) - decided $($b.Entry.decided)"
            Write-Host "  $($b.Entry.decision)"
        }
        Write-Host ""
        Write-Error "Publication gate FAILED. This repo is public. Remove these from the push, or have the operator change the policy entry deliberately."
        exit 1
    }

    if (-not $Quiet) { Write-Host "publication gate: OK" }
    exit 0

} catch {
    # Fail CLOSED. If this gate cannot evaluate the policy, it must not let a
    # public push through on the assumption that everything is fine.
    Write-Warning ("publication gate ERRORED: " + $_.Exception.Message)
    Write-Error "Gate could not complete - refusing the push. Fix the gate, do not bypass it."
    exit 1
}
