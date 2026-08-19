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

## Rules

- HALO identities are unsuffixed; every other machine suffixes its model
  identities (`-5070ti`) so LM Link federation can't cross-resolve them.
- A portable fix (launcher hardening, Mission Control) lands ONCE in the
  base files and every machine inherits it on next deploy — profiles carry
  only genuine per-machine deltas.
- On a port box, do NOT run Sync-FromLive against adapted files; update the
  machine profile instead.
