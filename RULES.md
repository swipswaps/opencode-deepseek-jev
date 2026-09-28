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

## Not rules

The digits `#5`, `#12`, `#9`, `#13`, `#14`, and `#5604` that appear when
grepping the notes for `#N` are Docker BuildKit step markers (`#5 [ 4/14] RUN
...`) and an npm issue number (`#5604`), not rule references. Only the numbers
in the table above are rules.
