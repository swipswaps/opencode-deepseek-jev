# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-09-28

## Outstanding issues (audited — resolve or explicitly accept)

- **Guard runtime was silently inert (root-caused + fixed).** Web sessions boot
  at `$HOME/.opencode`, so the project-scoped `{plugin,plugins}/*.{ts,js}` glob
  never found the guard; `web-entrypoint.sh` now links it into the **global**
  plugin dir (`~/.config/opencode/plugins/`). Verified: `guard.log` shows
  `loaded` + `hook` and a live `sed` was blocked (`logs.sh --source guard`).
- **Rotation bricked startup (fixed).** `rotate-api-keys.sh` wrote a 2-line
  `.env.local`, dropping `OPENCODE_SERVER_PASSWORD`/`GEMINI_API_KEY`, so the
  entrypoint refused to start unsecured and R6 timed out (`http=000`). It now
  rewrites only the rotated lines. *Action (host):* re-run if the keys must
  change; DeepSeek/JEV are currently **unrotated**.
- **Secret exposure — accept local, no rotation.** `tr '\0' '\n' </proc/1/environ`
  printed `JEV_API_KEY` + `OPENCODE_SERVER_PASSWORD` into a tool result.
  `data/**` is gitignored and 4096 is loopback-only, so it is contained, and
  session **exports are redacted** (`scripts/redact.mjs`). Rotate only if 4096
  is widened to the LAN (see HANDOFF "Exposing 4096 to the LAN").
- **/explore overview height.** Fixed at the source
  (`#stable{max-height:58vh;overflow:auto}`), gated structurally; host
  `ux-audit.py` confirmed PASS (1.0x).
- **Session blindness (P1 done).** `scripts/session-health.mjs` (+ `/api/health`,
  `/explore ▸ signals`) detects stalled/blank turns without a browser; the naive
  long-gap signal is rejected as ~100% user-idle. The SPA freeze is upstream
  (#48623/#46419) — the panel is the route-around.
- **P3 downscale-before-attach — deferred (D, upstream/frontend).** `#46419` is
  client-side; the only server hook runs after the SPA renders the inline image,
  so a repo transform cannot prevent the black page. Guidance only.
- **Resolved / accepted (full detail in `git log`).** Dashboard reloads only on
  restart; guard firing; model pinned to `deepseek-flash` (preflight fails closed
  otherwise); orphaned word cloud restored; cache-hit report + patterns view
  built; `session_context_epoch`/credential tables unused (opencode-owned);
  historical `JEV_API_KEY` rejections pre-rotation; `echo` warn-only;
  `logs.sh --source system` needs the host; `test-dashboard.sh` ~2.5 min (run
  alone; `harness --fast` skips it).

## Segmented plan (do not balloon — one segment per session)

- **A — local, doable now:** doc trim (`scripts/README.txt`), `quirks` fuzzy
  precision on real data, `ensure-env.sh` password-regen review.
- **B — needs a host/test this container cannot run:** `doctor.sh --full` Tier 10,
  `ux-audit.py`/`ux-test.py`, `test-sidebar-streaming.sh`, `rotate-api-keys.sh`
  end-to-end.
- **C — larger code (own session):** per-model adaptation (not just the ledger),
  auto-handoff **action**, client-vs-agent stall, Plot migration, G1 UX
  residuals, embeddings rerank.
- **D — external / new deps (never batch):** upstream SPA, LiteLLM `max_budget`
  routing, finos/perspective, Laya, Blockly/n8n.

## Queue (ranked, top first)

- [ ] G3: migrate the hand-rolled d3 charts to Plot specs (one at a time)
- [ ] G4: wire `docker/litellm.config.yaml` `max_budget` into routing (needs proxy)
- [ ] G5: Laya self-host (cuts Jev only, ~11 calls); embeddings rerank over FTS5
      + redaction + hard request cap
- [ ] G6: run `doctor.sh --full` from a host
- [ ] G7: Blockly (vendored) rule/runbook authoring; n8n scheduled jobs (host)

## Done (most recent first)

- [x] capability registry + evidence levels (from the attached LifeOS
      methodology; all these concepts existed only in `notes/6ab95225-…089.txt`):
      `scripts/capabilities.json` + `capabilities.mjs` check the four links that
      can silently diverge — implementation / registration / test / evidence —
      and emit GREEN / DEGRADED / MISSING with an evidence level. `RULES.md`
      gains "Evidence levels" (E0–E5; nothing confirmed below E3). The
      falsifiable case is the guard incident: it is GREEN now and would be
      DEGRADED if its global symlink were absent. A checker bug (`expand(~)`
      applied after rooting the path) was caught by running it against reality.
- [x] held-out validation of the matcher (the honest counterweight to Step 3):
      added an out-of-sample `heldout` block to `quirks-eval.json` and measured
      it. Result: **recall 40% / FPR 20%** — so the frozen-set "FPR 0%" was
      **in-sample** (the map was tuned on the same 9 cases it was scored on).
      Production `/api/health` is unaffected (it correlates synthetic
      `symptomText` that fires via regex); the weakness is free-text paraphrase
      recall. Rule encoded: `cases` = train (ok to tune), `heldout` = report-only.
- [x] `quirks` threshold tuned: `matchIssues` default 0.15 → **0.5** (the sweep
      knee — 0.5 and 1.0 predict identically), cutting frozen-set free-text FPR
      67% → 44% while every production synthetic symptom still fires via regex
      (≥1.0); honest typo test (combination form) + a `levenshtein === 1`
      primitive assertion + a `real FPR ≤ 44%` gate. Residual 4/9 FPs are
      regex-driven → next session = keyword/regex surgery (its own segment).
- [x] `ensure-env.sh` backup names now carry microseconds — the behavior test
      exposed a real same-second collision that silently dropped a backup
      (flake → bug). 18/18, stable across reruns.
- [x] `ensure-env.sh` made safe to run unattended: a no-change rerun is a
      strict no-op (no write/backup/password); `OPENCODE_SERVER_PASSWORD`
      regenerates only when missing/empty or `--rotate` (short-but-present now
      warns, never replaces); atomic temp+rename write; preserves unknown
      keys/comments; `PASSWORD_ROTATED` marker surfaced by `web.sh` as a
      "re-login" notice. New gated behavior test `scripts/test-ensure-env.sh`
      (15/15, in `test-hygiene.sh`). Drive-by: HANDOFF documented the
      non-existent `verify-password-drift.sh` (never in this repo) — stale row
      removed.
- [x] `quirks` fuzzy precision measured on a frozen labeled set
      (`scripts/quirks-eval.json`): constructive recall 100%, decoy FPR 0%
      (asserted invariants); on 9 real redacted samples the free-text matcher
      over-fires — FPR 67% at the default threshold 0.15, 44% at 0.5 (sweep
      reported). Caught + fixed a real bug (`report` ~ `import` at edit-distance
      2; the `d===2` fuzzy bonus was removed). This session measures; the next
      tunes the threshold armed with the sweep. Note: production `/api/health`
      correlates *synthetic* symptom strings (which match correctly); the FPR
      applies to the free-text/`--query` path.
- [x] recurring `edit` failure root-caused from the DB (13/13 `edit` errors are
      `oldString` mismatch; 15 `Aborted` turns in `opencode.log`) and resolved
      deterministically: the guard pre-checks `oldString` against the file and
      records an `advisory` when absent (gated), plus a `jev-harness` rule to
      re-read before editing.
- [x] handoff advice surfaced (was dead code): `handoffAdvice()` → `/api/health`,
      `/explore ▸ signals`, `cost-bottlenecks.sh`, `session-health` CLI; gated.
- [x] A-items proven from the DB/logs: `--live` tested + live (`available:true`);
      `quirks --check-issues`; redacted export (0 secret hits, 91 `[REDACTED]`).
- [x] A1/A2/A3: `scripts/redact.mjs` (egress redaction), guard dedupe, global
      skill link.
- [x] P0–P4: 4096 loopback, session-health, quirks/known-issues, per-model
      ledger; guard observability (heartbeat); Plot pivot; doc trim.
- [x] Earlier (condensed — full detail in `git log`): OCR read-back + `ux-trace`
      (clicks/hotspots/`--ocr`), sub-24px touch-target fix, repo code index,
      `prompt-lint` dedupe, Gemini provider/picker, `/manage`, ECC security-review
      (interpreter-wrapper + pipe-to-shell), strategic-compact, fuzzy search,
      treemap/390px fixes, viewport + favicon, ux-test runbook, `/explore` tabs,
      test-tooling, doctor Tier 10, `harness --json`, `/status`, solution library,
      patterns view, cache-hit report, runbook filter, `doc-budget`, ECC audit +
      skill, model cost policy, `learn-rules`, `preflight`, `DESIGN.md`,
      `harness.sh`, `logs.sh`, guard plugin/log, gate telemetry, parallel
      shellcheck, strict-id headless UI test, docs.
