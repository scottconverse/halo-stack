<#
.SYNOPSIS
  HALO 2.0 Large-Job Protocol -- phase 2, PLAN. Deterministic unit planning.

.DESCRIPTION
  Consumes a sizing.json (from Halo-Size.ps1) and packs its files into units
  under a per-unit prompt budget. Pure function of its input: the same sizing.json
  and the same budget always produce byte-identical units and manifest. No model
  call. This is spec gap #2 (docs/design/halo2/SPEC.md 4.2.2).

  Units carry file REFERENCES (path + byte cap), never file bodies -- children
  read their own files. Nothing is silently dropped: any file that cannot fit
  whole is included truncated, with the reason recorded, and carried to COVERAGE.

  The run id is derived deterministically from the file set unless supplied, so a
  re-plan of the same tree lands the same runs/<id>/ -- the basis for resume (E4).

.PARAMETER SizingFile
  Path to a sizing.json produced by Halo-Size.ps1.

.PARAMETER RunsRoot
  Directory under which runs/<id>/ is written. Default: .\runs

.PARAMETER RunId
  Stable run identifier. If omitted, derived from a SHA256 of the sorted
  (path,bytes) list -- same tree -> same id -> resumable.

.PARAMETER UnitBudgetTokens
  Per-unit prompt budget. Default 24000. Must match what SIZE assumed.

.PARAMETER SafetyFactor
  Fraction of the unit budget available to content after framing. Default 0.85.

.PARAMETER GroupThreshold
  At or below this many units, REDUCE is single-level (one group). Above it,
  units are grouped for a hierarchical reduce. Default 8.

.OUTPUTS
  Writes runs/<id>/manifest.json and runs/<id>/units/unit-NNN.json, prints the
  manifest. Exit 0 on success, 2 on bad input.

.NOTES
  ASCII only, PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SizingFile,

    [string]$RunsRoot = (Join-Path (Get-Location) 'runs'),
    [string]$RunId,
    [int]$UnitBudgetTokens = 24000,
    [double]$SafetyFactor = 0.85,
    [int]$GroupThreshold = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CharsPerToken = 3.5

function Write-JsonFile {
    param([string]$FilePath, $Object, [int]$Depth = 8)
    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ($Object | ConvertTo-Json -Depth $Depth)
    $lf = ($json -replace "`r`n", "`n")
    [System.IO.File]::WriteAllText($FilePath, $lf, (New-Object System.Text.UTF8Encoding($false)))
    return $lf
}

function Get-RunId {
    param([object[]]$Files)
    # Stable digest of the ordered (path|bytes) list. Same set -> same id.
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $Files) { [void]$sb.Append($f.path); [void]$sb.Append('|'); [void]$sb.Append([string]$f.bytes); [void]$sb.Append("`n") }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return 'run-' + $hex.Substring(0, 12)
}

function Get-ReduceGroups {
    <#
      Pure function: unit count -> a list of groups (each an int[] of 0-based
      unit indices) for the hierarchical reduce. Same count -> same grouping,
      verifiable without a model (spec 4.2.5, v2.1 audit). At or below the
      threshold, one group. Above it, ceil(sqrt(n)) groups filled in order.
    #>
    param([int]$UnitCount, [int]$Threshold = 8)
    $groups = New-Object System.Collections.Generic.List[object]
    if ($UnitCount -le 0) { return , ($groups.ToArray()) }
    if ($UnitCount -le $Threshold) {
        $groups.Add([int[]](0..($UnitCount - 1)))
        # Leading comma: stop PowerShell from unwrapping a one-group result into
        # its inner int[] (which would read as N groups instead of 1).
        return , ($groups.ToArray())
    }
    $groupCount = [int][math]::Ceiling([math]::Sqrt($UnitCount))
    $perGroup = [int][math]::Ceiling($UnitCount / [double]$groupCount)
    for ($i = 0; $i -lt $UnitCount; $i += $perGroup) {
        $end = [math]::Min($i + $perGroup - 1, $UnitCount - 1)
        $groups.Add([int[]]($i..$end))
    }
    return , ($groups.ToArray())
}

# --- read sizing -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $SizingFile)) {
    Write-Error "PLAN: sizing file not found: $SizingFile"
    exit 2
}
$sizing = Get-Content -LiteralPath $SizingFile -Raw | ConvertFrom-Json
if (-not $sizing.files -or @($sizing.files).Count -eq 0) {
    Write-Error "PLAN: sizing file has no files: $SizingFile"
    exit 2
}
$files = @($sizing.files)

$perUnitContent = [int64][math]::Floor($UnitBudgetTokens * $SafetyFactor)
if ($perUnitContent -lt 1) { $perUnitContent = 1 }
$capBytes = [int64][math]::Floor($perUnitContent * $script:CharsPerToken)

if (-not $RunId) { $RunId = Get-RunId -Files $files }
$runDir = Join-Path $RunsRoot $RunId
$unitsDir = Join-Path $runDir 'units'

# --- deterministic greedy pack --------------------------------------------
$units = New-Object System.Collections.Generic.List[object]
$current = New-Object System.Collections.Generic.List[object]
$currentTokens = [int64]0
$truncatedCount = 0

function Flush-Unit {
    if ($current.Count -gt 0) {
        $units.Add([pscustomobject]@{ files = $current.ToArray(); tokens = $currentTokens })
        $script:current = New-Object System.Collections.Generic.List[object]
        $script:currentTokens = [int64]0
    }
}

foreach ($f in $files) {
    $fTokens = [int64]$f.tokens
    if ($fTokens -gt $perUnitContent) {
        # Oversized: its own unit, read only the first cap bytes (recorded).
        Flush-Unit
        $bigFile = [pscustomobject]@{ path = $f.path; bytes = [int64]$f.bytes; byteCap = $capBytes; truncated = $true }
        $bigList = New-Object System.Collections.Generic.List[object]
        $bigList.Add($bigFile)
        $units.Add([pscustomobject]@{ files = $bigList.ToArray(); tokens = $perUnitContent })
        $truncatedCount++
        continue
    }
    if (($currentTokens + $fTokens) -gt $perUnitContent -and $current.Count -gt 0) {
        Flush-Unit
    }
    $current.Add([pscustomobject]@{ path = $f.path; bytes = [int64]$f.bytes; byteCap = [int64]$f.bytes; truncated = $false })
    $currentTokens += $fTokens
}
Flush-Unit

# --- write units + manifest ------------------------------------------------
# Remove stale unit files from a prior, larger plan of the same run id so MAP
# never sees an orphan. Per-file and guarded (a re-plan must not crash on a
# locked file); the units directory itself is left in place.
if (Test-Path -LiteralPath $unitsDir) {
    foreach ($old in (Get-ChildItem -LiteralPath $unitsDir -Filter 'unit-*.json' -File)) {
        try { Remove-Item -LiteralPath $old.FullName -Force } catch { Write-Warning "PLAN: could not remove stale $($old.Name): $_" }
    }
}

$unitRows = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $units.Count; $i++) {
    $u = $units[$i]
    $unitId = 'unit-{0:D3}' -f $i
    $unitObj = [ordered]@{
        schema = 'halo-unit/1'
        runId  = $RunId
        unit   = $unitId
        index  = $i
        tokens = [int64]$u.tokens
        files  = $u.files
    }
    Write-JsonFile -FilePath (Join-Path $unitsDir "$unitId.json") -Object $unitObj | Out-Null
    $unitRows.Add([pscustomobject]@{
            unit      = $unitId
            index     = $i
            tokens    = [int64]$u.tokens
            fileCount = @($u.files).Count
            truncated = (@($u.files | Where-Object { $_.truncated }).Count)
        })
}

$groups = Get-ReduceGroups -UnitCount $units.Count -Threshold $GroupThreshold

$manifest = [ordered]@{
    schema         = 'halo-manifest/1'
    runId          = $RunId
    unitBudget     = $UnitBudgetTokens
    safetyFactor   = $SafetyFactor
    perUnitContent = $perUnitContent
    capBytes       = $capBytes
    fileCount      = $files.Count
    unitCount      = $units.Count
    truncatedCount = $truncatedCount
    groupThreshold = $GroupThreshold
    groupCount     = @($groups).Count
    groups         = $groups
    units          = $unitRows
}
$manifestJson = Write-JsonFile -FilePath (Join-Path $runDir 'manifest.json') -Object $manifest

Write-Output $manifestJson
exit 0
