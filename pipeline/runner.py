"""Process boundaries: how this workflow talks to agents, shells, and people.

Everything that leaves the Python process goes through here, so there is exactly one
place to change when you swap the agent CLI for an SDK, add tracing, or set a budget.

Agent nodes run one of two ways, and the choice is about where you work rather than
what the workflow does:

    subprocess (default)  spawn an agent CLI. Right for a terminal, CI, or cron,
                          where an unattended run should go start to finish alone.
    delegate              park and let the assistant you are already talking to do
                          the node, then resume. Right when you work inside an
                          assistant and have no terminal to run this from.

Delegate mode is not a lesser path. The deterministic half — routing, retry
ceilings, payloads, isolation of one node from the next — is identical, because it
lives in the driver rather than here. Only the model call moves, and moving it means
no CLI on PATH, no nested session spending tokens out of sight, and every agent step
visible where you are working.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class Result:
    ok: bool
    output: str = ""
    session_id: str | None = None
    # False only when no model call actually happened, which is what separates
    # "the CLI is missing" from "the call ran and failed". The budget charges
    # for the second and not the first.
    launched: bool = True


AGENT_TIMEOUT = int(os.environ.get("WORKFLOW_AGENT_TIMEOUT", "1800"))
STEP_TIMEOUT = int(os.environ.get("WORKFLOW_STEP_TIMEOUT", "3600"))
PERMISSION_MODE = os.environ.get("WORKFLOW_PERMISSION_MODE", "acceptEdits")

# The agent CLI, overridable so tests can substitute a stub and so a different
# CLI can be swapped in without editing this file. Split with shlex so the
# override may carry its own arguments, e.g. "python /path/to/stub.py".
AGENT_CLI = shlex.split(os.environ.get("WORKFLOW_AGENT_CLI", "claude")) or ["claude"]

# The other backends, overridable the same way. Antigravity in particular is
# usually not on PATH -- on Windows it installs to %LOCALAPPDATA%\agy\bin.
CODEX_CLI = shlex.split(os.environ.get("WORKFLOW_CODEX_CLI", "codex")) or ["codex"]
AGY_CLI = shlex.split(os.environ.get("WORKFLOW_AGY_CLI", "agy")) or ["agy"]

# read-only by default. Codex's own default is workspace-write with approvals
# off, which edits files without asking -- not a thing to inherit silently in a
# workflow whose whole premise is that each node's effects are declared.
CODEX_SANDBOX = os.environ.get("WORKFLOW_CODEX_SANDBOX", "read-only")

# Antigravity takes its prompt as a command-line argument and ignores stdin, so
# it alone is bounded by the OS command-line limit. Set well under the 32767
# Windows ceiling to leave room for the rest of the argv.
AGY_PROMPT_LIMIT = int(os.environ.get("WORKFLOW_AGY_PROMPT_LIMIT", "28000"))

# Self-hosted reasoning models spend hidden thinking tokens before any visible
# output, so a small ceiling returns an empty reply rather than a short one.
OPENAI_COMPAT_MAX_TOKENS = int(os.environ.get("WORKFLOW_OPENAI_MAX_TOKENS", "4096"))

NEEDS_HUMAN = 75  # EX_TEMPFAIL: the run is not wrong, it is waiting on a person
NEEDS_AGENT = 76  # likewise, waiting on a delegated agent node


def delegating(environ=None):
    """Read the mode at call time so --delegate can set it before the run."""
    if environ is None:
        environ = os.environ
    return environ.get("WORKFLOW_DELEGATE", "") not in ("", "0")


def _bash(environ=None):
    """Locate a bash that can run step scripts.

    On Windows an unqualified "bash" goes through CreateProcess's search order,
    which checks System32 before PATH — and System32's bash.exe is the WSL
    launcher, which re-tokenizes the command line POSIX-style and cannot see
    Windows drive paths anyway. Prefer Git's bash, which handles them natively.
    """
    if environ is None:
        environ = os.environ
    if os.name != "nt":
        return "bash"
    override = environ.get("WORKFLOW_BASH")
    if override:
        return override
    for base in filter(None, (environ.get("ProgramFiles"),
                              environ.get("ProgramFiles(x86)"))):
        for sub in ("Git/usr/bin/bash.exe", "Git/bin/bash.exe"):
            cand = os.path.join(base, sub)
            if os.path.exists(cand):
                return cand
    found = shutil.which("bash", path=environ.get("PATH", ""))
    if found and "system32" not in found.lower():
        return found
    # No unqualified-"bash" fallback: that silently lands on the WSL launcher
    # again, the same invisible-failure class as a swallowed exception.
    raise SystemExit(
        "no usable bash found for step scripts. Install Git for Windows, or set "
        "WORKFLOW_BASH to a bash that understands Windows paths."
    )


def delegate_agent(prompt, *, node_id, run_dir, model=None, tools=None):
    """Hand one agent node to the operator, or collect what they left.

    One node, split across two invocations. First call writes the composed prompt
    and parks; the next call finds the answer and carries on. The answer is renamed
    rather than deleted, so a retry cannot silently re-consume the reply to an
    earlier attempt, and the run directory still reads as a transcript afterwards.
    """
    run_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = run_dir / f"{node_id}.prompt.md"
    result_path = run_dir / f"{node_id}.result.md"

    if result_path.exists():
        text = result_path.read_text(encoding="utf-8").strip()
        consumed = run_dir / f"{node_id}.result.consumed.md"
        consumed.unlink(missing_ok=True)
        result_path.rename(consumed)
        # An empty answer is a failure, not a silent success: it routes down the
        # node's fail edge like any other, rather than passing nothing downstream.
        return Result(bool(text), text or "delegated node returned nothing")

    prompt_path.write_text(prompt, encoding="utf-8")
    log_event(run_dir, "park", node=node_id, waiting_for="agent", exit_code=NEEDS_AGENT)
    spec_note = ""
    if model:
        spec_note = f"This node is specified for model {model}"
        if tools:
            spec_note += f", limited to tools: {', '.join(tools)}"
        spec_note += ".\n"
    print(
        f"\n=== {node_id} is delegated ===\n"
        f"{spec_note}"
        f"Prompt written to : {prompt_path}\n"
        f"Write the answer to: {result_path}\n\n"
        f"Do the work the prompt describes, save the result to that path, then run "
        f"this workflow again with the same --run-dir to continue. Attempt counts "
        f"and the retry ceiling are preserved across the pause.",
        file=sys.stderr,
    )
    raise SystemExit(NEEDS_AGENT)


def run_agent(prompt, *, session_id=None, model=None, tools=None, cwd=None,
              node_id=None, run_dir=None, backend=None, endpoint=None):
    """Send one node's prompt to whichever system runs it.

    Four backends, because no single one reaches every model and they are billed to
    different meters. The choice is per node and lives in the spec; everything else
    about a run -- routing, retry ceilings, payloads, the budget -- is identical
    whichever way this dispatches, because all of that lives in the driver rather
    than here.

    Delegate mode short-circuits every backend. When a person is doing the agent
    nodes there is no CLI to pick.
    """
    if delegating():
        return delegate_agent(
            prompt, node_id=node_id, run_dir=run_dir, model=model, tools=tools
        )

    backend = backend or "claude"
    if backend == "claude":
        return _run_claude(prompt, session_id=session_id, model=model, tools=tools,
                           cwd=cwd)
    if backend == "codex":
        return _run_codex(prompt, session_id=session_id, model=model, cwd=cwd,
                          run_dir=run_dir, node_id=node_id)
    if backend == "agy":
        return _run_agy(prompt, session_id=session_id, model=model, cwd=cwd)
    if backend == "openai-compat":
        return _run_openai_compat(prompt, model=model, endpoint=endpoint)
    return Result(False, f"unknown backend {backend!r}", session_id, launched=False)


def _run_claude(prompt, *, session_id=None, model=None, tools=None, cwd=None):
    """Invoke an agent as a subprocess and return its result plus session id.

    Resuming matters on retries. A producer that just failed already holds the context
    of what it was attempting; what it lacks is the news that it failed and why.
    Starting a fresh session throws away the former to deliver the latter, and usually
    produces a different first mistake rather than a fix.
    """
    cmd = [*AGENT_CLI, "-p", "--output-format", "json", "--permission-mode", PERMISSION_MODE]
    if session_id:
        cmd += ["--resume", session_id]
    if model:
        cmd += ["--model", model]
    if tools:
        cmd += ["--allowed-tools", *tools]

    try:
        # The prompt travels on stdin, not argv. Windows caps a command line at
        # 32767 chars — 8191 through cmd.exe shims, which also truncate at the
        # first newline — and a prompt carrying payload files exceeds that
        # routinely. stdin has no ceiling and no quoting hazards anywhere.
        proc = subprocess.run(
            cmd, input=prompt, capture_output=True, text=True, cwd=cwd,
            timeout=AGENT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return Result(False, f"agent exceeded {AGENT_TIMEOUT}s timeout", session_id)
    except FileNotFoundError:
        # Kept ahead of OSError, which it subclasses, because "not on PATH" is
        # the one start failure with an obvious fix worth naming.
        return Result(False, f"the `{AGENT_CLI[0]}` CLI is not on PATH", session_id,
                      launched=False)
    except OSError as exc:
        # Everything else that stops a command starting. Pointing the CLI at a
        # directory raises PermissionError and at a non-executable file raises a
        # bare OSError, and both escaped as tracebacks -- killing the run rather
        # than failing the node -- while only the missing-file case was caught.
        return Result(False, f"could not start `{AGENT_CLI[0]}`: {exc}", session_id,
                      launched=False)

    if not proc.stdout.strip():
        return Result(False, proc.stderr.strip() or "agent produced no output", session_id)

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return Result(False, f"unparseable agent output: {proc.stdout[:500]}", session_id)

    new_session = data.get("session_id") or session_id
    text = str(data.get("result", ""))
    if proc.returncode != 0 or data.get("is_error"):
        return Result(False, text or proc.stderr.strip(), new_session)
    return Result(True, text, new_session)


def _spawn(cmd, prompt, *, cwd, name):
    """Run a backend CLI with the prompt on stdin, or report why it could not.

    Separated from every backend's own parsing because the three failures that are
    not about the reply -- timeout, missing CLI, no output -- read the same for all
    of them, and only the missing-CLI case must avoid charging the budget.
    """
    try:
        proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True,
                              cwd=cwd, timeout=AGENT_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, Result(False, f"{name} exceeded {AGENT_TIMEOUT}s timeout")
    except FileNotFoundError:
        return None, Result(False, f"the `{cmd[0]}` CLI is not on PATH", None,
                            launched=False)
    except OSError as exc:
        # See _run_claude. These two CLIs are the ones most likely to be named by
        # a hand-written path -- Antigravity is normally not on PATH -- so the
        # near-miss that lands on the containing directory is the ordinary
        # mistake, and it raises PermissionError rather than FileNotFoundError.
        return None, Result(False, f"could not start `{cmd[0]}`: {exc}", None,
                            launched=False)
    return proc, None


def _find_session_id(text):
    """Best effort: pull a session id out of Codex's JSONL event stream.

    The event schema is not part of Codex's documented contract, so this looks for
    any of the plausible keys at any depth rather than pinning one shape. Failing to
    find one is not an error -- the retry simply starts cold, still carrying the
    feedback payload that says what went wrong, which is the larger half of what a
    resume would have given it.
    """
    keys = ("session_id", "conversation_id", "thread_id")

    def walk(obj):
        if isinstance(obj, dict):
            for key in keys:
                value = obj.get(key)
                if isinstance(value, str) and value:
                    return value
            for value in obj.values():
                found = walk(value)
                if found:
                    return found
        elif isinstance(obj, list):
            for item in obj:
                found = walk(item)
                if found:
                    return found
        return None

    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            found = walk(json.loads(line))
        except json.JSONDecodeError:
            continue
        if found:
            return found
    return None


def _run_codex(prompt, *, session_id=None, model=None, cwd=None, run_dir=None,
               node_id=None):
    """Run a node on the Codex CLI, billed to the OpenAI account.

    The prompt goes on stdin via the `-` argument, and the reply comes back through
    --output-last-message rather than by parsing the JSONL event stream: the final
    message is the only part of that stream this needs, and reading it from a file
    means a schema change upstream cannot quietly alter what a node returns.
    """
    target = Path(run_dir) if run_dir else Path(cwd or ".")
    target.mkdir(parents=True, exist_ok=True)
    last = target / f"{node_id or 'agent'}.codex-last.txt"
    last.unlink(missing_ok=True)

    cmd = [*CODEX_CLI, "exec"]
    if session_id:
        # resume takes the id positionally, before the prompt.
        cmd += ["resume"]
    if model:
        cmd += ["-m", model]
    cmd += ["-s", CODEX_SANDBOX, "--skip-git-repo-check", "--json",
            "--output-last-message", str(last)]
    if session_id:
        cmd += [session_id]
    cmd += ["-"]

    proc, failure = _spawn(cmd, prompt, cwd=cwd, name="codex")
    if failure:
        return failure

    text = ""
    if last.is_file():
        text = last.read_text(encoding="utf-8", errors="replace").strip()
    new_session = _find_session_id(proc.stdout) or session_id

    if proc.returncode != 0:
        return Result(False, text or proc.stderr.strip() or "codex failed",
                      new_session)
    if not text:
        return Result(False, proc.stderr.strip() or "codex produced no final message",
                      new_session)
    return Result(True, text, new_session)


def _run_agy(prompt, *, session_id=None, model=None, cwd=None):
    """Run a node on Antigravity, which reaches Gemini and GPT-OSS.

    Antigravity takes its prompt as an argument and ignores stdin -- verified, not
    assumed. That reintroduces the command-line ceiling every other path here avoids,
    so an oversized prompt is refused outright. A truncated prompt would return a
    confident answer to a question that was cut in half, which is the failure this
    whole design exists to prevent; refusing costs a run and explains itself.
    """
    if len(prompt) > AGY_PROMPT_LIMIT:
        return Result(
            False,
            f"prompt is {len(prompt)} characters and Antigravity takes it on the "
            f"command line, which caps out near {AGY_PROMPT_LIMIT}. It would be "
            "truncated silently. Route this node to a backend that reads stdin "
            "(claude, codex) or shrink what the incoming edges carry.",
            session_id, launched=False,
        )

    cmd = [*AGY_CLI, "-p", prompt, "--output-format", "json"]
    if model:
        cmd += ["--model", model]
    if session_id:
        cmd += ["--conversation", session_id]

    proc, failure = _spawn(cmd, "", cwd=cwd, name="agy")
    if failure:
        return failure

    if not proc.stdout.strip():
        return Result(False, proc.stderr.strip() or "agy produced no output",
                      session_id)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return Result(False, f"unparseable agy output: {proc.stdout[:500]}", session_id)

    new_session = data.get("conversation_id") or session_id
    text = str(data.get("response", "")).strip()
    if proc.returncode != 0 or data.get("status") not in (None, "SUCCESS"):
        return Result(False, text or f"agy status {data.get('status')!r}", new_session)
    if not text:
        return Result(False, "agy returned an empty response", new_session)
    return Result(True, text, new_session)


def _post_json(url, payload):
    """POST a JSON body and return (status, decoded-body-or-None, error-text)."""
    try:
        # Built inside the try, not above it: Request() parses the URL in its
        # constructor and raises for one it cannot read, so a malformed endpoint
        # never reaches urlopen and would escape a handler placed after this.
        request = urllib.request.Request(
            url, data=json.dumps(payload).encode("utf-8"),
            headers={"content-type": "application/json",
                     "anthropic-version": "2023-06-01"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=AGENT_TIMEOUT) as response:
            return response.status, json.loads(response.read().decode("utf-8")), ""
    except urllib.error.HTTPError as exc:
        return exc.code, None, exc.read().decode("utf-8", "replace")[:500]
    except urllib.error.URLError as exc:
        return 0, None, str(exc.reason)
    except json.JSONDecodeError as exc:
        return 0, None, f"reply was not JSON ({exc})"
    except ValueError as exc:
        # Request() raises this for a URL it cannot parse, before any of the
        # above can apply. The validator refuses such an endpoint at scaffold
        # time, so this is unreachable from a generated package -- but a
        # function whose whole job is to turn failure into a return value
        # should not depend on something upstream to stay true.
        return 0, None, f"not a usable URL ({exc})"


def _run_openai_compat(prompt, *, model=None, endpoint=None):
    """Call an OpenAI-compatible server directly over HTTP.

    Tries the Anthropic-format path first and falls back to the OpenAI one on the
    three statuses that all mean "this server does not serve that path". No session
    resume: these endpoints are stateless, so a retry carries its context in the
    feedback payload instead.

    There is no privacy check here on purpose. Whether this endpoint is loopback or a
    machine across the room is a decision made in the spec, and the design doc names
    where every payload goes -- enforcing it at call time would be too late to be a
    decision at all.
    """
    if not endpoint:
        return Result(False, "no endpoint configured for an openai-compat node",
                      None, launched=False)
    base = endpoint.rstrip("/")
    body = {"model": model or "default", "max_tokens": OPENAI_COMPAT_MAX_TOKENS,
            "messages": [{"role": "user", "content": prompt}]}

    status, data, error = _post_json(f"{base}/v1/messages", body)
    if status in (404, 405, 501):
        status, data, error = _post_json(f"{base}/v1/chat/completions", body)

    if status != 200 or data is None:
        detail = error or f"HTTP {status}"
        launched = status != 0  # a connection that never opened cost nothing
        return Result(False, f"{base}: {detail}", None, launched=launched)

    if "content" in data:  # Anthropic shape
        blocks = data["content"] if isinstance(data["content"], list) else []
        text = "".join(b.get("text", "") for b in blocks
                       if isinstance(b, dict) and b.get("type") == "text")
    elif "choices" in data:  # OpenAI shape
        try:
            text = data["choices"][0]["message"]["content"] or ""
        except (IndexError, KeyError, TypeError) as exc:
            return Result(False, f"malformed OpenAI-format reply ({exc})", None)
    else:
        return Result(False, f"unrecognized reply shape (keys: "
                             f"{', '.join(sorted(data))})", None)

    if not text.strip():
        # A reasoning-style model spends hidden tokens before any visible output, so
        # an empty reply usually means the ceiling was too low. Never report it as a
        # success: a batch caller recording "" as an answer is the silent kind of
        # wrong.
        return Result(False, "server replied 200 with no visible text - raise "
                             "WORKFLOW_OPENAI_MAX_TOKENS", None)
    return Result(True, text.strip(), None)


def run_step(script, *, cwd=None):
    """Run a deterministic step. Exit status is the verdict; output is the payload."""
    try:
        # Forward slashes: a backslashed path is mangled by msys bash's own
        # command-line re-parse when launched from a native Windows process.
        proc = subprocess.run(
            [_bash(), str(script).replace(os.sep, "/")], capture_output=True,
            text=True, cwd=cwd, timeout=STEP_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return Result(False, f"step exceeded {STEP_TIMEOUT}s timeout")
    return Result(proc.returncode == 0, (proc.stdout + proc.stderr).strip())


EVENT_LOG = "run.jsonl"
MAX_EVENT_OUTPUT = 20_000


def log_event(run_dir, event, **fields):
    """Append one JSON object to the run's event log.

    The run directory keeps only the latest of everything: <node>.out and
    <node>.prompt.md are overwritten on every retry. That loses the one thing
    worth seeing when a bounded loop burns its ceiling — what changed between
    attempt two and attempt three. This keeps every attempt.

    Opened for append, never for write, because each delegated pause is a new
    process and truncating here would quietly discard the run's whole history
    at the first park.
    """
    run_dir = Path(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    output = fields.get("output")
    if isinstance(output, str) and len(output) > MAX_EVENT_OUTPUT:
        # A runaway node must not make the log unreadable, and a record that
        # was trimmed without saying so is worse than no record.
        fields["output"] = output[:MAX_EVENT_OUTPUT]
        fields["output_truncated_from"] = len(output)
    record = {
        "at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "event": event,
        **fields,
    }
    with (run_dir / EVENT_LOG).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")


APPROVALS = ("y", "yes", "approve", "approved")
REJECTIONS = ("n", "no", "reject", "rejected")


def read_answer(text):
    """Parse an operator's written answer into (approved, verdict, rationale).

    The first line is the verdict and everything after it is why. An answer
    that is neither an approval nor a rejection is NOT approved: an answer the
    parser does not understand is exactly the case where a person meant
    something specific, and reading consent into it is the one wrong way to
    resolve the ambiguity.
    """
    lines = [line.strip() for line in text.strip().splitlines()]
    verdict = (lines[0] if lines else "").lower().strip(".!,;: ")
    rationale = "\n".join(lines[1:]).strip()
    if verdict in APPROVALS:
        return True, verdict, rationale
    if verdict in REJECTIONS:
        return False, verdict, rationale
    return False, verdict, text.strip()


def write_decision(run_dir, node_id, *, label, detail, context, approved,
                   verdict, rationale, mode):
    """Record who decided what, and why. A gate nobody can audit is a gesture."""
    record = {
        "node": node_id,
        "label": label,
        "detail": detail,
        "context": str(context),
        "approved": approved,
        "answer": verdict,
        "rationale": rationale,
        "mode": mode,
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    (Path(run_dir) / f"{node_id}.decision.json").write_text(
        json.dumps(record, indent=2) + "\n", encoding="utf-8"
    )
    log_event(run_dir, "decision", node=node_id, approved=approved,
              answer=verdict, mode=mode)
    return record


def ask_human(label, detail, context_path, *, node_id="decision"):
    """Get a decision from a person, by whatever route is actually available.

    Three routes, in the order they are tried. Delegate mode parks and reads a
    written answer, which is the only route open to someone driving a workflow
    from inside an assistant with no terminal at all. A real terminal prompts.
    Anything else parks without deciding, because an unattended run that
    approves its own work removes the only check the node existed to provide.
    """
    run_dir = Path(context_path)
    unattended = (
        "No interactive terminal, so this run stops here rather than deciding for "
        "you. Review the context above and rerun with --from to continue."
    )

    if delegating():
        run_dir.mkdir(parents=True, exist_ok=True)
        request_path = run_dir / f"{node_id}.decision.md"
        answer_path = run_dir / f"{node_id}.answer.md"

        if answer_path.exists():
            raw = answer_path.read_text(encoding="utf-8")
            consumed = run_dir / f"{node_id}.answer.consumed.md"
            consumed.unlink(missing_ok=True)
            answer_path.rename(consumed)
            approved, verdict, rationale = read_answer(raw)
            write_decision(
                run_dir, node_id, label=label, detail=detail, context=run_dir,
                approved=approved, verdict=verdict, rationale=rationale,
                mode="delegated",
            )
            return Result(approved, f"human answered: {verdict or 'nothing'}")

        request_path.write_text(
            f"# Decision: {label}\n\n{detail}\n\n"
            f"Context: {run_dir}\n\n---\n\n"
            f"Write your answer to `{answer_path.name}` in this directory.\n\n"
            f"The first line must be `yes` or `no`. Everything after it is kept as "
            f"your reasoning. An answer that is neither is recorded as not "
            f"approved, so say plainly which you mean.\n",
            encoding="utf-8",
        )
        # Logged here as well as on the unattended path, because delegate mode is
        # the one where a person is actually reading this log back. Without it the
        # history shows a decision arriving in answer to a question it never
        # recorded being asked.
        log_event(run_dir, "park", node=node_id, waiting_for="human",
                  exit_code=NEEDS_HUMAN)
        print(
            f"\n=== {label} needs a decision ===\n{detail}\n"
            f"Question written to: {request_path}\n"
            f"Write the answer to : {answer_path}\n\n"
            f"First line `yes` or `no`, reasoning after. Then run this workflow "
            f"again with the same --run-dir.",
            file=sys.stderr,
        )
        raise SystemExit(NEEDS_HUMAN)

    print(f"\n=== {label} ===\n{detail}\nContext: {context_path}\n")
    if not sys.stdin.isatty():
        log_event(run_dir, "park", node=node_id, waiting_for="human",
                  exit_code=NEEDS_HUMAN)
        print(unattended, file=sys.stderr)
        raise SystemExit(NEEDS_HUMAN)
    try:
        answer = input("Approve? [y/N] ").strip().lower()
    except EOFError:
        # A stdin that claims to be a TTY but delivers EOF has nobody at it.
        # Windows does this even for NUL, so isatty alone cannot be trusted.
        print(unattended, file=sys.stderr)
        raise SystemExit(NEEDS_HUMAN)
    approved = answer in APPROVALS
    write_decision(
        run_dir, node_id, label=label, detail=detail, context=context_path,
        approved=approved, verdict=answer or "no", rationale="",
        mode="interactive",
    )
    return Result(approved, f"human answered: {answer or 'no'}")
