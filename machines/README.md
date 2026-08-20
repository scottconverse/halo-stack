# Per-machine profiles — one master serves every box

The 5070Ti port required hand-editing seven files because machine-specific
values (model identity, GGUF path/quant, context, KV cache, MTP, hardware
facts) were baked into shared config. These profiles fix that (issue #6).

## Design: base + overlay, not templates

`master`'s config files are **HALO-canonical literals** — HALO is the base
profile, and on HALO the deploy uses repo files byte-for-byte, exactly as
before. A non-HALO machine gets a `machines/<name>.yml` profile whose
`replacements` list is applied to a rendered copy of the repo files at
deploy time, before validation. Nothing on HALO is templated, so
`Sync-FromLive` on HALO stays a clean two-way street.

Why not templates everywhere? Because `Sync-FromLive` (live → repo) cannot
un-render a template: the sync/deploy pair would become asymmetric on every
machine including HALO. With base+overlay, the asymmetry is confined to
port boxes — where live edits belong in the machine's profile, not in
synced files. This mirrors the stack's own config doctrine (base → patch
overlay, dsh's cordis.patch.yml layering).

## How a machine is selected

`Deploy-ToLive.ps1` resolves the machine as: `$env:MACHINE` env var →
`~\.dsh\machine` marker file → default `halo`. Every deploy writes the
marker back, so after the first `MACHINE=<name>` deploy the box remembers
what it is.

## Validating another machine's profile without owning that machine

`DEPLOY_DRYRUN=1` runs machine resolution, the profile render, and the scope
gate, prints every file that would be written and whether it changes, then
stops before touching anything live:

```powershell
$env:DEPLOY_DRYRUN='1'; $env:MACHINE='5070ti'; .\scripts\Deploy-ToLive.ps1
```

It leaves the rendered deploy copy in `%TEMP%` so you can read the exact bytes
a port box would receive. Use it from HALO before handing a profile to a box.
Without it the only way to test `MACHINE=5070ti` was to deploy 5070Ti config
onto the live machine — which is why the 5070Ti profile shipped unvalidated,
and why issue #35 was found by a contaminated Codex session instead of by a
test.

## Profile format

```yaml
machine: 5070ti                # must match the filename
description: ...
facts:                         # documentation block, rendered nowhere
  identity: qwen/qwen3.8-27b-5070ti
  ...
replacements:                  # applied to rendered copies at deploy time
  - file: dsh\settings.yaml
    find: "qwen/qwen3.8-27b"
    replace: "qwen/qwen3.8-27b-5070ti"
```

Replacements are literal string substitutions (no regex), applied in order,
to the listed file only. Every `find` MUST currently exist in the repo file —
the deploy fails loudly if a replacement matches nothing, so profiles can't
rot silently when master moves.

## Whole-file swaps (`files:`)

Line-replacements are the wrong tool for a **prose** file. `workspace\AGENTS.md`
has no stable `find` string, and a missed substitution does not just ship a
wrong value — it ships another machine's *instructions*. Issue #35 is exactly
that: the conversion deploy put HALO's AGENTS.md into the 5070Ti box's
`Desktop\Code`, where a live Codex session read it as its own operating
instructions and believed it was running on Strix Halo.

```yaml
files:
  - file: workspace\AGENTS.md                      # the deployed file to replace
    from: machines\files\5070ti\AGENTS.md          # this machine's authored copy
    baseSha256: AC2196...A485                      # the master file it was derived from
```

`baseSha256` is the rot guard, and it does the same job for swaps that
find-must-exist does for replacements. A whole-file swap means the port box
stops inheriting base improvements to that file — so the hash pins the master
version the copy was written against, and **the deploy fails if master's file
has moved**. Refresh the machine copy, re-hash, then deploy:

```powershell
(Get-FileHash -Algorithm SHA256 .\workspace\AGENTS.md).Hash
```

A file may be listed in `files:` or `replacements:`, never both; the deploy
rejects a profile that does both to one file.

## The AGENTS.md scope rule (every machine, no exceptions)

`workspace\AGENTS.md` deploys to `~\Desktop\Code\AGENTS.md` — a **shared**
directory where other agents work. Any AGENTS.md there is read as operating
instructions by whatever agent opens it, so it must open with a scope header
naming who it is for and telling everyone else to ignore it:

```markdown
SCOPE: these instructions are for HALO-stack (DeepSeek Harness) sessions only.
If you are a different agent working in this directory (e.g. CivicCast work,
a Codex fleet session, a Claude Code session), ignore this file.
```

This is enforced, not documented: `Deploy-ToLive.ps1` has a **scope gate** that
inspects the rendered bytes of every deployed `AGENTS.md` and aborts the deploy
if the first ten lines carry no `SCOPE:` line. It runs on HALO too, where the
header is merely harmless — because the machine that needs it most is the one
nobody remembered to think about.

## Rules

- HALO identities are unsuffixed; every other machine suffixes its model
  identities (`-5070ti`) so LM Link federation can't cross-resolve them.
- A portable fix (launcher hardening, Mission Control) lands ONCE in the
  base files and every machine inherits it on next deploy — profiles carry
  only genuine per-machine deltas.
- On a port box, do NOT run Sync-FromLive against adapted files; update the
  machine profile instead.
