# Telemetry audit — Chinese-origin components (2026-08-17)

Scope: all DeepSeek-authored code installed on HALO (199 `@deepseek-ai` packages
across the npx install and both profile plugin dirs) and the Qwen model artifacts.
Method: static sweep of every URL/hostname in code AND config files, source read
of the telemetry subsystem, live socket inspection of running processes.

## Verdict: clean. Nothing phones home in the running configuration.

### Qwen models — zero code executes
GGUF files are pure weights (data). They are executed by LM Studio's engine
(Element Labs — not a Chinese company); no Qwen-authored code runs at all. The
embedded chat template is rendered locally by LM Studio's template engine. A
model file cannot open a socket. **No telemetry surface exists.**

### DeepSeek Harness — one telemetry pipeline, verified inert
- The harness ships `dsh-session-telemetry-otel` with a default export target of
  `https://harness-telemetry.deepseeksvc.com/v1/logs` (found in bundle config
  YAML, not JS — sweep both).
- **Default mode: `DISABLED`.** Source-verified behavior when disabled
  (`lib/index.js:109-112`): no OpenTelemetry SDK is constructed at all —
  `provider = undefined`, emit = no-op `DROP_RECORD`. There is no object in
  memory capable of sending. Modes: FULL / FEEDBACK_ONLY / DISABLED.
- Enable switches `DSH_TELEMETRY_MODE` / `DSH_TELEMETRY_OTLP_URL`: **both unset**
  on this machine (checked live). Our launcher sets neither.
- `~\.dsh\.anonymous-user-id`: a local random UUID for telemetry identity;
  inert while telemetry is disabled.

### Complete external-host inventory of the installed code
| Host | Where | Status |
|---|---|---|
| `harness-telemetry.deepseeksvc.com` | telemetry exporter default (config) | disabled, no SDK constructed |
| `api.deepseek.com` | default endpoints of `llm-deepseek` (no key configured, unused route) and `web-search-deepseek` (**row disabled by us**) | never contacted |
| `www.deepseek.com` / `docs.deepseek.com` | UI demo fixtures + doc links | inert strings |
| `w3.org`, `json-schema.org`, `github.com`, `paulmillr.com`, etc. | XML namespaces, schema ids, doc links, package metadata | inert |
**No third-party analytics of any kind** (no Sentry, PostHog, Segment, GA, crash reporters).

### Live socket proof
Established connections of the three running harness node processes at audit
time: exactly one — `127.0.0.1:1234` (LM Studio). Zero external sockets.

### What DOES touch the internet (all user-initiated, none Chinese)
npm registry (installs), Exa MCP (search/fetch, our wiring), GitHub/HuggingFace
APIs (delta scans), Codex/Claude/OpenCode subagents (existing auth).

## Residual risk & standing mitigations
1. **Upgrades can change defaults.** The pin (`0.1.0-rc.7`) prevents silent
   upgrades; the `/delta-scan-halo` skill now explicitly checks new releases for
   telemetry-default changes before any re-pin.
2. Optional belt-and-suspenders (not applied): a hosts-file block of
   `harness-telemetry.deepseeksvc.com`, making transmission impossible even
   under a future misconfiguration.
