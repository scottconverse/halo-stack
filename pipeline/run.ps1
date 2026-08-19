# Budgeted-emit pipeline launcher (HALO).
# Sets the env the steps and the openai-compat backend need, then runs the
# workflow. All arguments pass through to workflow.py, e.g.:
#   .\run.ps1                      full run against runs\latest
#   .\run.ps1 --run-dir runs\r2    separate run record
#   .\run.ps1 --from emit_chunk    resume partway
# Requires: LM Studio serving the brain at 127.0.0.1:1234, node on PATH,
# python on PATH, Git Bash (workflow.py finds it via WORKFLOW_BASH if needed).
param([Parameter(ValueFromRemainingArguments = $true)] $Rest)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

# The runner's per-call output ceiling. Qwen3.8 spends thinking tokens from
# the same budget, so this sits well above the 12K chunk cap.
if (-not $env:WORKFLOW_OPENAI_MAX_TOKENS) { $env:WORKFLOW_OPENAI_MAX_TOKENS = "24000" }

# Steps locate the run directory through this; keep it in lockstep with
# --run-dir if you pass one.
$runDir = "runs\latest"
for ($i = 0; $i -lt @($Rest).Count; $i++) {
    if (@($Rest)[$i] -eq "--run-dir" -and $i + 1 -lt @($Rest).Count) { $runDir = @($Rest)[$i + 1] }
}
$env:WORKFLOW_RUN_DIR = $runDir
New-Item -ItemType Directory -Force $runDir | Out-Null

# The task brief must exist before a run.
if (-not (Test-Path (Join-Path $runDir "task-brief.md"))) {
    Write-Warning "No task-brief.md in $runDir - the planner will have nothing to plan. Create it first."
}

python workflow.py @Rest
exit $LASTEXITCODE
