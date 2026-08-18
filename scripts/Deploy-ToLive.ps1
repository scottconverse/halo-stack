# Rebuild: push this repo's stack files out to their live locations.
# Machine-rebuild order after this: install Node 22+, LM Studio (+ the two GGUF
# models), pnpm 11, then run the desktop launchers (they pin dsh 0.1.0-rc.7 via npx).
$repo = Split-Path $PSScriptRoot -Parent
$U = $env:USERPROFILE

$map = @(
    @{ src = "dsh\settings.yaml";                dst = "$U\.dsh\settings.yaml" }
    @{ src = "dsh\cordis.patch.yml";             dst = "$U\.dsh\cordis.patch.yml" }
    @{ src = "dsh\dot-env";                      dst = "$U\.dsh\.env" }
    @{ src = "dsh\Start-DSH.ps1";                dst = "$U\.dsh\Start-DSH.ps1" }
    @{ src = "dsh\Start-MissionControl.ps1";     dst = "$U\.dsh\Start-MissionControl.ps1" }
    @{ src = "dsh\overlays\bench-overlay-coder.yml";     dst = "$U\.dsh\bench-overlay-coder.yml" }
    @{ src = "dsh\overlays\bench-overlay-code-mode.yml"; dst = "$U\.dsh\bench-overlay-code-mode.yml" }
    @{ src = "dsh\overlays\bench-overlay-trio.yml";      dst = "$U\.dsh\bench-overlay-trio.yml" }
    @{ src = "dsh\agent-presets\halo-standard\agent.cordis.yml"; dst = "$U\.dsh\.agent-presets\halo-standard\agent.cordis.yml" }
    @{ src = "dsh\agent-presets\halo-standard\preset.yml";       dst = "$U\.dsh\.agent-presets\halo-standard\preset.yml" }
    @{ src = "dsh\skills\delta-scan-halo\SKILL.md"; dst = "$U\.dsh\skills\delta-scan-halo\SKILL.md" }
    @{ src = "lmstudio\Load-OpenCode-Qwen.mjs";  dst = "$U\.lmstudio\scripts\Load-OpenCode-Qwen.mjs" }
    @{ src = "lmstudio\Load-Worker-Coder.mjs";   dst = "$U\.lmstudio\scripts\Load-Worker-Coder.mjs" }
    @{ src = "lmstudio\Sweep-MTP.mjs";           dst = "$U\.lmstudio\scripts\Sweep-MTP.mjs" }
    @{ src = "mission-control\mission-control.mjs"; dst = "$U\.dsh\mission-control\mission-control.mjs" }
    @{ src = "opencode\opencode.json";           dst = "$U\.config\opencode\opencode.json" }
)

foreach ($m in $map) {
    $source = Join-Path $repo $m.src
    if (Test-Path $source) {
        New-Item -ItemType Directory -Force (Split-Path $m.dst) | Out-Null
        Copy-Item $source $m.dst -Force
        Write-Host "deployed $($m.src) -> $($m.dst)"
    } else {
        Write-Warning "missing repo file: $($m.src)"
    }
}
Write-Host "`nDone. Subagent plugins per profile: npx @deepseek-ai/dsh@0.1.0-rc.7 plugin --profile <web|headless> add @deepseek-ai/dsh-subagent-codex@0.1.0-rc.7 @deepseek-ai/dsh-subagent-claude-code@0.1.0-rc.7 @deepseek-ai/dsh-subagent-acp@0.1.0-rc.7 @deepseek-ai/dsh-sdk-protocol@0.1.0-rc.7"
