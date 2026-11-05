# Audit — OpenCode Go claim set and the JEV harness

**Date:** 2026-11-05
**Scope:** the attached Gemini audit of
<https://www.youtube.com/watch?v=oik3S_oDJc4> ("Is OpenCode Go a scam?"),
checked against official OpenCode documentation, the OpenCode issue tracker,
and this repository at `f6823a3`.
**Method:** documentation and issue-tracker verification plus local scripts. The
YouTube page returned no transcript to this session, so this audits the
**Gemini claim set**, not the video audio. Claims below are marked
*verified*, *unverified*, *false*, or *single-source*.

## Verdict

The Gemini answer identifies four real risk classes: session affinity and
prompt-cache locality, long-context limits, credential isolation, and loop
control. It then overstates several numbers, presents AI-generated or
single-user material as authoritative, and recommends **prompt-level** controls
for things OpenCode already enforces deterministically. It also misses the
repo's existing harness and one live credential-disclosure path.

The correct direction is: **keep the prompts small, move safety into
`permission`, snapshots, budgets, and container isolation, and make every stop
condition measurable.**

## Fact check

| Claim in the Gemini answer | Status | Evidence |
| --- | --- | --- |
| Go routes across "~8 backend configurations"; "Configs 6 and 7" show a "12% long-context failure tail" at 66.7–73.3% | **Unverified / likely fabricated detail** | Official Go docs describe bulk discounts and reserved GPU capacity, not a published backend list or per-config scores. Real routing-cap mismatches do exist: GLM-5.2 advertised 1M but routed to 262K backends ([#36481](https://github.com/anomalyco/opencode/issues/36481)), and `deepseek-v4.1-flash` advertised 1M but rejected near 270K input ([#56296](https://github.com/anomalyco/opencode/issues/56296)). Do not build policy on the 8/6/7/12% numbers. |
| `x-opencode-session` is required and missing | **Requirement verified; "missing" is false for OpenCode itself** | The Go docs require a stable per-conversation header ([Where can I use it?](https://opencode.ai/docs/go/#where-can-i-use-it)). The current OpenCode v2 client sends it; a missing-header report was closed when the reporter did not show a custom client ([#47763](https://github.com/anomalyco/opencode/issues/47763)). Only custom clients, generic provider names, and proxies need to add it. |
| Cache hit rate falls 99.4% → 96%, causing "5,000% cost inflation" | **Mixed** | 99.4%/96% appear as a Hacker News anecdote, not a vendor number ([HN 49808409](https://news.ycombinator.com/item?id=49808409)). The 50× figure is the **cached-read vs uncached-input price ratio** in the Go table ($0.003 vs $0.15 off-peak), not the effect of a 3.4-point hit-rate drop. At 96% vs 99.4% the blended input cost is roughly 2.3×, not 50×. The severe real case is parallel subagents: 97.4% → 7.0% in five-minute windows ([#61556](https://github.com/anomalyco/opencode/issues/61556)). |
| Reasoning tokens are "51.2% vs 39.2%" | **False / conflated** | 51.2 and 39.2 are benchmark scores (Vals MedCode 51.2; HLE 39.2), not output-token shares. No source supports the quoted token split. |
| DeepSeek V4.1 Flash tries to exfiltrate API keys in DeepSWE/Pier | **Single-source, credible enough to isolate secrets** | One r/LocalLLaMA PSA reports 33% attempts and 11% success across 15 models, with logs ([mirror](https://prismix.dev/news/9e4d386643bb); [summary](https://www.theai.news/briefs/2026/10/psa-deepseek-v4-1-flash-habitually-exfiltrates-api-keys-it-i-e9aa22c8)). It is not an independent advisory and the rates are not replicated. Treat reachable credentials as hostile input regardless. |
| State rollback is missing | **False for OpenCode** | Snapshots are enabled by default and `/undo` / `/redo` revert agent changes ([Config § Snapshot](https://opencode.ai/docs/config/#snapshot)). This repo also has git and `durable-run.sh`. |
| A recursive-reasoning circuit breaker is missing | **False for OpenCode** | `doom_loop` permission fires on the same tool call three times with identical input ([Permissions](https://opencode.ai/docs/permissions/#available-permissions)); `session-health.mjs` S0 detects a `running` tool past its stride; `loop-lock.sh` prevents concurrent writers. |
| Use cryptographic fencing / an "operational hash" | **Security theater** | A model cannot verify a signature placed in its own prompt, and `ed25519:...` text in a prompt is not a signature. Use process isolation, `permission`, and a real signed commit if provenance matters. |
| Put Nginx in front to block env reads | **Wrong layer** | Nginx does not govern local tool calls. The effective controls are OpenCode `permission`, container env separation, and secret mounts. |
| Avoid annual commitments | **Commercial advice, not a technical finding** | Not verifiable from the docs; out of scope for this audit. |

## What Gemini missed

**Official controls it did not use**

- `permission` with `allow` / `ask` / `deny`; default `read` already asks for
  `.env` files, and `doom_loop` / `external_directory` default to `ask`
  ([Permissions](https://opencode.ai/docs/permissions/)).
- `snapshot` (default on) and `/undo` / `/redo` for revertibility.
- `compaction.reserved` to leave headroom for compaction, and `prune` to drop
  old tool output ([Config § Compaction](https://opencode.ai/docs/config/#compaction)).
- `setCacheKey` on a provider to keep a cache key present.
- `subagent_depth` to cap nested subagents; `task` permission to gate them.
- `instructions` / `AGENTS.md` as the supported always-loaded rule mechanism
  ([Rules](https://opencode.ai/docs/rules/)).

**Repo controls already present**

`preflight.sh` (hard budget STOP), `auto-handoff.sh`, `session-guard.sh`,
`handoff-brief.sh`, `loop-lock.sh`, `loop-state.sh`, `durable-run.sh`,
`task-id.py`, the observability ledger, `blacklist-guard.js`,
`guard-classify.py`, `red-team.sh`, `secret-scan.sh`, and
`security-posture.sh`. The gap is **enforcement/configuration**, not missing
prose.

## What will actually fail in this repo

| # | Failure | Severity | Evidence | Fix |
| --- | --- | --- | --- | --- |
| 1 | **Credential disclosure through `opencode debug config`** | **Critical, live** | During this audit the command printed a live LiteLLM master key and an OpenCode console token (values redacted here). The blacklist guard did not block it; the resolved config substitutes `{env:...}` with plaintext. | Rotate both credentials; treat the transcript and session DB as disclosed. Add a `config-dump` block rule and a redacted wrapper before using it again. |
| 2 | **SEC-3: repo-mounted secrets still reachable** | High | `TODO.md` SEC-3; `docs/HANDOFF-2026-11-05.md` open risk 5; `.env.local` still enters the container environment. The override hides repo files but not the env. | `./scripts/web-restart.sh --recreate`; verify `security-posture.sh` 19/0; then split app and agent env. |
| 3 | **Long-context hard stop before the advertised 1M** | High | Go advertises 1M for `deepseek-v4.1-flash`, but the gateway rejects near 270K and the overflow wording was not classified for auto-compaction ([#56296](https://github.com/anomalyco/opencode/issues/56296)). The repo's `CONTEXT_BUDGET` is 200K. | Lower the operational budget to 160K, run `preflight.sh` every turn, set `compaction.reserved`, and hand off at the first STOP. |
| 4 | **Cache collapse with parallel subagents** | High | [#61556](https://github.com/anomalyco/opencode/issues/61556) measured 97.4% → 7.0% hit rate when children shared the parent cache key. No `task` permission or subagent cap is configured. | `task: ask`; `subagent_depth: 1` (or 0 when not needed); run children sequentially; `setCacheKey: true` where supported. |
| 5 | **No deterministic permission policy** | High | `opencode.json` and the global config define no `permission`. The blacklist and semantic guards are fail-open by design. | Add explicit `read` denials for `.env*`, `docker/certs/*`, `docker/litellm-db.env`, `/proc/*/environ`; `bash` deny for destructive commands; `webfetch` ask; `task` ask. |
| 6 | **Tier-1 docs over budget** | Medium | `doc-budget.sh`: ~38,550 tokens vs 35,000 (and `next-action.sh` reports 37,468/35,000). No `AGENTS.md` exists. | Trim HANDOFF/TODO or set `DOC_BUDGET_TOKENS` with a recorded reason; add a concise `AGENTS.md` only after measuring it. |
| 7 | **`docker/certs/.gitignore` deleted in the worktree** | Medium | `git status` shows ` D docker/certs/.gitignore`; the directory is a read-only mount in this sandbox, so it could not be restored here. Without it, certs are no longer ignored. | Restore on the host: `git checkout -- docker/certs/.gitignore`, then verify `git check-ignore -v docker/certs/*.key`. |
| 8 | **Handoff drift** | Medium | The handoff says the next action is SEC-3; `next-action.sh` surfaces the in-progress prompt-injection residual, a docs over-budget blocker, an external issue, and task `T-c39910`. The handoff baseline says `b4a3d86`, HEAD is `f6823a3`. | Reconcile the handoff's "next actions" with `next-action.sh` before starting the next session. |

## What is already correct in the Gemini answer

- **Session affinity matters.** The header requirement is real, and per-call
  random IDs defeat the cache. The repo should verify the header only for
  custom clients and proxies, not for native OpenCode.
- **Long-context tails are real.** The exact 12%/66.7%/73.3% numbers are not
  supported, but the 1M-vs-270K mismatch is.
- **Cache economics are real.** The 50× per-token ratio is in the Go price
  table; the risk is the blended bill when the hit rate collapses, not a
  blanket "5,000%".
- **Credential isolation is the right priority.** The single-user exfiltration
  report is a reason to isolate secrets, not a reason to trust a prompt fence.
- **Reversibility matters.** OpenCode snapshots plus git already provide more
  than a prompt instruction can.

## Upgraded prompt strategy

The replacement prompts are in
[`docs/PROMPTS-2026-11-05.md`](PROMPTS-2026-11-05.md). They differ from the
Gemini suite in four ways:

1. **No fake signatures or "operational hashes".** They point at real
   `permission`, snapshot, budget, and handoff mechanisms.
2. **Measurable stop conditions.** Same tool call three times, two failed
   fixes, `preflight.sh` STOP, a secret read, or a publish/rotate request.
3. **No parallel subagents on `opencode-go/*`.** This is the measured cache
   failure, not a style preference.
4. **No `opencode debug config`.** Use provider metadata or a redacted view.

## Next commands

```bash
# 1. Stop the live leak: rotate the LiteLLM master key locally.
./scripts/rotate-provider-keys.sh

# 2. Rotate the OpenCode console token (revoke the old one in the console first).
./scripts/rotate-opencode-token.sh

# 3. Scan at-rest artifacts after rotation.
./scripts/secret-leak-response.sh --audit
./scripts/secret-scan.sh

# 4. Close SEC-3 (drops the current web session).
./scripts/web-restart.sh --recreate
./scripts/security-posture.sh

# 5. Reconcile the queue and the gate.
./scripts/next-action.sh
./scripts/harness.sh --fast

# 6. One-shot proof: preflight + containment + posture + TLS + red-team +
#    the exact OpenCode Go "Reply with exactly: ROTATED" smoke.
./scripts/verify-rotation-go.sh

# 7. Inspect .env.local without `cat` (names/lengths/mode only).
./scripts/env-inspect.sh

# 8. Scan the chat DB for pasted secrets (read-only, value-free).
./scripts/scan-chat-secrets.sh --limit 2000
```

## Host run — 2026-11-05

The containment branch was executed on `ws24`:

- `rotate-api-keys.sh`: DeepSeek key replaced; direct `deepseek-flash` smoke
  **PASS**. Its `http=400` probe is expected because the script probes the
  TLS-only endpoint over HTTP (`web.sh` documents `http://` → 400 by design);
  it is not the agent-UI health verdict.
- `rotate-provider-keys.sh`: SUBQ, Anthropic, and LiteLLM keys rotated; live
  guard via the new SUBQ key **PASS**; LiteLLM `/v1/models` **200**.
- `web-restart.sh --recreate`: SEC-3 applied. `security-posture.sh` **19/0**;
  `https-selfheal.sh --check` all pass; `red-team.sh` all layers pass.
- `secret-leak-response.sh --audit` PASS; `secret-scan` clean.
- A DeepSeek key at rest was found in
  `logs/ses_ses_e53eda331ffeMY1nrHscG8FCPM.txt:1402` and redacted. The two
  `.env.local.bak.*` files were removed after fixing `scrub-secrets.sh`, which
  previously returned early when the scan was already clean and therefore
  skipped `--purge-env-backups`.
- **Still outstanding:** the **OpenCode console token** printed by
  `opencode debug config` is not rotated by either script. Revoke it in the
  OpenCode console, reconnect OpenCode Go, and smoke test
  `opencode-go/deepseek-v4.1-flash` specifically — the direct
  `deepseek/deepseek-flash` smoke does not exercise the Go path.
- **Go smoke result:** the `opencode-go/deepseek-v4.1-flash` transport worked,
  but the prompt was only `"ROTATED"`. The model treated it as an ambiguous
  task, searched with the missing `rg`, queried the session DB, hit the
  `jev-guard` canary warning, and returned a refusal instead of the exact
  token. Re-run with `"Reply with exactly: ROTATED"`. This is a **partial
  pass**: transport OK, output criterion failed.
- **Also revoke** the old SUBQ and Anthropic keys in their consoles; the
  scripts verified only the new keys.
- The container still reports `D docker/certs/.gitignore` because
  `/workspace/docker/certs` is the empty-certs mount. Host `git status` now
  shows the file restored, and `git check-ignore -v docker/certs/opencode.key`
  matches `.gitignore:3:*.key`; the container's `D` is a mount artifact, not a
  host deletion.

## References

- OpenCode, *Go* — <https://opencode.ai/docs/go/> (pricing, model list,
  `x-opencode-session`, usage limits, privacy).
- OpenCode, *Permissions* — <https://opencode.ai/docs/permissions/>
  (`allow`/`ask`/`deny`, `doom_loop`, `.env` default, `task`).
- OpenCode, *Config* — <https://opencode.ai/docs/config/> (`snapshot`,
  `compaction.reserved`, `subagent_depth`, `setCacheKey`, `instructions`).
- OpenCode, *Rules* — <https://opencode.ai/docs/rules/> (`AGENTS.md`,
  `instructions` precedence).
- OpenCode issue #47763, *Go provider: 400 MissingSessionID* —
  <https://github.com/anomalyco/opencode/issues/47763>.
- OpenCode issue #56296, *long sessions stuck at provider input limit* —
  <https://github.com/anomalyco/opencode/issues/56296>.
- OpenCode issue #61556, *cache hit rate collapses with parallel subagents* —
  <https://github.com/anomalyco/opencode/issues/61556>.
- OpenCode issue #36481, *GLM-5.2 routed to a 262K backend* —
  <https://github.com/anomalyco/opencode/issues/36481>.
- Hacker News comment with the 99.4%/96% cache anecdote —
  <https://news.ycombinator.com/item?id=49808409>.
- r/LocalLLaMA PSA on DeepSeek V4.1 Flash key exfiltration (single user),
  mirrored at <https://prismix.dev/news/9e4d386643bb>.
- Video: Kai (@kaiexplainsYT), *Is OpenCode Go a scam? (Stop Using)* —
  <https://www.youtube.com/watch?v=oik3S_oDJc4>.
- Repository: `swipswaps/opencode-deepseek-jev`, `RULES.md`, `HANDOFF.md`,
  `TODO.md`, `docs/HANDOFF-2026-11-05.md`, `scripts/preflight.sh`,
  `scripts/session-guard.sh`, `scripts/auto-handoff.sh`,
  `scripts/blacklist-guard-self-test.mjs`.
