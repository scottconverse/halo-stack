# Mission Control launcher — idempotent, hidden, browser only when serving.
if (Get-NetTCPConnection -LocalPort 3090 -State Listen -ErrorAction SilentlyContinue) {
    Start-Process "http://127.0.0.1:3090"
    exit 0
}
$mc = Start-Process -PassThru -WindowStyle Hidden node -ArgumentList "`"$env:USERPROFILE\.dsh\mission-control\mission-control.mjs`""
$deadline = (Get-Date).AddSeconds(20)
do { Start-Sleep -Milliseconds 500; $up = Get-NetTCPConnection -LocalPort 3090 -State Listen -ErrorAction SilentlyContinue } until ($up -or (Get-Date) -gt $deadline)
Start-Process "http://127.0.0.1:3090"
if ($mc) { Wait-Process -Id $mc.Id }
