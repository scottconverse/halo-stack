# Rebuild: push this repo's stack files out to their live locations.
# Transactional: stage -> validate -> validate-composed -> backup -> apply ->
# validate-composed -> OK, or automatic rollback. Modeled on dsh's own
# hot-module-replacement pattern (cordis.patch.yml hot-reconciles live plugin
# fibers in ~20s with no restart, so a bad edit reaches production fast -- this
# script makes sure a bad edit never reaches production, or if it briefly does,
# self-heals within seconds instead of staying broken).
# Machine-rebuild order after this: install Node 22+, LM Studio (+ the two GGUF
# models), pnpm 11, then run the desktop launchers (they pin dsh 0.1.0-rc.7 via npx).
$repo = Split-Path $PSScriptRoot -Parent
$U = $env:USERPROFILE
$dshPkg = "@deepseek-ai/dsh@0.1.0-rc.7"

$map = @(
    @{ src = "dsh\settings.yaml";                dst = "$U\.dsh\settings.yaml" }
    @{ src = "dsh\cordis.patch.yml";             dst = "$U\.dsh\cordis.patch.yml" }
    # .env is template-only: never overwrite a live keys file.
    @{ src = "dsh\dot-env.template";             dst = "$U\.dsh\.env"; skipIfExists = $true }
    @{ src = "dsh\Start-DSH.ps1";                dst = "$U\.dsh\Start-DSH.ps1" }
    @{ src = "dsh\Start-MissionControl.ps1";     dst = "$U\.dsh\Start-MissionControl.ps1" }
    @{ src = "dsh\overlays\bench-overlay-coder.yml";     dst = "$U\.dsh\bench-overlay-coder.yml" }
    @{ src = "dsh\overlays\bench-overlay-code-mode.yml"; dst = "$U\.dsh\bench-overlay-code-mode.yml" }
    @{ src = "dsh\overlays\bench-overlay-trio.yml";      dst = "$U\.dsh\bench-overlay-trio.yml" }
    @{ src = "dsh\agent-presets\halo-standard\agent.cordis.yml"; dst = "$U\.dsh\.agent-presets\halo-standard\agent.cordis.yml" }
    @{ src = "dsh\agent-presets\halo-standard\preset.yml";       dst = "$U\.dsh\.agent-presets\halo-standard\preset.yml" }
    @{ src = "dsh\skills\delta-scan-halo\SKILL.md"; dst = "$U\.dsh\skills\delta-scan-halo\SKILL.md" }
    @{ src = "dsh\memory\Snapshot-Memory.ps1";      dst = "$U\.dsh\memory\Snapshot-Memory.ps1" }
    @{ src = "agents-skills\reddit-search\SKILL.md"; dst = "$U\.agents\skills\reddit-search\SKILL.md" }
    @{ src = "workspace\AGENTS.md";                  dst = "$U\Desktop\Code\AGENTS.md" }
    @{ src = "lmstudio\Load-OpenCode-Qwen.mjs";  dst = "$U\.lmstudio\scripts\Load-OpenCode-Qwen.mjs" }
    @{ src = "lmstudio\Load-Worker-Coder.mjs";   dst = "$U\.lmstudio\scripts\Load-Worker-Coder.mjs" }
    @{ src = "lmstudio\Sweep-MTP.mjs";           dst = "$U\.lmstudio\scripts\Sweep-MTP.mjs" }
    @{ src = "mission-control\mission-control.mjs"; dst = "$U\.dsh\mission-control\mission-control.mjs" }
    @{ src = "opencode\opencode.json";           dst = "$U\.config\opencode\opencode.json" }
)

function Test-YamlSyntax {
    # Borrow js-yaml from wherever the harness already installed it, and parse
    # with a permissive schema that tolerates cordis.patch.yml's custom !!js
    # tag (inline JS template strings) as an opaque scalar -- a parse failure
    # on !!js alone must never count as invalid.
    param([string]$Path, [string]$JsYamlPath, [string]$ValidatorScript)
    $out = & node $ValidatorScript $JsYamlPath $Path 2>&1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Message = ($out -join "`n") }
}

function New-StagingHome {
    # Mirror $U\.dsh well enough for `dsh --dump-config` to compose the real
    # tree, without copying the 269MB profiles/ install: junction it instead
    # (never touched by this deploy). Seed with the CURRENT live config, then
    # overlay this deploy's staged files on top, so the staging home is an
    # exact preview of what live will look like right after apply.
    param([string]$StagingRoot, [array]$Map)
    New-Item -ItemType Directory -Force $StagingRoot | Out-Null
    New-Item -ItemType Junction -Path "$StagingRoot\profiles" -Target "$U\.dsh\profiles" | Out-Null

    foreach ($f in @(".env", "settings.yaml", "cordis.patch.yml",
                     "bench-overlay-coder.yml", "bench-overlay-code-mode.yml", "bench-overlay-trio.yml")) {
        $src = "$U\.dsh\$f"
        if (Test-Path $src) { Copy-Item $src "$StagingRoot\$f" -Force }
    }
    foreach ($d in @(".agent-presets\halo-standard", "skills\delta-scan-halo", "mission-control")) {
        $src = "$U\.dsh\$d"
        if (Test-Path $src) {
            New-Item -ItemType Directory -Force "$StagingRoot\$d" | Out-Null
            Copy-Item "$src\*" "$StagingRoot\$d\" -Recurse -Force
        }
    }
    foreach ($m in $Map) {
        if ($m.dst -notlike "$U\.dsh\*") { continue }
        if ($m.skipIfExists -and (Test-Path $m.dst)) { continue }
        $source = Join-Path $repo $m.src
        if (-not (Test-Path $source)) { continue }
        $rel = $m.dst.Substring("$U\.dsh\".Length)
        $target = Join-Path $StagingRoot $rel
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $source $target -Force
    }
}

function Invoke-DumpConfigGate {
    # Same invocation Sync-FromLive.ps1 uses. Pass -Home to point DSH_HOME at
    # an alternate config dir (dsh's own precedence: configured > $DSH_HOME >
    # ~/.dsh -- see @deepseek-ai/dsh-home-paths) instead of composing live.
    param([string]$AltHome = $null)
    if ($AltHome) { $env:DSH_HOME = $AltHome }
    $env:DSH_PERMISSION_MODE = 'danger-full-access'
    $dump = npx $dshPkg web --dump-config 2>&1
    $exit = $LASTEXITCODE
    if ($AltHome) { Remove-Item Env:\DSH_HOME -ErrorAction SilentlyContinue }
    $warnings = $dump | Select-String -Pattern "warn|unmatched|error"
    [pscustomobject]@{ Clean = ($exit -eq 0 -and -not $warnings); Exit = $exit; Warnings = $warnings; Raw = $dump }
}

# ---------------------------------------------------------------------------
Write-Host "== stage: drift guard (live edits not yet synced?) =="
# A deploy overwrites live files with repo files. If a live file is NEWER than
# its repo counterpart and differs, someone edited live and never ran
# Sync-FromLive -- deploying now would silently clobber those edits (this
# exact incident happened 2026-08-18: a deploy test wiped four sets of fresh
# live edits; the backup stage saved them). Abort unless $env:DEPLOY_FORCE=1.
$drifted = @()
foreach ($m in $map) {
    $source = Join-Path $repo $m.src
    if (-not (Test-Path $source) -or -not (Test-Path $m.dst)) { continue }
    if ($m.skipIfExists) { continue }
    $srcItem = Get-Item $source; $dstItem = Get-Item $m.dst
    if ($dstItem.LastWriteTime -gt $srcItem.LastWriteTime) {
        $srcHash = (Get-FileHash $source -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash $m.dst -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) { $drifted += $m.dst }
    }
}
if ($drifted.Count -gt 0 -and $env:DEPLOY_FORCE -ne '1') {
    Write-Warning "These LIVE files are newer than the repo copies and differ -- unsynced live edits would be clobbered:"
    $drifted | ForEach-Object { Write-Warning "  $_" }
    Write-Error "Run scripts\Sync-FromLive.ps1 first (or set DEPLOY_FORCE=1 to overwrite deliberately). Nothing live was touched."
    exit 1
}
if ($drifted.Count -gt 0) { Write-Warning "DEPLOY_FORCE=1 set - overwriting $($drifted.Count) drifted live file(s) deliberately." }
else { Write-Host "no drift - live matches or is older than repo everywhere" }

Write-Host "`n== stage: pre-validate (YAML syntax) =="
$jsYamlPath = @(
    "$U\.dsh\profiles\node_modules\js-yaml"
    "$U\AppData\Local\npm-cache\_npx\2ede61d9d1d3d32e\node_modules\js-yaml"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $jsYamlPath) {
    Write-Error "No js-yaml install found to borrow (checked dsh profile + npx cache). Aborting -- nothing live touched."
    exit 1
}
$validatorScript = Join-Path $env:TEMP "dsh-deploy-yaml-validate.js"
Set-Content -Path $validatorScript -Encoding utf8 -Value @'
const yaml = require(process.argv[2]);
const fs = require("fs");
const jsTag = new yaml.Type("tag:yaml.org,2002:js", { kind: "scalar", construct: (d) => d });
const schema = yaml.DEFAULT_SCHEMA.extend([jsTag]);
const target = process.argv[3];
try {
    yaml.load(fs.readFileSync(target, "utf8"), { schema, filename: target });
    process.exit(0);
} catch (e) {
    console.error(e.message);
    process.exit(1);
}
'@

$preValidateFailed = $false
foreach ($m in ($map | Where-Object { $_.src -match '\.ya?ml$' })) {
    $source = Join-Path $repo $m.src
    if (-not (Test-Path $source)) { continue }
    if ($m.skipIfExists -and (Test-Path $m.dst)) { continue }
    $result = Test-YamlSyntax -Path $source -JsYamlPath $jsYamlPath -ValidatorScript $validatorScript
    if ($result.Ok) {
        Write-Host "  ok: $($m.src)"
    } else {
        Write-Warning "  YAML SYNTAX ERROR in $($m.src):"
        Write-Warning "    $($result.Message)"
        $preValidateFailed = $true
    }
}
if ($preValidateFailed) {
    Write-Error "Pre-validation failed. Nothing live was touched."
    exit 1
}

Write-Host "`n== stage: validate (staged config composes clean, DSH_HOME override) =="
$stagingHome = Join-Path $env:TEMP "dsh-deploy-stage-$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    New-StagingHome -StagingRoot $stagingHome -Map $map
    $staged = Invoke-DumpConfigGate -AltHome $stagingHome
} finally {
    Remove-Item -Recurse -Force $stagingHome -ErrorAction SilentlyContinue
}
if (-not $staged.Clean) {
    Write-Error "Staged config fails compose-validation (exit=$($staged.Exit)). Nothing live was touched."
    $staged.Warnings | ForEach-Object { Write-Warning $_.Line }
    exit 1
}
Write-Host "staged config composes clean - no unmatched patch targets"

Write-Host "`n== stage: backup =="
$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
$backupRoot = "$U\.dsh\ConfigBackups\deploy-$timestamp"
$backedUp = @()
foreach ($m in $map) {
    if ($m.skipIfExists -and (Test-Path $m.dst)) { continue }
    $existed = Test-Path $m.dst
    $backupPath = $null
    if ($existed) {
        $rel = $m.dst.Substring($U.Length + 1)
        $backupPath = Join-Path $backupRoot $rel
        New-Item -ItemType Directory -Force (Split-Path $backupPath) | Out-Null
        Copy-Item $m.dst $backupPath -Force
        Write-Host "  backed up $($m.dst)"
    }
    $backedUp += [pscustomobject]@{ Dst = $m.dst; BackupPath = $backupPath; Existed = $existed }
}
Write-Host "backups at $backupRoot"

Write-Host "`n== stage: apply =="
foreach ($m in $map) {
    $source = Join-Path $repo $m.src
    if ($m.skipIfExists -and (Test-Path $m.dst)) { Write-Host "kept existing $($m.dst)"; continue }
    if (Test-Path $source) {
        New-Item -ItemType Directory -Force (Split-Path $m.dst) | Out-Null
        Copy-Item $source $m.dst -Force
        Write-Host "deployed $($m.src) -> $($m.dst)"
    } else {
        Write-Warning "missing repo file: $($m.src)"
    }
}

Write-Host "`n== stage: validate (live config composes clean) =="
$live = Invoke-DumpConfigGate
if (-not $live.Clean) {
    Write-Warning "LIVE CONFIG FAILED POST-VALIDATION (exit=$($live.Exit)) -- rolling back automatically."
    $live.Warnings | ForEach-Object { Write-Warning $_.Line }

    foreach ($b in $backedUp) {
        if ($b.Existed) {
            Copy-Item $b.BackupPath $b.Dst -Force
            Write-Host "  restored $($b.Dst)"
        } elseif (Test-Path $b.Dst) {
            Remove-Item $b.Dst -Force
            Write-Host "  removed newly-introduced $($b.Dst)"
        }
    }

    $rollback = Invoke-DumpConfigGate
    if (-not $rollback.Clean) {
        Write-Error "ROLLBACK DID NOT VALIDATE CLEAN (exit=$($rollback.Exit)) -- live config may still be broken. Manual intervention required. Backups at: $backupRoot"
        exit 1
    }
    Write-Host "rollback confirmed clean - live config restored to pre-deploy state."
    Write-Error "DEPLOY FAILED AND WAS ROLLED BACK. Backups retained at: $backupRoot"
    exit 1
}
Write-Host "live config composes clean - no unmatched patch targets"

Write-Host "`nOK. staged -> validated -> backed up -> applied -> validated -> OK."
Write-Host "Backups retained at: $backupRoot"
Write-Host "`nDone. Subagent plugins per profile: npx @deepseek-ai/dsh@0.1.0-rc.7 plugin --profile <web|headless> add @deepseek-ai/dsh-subagent-codex@0.1.0-rc.7 @deepseek-ai/dsh-subagent-claude-code@0.1.0-rc.7 @deepseek-ai/dsh-subagent-acp@0.1.0-rc.7 @deepseek-ai/dsh-sdk-protocol@0.1.0-rc.7"
