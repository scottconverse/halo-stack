# Pull the live HALO stack files into this repo. Run from anywhere.
$repo = Split-Path $PSScriptRoot -Parent
$U = $env:USERPROFILE

$map = @(
    # dsh config surface
    @{ src = "$U\.dsh\settings.yaml";                dst = "dsh\settings.yaml" }
    @{ src = "$U\.dsh\cordis.patch.yml";             dst = "dsh\cordis.patch.yml" }
    # NOTE: $U\.dsh\.env is deliberately NOT synced — it now holds real API keys.
    # The repo carries dsh\dot-env.template instead; Deploy writes it only if
    # no live .env exists.
    @{ src = "$U\.dsh\Start-DSH.ps1";                dst = "dsh\Start-DSH.ps1" }
    @{ src = "$U\.dsh\Start-MissionControl.ps1";     dst = "dsh\Start-MissionControl.ps1" }
    @{ src = "$U\.dsh\bench-overlay-coder.yml";      dst = "dsh\overlays\bench-overlay-coder.yml" }
    @{ src = "$U\.dsh\bench-overlay-code-mode.yml";  dst = "dsh\overlays\bench-overlay-code-mode.yml" }
    @{ src = "$U\.dsh\bench-overlay-trio.yml";       dst = "dsh\overlays\bench-overlay-trio.yml" }
    @{ src = "$U\.dsh\.agent-presets\halo-standard\agent.cordis.yml"; dst = "dsh\agent-presets\halo-standard\agent.cordis.yml" }
    @{ src = "$U\.dsh\.agent-presets\halo-standard\preset.yml";       dst = "dsh\agent-presets\halo-standard\preset.yml" }
    # Memory-graph snapshot compensation (hourly scheduled task "HALO Memory Snapshot")
    @{ src = "$U\.dsh\memory\Snapshot-Memory.ps1";      dst = "dsh\memory\Snapshot-Memory.ps1" }
    # Harness skills
    @{ src = "$U\.dsh\skills\delta-scan-halo\SKILL.md"; dst = "dsh\skills\delta-scan-halo\SKILL.md" }
    # Shared-root skills (~\.agents\skills — visible to Claude Code AND the harness)
    @{ src = "$U\.agents\skills\reddit-search\SKILL.md"; dst = "agents-skills\reddit-search\SKILL.md" }
    # Workspace instruction file (auto-loaded by dsh into every session)
    @{ src = "$U\Desktop\Code\AGENTS.md"; dst = "workspace\AGENTS.md" }
    # LM Studio loader scripts
    @{ src = "$U\.lmstudio\scripts\Load-OpenCode-Qwen.mjs"; dst = "lmstudio\Load-OpenCode-Qwen.mjs" }
    @{ src = "$U\.lmstudio\scripts\Load-Worker-Coder.mjs";  dst = "lmstudio\Load-Worker-Coder.mjs" }
    @{ src = "$U\.lmstudio\scripts\Sweep-MTP.mjs";          dst = "lmstudio\Sweep-MTP.mjs" }
    # Mission Control
    @{ src = "$U\.dsh\mission-control\mission-control.mjs"; dst = "mission-control\mission-control.mjs" }
    # OpenCode config (placeholder key only; auth files deliberately excluded)
    @{ src = "$U\.config\opencode\opencode.json";           dst = "opencode\opencode.json" }
)

foreach ($m in $map) {
    if (Test-Path $m.src) {
        $target = Join-Path $repo $m.dst
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $m.src $target -Force
        Write-Host "synced $($m.dst)"
    } else {
        Write-Warning "missing live file: $($m.src)"
    }
}
Write-Host "`nValidating composed config (dsh --dump-config; watch for 'unmatched' warnings)..."
$env:DSH_PERMISSION_MODE = 'danger-full-access'
# MIGRATION 2026-08-21: pnpm dlx, not npx (npm resolver hangs on Node 25).
$dump = pnpm dlx "@deepseek-ai/dsh@0.1.1-rc.2" web --dump-config 2>&1
$warnings = $dump | Select-String -Pattern "warn|unmatched"
if ($warnings) { Write-Warning "CONFIG WARNINGS:"; $warnings | ForEach-Object { Write-Warning $_.Line } }
else { Write-Host "config composes clean - no unmatched patch targets" }

Write-Host "`nDone. Review with: git -C `"$repo`" diff"
