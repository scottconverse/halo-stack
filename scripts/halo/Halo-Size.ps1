<#
.SYNOPSIS
  HALO 2.0 Large-Job Protocol -- phase 1, SIZE. Deterministic pre-flight sizing.

.DESCRIPTION
  Walks the target paths, estimates tokens overhead-aware, reads the live window,
  and returns a verdict: single-pass / decompose / refuse. Pure function of its
  input: the same tree + the same knobs always produce byte-identical sizing.json.
  No model call, no network. This is spec gap #1 (docs/design/halo2/SPEC.md 4.2.1).

  Token estimate is pessimistic: content tokens = ceil(bytes / 3.5). The verdict
  compares that against a fraction of the window, and against a decompose ceiling
  derived from the per-unit budget and the run's agent cap.

.PARAMETER Path
  One or more files or directories to size. Directories are walked recursively.

.PARAMETER WindowTokens
  The live model context window in tokens. Tests pass it explicitly for hermetic
  runs; at runtime the skill passes the deployed window. Default 131072 (HALO).

.PARAMETER FitRatio
  A tree whose estimate is <= WindowTokens * FitRatio may run single-pass.
  Default 0.60 (spec 4.2.1).

.PARAMETER UnitBudgetTokens
  Per-unit prompt budget used to estimate the unit count. Default 24000.

.PARAMETER SafetyFactor
  Fraction of the unit budget actually available to content after framing.
  Default 0.85.

.PARAMETER MaxUnits
  The most units a run may hold before SIZE refuses. Default 60 (under the
  maxTotalAgents: 64 engine cap, leaving room for the reduce children).

.PARAMETER OutFile
  Where to write sizing.json. If omitted, JSON is written to stdout only.

.OUTPUTS
  Writes sizing.json (see below) and prints it. Exit code:
    0  single-pass or decompose (a runnable verdict)
    3  refuse (too large for the configured ceiling)
    2  bad input (no readable paths)

.NOTES
  ASCII only, PowerShell 5.1 compatible. Deterministic: files are sized in a
  stable ordinal-sorted order and the estimate depends only on byte lengths.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    [int]$WindowTokens = 131072,
    [double]$FitRatio = 0.60,
    [int]$UnitBudgetTokens = 24000,
    [double]$SafetyFactor = 0.85,
    [int]$MaxUnits = 60,
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Directories never worth reading into a context. Matched by exact segment name.
$script:SkipDirs = @(
    '.git', 'node_modules', 'dist', 'build', 'out', 'vendor', 'bin', 'obj',
    '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache', '.pytest_cache',
    'coverage', '.next', '.nuxt', '.svelte-kit', '.turbo', '.cache', 'target'
)

# Chars-per-token divisor. 3.5 is pessimistic for English+code (real is ~4).
$script:CharsPerToken = 3.5

function Test-SkipPath {
    param([string]$FullPath, [string]$Root)
    # True if any path segment below the root is a skip dir.
    $rel = $FullPath.Substring($Root.Length).TrimStart('\', '/')
    foreach ($seg in ($rel -split '[\\/]+')) {
        if ($script:SkipDirs -contains $seg) { return $true }
    }
    return $false
}

function Get-SizedFiles {
    param([string[]]$Paths)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warning "path not found, skipped: $p"
            continue
        }
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) {
            $root = $item.FullName
            $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                if (Test-SkipPath -FullPath $f.FullName -Root $root) { continue }
                $rows.Add([pscustomobject]@{ Full = $f.FullName; Bytes = [int64]$f.Length })
            }
        }
        else {
            $rows.Add([pscustomobject]@{ Full = $item.FullName; Bytes = [int64]$item.Length })
        }
    }
    # Deterministic order: ordinal, case-insensitive, by full path. Dedupe.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($r in $rows) {
        if ($seen.Add($r.Full)) { $unique.Add($r) }
    }
    return ($unique | Sort-Object -Property @{ Expression = { $_.Full }; Ascending = $true } -Culture '')
}

function Get-TokenEstimate {
    param([int64]$Bytes)
    return [int64][math]::Ceiling($Bytes / $script:CharsPerToken)
}

# --- size the tree ---------------------------------------------------------
$sized = @(Get-SizedFiles -Paths $Path)
if ($sized.Count -eq 0) {
    Write-Error "SIZE: no readable files under: $($Path -join ', ')"
    exit 2
}

$contentTokens = [int64]0
$fileRows = New-Object System.Collections.Generic.List[object]
foreach ($s in $sized) {
    $t = Get-TokenEstimate -Bytes $s.Bytes
    $contentTokens += $t
    $fileRows.Add([pscustomobject]@{ path = $s.Full; bytes = $s.Bytes; tokens = $t })
}

$fitThreshold = [int64][math]::Floor($WindowTokens * $FitRatio)
$perUnitContent = [int64][math]::Floor($UnitBudgetTokens * $SafetyFactor)
if ($perUnitContent -lt 1) { $perUnitContent = 1 }
$estimatedUnits = [int64][math]::Ceiling($contentTokens / $perUnitContent)
if ($estimatedUnits -lt 1) { $estimatedUnits = 1 }

# --- verdict ---------------------------------------------------------------
# single-pass if it fits the fit threshold; else decompose; refuse if even
# decomposed it needs more units than the run may hold.
if ($contentTokens -le $fitThreshold) {
    $verdict = 'single-pass'
    $exit = 0
}
elseif ($estimatedUnits -le $MaxUnits) {
    $verdict = 'decompose'
    $exit = 0
}
else {
    $verdict = 'refuse'
    $exit = 3
}

$result = [ordered]@{
    schema         = 'halo-size/1'
    verdict        = $verdict
    contentTokens  = $contentTokens
    fileCount      = $fileRows.Count
    windowTokens   = $WindowTokens
    fitRatio       = $FitRatio
    fitThreshold   = $fitThreshold
    unitBudget     = $UnitBudgetTokens
    safetyFactor   = $SafetyFactor
    perUnitContent = $perUnitContent
    estimatedUnits = $estimatedUnits
    maxUnits       = $MaxUnits
    charsPerToken  = $script:CharsPerToken
    files          = $fileRows
}

$json = ($result | ConvertTo-Json -Depth 6)
if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # ASCII, no BOM, LF -- so the same input yields a byte-identical file.
    $lf = ($json -replace "`r`n", "`n")
    [System.IO.File]::WriteAllText($OutFile, $lf, (New-Object System.Text.UTF8Encoding($false)))
}
Write-Output $json
exit $exit
