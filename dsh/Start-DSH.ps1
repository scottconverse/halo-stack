# DeepSeek Harness launcher — HALO (v2 plan, post-reboot fix)
# Order: model first, server second, browser LAST (only when the page will actually load).

# Already running? Just open the page.
if (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue) {
    Start-Process "http://127.0.0.1:3080"
    exit 0
}

# 1) Make sure LM Studio's server is up (no-op if already running).
lms server start 2>$null | Out-Null

# 2) Load the Q5 brain only if it isn't already resident with the stable id.
$loaded = (lms ps --json 2>$null | ConvertFrom-Json) | Where-Object { $_.identifier -eq 'qwen/qwen3.8-27b' }
if (-not $loaded) {
    node "$env:USERPROFILE\.lmstudio\scripts\Load-OpenCode-Qwen.mjs" | Out-Null
}

# 3) Start the harness (pinned) in the background of this hidden window.
$env:DSH_PERMISSION_MODE = 'danger-full-access'
Set-Location C:\
$dsh = Start-Process -PassThru -WindowStyle Hidden npx.cmd -ArgumentList '"@deepseek-ai/dsh@0.1.0-rc.7"','web'

# 4) Open the browser only once the server answers (up to 3 min for a cold npx).
$deadline = (Get-Date).AddSeconds(180)
do {
    Start-Sleep -Seconds 3
    $up = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
} until ($up -or (Get-Date) -gt $deadline)
Start-Process "http://127.0.0.1:3080"

# Keep this hidden host alive while the server runs so closing it is clean.
if ($dsh) { Wait-Process -Id $dsh.Id }
