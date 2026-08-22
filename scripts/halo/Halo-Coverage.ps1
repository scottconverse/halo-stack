<#
.SYNOPSIS
  HALO 2.0 Large-Job Protocol -- phase 6, COVERAGE (mechanical coverage).

.DESCRIPTION
  Recomputes what a run actually covered from the artifacts on disk -- the
  manifest, the unit files, the findings, and the child session logs -- never
  from a model's claim. Two hard gates (spec 4.2.8, and E5 in spec 4.2.7):

    1. GAP HONESTY. Every gap (a unit not attempted, a unit that failed, a file
       truncated or omitted) MUST be named in REPORT.md. A report that hides a
       gap is the most expensive artifact this system can produce, so a hidden
       gap is a non-zero exit, not a warning.

    2. CONTAINMENT (E5). No child may have reached an external frontier provider
       (Codex / Claude Code / OpenCode). The check reads child session logs and
       each findings file's providersUsed; any hit is a containment breach and a
       distinct non-zero exit. This is the tripwire behind the restricted preset.

  Pure over its inputs: same run directory -> same coverage.json and same exit.

.PARAMETER RunDir
  A runs/<id>/ directory containing manifest.json, units/, and (after a run)
  findings/, logs/, and REPORT.md.

.PARAMETER ReportFile
  Path to the report to check. Default: <RunDir>/REPORT.md

.PARAMETER OutFile
  Where to write coverage.json. Default: <RunDir>/coverage.json

.PARAMETER AllowMissingReport
  If set, a missing REPORT.md is not itself a failure (used mid-run). Off by
  default: at COVERAGE time a missing report IS the ultimate hidden gap.

.OUTPUTS
  coverage.json, and exit code:
    0  complete: every gap named, no containment breach
    4  a gap is hidden (REPORT.md missing, or does not name a gap)
    5  containment breach: a child reached an external provider (E5)
    2  bad input (no manifest)
  Codes 4 and 5 can both apply; 5 (breach) takes precedence in the exit code.

.NOTES
  ASCII only, PowerShell 5.1 compatible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$RunDir,

    [string]$ReportFile,
    [string]$OutFile,
    [switch]$AllowMissingReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Tool names / provider ids that mean a child left the local machine. Any of
# these appearing in a child log or a findings providersUsed list is a breach.
$script:ExternalMarkers = @(
    'subagent_codex', 'subagent_claude_code', 'subagent_opencode',
    'subagent-codex', 'subagent-claude-code', 'subagent-opencode-acp'
)

function Write-JsonFile {
    param([string]$FilePath, $Object, [int]$Depth = 8)
    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ($Object | ConvertTo-Json -Depth $Depth)
    $lf = ($json -replace "`r`n", "`n")
    [System.IO.File]::WriteAllText($FilePath, $lf, (New-Object System.Text.UTF8Encoding($false)))
    return $lf
}

if (-not $ReportFile) { $ReportFile = Join-Path $RunDir 'REPORT.md' }
if (-not $OutFile) { $OutFile = Join-Path $RunDir 'coverage.json' }

$manifestPath = Join-Path $RunDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Error "COVERAGE: manifest not found: $manifestPath"
    exit 2
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$unitsDir = Join-Path $RunDir 'units'
$findingsDir = Join-Path $RunDir 'findings'
$logsDir = Join-Path $RunDir 'logs'

# --- per-unit status + truncated file inventory (from unit files) ----------
$notAttempted = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[string]
$succeeded = New-Object System.Collections.Generic.List[string]
$truncatedFiles = New-Object System.Collections.Generic.List[string]
$providerHits = New-Object System.Collections.Generic.List[object]

foreach ($row in @($manifest.units)) {
    $unitId = [string]$row.unit
    $unitFile = Join-Path $unitsDir "$unitId.json"
    if (Test-Path -LiteralPath $unitFile) {
        $u = Get-Content -LiteralPath $unitFile -Raw | ConvertFrom-Json
        foreach ($fr in @($u.files)) {
            if ($fr.truncated) { $truncatedFiles.Add([string]$fr.path) }
        }
    }

    $findFile = Join-Path $findingsDir "$unitId.json"
    if (-not (Test-Path -LiteralPath $findFile)) {
        $notAttempted.Add($unitId)
        continue
    }
    $status = 'ok'
    try {
        $fnd = Get-Content -LiteralPath $findFile -Raw | ConvertFrom-Json
        if ($fnd.PSObject.Properties.Name -contains 'status' -and [string]$fnd.status -ne 'ok') { $status = [string]$fnd.status }
        # E5: a findings file may self-report providers used.
        if ($fnd.PSObject.Properties.Name -contains 'providersUsed') {
            foreach ($p in @($fnd.providersUsed)) {
                if ($script:ExternalMarkers -contains [string]$p) {
                    $providerHits.Add([pscustomobject]@{ where = "findings/$unitId.json"; marker = [string]$p })
                }
            }
        }
    }
    catch { $status = 'unreadable' }
    if ($status -eq 'ok') { $succeeded.Add($unitId) } else { $failed.Add($unitId) }
}

# --- E5: scan child logs for external-provider markers ---------------------
if (Test-Path -LiteralPath $logsDir) {
    foreach ($log in (Get-ChildItem -LiteralPath $logsDir -File -ErrorAction SilentlyContinue)) {
        $text = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in $script:ExternalMarkers) {
            if ($text.IndexOf($m, [System.StringComparison]::Ordinal) -ge 0) {
                $providerHits.Add([pscustomobject]@{ where = "logs/$($log.Name)"; marker = $m })
            }
        }
    }
}
$containmentBreached = ($providerHits.Count -gt 0)

# --- omitted files carried from the manifest (if any) ----------------------
$omitted = New-Object System.Collections.Generic.List[string]
if ($manifest.PSObject.Properties.Name -contains 'omitted') {
    foreach ($o in @($manifest.omitted)) { $omitted.Add([string]$o) }
}

# --- gap-honesty gate: REPORT.md must name every gap -----------------------
$gapsUnnamed = New-Object System.Collections.Generic.List[string]
$reportMissing = -not (Test-Path -LiteralPath $ReportFile)
if ($reportMissing) {
    if (-not $AllowMissingReport) { $gapsUnnamed.Add('REPORT.md is missing') }
}
else {
    $report = Get-Content -LiteralPath $ReportFile -Raw
    if (-not $report) { $report = '' }
    $named = {
        param($needle)
        return ($report.IndexOf([string]$needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    foreach ($g in $notAttempted) { if (-not (& $named $g)) { $gapsUnnamed.Add("unit not attempted, unnamed in report: $g") } }
    foreach ($g in $failed) { if (-not (& $named $g)) { $gapsUnnamed.Add("unit failed, unnamed in report: $g") } }
    foreach ($p in ($truncatedFiles | Select-Object -Unique)) { if (-not (& $named $p)) { $gapsUnnamed.Add("truncated file unnamed in report: $p") } }
    foreach ($p in $omitted) { if (-not (& $named $p)) { $gapsUnnamed.Add("omitted file unnamed in report: $p") } }
}

$gapHidden = ($gapsUnnamed.Count -gt 0)
$unitTotal = [int]$manifest.unitCount

$coverage = [ordered]@{
    schema             = 'halo-coverage/1'
    runId              = [string]$manifest.runId
    unitsTotal         = $unitTotal
    unitsSucceeded     = $succeeded.Count
    unitsFailed        = $failed.Count
    unitsNotAttempted  = $notAttempted.Count
    truncatedFileCount = (@($truncatedFiles | Select-Object -Unique)).Count
    omittedFileCount   = $omitted.Count
    containmentBreached = $containmentBreached
    providerHits       = $providerHits.ToArray()
    reportMissing      = $reportMissing
    gapHidden          = $gapHidden
    gapsUnnamed        = $gapsUnnamed.ToArray()
    failedUnits        = $failed.ToArray()
    notAttemptedUnits  = $notAttempted.ToArray()
    complete           = ((-not $containmentBreached) -and (-not $gapHidden))
}
Write-JsonFile -FilePath $OutFile -Object $coverage | Out-Null
Write-Output ($coverage | ConvertTo-Json -Depth 8)

if ($containmentBreached) { exit 5 }
if ($gapHidden) { exit 4 }
exit 0
