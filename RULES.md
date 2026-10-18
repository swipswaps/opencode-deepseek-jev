# Rule set

Canonical reference for the constraints that every script in this repository
is expected to honour.

## Provenance

This document reconstructs the rule set from citations embedded in the
scripts themselves. The numbered rules are referenced in `push_notes_v18.sh`
(header lines 12-16) and re-cited across `scripts/` and
`scripts/archive/one-shot/`. The un-numbered conventions are stated verbatim
in `scripts/README.txt` ("Scripting conventions" and "Indent control") and in
the constraint blocks that open most one-shot scripts.

Where the exact canonical wording lived outside this repository, the meaning
below is reconstructed from how each rule is used in practice. When a rule
number and a constraint overlap, both are listed.

## Numbered rules

| Rule | Meaning | Evidence of use |
| ---- | ------- | --------------- |
| #7  | No `sed` — in scripts *and* in the agent's own "Thinking" commands. Reach for `python3`, then `awk`, then `grep`/`find`; use `cat`/`curl` to read. Only if none apply may a guarded `sed` be used and called out. | `push_notes_v18.sh` header |
| #8  | No `2>/dev/null` — in scripts *and* in "Thinking". Never suppress stderr. Handle the failure case explicitly instead. During "Thinking" the blacklist-guard removes the redirect so the diagnostic (the proof) reaches the tool result. | `patch-ls-2devnull.sh` |
| #28 | Dependency check. Verify required tools exist (`command -v`) before using them. | `push_notes_v18.sh` deps block |
| #34 | Push-evidence (paired with #47). After a push, prove the result. | `push_notes_v18.sh` header |
| #37 | SKIP is not PASS. A skipped check must never be reported as a pass. | `push_notes_v18.sh` header |
| #38 | `printf`, not `echo`. `printf '%s\n'` for all output. | `push_notes_v18.sh` header |
| #39 | Gitignore checked before add (paired with #45). | `push_notes_v18.sh` stage block |
| #41 | UTC timestamps everywhere (`date -u`). | `push_notes_v18.sh` header |
| #45 | Gitignore checked before add (paired with #39). | `push_notes_v18.sh` header |
| #47 | Push-evidence (paired with #34). | `push_notes_v18.sh` header |
| #53 | Owner/repo parsed via `python3`, never `sed`. | `push_notes_v18.sh` remote block |
| #54 | Evidence completeness gate. A linked artifact must exist, be non-empty, and carry a structural marker. | `push_notes_v18.sh` link block |
| #55 | Raw-link HTTP-200 validation with backoff. | `push_notes_v18.sh` link block |
| #57 | End sentinel. The script ends with a sentinel line so truncation in transit is detected. | `push_notes_v18.sh` line 20 |
| #61 | No escape-dependent generated code. When JS/HTML is produced from a JS template literal, `\n`, `\'`, `\"`, `\\` are evaluated by the generator, not the consumer. Never emit inline handlers or escaped quotes; use `data-*` attributes plus delegated listeners. Every served page's inline script must be syntax-parsed AND executed headlessly. | `dashboard.mjs` (`html`, `exploreHtml`); `test-dashboard.sh`; `test-dashboard-ui.mjs` |
| #62 | Drive a live browser over **CDP, never X11 automation**. `scripts/cdp-tab.mjs` (`tabs`/`open`/`openauth`/`text`/`eval`/`fill`/`click`/`waitfor`/`shot`/`probe`) is the browser-control path — no Playwright, no `xdotool`, no display inside the sandbox. Run it where the browser runs; the sandbox reaches it only if the debug port is exposed (`scripts/chrome-cdp-up.sh`, then bind/tunnel). Selectors resolve in-page, so setting a controlled input's value must dispatch `input`+`change` (React/Vue ignore a bare `.value=`). | `cdp-tab.mjs`; `chrome-cdp-up.sh` |
| #63 | `gh api` cannot mint a **fine-grained PAT** (no endpoint; only the legacy classic `POST /authorizations`). UI-only consent steps — token creation, OAuth-app installs, account settings — are driven as browser steps (#62), not API calls. | this session |
| #64 | Browser-driver choice is **benchmark-informed, with failover**. `scripts/browser_bench.py` probes every CDP driver against the live endpoint and writes `data/observability/browser-drivers.json` with an `order` (fastest working first); callers take `order[0]` and fall over down the list on runtime error. SKIP is not PASS. Measured: `cdp_tab` ~1.3s < `playwright` ~11s < `browser_use` ~25s; `selenium` FAIL (chromedriver needs libnss3/libnspr4/libdbus-1). | `browser_bench.py` |
| #65 | For UX "what does a user see" checks, prefer the **local OCR** tool (`scripts/ocr-image.sh`, tesseract) over a paid cloud **VL** model — no allow-listed `opencode-go` model is vision-capable, so a semantic assertion would be outside the spend policy. `ux-smoke.py --vision` screenshots + OCRs locally; the dark theme OCRs garbled, so word-level checks run against the light theme (#66). Semantic vision (colors/layout) needs a VL model and is a separate, budgeted decision. | `ux-smoke.py --vision`; `ocr-image.sh` |
| #66 | The dashboard has a **light theme** (`?theme=light`, or the nav `◐` toggle; `html.light` overrides the CSS variables `--bg/--fg/--surface/…`) precisely so the **local OCR** vision check can read the screen (tesseract reads dark-on-light; the dark theme reads garbled). `ux-smoke.py --vision` loads `?theme=light`. | `dashboard.mjs` (`THEME_CSS`, `nav`); `ux-smoke.py --vision` |
| #67 | Telemetry/visualization doctrine: prefer **declarative, DB-driven, drill-down-native** tools over bespoke SVG — Grafana (+ a SQLite datasource) for ops/exploration telemetry, Vega-Lite/Observable Plot for embedded charts, TanStack Table for grids. **Every datum must drill down**; bottlenecks / high-cost / slowdowns are surfaced as **flags + summaries + annotations**, for the operator **and** the agent, from the same DB. **No Flutter** — this is a served web app, not a cross-platform binary. Full guidance: `.opencode/skills/telemetry-dashboard/SKILL.md`. | `telemetry-dashboard` skill |
| #68 | **Claude/Anthropic is ASK-tier and deliberation-only.** It is not on the allow-list (input/M ~$3), so it must never be the default, automated, or agent-initiated. `scripts/ask-claude.py` enforces the gate: it refuses unless you pass **`--reason "<why>"` AND `--yes`** (or `CLAUDE_ALLOW=1`) *after consulting the operator*. `--dry-run` prints the plan + cost estimate and makes no call. Vision uses **PaddleOCR (host) or Gemini**, not Claude. | `ask-claude.py`; `models.policy.json` `$anthropic` |
| #69 | **Durable-harness doctrine** (from pi-durable / durable-pi): (a) **layered decisions** — deterministic code thresholds → a cheap classifier → the agent only for open-ended work (never an LLM per row); (b) **handoff = curate + reset-note + search the old history**, never replay the giant context; (c) clients get **snapshot → deltas** (reconnect from a fresh snapshot), not polling; (d) a **beforeTool semantic guard** whose verdict is a **durable memo** (a restart never re-asks); (e) **checkpointed/supervised** long jobs. Also: *durable = checkpointed, not exactly-once*; a token is a shell, not a sandbox. Full mapping: `docs/pi-durable-mapping.md`. | `docs/pi-durable-mapping.md` |
| #70 | **Operator-facing text must be selectable text** — real DOM/terminal text, never rendered only inside a canvas, bitmap, or image. This is an accessibility requirement (screen readers, zoom, high-contrast) *and* a copy/paste requirement: the operator must be able to select any answer, flag, or command and paste it. Charts therefore keep an accessible `<table>` twin (#67); briefs print plain text; question options are plain strings. | `dashboard.mjs` (table twins); `triage-alerts.py` |
| #71 | **A pushed alert is not actioned until it carries severity + runbook + the exact next command.** `scripts/triage-alerts.py` reads the sink JSONL, de-dupes the stable-key ledger flags (a chronic condition is one row, repeated per sweep), classifies each, and prints that brief as plain text (`--json` for machines). Detecting a flag and *acting* on it are separate steps; the sink closes detect→push, triage closes push→act. | `triage-alerts.py`; `notify-sink.mjs` |
| #72 | **A measured `duration` is time-in-system, not handler cost.** Both servers here are single-threaded Node, so one blocking handler inflates *every* queued request (M/M/1: wait ~ ρ/(1−ρ)) — the caddy access-log `duration` is queue-wait + service. Fix at the source: keep heavy reads **off the event loop** (a worker + TTL, never a synchronous scan) and cut **repeats** (edge-cache immutable statics, lower poll rates). Corollary: a streaming/SSE route's `duration` is the **connection lifetime**, not latency — sentinel T4 excludes `/global/event` so a healthy open stream cannot cry-wolf the watchdog. | `sentinel.sh` T4; `docker/Caddyfile`; `triage-alerts.py`; runbook `slow-fetch` |
| #73 | **Read the durable source, not the delivery log** (pi-durable: *"a new process opens the same storage and continues"*; *"older messages always stay in storage"*). The ledger (`observability.db`) is the source of truth; the webhook sink is only a delivery channel — a dropped POST must never lose an alert. `triage-alerts.py` **defaults to the ledger** and takes `--in` for the sink. Proof: the same window yielded **21** alerts via the sink vs **124** via the ledger (~103 lost to a thin delivery log). Corollary: every projection (dashboard, brief, sink) is rebuildable from storage, so a lost client is a reconnect, not data loss; a report is written with `--out` so it survives the session. | `triage-alerts.py`; `notify-sink.mjs`; `docs/pi-durable-mapping.md` |
| #74 | **Long jobs are checkpointed, not restart-from-scratch** (pi-durable: *"every step… stores a checkpoint before it moves on"*). `scripts/durable-run.sh --job N --step ID -- cmd` records each completed step **durably** (`data/observability/jobs/<job>.jsonl`); re-running the job **skips** done steps and resumes after a crash (a *failed* step is not recorded, so it retries). First adopter: `caddy-reload.sh` (validate→restart→verify). Corollary: a job that can be typed as a sequence is a checkpointed script, and derived state is **rebuildable from storage** via `rebuild-derived.sh`; another client of the same committed state is `grafana-up.sh`. | `durable-run.sh`; `caddy-reload.sh`; `rebuild-derived.sh`; `grafana-up.sh` |
| #75 | **Discover a port; never assume one.** Port conflicts recur (the chat DB: 18× *"already in use"*, 10× *"port conflict"*, 6× `"port 3000"`). Any script that binds/publishes a port calls `scripts/free-port.sh` (`--check`, `--owner`, or *find the next free ≥ START*) and uses the result — `grafana-up.sh` auto-picks a free port when the default is taken and names the holder; `deploy.sh` already did this inline. A hardcoded port that `compose up` binds is a crash waiting on someone else's listener. The port is also overridable (`GF_PORT`) and the compose publishes `127.0.0.1:${GF_PORT:-3000}:3000`. | `free-port.sh`; `grafana-up.sh`; `docker-compose.observability.yml` |
| #76 | **The session budget is a hard STOP, not advice** (the operator's standing stipulation). An over-budget session still answers, but re-sends its whole history every turn — minutes and real money per turn. `preflight.sh` now **fails closed** (`crit`) when the latest/current session exceeds `CONTEXT_BUDGET`, so the harness loop's step 1 ("run preflight; if it prints STOP, fix that first") forces a **handoff**: `./scripts/session-guard.sh --handoff`, paste the brief into a fresh session, never `--fork`/`--continue`. It was previously *advisory-only* (`WARN, never STOP` in the code) — which is why a session could sail to **30× budget** with the warning visible every turn. Watch it on **every** turn, not when asked. | `preflight.sh`; `session-guard.sh`; jev-harness skill |
| #77 | **Budget the session-start set, not every doc.** `doc-budget.sh` charges only what the jev-harness skill tells a fresh session to read — **tier 1** = `HANDOFF.md` + `RULES.md` + `TODO.md` + the auto-loaded `.opencode/skills/*/SKILL.md` — against `DOC_BUDGET_TOKENS`. `README.md`, `DESIGN.md` and `scripts/README.txt` are on-demand reference (**tier 2**) and are only *reported*, not budgeted. Charging reference docs made the WARN permanently red — the same cry-wolf the sentinel doctrine rejects. Corollary: shrink tier 1 by moving old logs out (`TODO` Done → `docs/todo-archive-2026.md`) rather than by gutting durable docs; a monitor that cannot go green is not a monitor. | `doc-budget.sh`; jev-harness skill |
| #78 | **A fresh session resumes from the durable store, not the transcript.** `next-action.sh` is the missing *consumer* of pi-durable's storage for the dev loop: it reads git state, `last-gate.json`, the ledger, TODO's queue and `docs.json`, and prints the exact next unit plus what changed since the last gate — with **zero re-derivation** (no transcript replay, no re-explaining state a handoff would otherwise carry). Run it first, then read the docs it points at. Durability without a consumer is just a bigger log. | `next-action.sh`; `docs/pi-durable-mapping.md` |
| #79 | **The loop reviews itself on a timer, and a stall is news.** `progress-review.sh` (timer, every 15 min) records a durable PASS row when the rev/gate advanced since the last sweep, and a FAIL row when the loop has **not** advanced for `PROGRESS_STALL_TICKS` sweeps — stable `progress-advance-<rev>` / `progress-stall-<rev>` keys, so a persisting stall is ONE row (no cry-wolf). Review is continuous without a session; a stalled loop is surfaced by the store, not by a human noticing. Sibling to the sentinel (§#sentinel doctrine: only news trips). | `progress-review.sh`; `progress-review-install.sh` |
| #80 | **The in-flight loop segment is checkpointed, not re-derived.** `loop-state.sh --begin UNIT` records the segment (unit + rev) on `durable-run.sh`'s job store (`dev-loop`); `--end UNIT` records the gate result. A fresh session — or `next-action.sh`, which surfaces the in-flight unit — **resumes or skips** the segment from storage instead of reconstructing "where was I" from a diary. Same law as #74 (checkpointed long jobs), applied to the dev loop itself. | `loop-state.sh`; `durable-run.sh`; `next-action.sh` |
| #81 | **Before `edit`, re-read the exact region — `oldString` must match the file's CURRENT bytes.** A chat-DB audit (2026-10-18) found this the **#1 recurring failure**: `Could not find oldString …` **70×** (and `Found multiple matches` 12×), always because the region had shifted since it was last read (or the fixture lived in a different file than remembered). Read the region immediately before editing; make `oldString` unique with surrounding context. The guard records an `advisory` to `guard.log` when an edit pre-check fails, so the pattern is visible via `logs.sh --source guard`. | `issue-solutions.py` (`--write`); jev-harness skill §2 |
| #82 | **`opencode/*-free` is gateway-METERED, not free — it is deny-listed for cause.** The chat DB shows the "free" contributor model accrued **real cost** before denial: `muse-spark-1.3-contributor-free` → **$1.74 over 26 sessions** (one session **$1.51**); with its non-free sibling, **$2.06**. It also mostly returned `AI_APICallError backend temporarily unavailable` (`modelDenied`). Never re-enable it "because it is free": the price is paid in the gateway, and a huge session re-prices the whole context every turn. Keep the flash default (`deepseek-flash` / `opencode-go/deepseek-v4.1-flash`). | `models.policy.json` (`deny`); `session-health.modelDenied`; `cost-bottlenecks.sh` |
| #83 | **An ambiguous next step is decided by a bounded menu, not prose.** When the branch is open (an external blocker, several valid units, a cost/scope trade-off), call the `question` tool with **3–5 mutually-exclusive, single-select options, exactly one labelled `(Recommended)` and listed first**, each a concrete **falsifiable** deliverable, and **every option MUST carry a `description`** (a missing one is a schema error). A short header names the *axis* of choice (`Next action` / `Next unit` / `Hand off`). Evidence: the chat DB holds **74** `question` parts — the dominant, working shape is a 3–5 option `Next action|Next unit` menu led by a first `(Recommended)` pick; the only **2** recorded failures were a **dismissed** prompt and a **schema error** (an option missing `description`). A menu turns an open decision into one pick, so the loop advances instead of the operator re-deriving it. | chat DB `part` `tool='question'` (74; 69 completed); `issue-solutions.py` |

## Substitutions for the blacklist

When a banned construct is needed, use the substitute. "Find where to
address" means: fix the *file* (`scan-constraints.py`, wired into `lint.sh`)
and audit the *runtime* (`scripts/audit-tool-calls.py` over the tool-call
database), because the agent's own commands are where these accumulate
silently.

| Banned | Substitute | Why |
| ------ | ---------- | --- |
| `sed` (#7) | `python3` → `awk` → `grep`/`find`; `cat`/`curl` to read | `sed`'s in-place and escape semantics are a recurring footgun; the substitute is explicit and testable. Preference order is literal: try `python3`, then `awk`, then `grep`/`find` before `sed`. |
| `2>/dev/null` (#8) | let stderr flow and branch on the failure | Suppressing stderr hides the diagnostic that explains the failure — the telemetry the operator needs. Applies equally to the agent's own "Thinking" bash calls; the guard strips the redirect so the proof is not lost. |
| `subprocess.run` | `subprocess.Popen(..., stdout=PIPE, stderr=PIPE)` then `communicate()` and log both streams | `.run` buffers and discards the live output; `.Popen` preserves it. |
| `echo` (#38) | `printf '%s\n'` | `echo` flag/escape handling is not portable. |
| `rm -rf` | `rm -f` on named paths | Never blind-delete a tree. |
| `set -e` | `set -o pipefail` + explicit per-step handling | `-e` exits silently mid-pipe and hides which step failed. |
| top-level `exit 1` | `main()` wrapper returning a code; final line `main "$@"` | Keeps control flow testable and the exit status explicit. |
| bare `kill` | `kill -TERM` / `kill -KILL` | Signal explicitly. |

A blacklisted token that is merely *named* (in a prompt, comment, or a search
pattern) is not a violation. `scan-constraints.py` classifies file matches as
code / string / comment and only fails on code; `audit-tool-calls.py` strips
quoted regions before matching so `grep 'sed'` is not counted as `sed`.

## Service exposure and data egress

Two security practices that are testable and repeatedly relevant here:

- **Loopback by default.** A service published by compose binds
  `127.0.0.1:<port>`, never `0.0.0.0`. The web UI's only gate is
  `OPENCODE_SERVER_PASSWORD`, so widening it is a **three-part change**:
  rotate the password first, change only the publish line, then firewall the
  CIDR (see HANDOFF "Exposing 4096 to the LAN"). Never widen the port alone.
- **Minimise before egress.** Do not send secret-bearing content to a hosted
  free tier. Preference order: (1) no external call at all; (2) a closed
  allow-list of structural fields (counts, durations, tool names, error
  *categories*); (3) a local, self-hosted model; (4) redaction **plus** an
  operator preview. Regex-only redaction is the weakest option — it fails
  open, because a token fragment can cross (demonstrated: a Jev-key tail
  survived a masking pass). "Thinking" tool calls also obey `#7`/`#8`, and
  `blacklist-guard.js` enforces them at execution time.
- **Redact at egress.** Every serialisation boundary strips key shapes and
  `NAME=value` assignments via `scripts/redact.mjs` (`/api/export/session`, the
  sessions/patterns/guard CSVs); its `--self-test` is gated in
  `test-hygiene.sh`. This is defence in depth for a value already in the
  transcript, not a substitute for not leaking it.

## Evidence levels

A claim's strength is its evidence, not its confidence. Use this taxonomy
(adapted from the LifeOS audit methodology; see `notes/6ab95225-…089.txt`):

| Level | Meaning |
| ----- | ------- |
| E0 | model/agent assertion |
| E1 | source/document assertion (a doc or issue says so) |
| E2 | repository/file evidence (the code/symbol exists) |
| E3 | executed or observed behaviour (a run, a log line, a reproduced result) |
| E4 | independent reproduction (someone/something else reproduces it) |
| E5 | reproducible automated test/gate |

**No finding may be called "confirmed" below E3.** "I did not find it" is not
"it does not exist" — the correct phrasing is "not located within the examined
scope" (E1). "Configured" is not "executing": a capability is only GREEN with
its implementation **and** registration **and** a test/observed marker
(`scripts/capabilities.json` + `scripts/capabilities.mjs`).

## Model cost policy

Model choice is a rule, not a preference. `models.policy.json` sets the
ceiling (`max_input_per_m_usd`), the `allow` list and the `deny` list; free
models always pass. `scripts/models.py` applies the policy to the catalog from
`opencode models --verbose` and returns one of:

- **ALLOW** — within policy (free, allow-listed, or ≤ the ceiling).
- **ASK** — over policy but cheaper/qualified alternatives exist: alert the
  user and let them choose (interactive; `/models` in the UI).
- **BLOCK** — deny-listed, or no model satisfies the policy.

`preflight.sh` fails closed on ASK/BLOCK (override with `--allow-pro`). Do not
hard-code a single model: the cheapest sufficient model wins, and the choice
stays reviewable at `/models`. This replaces a blunt "flash or STOP" — there
are free and specialty models the operator may prefer.

**Dedup before spend.** Run `scripts/prompt-lint.py` on a large request first:
a prompt that is >= 0.9 similar to a prior user prompt (token Jaccard) is a
duplicate — reuse the prior answer instead of re-spending a session. That is
the local, deterministic form of a semantic cache. The same principle applies
to repo code: `scripts/code-index.py` assembles and flags it so inspection
does not require re-reading the tree.

## Generated code and escapes (rule #61)

The recurring "backtick" defect class. A page's inline `<script>` is
authored inside a backtick template literal in `dashboard.mjs`, then
served to the browser. Escape sequences in that literal are consumed by
the **generator** (Node), not the browser, so what looks right in source
is frequently broken in the served artifact.

Two incidents, same mechanism:

- `r.commands.join('\n')` — `\n` collapsed to a real newline, producing an
  unterminated JS string → the whole `<script>` failed to parse.
- `onclick="drill(\''+id+'\')"` — `\'` collapsed to `'`, producing two
  adjacent string literals (`...drill(''+id+'')"><span...`) → `SyntaxError:
  Unexpected string`.

Rules that follow:

- Do **not** put `\` before whitespace, quotes, or a line break inside a
  generated-code template. If the *consumer* must see a literal backslash,
  write `\\`.
- Do **not** emit inline event handlers (`onclick=…`) or escape quotes into
  generated JS. Emit `data-*` attributes and attach one delegated listener
  on a stable ancestor (`addEventListener`).
- Every served page's inline script must pass BOTH gates: a syntax parse
  (`node --check` on the extracted script) **and** a headless execution
  (`scripts/test-dashboard-ui.mjs`). A substring grep is not a gate.

## General scripting conventions

Enforced across the operating scripts. Violating any of these is a review
finding, even when the script still runs.

- **No `sed`.** See #7.
- **No `2>/dev/null`.** See #8. `>/dev/null` alone is acceptable only where
  the exit status is the intent and there is no stderr worth keeping.
- **No blanket `set -e`.** Use `set -o pipefail` only. Failure handling is
  explicit per step.
- **No top-level `exit` or `return`.** All control flow lives inside a
  `main()` wrapper; the final line is `main "$@"` and its return code is the
  script's exit status.
- **No `rm -rf`.** Use `rm -f` on named files.
- **No `subprocess.run`.** Do not shell out from Python for side effects.
- **No bare `kill`.** Always signal explicitly (`kill -TERM`, `kill -KILL`).
- **`printf` only.** See #38.
- **`main()` wrapper.** Every script factors its body into `main()`.

## Logging convention

Structured, single-line, key=value records. The `log()` helper used by
`push-telemetry.sh` emits:

```
ts=<ISO-8601 UTC> level=<INFO|WARN|ERROR> phase=<phase> status=<PASS|FAIL|SKIP> msg="<text>" [key=value ...]
```

`push_notes_v18.sh` uses a compatible `[timestamp] [SUCCESS|FAILURE] op :: detail`

Telemetry quoted in-chat or in reports carries its ISO date and age
(archival vs live) — 5-day-old Jev errors re-rendered in the TUI read as
live alarms without it.
form. Either way the rules are the same: UTC timestamps (#41), explicit
level and pass/fail status, and no silent suppression of a failed step (#37,
#8).

## Heredoc and pasteability

From `scripts/README.txt`:

- Every operation that can be typed is scripted and lives in the repository
  under `scripts/` or `scripts/archive/`. Nothing lives only in `/tmp` or only
  in a chat transcript.
- A response that emits multiple files does so through one script, and that
  script creates each file via a heredoc. The recipient pastes the whole
  script once. Prose goes before or after the script, never between heredocs.
- Use a distinct closing delimiter per nesting level (for example
  `SCRIPT_EOF`, `PATCH_EOF`, `WATCH_EOF`). A delimiter must appear on a line
  of its own with no leading whitespace.

## Interaction contract

These govern how the agent replies, not how scripts are written; they are kept
here because review enforces them the same way. Grounded in the corpus: over
1286 user turns, `audit` appears 298 times, `//re:` 180, `deduce` 164,
`prove`/`proof` 161.

- `//re: "<claim>"` is a direct-reply contract: answer *that* claim with
  evidence. Do not substitute a different (easier) question, and do not answer
  from memory — cite the file:line, DB count, or pasted command output that
  settles it. A claim that cannot be evidenced is stated as an open gap.
- "prove it" is satisfied by pasted raw output, never a quoted assertion.
  SKIP is not PASS (rule #37) applies to proof as much as to gates.
- The audit → deduce → write → audit → upgrade → implement → explain loop
  (the `phd-pipeline` skill) is the standing shape of a PhD-terms request; the
  upgrade step is not skipped even when the first prompt looks clean.
- When the next unit is *genuinely* ambiguous, ask with the bounded decision
  menu (rule #83): 3–5 mutually-exclusive, single-select, falsifiable options,
  one `(Recommended)` first, each with a `description`. Prose option-lists make
  the operator re-derive what one pick settles.

## Not rules

The digits `#5`, `#12`, `#9`, `#13`, `#14`, and `#5604` that appear when
grepping the notes for `#N` are Docker BuildKit step markers (`#5 [ 4/14] RUN
...`) and an npm issue number (`#5604`), not rule references. Only the numbers
in the table above are rules.
