# DeepSeek Harness launcher (hardened).
# Order: model first, server second, browser LAST.
#
# Hardening over the original, from failures observed porting the stack to a
# second machine (see TESTER-5070ti-bench.md on branch tester/5070ti):
#   1. Wait for LM Studio's API before loading. On a cold boot the loader ran
#      before the server accepted connections, failed, and Out-Null ate it.
#   2. Ensure the brain is resident even when :3080 is already up. The old
#      early-exit skipped the model check, so an evicted brain stayed dead
#      (eviction is rare on 128GB, routine on smaller boxes).
#   3. Loader output goes to ~\.dsh\launcher.log with one retry; on repeated
#      failure the log opens in Notepad. Nothing fails silently.
#   4. Brain check requires deviceIdentifier null: on an LM Studio federated
#      with other devices, a remote box can publish the same identity and
#      satisfy a naive check.
# ASCII only: PowerShell 5.1 misparses BOM-less UTF-8 punctuation.

$log = "$env:USERPROFILE\.dsh\launcher.log"
"=== launch $(Get-Date -Format o) ===" | Out-File -FilePath $log -Encoding utf8

# 1) LM Studio server up, and actually answering.
lms server start 2>$null | Out-Null
$apiUp = $false
$deadline = (Get-Date).AddSeconds(60)
do {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:1234/v1/models" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) { $apiUp = $true; break }
    } catch { Start-Sleep -Seconds 2 }
} until ((Get-Date) -gt $deadline)
"LM Studio API up: $apiUp" | Add-Content $log
if (-not $apiUp) { Start-Process notepad $log; exit 1 }

# 2) Brain resident with the stable id, locally? Runs even if :3080 is up.
function Test-BrainLoaded {
    $ps = lms ps --json 2>$null | ConvertFrom-Json
    return [bool]($ps | Where-Object { $_.identifier -eq 'qwen/qwen3.8-27b' -and -not $_.deviceIdentifier })
}
if (-not (Test-BrainLoaded)) {
    foreach ($attempt in 1, 2) {
        "brain load attempt $attempt" | Add-Content $log
        node "$env:USERPROFILE\.lmstudio\scripts\Load-OpenCode-Qwen.mjs" *>> $log
        if (Test-BrainLoaded) { break }
        Start-Sleep -Seconds 5
    }
    if (-not (Test-BrainLoaded)) {
        "BRAIN LOAD FAILED TWICE -- see output above." | Add-Content $log
        Start-Process notepad $log
        # keep going: the cockpit page is still useful for reading sessions
    }
}

# 3) Harness (pinned) -- only if not already serving.
if (-not (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)) {
    $env:DSH_PERMISSION_MODE = 'danger-full-access'
    Set-Location C:\
    $dsh = Start-Process -PassThru -WindowStyle Hidden npx.cmd -ArgumentList '"@deepseek-ai/dsh@0.1.0-rc.7"','web'
    $deadline = (Get-Date).AddSeconds(180)
    do {
        Start-Sleep -Seconds 3
        $up = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
    } until ($up -or (Get-Date) -gt $deadline)
}

# 4) Browser last.
Start-Process "http://127.0.0.1:3080"
if ($dsh) { Wait-Process -Id $dsh.Id }
