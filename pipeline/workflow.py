#!/usr/bin/env python3
"""budgeted-emit-pipeline — Produce arbitrarily large generated artifacts (plugins, modules, documents) on the HALO stack without ever hitting the output-token wall: every emit is sized to measured context room before it is requested, retries always land in fresh context, and the run never stalls waiting for a human 'continue'

Trigger: A generative task brief (task-brief.md) lands in the run directory
Isolation: worktree (declared in the spec; this package does not create it)

Generated from spec.json. Regenerating overwrites this file, so put durable edits in
prompts/ and steps/ (never overwritten) or stop regenerating once you take ownership.

Run:
    python3 workflow.py                 # full run, agents via the agent CLI
    python3 workflow.py --delegate      # full run, agents done by you
    python3 workflow.py --only build    # one node, against the last run's payloads
    python3 workflow.py --from verify   # resume partway

Exit codes:
    0   reached a terminal node
    1   a node failed with nowhere to route, or exhausted its retries
    2   operator error, such as an unknown node passed to --only
    75  parked: a human node was reached with nobody watching
    76  parked: a delegated agent node is waiting for its answer
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from runner import (EVENT_LOG, Result, ask_human, delegating, log_event,
                    run_agent, run_step)

HERE = Path(__file__).parent
ENTRY = 'measure_room'

# Ceiling on agent calls for the whole run, or None for no ceiling. Per-node
# max_attempts cannot see across nodes, so two nodes on a loop edge can each
# honour their own bound and still ping-pong indefinitely. This counts the run.
BUDGET_AGENT_CALLS = 24

# --- generated from spec.json ------------------------------------------------
NODES = {   'measure_room': {   'id': 'measure_room',
                        'label': 'Measure context room via harness API',
                        'kind': 'code',
                        'detail': 'GET the dsh apiproxy sessions tail for the target '
                                  'session; read projections.contextPressure '
                                  '{contextWindow, projectedTokens}; room = '
                                  'contextWindow - projectedTokens; write room.json. '
                                  'This projection exists today (dsh-token-meter -> '
                                  'dsh-host-apiproxy sessions endpoint) - Mission '
                                  'Control already speaks this API.',
                        'writes': ['room.json'],
                        'evidence': 'room.json',
                        'max_attempts': 2,
                        'on_exhausted': 'fail'},
    'fresh_session_start': {   'id': 'fresh_session_start',
                               'label': 'No usable session: start fresh headless',
                               'kind': 'code',
                               'detail': 'Start a new dsh --profile headless session '
                                         '(cold context = maximum room: ~120K usable '
                                         'of the 131,072 window after the ~10K boot '
                                         'prefix); write room.json from its measured '
                                         'pressure.',
                               'writes': ['room.json'],
                               'max_attempts': 2,
                               'on_exhausted': 'fail'},
    'plan_chunks': {   'id': 'plan_chunks',
                       'label': 'Split the artifact into room-sized chunks',
                       'kind': 'agent',
                       'backend': 'openai-compat',
                       'endpoint': 'http://127.0.0.1:1234',
                       'model': 'qwen/qwen3.8-27b',
                       'detail': 'Read task-brief.md and room.json. Produce '
                                 'emit-plan.json: an ordered list of chunks, each '
                                 'targeting one file region, with est_tokens <= cap '
                                 'where cap = min(0.5 * room, 12000). The 0.5 factor '
                                 'reserves output budget for thinking tokens, which '
                                 'spend from the same per-reply budget (measured on '
                                 "this stack). Chunks are written with the harness's "
                                 'incremental file tools (create / insert / '
                                 'str_replace), never as one giant tool-call argument.',
                       'reads': ['task-brief.md', 'room.json', 'rework.json'],
                       'writes': ['emit-plan.json'],
                       'max_attempts': 6,
                       'on_exhausted': 'human'},
    'plan_check': {   'id': 'plan_check',
                      'label': 'Validate plan deterministically',
                      'kind': 'code',
                      'detail': 'Schema-check emit-plan.json; assert every chunk '
                                'est_tokens <= cap, file regions disjoint, order '
                                'dependency-safe. Exit non-zero with reasons in '
                                'plan-check.txt.',
                      'reads': ['emit-plan.json', 'room.json'],
                      'writes': ['plan-check.txt'],
                      'evidence': 'plan-check.txt',
                      'max_attempts': 1,
                      'on_exhausted': 'fail'},
    'emit_chunk': {   'id': 'emit_chunk',
                      'label': 'Emit ONE chunk via incremental file tools',
                      'kind': 'agent',
                      'backend': 'openai-compat',
                      'endpoint': 'http://127.0.0.1:1234',
                      'model': 'qwen/qwen3.8-27b',
                      'detail': 'Generate the current chunk only, writing with '
                                'create/insert/str_replace so no single tool-call '
                                'argument exceeds the chunk cap. On rework, the '
                                'incoming report says exactly what failed - fix that, '
                                'do not regenerate the artifact. max_attempts is high '
                                'ON PURPOSE: the driver counts every fail-edge '
                                "re-entry, and route_next's next-chunk routing arrives "
                                'on a fail edge, so this ceiling bounds chunks+rework, '
                                'not genuine retries - those are bounded by '
                                'refresh_context (3), and the run-level agent_calls '
                                'budget is the global stop.',
                      'reads': ['emit-plan.json', 'emit-state.json', 'worktree'],
                      'writes': ['worktree', 'emit-state.json'],
                      'max_attempts': 30,
                      'on_exhausted': 'human'},
    'emit_check': {   'id': 'emit_check',
                      'label': 'Truncation + syntax gate',
                      'kind': 'code',
                      'detail': 'Two checks, both deterministic: (1) read the '
                                "session's last turn/end reason from the apiproxy "
                                "event tail - reason kind 'max-tokens' is a HARD FAIL "
                                'even if the file looks plausible, because the harness '
                                'silently DROPS truncated tool-call blocks (dsh-llm '
                                'BlockAssembler: max-token truncation discards tool '
                                'calls); (2) node --check / linter on touched files. '
                                'Write emit-check.txt.',
                      'reads': ['worktree', 'emit-state.json'],
                      'writes': ['emit-check.txt'],
                      'evidence': 'emit-check.txt',
                      'max_attempts': 1,
                      'on_exhausted': 'fail'},
    'refresh_context': {   'id': 'refresh_context',
                           'label': 'Retry ALWAYS lands in fresh context',
                           'kind': 'code',
                           'detail': 'Park the current session, start a fresh headless '
                                     'session, re-measure room, shrink remaining chunk '
                                     'caps if room changed. Encodes the traced harness '
                                     "behavior: 'continue' after truncation is a "
                                     'brand-new generation against a fuller window, '
                                     'and a truncated tool call is unrecoverable - so '
                                     'never retry a failed emit in the same session.',
                           'writes': ['room.json'],
                           'max_attempts': 3,
                           'on_exhausted': 'human'},
    'route_next': {   'id': 'route_next',
                      'label': 'More chunks?',
                      'kind': 'code',
                      'detail': 'Router: exit 0 (pass) when emit-state.json shows '
                                'every chunk emitted and checked; exit 1 (fail) with '
                                'next-chunk.json otherwise. A code decision - no model '
                                'call to decide what a file already says.',
                      'reads': ['emit-state.json'],
                      'writes': ['next-chunk.json'],
                      'max_attempts': 1,
                      'on_exhausted': 'fail'},
    'integrate': {   'id': 'integrate',
                     'label': 'Assemble + full verification',
                     'kind': 'code',
                     'detail': "Run the project's full check suite over the assembled "
                               'artifact (syntax, tests, compose-validation where '
                               'config is involved); git commit on the run branch. '
                               'Write integrate-report.txt and review-input.md (the '
                               'assembled artifact/diff inlined for the stateless '
                               'reviewer).',
                     'reads': ['worktree'],
                     'writes': ['integrate-report.txt', 'review-input.md', 'worktree'],
                     'evidence': 'integrate-report.txt',
                     'max_attempts': 1,
                     'on_exhausted': 'fail'},
    'review': {   'id': 'review',
                  'label': 'Clean-room review of the diff',
                  'kind': 'agent',
                  'backend': 'openai-compat',
                  'endpoint': 'http://127.0.0.1:1234',
                  'model': 'qwen/qwen3.8-27b',
                  'detail': 'Adversarial review by the LOCAL brain in a fresh '
                            'clean-room call: the reviewer receives ONLY task-brief.md '
                            'plus review-input.md (the assembled artifact) - zero '
                            'generation history, so it did not write what it judges. '
                            'Targets: correctness, completeness vs the brief, and '
                            'seams between chunks (the failure mode chunked generation '
                            'adds). Findings to review.json; empty findings = clean. '
                            'Cost-direction rule: an autonomous local pipeline never '
                            'calls a paid frontier model for a role the local model '
                            'can fill.',
                  'reads': ['task-brief.md', 'review-input.md'],
                  'writes': ['review.json'],
                  'max_attempts': 8,
                  'on_exhausted': 'human'},
    'review_gate': {   'id': 'review_gate',
                       'label': 'Validate the review itself',
                       'kind': 'code',
                       'detail': 'Schema-check review.json: verdict field present, '
                                 'every finding references a real file/line in the '
                                 'worktree. Deterministic guard against malformed '
                                 'reviewer output.',
                       'reads': ['review.json', 'worktree'],
                       'writes': ['review-gate.txt'],
                       'evidence': 'review-gate.txt',
                       'max_attempts': 1,
                       'on_exhausted': 'fail'},
    'verdict_route': {   'id': 'verdict_route',
                         'label': 'Findings?',
                         'kind': 'code',
                         'detail': 'Router: exit 0 (pass) when review.json has zero '
                                   'findings; exit 1 (fail) otherwise, forwarding the '
                                   'findings to the PLANNER - rework is a replan (a '
                                   'fresh repair plan whose chunks recreate the '
                                   'affected files with fixes), never a blind re-emit '
                                   'against a spent chunk list.',
                         'reads': ['review.json'],
                         'writes': ['rework.json'],
                         'max_attempts': 1,
                         'on_exhausted': 'fail'},
    'open_pr': {   'id': 'open_pr',
                   'label': 'Push branch, open PR',
                   'kind': 'code',
                   'detail': 'git push, gh pr create with emit-plan.json + review.json '
                             'summarized in the body. Repo doctrine: branch + PR into '
                             'master, never direct.',
                   'reads': ['worktree', 'review.json'],
                   'writes': ['pr_url'],
                   'max_attempts': 2,
                   'on_exhausted': 'human'},
    'accept': {   'id': 'accept',
                  'label': 'Operator merges',
                  'kind': 'human',
                  'detail': 'Scott decides whether the artifact is wanted. Merge and '
                            'any tag are the irreversible, outward-facing steps - the '
                            'only interior human gate this pipeline has.',
                  'reads': ['pr_url']}}

EDGES = [   {   'from': 'measure_room',
        'to': 'plan_chunks',
        'when': 'pass',
        'payload': 'room.json'},
    {   'from': 'measure_room',
        'to': 'fresh_session_start',
        'when': 'fail',
        'payload': 'measure-error.txt'},
    {   'from': 'fresh_session_start',
        'to': 'plan_chunks',
        'when': 'always',
        'payload': 'room.json'},
    {   'from': 'plan_chunks',
        'to': 'plan_check',
        'when': 'always',
        'payload': 'emit-plan.json'},
    {   'from': 'plan_check',
        'to': 'emit_chunk',
        'when': 'pass',
        'payload': 'emit-plan.json'},
    {   'from': 'plan_check',
        'to': 'plan_chunks',
        'when': 'fail',
        'payload': 'plan-check.txt',
        'loop': True},
    {'from': 'emit_chunk', 'to': 'emit_check', 'when': 'always', 'payload': 'worktree'},
    {   'from': 'emit_check',
        'to': 'route_next',
        'when': 'pass',
        'payload': 'emit-state.json'},
    {   'from': 'emit_check',
        'to': 'refresh_context',
        'when': 'fail',
        'payload': 'emit-check.txt'},
    {   'from': 'refresh_context',
        'to': 'emit_chunk',
        'when': 'always',
        'payload': 'room.json',
        'loop': True},
    {'from': 'route_next', 'to': 'integrate', 'when': 'pass', 'payload': 'worktree'},
    {   'from': 'route_next',
        'to': 'emit_chunk',
        'when': 'fail',
        'payload': 'next-chunk.json',
        'loop': True},
    {'from': 'integrate', 'to': 'review', 'when': 'pass', 'payload': 'review-input.md'},
    {   'from': 'integrate',
        'to': 'emit_chunk',
        'when': 'fail',
        'payload': 'integrate-report.txt',
        'loop': True},
    {'from': 'review', 'to': 'review_gate', 'when': 'pass', 'payload': 'review.json'},
    {   'from': 'review',
        'to': 'review',
        'when': 'fail',
        'payload': 'review-shortfall.txt',
        'loop': True},
    {   'from': 'review_gate',
        'to': 'verdict_route',
        'when': 'pass',
        'payload': 'review.json'},
    {   'from': 'review_gate',
        'to': 'review',
        'when': 'fail',
        'payload': 'review-gate.txt',
        'loop': True},
    {   'from': 'verdict_route',
        'to': 'open_pr',
        'when': 'pass',
        'payload': 'review.json'},
    {   'from': 'verdict_route',
        'to': 'plan_chunks',
        'when': 'fail',
        'payload': 'rework.json',
        'loop': True},
    {'from': 'open_pr', 'to': 'accept', 'when': 'always', 'payload': 'pr_url'}]
# -----------------------------------------------------------------------------


class Context:
    """Payloads on disk, sessions in memory.

    Payloads are real files rather than variables so that a single node can be rerun
    against a fixed input, and so a failed run leaves behind something readable.
    """

    def __init__(self, run_dir: Path, workdir: Path):
        self.run_dir = run_dir
        self.workdir = workdir
        self.sessions: dict[str, str] = {}
        self.feedback: str | None = None
        run_dir.mkdir(parents=True, exist_ok=True)

    def _path(self, name: str) -> Path:
        """A payload path, guaranteed to be inside the run directory.

        Payload and evidence names come from the spec, and `run_dir / name`
        follows `..` wherever it leads: a payload called
        `../../../etc/thing` wrote a node's output there. The validator
        refuses such a name now, but the check is repeated here on purpose.
        The validator runs when a package is *generated* and this runs when
        one is *run*, and the two are separated by a copied directory, a
        hand-edited spec, and however long the package sits on disk.
        """
        path = (self.run_dir / name).resolve()
        root = self.run_dir.resolve()
        if path != root and root not in path.parents:
            raise SystemExit(
                f"refusing to touch {name!r}: it resolves outside the run "
                f"directory ({path}). Payload and evidence names are file "
                "names, not paths."
            )
        return path

    def read(self, name: str) -> str:
        path = self._path(name)
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def write(self, name: str, text: str) -> None:
        path = self._path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def prompt_for(self, node_id: str) -> str:
        """Fill a prompt template with the payloads this node declares it reads."""
        template = (HERE / "prompts" / f"{node_id}.md").read_text(encoding="utf-8")
        # Authoring notes are for whoever maintains the prompt, not for the model.
        template = re.sub(r"<!--.*?-->", "", template, flags=re.DOTALL)
        for name in NODES[node_id].get("reads", []):
            template = template.replace("{{" + name + "}}", self.read(name))
        template = template.replace("{{feedback}}", self.feedback or "")
        return template.strip()


def check_evidence(node, ctx: Context):
    """Return what is missing, or None when the node left proof it worked.

    The bar is that the named artifact exists and is not empty. That catches
    the silent no-op — the node that reported success and produced nothing —
    which is the common failure. It does not catch a node that writes a token
    file to satisfy the check, and it is not meant to: the point is to stop a
    claim from travelling downstream unaccompanied, not to grade the artifact.
    """
    name = node.get("evidence")
    if not name:
        return None
    path = ctx.run_dir / name
    if not path.exists():
        return f"declared evidence '{name}' but produced no such file ({path})"
    if not path.read_text(encoding="utf-8", errors="replace").strip():
        return f"declared evidence '{name}' but the file is empty"
    return None


def log(message: str) -> None:
    stamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


def next_node(node_id: str, conditions: tuple[str, ...]):
    for edge in EDGES:
        if edge["from"] == node_id and edge.get("when") in conditions:
            return edge
    return None


def run_node(node_id: str, ctx: Context) -> Result:
    node = NODES[node_id]
    kind = node["kind"]

    if kind == "code":
        return run_step(HERE / "steps" / f"{node_id}.sh", cwd=ctx.workdir)

    if kind == "agent":
        result = run_agent(
            ctx.prompt_for(node_id),
            session_id=ctx.sessions.get(node_id),
            model=node.get("model"),
            tools=node.get("tools"),
            cwd=ctx.workdir,
            node_id=node_id,
            run_dir=ctx.run_dir,
            backend=node.get("backend"),
            endpoint=node.get("endpoint"),
        )
        if result.session_id:
            ctx.sessions[node_id] = result.session_id
        return result

    if kind == "human":
        return ask_human(node["label"], node.get("detail", ""), ctx.run_dir,
                         node_id=node_id)

    return Result(False, f"unknown node kind: {kind}")


ESCALATION_MODEL = "opus"

# A bound only means something for nodes a failure edge loops back into — those are
# the ones that can be re-entered indefinitely. A checker that fails is doing its job,
# not consuming a retry of its own. Human nodes are excluded for the same reason the
# validator does not demand a bound on them: reaching one costs a person's attention
# and stops the run until they act, so it cannot run away unattended.
RETRY_TARGETS = {e["to"] for e in EDGES
                 if e.get("when") == "fail" and NODES[e["to"]].get("kind") != "human"}


def give_up(node_id: str, ctx: Context, limit: int) -> int:
    node = NODES[node_id]
    action = node.get("on_exhausted", "fail")
    log(f"  {node_id}: giving up after {limit} attempt(s) -> {action}")
    if action == "human":
        outcome = ask_human(
            f"{node_id} could not be completed automatically",
            node.get("detail", ""),
            ctx.run_dir,
            node_id=node_id,
        )
        return 0 if outcome.ok else 1
    return 1


STATE_FILE = "driver-state.json"
FINAL_STATE_FILE = "driver-state.final.json"


def save_state(ctx: Context, current: str, attempts: dict[str, int],
               spend: int = 0) -> None:
    """Record where the driver is, so a pause can be resumed exactly.

    Only delegate mode pauses mid-run, but the state is cheap and writing it
    unconditionally means a crashed subprocess run also leaves a readable record
    of which node it died on and how many attempts it had spent.
    """
    (ctx.run_dir / STATE_FILE).write_text(
        json.dumps(
            {"current": current, "attempts": dict(attempts),
             "feedback": ctx.feedback, "agent_calls_spent": spend},
            indent=2,
        ),
        encoding="utf-8",
    )


def load_state(ctx: Context):
    """Return (current, attempts, feedback, spend) from a paused run, or None."""
    path = ctx.run_dir / STATE_FILE
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    if not data.get("current"):
        return None
    return (data["current"], defaultdict(int, data.get("attempts", {})),
            data.get("feedback"), data.get("agent_calls_spent", 0))


def clear_state(ctx: Context) -> None:
    """Retire the state file so a finished run cannot resume itself.

    Renamed rather than deleted. Stopping the resume needs the live name gone,
    which a rename achieves — and deleting it would throw away the one record
    of what the run cost: how many attempts each node took and how much budget
    it spent. That is exactly the receipt worth keeping for a run that
    succeeded, which is the case a delete was silently discarding.
    """
    live = ctx.run_dir / STATE_FILE
    if not live.exists():
        return
    final = ctx.run_dir / FINAL_STATE_FILE
    final.unlink(missing_ok=True)
    live.rename(final)


def budget_handoff(node_id: str, ctx: Context, spend: int) -> int:
    """Stop between nodes and hand the situation to a person.

    Deliberately not a failure. The run did nothing wrong; it reached a ceiling
    someone set on purpose, and the only way past is a person deciding the work
    is worth more than the ceiling says.
    """
    outcome = ask_human(
        f"Run budget spent before {node_id}",
        f"This run has used its whole budget of {BUDGET_AGENT_CALLS} agent "
        f"call(s) and stopped before launching another. To continue, raise "
        f"budget.agent_calls in spec.json, regenerate, and start a fresh run.",
        ctx.run_dir,
        node_id=node_id,
    )
    return 0 if outcome.ok else 1


def drive(ctx: Context, start: str) -> int:
    attempts: dict[str, int] = defaultdict(int)
    current = start
    spend = 0
    # A delegated run resumes where it parked. The attempt that parked was
    # already counted, so the first pass through the loop must not count it
    # again — otherwise every pause would burn a retry and a three-attempt
    # ceiling would be reached in two.
    resuming = False
    if delegating():
        saved = load_state(ctx)
        if saved:
            current, attempts, ctx.feedback, spend = saved
            resuming = True
            log(f"resuming at {current} (attempt {attempts[current]})")

    log_event(ctx.run_dir, "run_resumed" if resuming else "run_start",
              node=current, delegate=delegating(), budget=BUDGET_AGENT_CALLS,
              spent=spend)

    while current:
        node = NODES[current]
        if resuming:
            resuming = False
        else:
            attempts[current] += 1
        # Persisted before the ceiling check, not after. The attempt that
        # exhausts a node has to be written down, or an on_exhausted of
        # "human" parks the run before the count is ever saved — and every
        # resume then reloads the pre-exhaustion count and runs the node
        # again. A ceiling that resets on every pause is not a ceiling.
        save_state(ctx, current, attempts, spend)

        limit = node.get("max_attempts", 1)
        bounded = current in RETRY_TARGETS

        if bounded and attempts[current] > limit:
            # Escalation is a bet that the task was merely hard, not impossible. It
            # only pays off when a trustworthy check told us the cheap attempt failed.
            if node.get("on_exhausted") == "escalate-model" and not node.get("_escalated"):
                node["_escalated"] = True
                node["model"] = ESCALATION_MODEL
                node["max_attempts"] = limit + 1
                limit = node["max_attempts"]
                log(f"  {current}: escalating to {ESCALATION_MODEL} for a final attempt")
            else:
                code = give_up(current, ctx, limit)
                log_event(ctx.run_dir, "run_end", node=current, code=code,
                          reason=f"exhausted {limit} attempt(s)")
                clear_state(ctx)
                return code

        # Checked before the call so an exhausted budget never launches one.
        if (node["kind"] == "agent" and BUDGET_AGENT_CALLS is not None
                and spend >= BUDGET_AGENT_CALLS):
            log(f"  {current}: run budget of {BUDGET_AGENT_CALLS} agent "
                f"call(s) is spent - stopping before this one")
            log_event(ctx.run_dir, "budget_exhausted", node=current,
                      spent=spend, budget=BUDGET_AGENT_CALLS)
            return budget_handoff(current, ctx, spend)

        suffix = f" (attempt {attempts[current]}/{limit})" if bounded else ""
        log(f"{current} [{node['kind']}] {node['label']}{suffix}")
        log_event(ctx.run_dir, "node_start", node=current, kind=node["kind"],
                  attempt=attempts[current], limit=limit if bounded else None,
                  model=node.get("model"),
                  # Recorded even when it is the default, so --report can group by
                  # it without having to guess what an absent field meant in a log
                  # written before the node's backend was changed.
                  backend=node.get("backend", "claude") if node["kind"] == "agent"
                  else None)

        result = run_node(current, ctx)
        # Charged on return, whatever the outcome: a call that launched and then
        # errored or timed out has already cost money, so only crediting
        # successes would let a crash-looping node spend without moving the
        # counter. Two things never return here and so are never charged — a
        # missing CLI (launched is False) and a delegated park, which exits the
        # process before any model runs.
        if node["kind"] == "agent" and result.launched:
            spend += 1
            log_event(ctx.run_dir, "budget_charged", node=current, spent=spend,
                      budget=BUDGET_AGENT_CALLS)
        ctx.write(f"{current}.out", result.output)
        # Recorded per attempt, which is the point: <node>.out holds only the
        # last one, so a loop that burned its ceiling would otherwise show a
        # single output for three different tries.
        log_event(ctx.run_dir, "node_result", node=current, ok=result.ok,
                  attempt=attempts[current], output=result.output)
        ctx.feedback = None

        # Only an otherwise-successful node is asked for proof. One that already
        # failed has a real reason, and replacing it with a missing-artifact
        # complaint would bury the useful one. Checked before any edge is
        # followed, so it gates `always` traversals as much as `pass` ones —
        # gating only `pass` would leave most real workflows unchecked.
        if result.ok:
            shortfall = check_evidence(node, ctx)
            if shortfall:
                log(f"  {current}: {shortfall}")
                log_event(ctx.run_dir, "evidence_missing", node=current,
                          artifact=node.get("evidence"), detail=shortfall)
                result = Result(False, f"{current} {shortfall}", result.session_id)

        if result.ok:
            edge = next_node(current, ("always", "pass"))
            if edge is None:
                log(f"done - {current} was terminal")
                log_event(ctx.run_dir, "run_end", node=current, code=0,
                          reason="terminal node reached")
                clear_state(ctx)
                return 0
            if edge.get("payload") and result.output:
                ctx.write(edge["payload"], result.output)
            log_event(ctx.run_dir, "route", **{"from": current, "to": edge["to"],
                      "when": edge.get("when"), "payload": edge.get("payload")})
            current = edge["to"]
            continue

        log(f"  failed: {result.output[:300]}")

        edge = next_node(current, ("fail",))
        if edge is None:
            # Nothing to route to, so this failure ends the run.
            code = give_up(current, ctx, limit)
            log_event(ctx.run_dir, "run_end", node=current, code=code,
                      reason="failure with no fail edge")
            clear_state(ctx)
            return code

        if edge.get("payload"):
            ctx.write(edge["payload"], result.output)
        # A loop edge carries the failure back as feedback rather than as a fresh task.
        ctx.feedback = result.output if edge.get("loop") else None
        log_event(ctx.run_dir, "route", **{"from": current, "to": edge["to"],
                  "when": "fail", "payload": edge.get("payload"),
                  "loop": bool(edge.get("loop"))})
        current = edge["to"]

    log_event(ctx.run_dir, "run_end", code=0, reason="no next node")
    clear_state(ctx)
    return 0


def read_events(runs_root):
    """Every event from every run under runs_root, in path order.

    Path order, not time order: run directories are named by whoever passed
    --run-dir, and the default one is called `latest`, which sorts after any
    timestamped sibling. The only thing ordering decides is which backend label a
    node carries in the summary if it was moved between backends, so a real clock
    would buy nothing worth the assumption.

    Tolerant on purpose. A run that was killed mid-write leaves a partial last
    line, and a report that refuses to open because of it would be useless exactly
    when it is most wanted.
    """
    runs_root = Path(runs_root)
    if not runs_root.exists():
        return []
    events = []
    for log_path in sorted(runs_root.rglob(EVENT_LOG)):
        run_name = log_path.parent.name
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                # Valid JSON is not the same as a record. A line holding a list,
                # a bare string or a number parses fine and then fails on the
                # next line down, which turned "tolerant of a damaged log" into
                # a traceback -- and because this reads every run under the root,
                # one bad line in one old directory took the whole report with it.
                continue
            record["run"] = run_name
            events.append(record)
    return events


def summarise(events):
    """Per (node, backend) counts. Plain arithmetic over the log, no inference."""
    stats = {}
    backends = {}
    for event in events:
        node = event.get("node")
        # A string, specifically. These become dictionary keys, so a node or a
        # backend arriving as a list or an object is not merely odd data -- it
        # raises "unhashable type" and ends the report.
        if not isinstance(node, str) or not node:
            continue
        backend = event.get("backend")
        if event.get("event") == "node_start" and isinstance(backend, str) and backend:
            backends[node] = backend
        key = (node, backends.get(node) or "-")
        row = stats.setdefault(key, {"attempts": 0, "ok": 0, "failed": 0,
                                     "evidence_missing": 0, "runs": set()})
        row["runs"].add(event.get("run"))
        if event.get("event") == "node_result":
            row["attempts"] += 1
            if event.get("ok"):
                row["ok"] += 1
            else:
                row["failed"] += 1
        elif event.get("event") == "evidence_missing":
            row["evidence_missing"] += 1
    return stats


def report(runs_root) -> int:
    """Say what the logs already know, and change nothing.

    Deliberately diagnosis rather than routing. The numbers here are the ones that
    would drive an automatic model choice, but a run that silently re-routes itself
    is a different kind of program with a different set of surprises, so this
    prints and stops. Deciding what to do about a node that fails eight times in
    ten stays a person's job.
    """
    events = read_events(runs_root)
    if not events:
        print(f"no runs found under {runs_root}")
        print("run the workflow at least once, then try again.")
        return 0

    stats = summarise(events)
    runs = {e.get("run") for e in events}
    print(f"{len(runs)} run(s) under {runs_root}")
    print("")
    header = f"{'node':<18} {'backend':<14} {'runs':>5} {'attempts':>8} {'ok':>5} "              f"{'failed':>7} {'no evidence':>12}"
    print(header)
    print("-" * len(header))
    for (node, backend), row in sorted(stats.items()):
        if not row["attempts"]:
            continue
        # Runs alongside attempts because they answer different questions: eight
        # failures inside one run is a node that looped, eight across eight runs
        # is a node that does not work.
        print(f"{node:<18} {backend:<14} {len(row['runs']):>5} "
              f"{row['attempts']:>8} {row['ok']:>5} "
              f"{row['failed']:>7} {row['evidence_missing']:>12}")

    worst = [((node, backend), row) for (node, backend), row in stats.items()
             if row["attempts"] >= 3 and row["failed"] > row["ok"]]
    if worst:
        print("")
        for (node, backend), row in sorted(worst):
            print(f"note: {node} on {backend} failed {row['failed']} of "
                  f"{row['attempts']} attempts across {len(row['runs'])} run(s).")
        print("A node that fails more often than it succeeds is either mis-scoped,")
        print("under-modelled for the work, or checked by something stricter than")
        print("the prompt asks for. All three are worth reading the payloads over.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", default=str(HERE / "runs" / "latest"),
                    help="where payloads live")
    ap.add_argument("--report", action="store_true",
                    help="summarise past runs from their event logs and exit; "
                         "reads only, runs nothing")
    ap.add_argument("--runs", default=str(HERE / "runs"),
                    help="directory of run directories, for --report")
    ap.add_argument("--workdir", default=".", help="where code and agents execute")
    ap.add_argument("--only", help="run a single node against existing payloads")
    ap.add_argument("--from", dest="start", help="start partway through")
    ap.add_argument(
        "--delegate",
        action="store_true",
        help="do agent nodes yourself instead of spawning an agent CLI: the run "
             "parks at each one, writes the prompt, and resumes when you leave "
             "the answer beside it (same as WORKFLOW_DELEGATE=1)",
    )
    args = ap.parse_args()

    if args.report:
        # Before anything touches a run directory: --report must never be able to
        # start, resume, or disturb a run.
        return report(args.runs)

    if args.delegate:
        # Set before anything reads it, so --delegate and the environment
        # variable are genuinely the same switch rather than two code paths.
        os.environ["WORKFLOW_DELEGATE"] = "1"

    ctx = Context(Path(args.run_dir), Path(args.workdir).resolve())

    if args.only:
        if args.only not in NODES:
            print(f"unknown node: {args.only}", file=sys.stderr)
            return 2
        result = run_node(args.only, ctx)
        ctx.write(f"{args.only}.out", result.output)
        print(result.output)
        return 0 if result.ok else 1

    if args.start:
        # An explicit starting point overrides a parked run rather than being
        # silently ignored in favour of the saved position.
        clear_state(ctx)

    return drive(ctx, args.start or ENTRY)


if __name__ == "__main__":
    raise SystemExit(main())
