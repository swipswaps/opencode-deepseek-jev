scripts/ — operating scripts for the OpenCode + DeepSeek + Jev environment
===========================================================================

This is the per-script reference, not the repo introduction. Read
../README.md first for the stack and the 10-minute start path.

Start here
----------
Quick index by job:

  health/gates    preflight.sh, harness.sh, doctor.sh, test-*.sh
  start/restart   web.sh, web-restart.sh, web-stop.sh, web-logs.sh
  recovery        07-io-triage.sh, 08-gated-recovery.sh, 09-ollama-start.sh,
                  10-recovery-autopilot.sh, incident-resolve.sh
  security        guard-verify.sh, guard-env-read.sh, red-team.sh,
                  security-posture.sh, secret-scan.sh,
                  secret-leak-response.sh, rotate-*.sh, rotate-tls.sh,
                  scrub-secrets.sh, authorize-container-key.sh
  models/cost     models.sh, cost.sh, cost-bottlenecks.sh
  status/decisions issue-benchmark.py, pulse.py, choice-gate.py
  usability       usability-suite.py, usability-guided.py, usability-guide.sh,
                  closeout-gate.py, web-build-restart.sh,
                  usability-install.sh, ux-test.py, a11y-audit.mjs
  RAG             sibling production-local-rag/README.txt

Conventions:
- Numbered NN-*.sh are ordered runbooks; unnumbered scripts are tools.
- "Host-only" means run on ws24 (docker/systemctl/ollama); "container" means
  the web container. Each entry says which.
- Every tracked top-level script must appear here or in tools.json
  (test-hygiene enforces it). Add a tool = script + self-test + README entry +
  tools.json + ./scripts/harness.sh.
- Scripts print telemetry first; a timeout prints its measured basis, elapsed
  time, and last sample (RULES #91).

Host access
-----------
authorize-container-key.sh
    RUN ON THE HOST. Append the web container's current public key
    (<repo>/container-key.pub) to ~/.ssh/authorized_keys (0600), print only the
    fingerprint, then remove the public-key file. Needed after a web recreate:
    /home/node is container-local and its key is regenerated. `restrict` (no
    pty/agent/X11/port forwarding, no user rc) is the DEFAULT since 2026-11-10;
    `RESTRICT=0` is the explicit opt-out. It guarantees a newline boundary before
    appending, so an unterminated existing line cannot swallow the new key.

https-selfheal.sh
    Host-side HTTPS/CA self-heal + monitor. Verifies cert SANs, 443/5099 on
    loopback/Nebula/LAN/Tailscale, Caddy, CA download, CORS/PNA preflight, and
    dashboard APIs. --fix reissues missing SANs, reloads/recreates Caddy, and
    restarts the dashboard; --watch monitors without a deadline; --open opens
    the live app. Requires docker/curl/openssl on the host.
    bash scripts/https-selfheal.sh --check
    bash scripts/https-selfheal.sh --fix --watch

trust-ca-client.sh
    Client-side CA bootstrap for the PC. Downloads the public CA from the
    reachable server, verifies its fingerprint, optionally installs it into
    system/Firefox/Chromium NSS trust, and prints macOS/Windows/Android and
    local-network-access instructions. --check only verifies; --dry-run prints.
    bash scripts/trust-ca-client.sh --server https://10.100.0.24:5099
    bash scripts/trust-ca-client.sh --check

receipts-pages-monitor.sh
    Host-side gh monitor for the three receipts GitHub Pages sites
    (receipts-ocr, receipts-ocr-rag, receipts-ocr-rag-v2). Checks Pages status,
    latest deploy + Quality Gates run, HTTP status, and can gh run watch and
    xdg-open each result. Requires gh auth, curl, python3, and a display for
    --open. Run on the host.
    bash scripts/receipts-pages-monitor.sh [--open] [--watch] [--json]

readme-audit.sh
    Audit reader-facing docs: root "what this is" + start path, catalog
    start-here/conventions, vendor integrity baseline, plans link, every
    tracked script documented, and every local markdown link resolves.
    --repo DIR, --write PATH.

Operate the environment
-----------------------

deploy-dockge.sh
    Start the Dockge web UI on http://localhost:5001. Idempotent. Manages
    every compose stack under $HOME/dockge-stacks.

flatten-dockge-stacks.sh
    Refresh the flat symlink dir $HOME/dockge-stacks (Dockge scans it
    non-recursively). Run after adding a docker-compose.yml under
    $HOME/Documents.

Check the environment
---------------------

doctor.sh
    Ordered health check: binaries, docker daemon, keys, provider liveness,
    image presence, an end-to-end model round-trip. Fast mode (no args) is
    free; --full adds plugin/MCP checks, a live model call (~$1e-4), a Jev
    functional proof (Tier 9), and the repo gates (Tier 10). Exit 0 on
    success, non-zero otherwise; the output is the diagnostic.

gate-watch.sh
    Run a gate with a live log and heartbeat; no deadline. Prints the last log
    line and elapsed seconds every HEARTBEAT; the exit code is the child's.
    Use when a gate is slow or the host is loaded, instead of a blind timer.

Monitor cost and activity
-------------------------

cost.sh
    DeepSeek cost accounting: totals from the opencode db (sessions, USD,
    in/out/reasoning/cache tokens), the balance endpoint, and a Jev usage
    count. Reads DEEPSEEK_API_KEY, never prints it. Host or container.
    --estimate IN OUT [REASONING].

dashboard.sh
    Read-only observability sidecar on http://127.0.0.1:5099 (DASH_PORT/
    DASH_HOST). Reads the DB read-only, no docker/external deps. Cost cards +
    todos + one combined Activity timeline (the former live-activity list and
    diagnostic timeline): newest first, filter chips, 30/all toggle, expand and
    copy per row, start dot on the time axis, relative-duration bar, exact
    duration, full command/text, moving now line. Copy buttons for session IDs,
    each timeline row, and the visible timeline JSON; /api/session?id= (detail
    and parts), the installable PWA shell (/manifest.webmanifest, /sw.js,
    /icon-192.png, /icon-512.png; Chrome installability check returns []), the
    separate MUI/React app at /app/ (built from web/ to web/dist, with
    /app-manifest.webmanifest; build: cd web && npm ci && npm run build), and
    /api/export/session?id=&format=txt|md|json (redacted); /api/search.
    /api/health is CACHED (HEALTH_TTL_MS 15s): ~7s of sync aggregation that
    would otherwise block every other request in the single Node process.
    /explore (alias /viz): cost treemap, brushable burn-down, latency×cost
    scatter, part timeline, bigram pivot (d3 + Observable Plot vendored under
    scripts/vendor/). /runbooks renders the runbooks (/api/runbooks is data).

dashboard-restart.sh
    Host-only: restart the :5099 dashboard with DASH_SEGMENTS=cost,activity,todos.
    Finds the node process via /proc (no pgrep), stops it with the shell builtin,
    waits for the container port, starts the new code, and verifies the HTTPS
    caddy snapshot carries activity and todos. --status, --dry-run.

cost-bottlenecks.sh
    Ranks where API cost goes: totals + effective $/1k-input, top sessions by
    cost and by input tokens, worst effective $/1k-input, tiny-session
    overhead, and a per-model breakdown. Read-only. --top N.

semantic-search.sh
    Ranked full-text search (SQLite FTS5/bm25) over text, reasoning, tool
    commands; index at data/search/opencode-index.db (gitignored). --rebuild,
    --limit N, --fuzzy (delegates to fuzzy-search.py), --idx FILE (alternate
    index, used by tests). Builds to FILE.tmp.$$ then atomically renames it;
    meta(n,m) stores the row count + max time_created (the dashboard's
    incremental overlay watermark).

rerank.mjs
    Rerank FTS5/bm25 candidates by embedding cosine -- the missing semantic
    step over lexical search. OFFLINE by default: a deterministic, dependency-
    free hashing embedder (word unigrams + bigrams, L2-normalised). The
    external path is gated: it refuses unless RERANK_ALLOW=1, passes every text
    through redact.mjs BEFORE egress (mandatory), and obeys RERANK_MAX_TEXTS /
    RERANK_MAX_REQUESTS (over cap = refusal, not truncation). --query Q with
    --fts data/search/opencode-index.db (pulls candidates from the FTS5 index)
    or --docs FILE|- (JSONL {id,text}); --limit N, --json, --self-test. No
    model call on the default path.

fuzzy-search.py
    Typo-tolerant search over the on-disk index: exact hits + near-matches
    (diflib) ranked, so "edti" still finds "edit". Free, local, read-only,
    no model call. --limit N, --json, --self-test.

harvest.py
    Fetch a URL into a provenance-chained research candidate: raw bytes,
    sha256-pinned meta.json, candidate.md under logs/harvest-<ts>/
    (gitignored). Fetched content is UNTRUSTED; adoption is an explicit edit
    citing the hash — the script cannot write docs. Exits 0 stored, 2 fetch
    failure, 3 unsupported type/oversize. Stdlib only. --url, --outdir,
    --max-bytes, --timeout, --self-test.

ledger.py
    Append-only event ledger (observability.db table ledger): harness
    GATE_START/GATE rows (wired non-fatally in harness.sh; LEDGER_DB
    overrides), guard verdicts via ingest-guard, history via backfill;
    idempotent through UNIQUE(source,source_key). Read with
    `logs.sh --source ledger` or `ledger.py show --tail/--since/--type/
    --grep/--json`. Stdlib only. --self-test.

media-budget.sh
    Fail-closed size gate for committed media: video <= 2 MiB, images <= 150
    KiB (tracked files only via git ls-files, so scratch/logs never trip it).
    Wired into test-hygiene.sh.

pressure-watch.sh
    Observe-only contention snapshot: PSI, top CPU/MEM holders, nebula
    liveness (PID/start/NRestarts), D-state blockers, swap — archived to
    logs/pressure-<ts>.log. Sends no signals, touches no other project's
    services. Run twice ~60s apart and diff.

nebula-restart-trace.py
    Names WHAT issues the external nebula restarts (3 PIDs/10 min, never
    systemd-counted): reads /proc/<pid>/stat + the parent's comm/cmdline for
    every nebula process; a parent that is not PID 1 is the restarter.
    --watch SECS reports births + parents live; --json; --proc-root seam;
    offline --self-test. Read-only: no signals, kills nothing.

nebula-systemd-override.sh
    NEBULA-1 fix: the trace named systemd (PID 1) as the parent, but the live
    --diagnose FALSIFIED the churn premise (NRestarts=0, one stable PID; the
    recurring event is a TUNNEL flap). Writes an idempotent drop-in
    (etc/systemd/system/nebula.service.d/override.conf): StartLimitIntervalSec
    =300/StartLimitBurst=5 + CPUWeight/IOWeight=50 + MemoryMax=512M +
    LogRateLimit* as a defensive ceiling, and CLASSIFIES restart-churn vs
    tunnel-flap. Dry-run by default; --show/--diagnose/--apply/--revert;
    --handoff emits a ready-to-paste issue for the peer repo (the fix is
    external); --out F writes the body and prints the exact `gh issue create
    --repo OWNER/NAME --title … --body-file F` command; --restart opt-in;
    --file/--systemctl-file/--journal-file seams; offline --self-test. Sudo
    only on write.

tunnel-link-probe.sh
    Host-side, read-only evidence bundle for TUNNEL-1 LINK (issue #5). Runs the
    hand-off probes with a header before each and a per-step timeout, so the
    terminal never looks hung: unit state (NRestarts/MainPID), journal flap
    count + last teardown/handshake lines, teardown cadence (median/min/max
    gap), udpAddr endpoint distribution, overlay ping loss, DF/MTU probes at
    the route MTU (below nebula0's 1300; 1400/1472 fail at sendmsg and prove
    nothing), local UDP :4242 listeners, and a process snapshot. Also answers
    "reload or endpoint flip?": per-teardown udpAddr sequence + alternation %,
    per-endpoint gaps, 3 DNS samples for the lighthouse name, the
    lighthouse/static_map config lines, systemd reload timers, and container
    RestartCount/StartedAt. Re-samples MainPID/ActiveEnterTimestamp/NRestarts at
    the end: NRestarts counts only AUTOMATIC restarts, so a PID change with
    NRestarts=0 is an EXTERNAL restart loop. --sudo also reads the journal and
    config and names the restarter (sudo-logged command, cron, timers, visible
    loop process). Classifies restart-churn vs external-restart vs dns-flip vs
    endpoint-rotation vs tunnel-flap vs journal-unreadable vs
    overlay-unreachable vs no-evidence and writes logs/tunnel-link-<ts>.log.
    --no-net/--sudo (non-interactive)/--watch SECS/--json/--lighthouse
    NAME/--config FILE/--container NAME; --systemctl-file/-file2/--journal-file
    seams; offline --self-test.

issue-bridge.py
    E2 external-state bridge: gh is absent in-container, so an issue hand-off
    (nebula-systemd-override.sh --handoff) had no read-back. "link" records a
    filed issue (repo#number) as an open external unit; "poll" reads its state
    — `gh issue view` on the host (--gh), a host-written JSON file (--in,
    default data/observability/issue-state.json), or the public GitHub REST API
    from the container (--api, stdlib, no gh/token; GITHUB_TOKEN optional) —
    into the same ledger that triage/next-action read (idempotent by
    source_key); "status" prints the latest state per issue. next-action.sh
    surfaces open external issues. Offline --self-test.

task-id.py
    E4 durable, addressed task identity: a unit has no stable ID and the DB
    `todo` is session-local, so begin/close/hand-off cannot name the same unit.
    "new" mints (or returns, by title) a stable id (T-<6hex>, or an explicit
    --id like TUNNEL-1) and records title + owner; "close --id|--title" ends it;
    "show"/"list [--all]" read the latest state — all on the same ledger
    (TASK/TASK_STATE rows), idempotent by source_key. loop-state.sh --begin
    registers the unit and --end closes it; next-action.sh surfaces open tasks.
    Offline --self-test.

query-lib.mjs
    Pure read-only aggregations (signals/patterns/words/trends/search/integrations/
    cost/activity/board query bodies) shared
    by dashboard.mjs and query-worker.mjs: single source of truth so the
    worker cannot drift. Every function is (dbPath, ...) -> plain JSON with
    its own read-only handle. Also: the semantic FTS base (on-disk index) +
    in-memory overlay for new parts, and loadJsonCache/saveJsonCache (atomic
    durable snapshots for signals/health).

query-worker.mjs
    node:worker_threads entry running query-lib (plus health/model bundles)
    off the dashboard event loop. Protocol {id, fn, dbPath, args} in,
    {id, ok, value|error} out; spawned with a 60s guard, failures fall back
    inline.

fix-docker-network.sh
    Host-side recovery for a broken host->docker port path (SUDO): probes
    mapped ports, restarts the daemon after typed YES, re-probes.

route-via-proxy.sh
    G4 opt-in switch: backs up opencode.json, points the deepseek provider at
    the :4000 proxy (model id unchanged), restarts web. --revert restores the
    newest backup. Typed YES required; never prints secrets.

ocr-image.sh
    Local OCR fallback for reading screenshots/scans when API models cannot
    ingest images. Tries tesseract CLI, then tesseract.js, then PaddleOCR.
    Persists each run to observability.ocr_run (surfaced at /api/ocr,
    /api/export/ocr, searchable via /api/semantic). Usage:
    `ocr-image.sh <image> [lang]` | --check. No API model required.

lint.sh
    Static gate: bash -n on every script, shellcheck (optional), node --check
    on JS, py_compile on Python, a subprocess.run check, a scan-constraints.py
    pass over scripts/*.sh (code vs string/comment), and a RULES grep (no sed,
    no 2>/dev/null). Exits non-zero on any failure; also run by
    test-dashboard.sh.

scan-constraints.py
    Classifier-backed scan of shell scripts for the blacklist (sed,
    2>/dev/null, rm -rf, set -e, exit 1, subprocess.run, bare kill), reporting
    each match as code/string/comment and failing only on code. lint.sh runs it
    on scripts/*.sh (archive excluded).

audit-tool-calls.py
    Audits the agent's own runtime tool calls (read-only from opencode.db) for
    the same blacklist; strips quoted regions so `grep 'sed'` is not counted.
    Prints counts, sessions, samples, the sanctioned substitute. --recent N,
    --json, --fail.

prompt-lint.py
    Fuzzy classifier + preference linter for user prompts. Reads the DB and
    the repo's preference sources (RULES.md, HANDOFF.md, README.txt,
    opencode.json) to classify a prompt into a repo topic, fuzzy-match it
    against past prompts (token Jaccard), surface recurring error calls, and
    flag blacklisted-tool mentions, leaked secrets, underspecified asks and
    missing acceptance criteria. Advisory; --last lints the latest prompt,
    --fail gates.

issue-solutions.py
    Mines the chat database for recurring errors and the command that fixed
    each: pairs an error call with the next completed call in the session,
    normalises into a signature, ranks (issue, fix) pairs. Free, local,
    read-only. --recent N, --top N, --json, --write, --self-test.

logs.sh
    Aggregate actionable telemetry, local and read-only. Sources: guard
    (guard.log — every blacklist block/fix/warn + a `loaded` heartbeat and a
    one-time `hook` marker), error (tool failures + stack text), event (the
    event bus), app (opencode.log), system (docker logs of opencode-web; host
    only), packet (the exact tcpdump command; not run). --source S, --since
    MIN, --tail N, --grep RE.

harness.sh
    One command for the whole state: every gate (lint, test-hygiene,
    test-patterns, test-dashboard), live telemetry, the cost headline and the
    TODO "in flight" list, then a summary. --fast skips the slow dashboard
    gate; --export writes logs/harness-<UTC>.md; --json emits ONLY
    {ts,rev,passed,failed,gates[]}. A failing gate is reported and the run
    continues; a missing gate is SKIP, not pass. Records
    data/observability/last-gate.json for preflight.sh.

preflight.sh
    Fail-closed spend gate (exit 1) unless: repo+database exist, .env.local
    has all three keys, the last harness gate passed, the balance is >=
    MIN_BALANCE ($1.00), and the model is deepseek-flash. Also STOPs once the
    latest session exceeds CONTEXT_BUDGET (#76). --json; --allow-pro skips the
    model checks. Run before any paid session.

next-action.sh
    The durable "where are we / what changed / what's next" (pi-durable: a
    fresh process opens the same storage and continues). Reads the store a
    session leaves behind — git state, data/observability/last-gate.json, the
    ledger, TODO's queue, docs.json — and prints the exact next unit plus what
    changed since the last gate. A fresh session starts here with no
    transcript replay. Read-only, no model call. --json; --self-test;
    NEXT_ACTION_REPO / LEDGER_DB seams.

issue-benchmark.py
    One repeatable measurement of the issues claimed fixed: security posture
    (security-posture.sh --offline under --run), guard/injection counts, stall
    signals (running tools, blank tails, over-budget/denied sessions) from
    session-health or health-cache, and the newest tunnel probe. Writes an
    issue_bench history row per metric to observability.db plus
    data/observability/benchmark.json (served at /api/benchmark and drawn in
    /graph). A source it cannot read is SKIP, never PASS; score is null when no
    probe ran. --run/--json/--history N/--self-test; BENCH_ROOT seam.

pulse.py
    The abstraction over next-action + issue-benchmark + choice-gate: one
    headline, security/stalls/tunnel scores, an attention list (every FAIL/WARN
    metric and every undecided choice), and the next automatic command. Writes
    data/observability/pulse.json, served at /api/pulse and rendered in the
    dashboard's Project pulse card. --refresh runs the benchmark probes first;
    --open opens /graph; --json/--self-test; PULSE_ROOT seam.

choice-gate.py
    Turns a blocking human item into an explicit decision. scripts/choices.json
    is the single source: question, why, recommended option and options with
    kind=script|human|accept|defer. --auto executes only safe script options;
    a human option prints its exact commands and is never auto-run. The
    selection is recorded in data/observability/choices.json and one DECISION
    ledger row; /api/choices serves the same list. --apply ID=OPTION/--json/
    --self-test.

usability-suite.py
    Cited usability screen. Static layer: HTTP reachability + a11y-audit.mjs
    (WCAG 2.2 automated subset). Browser layer (Playwright): seven scripted
    tasks with ISO 9241-11 effectiveness/efficiency, LCP/CLS lab probes,
    24x24 target size (WCAG 2.5.8), keyboard skip-link/focus, reflow at
    320px (WCAG 1.4.10), reduced motion, optional axe-core. SUS is recorded
    only when supplied (--sus/--sus-file); SKIP is never PASS. Writes
    usability_run/usability_result + data/observability/usability.json.
    --static-only/--browser/--axe/--json/--check/--watch/--runs/--self-test.
    Method and references: docs/USABILITY-TESTING.md.

usability-guided.py
    Facilitator-led human session against the shared
    scripts/usability-tasks.json. --tasks prints the goal script; --interactive
    times each task, records success/failure/skip + difficulty + note, then
    the 10 SUS items; --import ingests the JSON submitted by /usability;
    --list reads history. Persists usability_guided + usability-guided.json.
    The in-app flow is /usability (guided runner + automated evidence + history).

usability-guide.sh
    Optional facilitator wrapper around usability-guided.py --guide: opens each
    task URL with xdg-open, an already-open CDP browser, headed Playwright, or
    Selenium (fallback: print), then records success/time/difficulty/note/SUS.
    Runs on the host where the browser lives; the in-app /usability runner is
    the zero-driver path. --opener/--base/--self-test.

usability-autopilot.sh
    One cited front-end for a fresh terminal: A1 provenance + the three host-stall
    fixes (bounded test-durable sub-checks, isolated self-test git config, bounded
    fixture cleanup), A2 citation log, A3 executable runner, A4 streamed/bounded
    gates, A5 build/restart/served==HEAD/tasks/redirect/asset, A6 closeout, A7
    push only a clean tree. Then it launches the guided retest. --base/--repo/
    --hygiene-timeout/--dry-run/--self-test.

usability-proceed.sh
    The end-to-end gated command: locate the correct repo, assert the remote and
    usability files, build web/, restart from the repo root, run harness --fast,
    verify /app/ + served==HEAD + /api/usability/tasks + /app/explore 302 + the
    served asset hash, run closeout-gate, and launch the real guided retest when
    that is the only block. --no-retest/--no-push/--base/--repo/--dry-run/
    --self-test. It never fabricates the human session.

closeout-gate.py
    RULES #93 completion gate. --check verifies the command root, web/dist
    freshness after web/src changes, served==HEAD + /api/usability/tasks,
    last-gate freshness, a NEW guided session after the UI change, git-tracked
    tool/runbook scripts, and the citation log. --ask prompts the unresolved
    questions; --answer id=defer --reason records an explicit deferral; exit 1
    means do not declare done. --json/--self-test; CLOSEOUT_BASE/--base seam.

web-build-restart.sh
    Host command that removes the `cd web && ./scripts/web-restart.sh` path
    error: builds in web/, runs scripts/web-restart.sh from the repo root, then
    verifies /app/ 200, served==HEAD, /api/usability/tasks 200, and the served
    asset hash == the built one. --dry-run/--self-test.

usability-install.sh
    Installs a user-level systemd timer (no sudo) that runs the static
    usability screen every 30 minutes; --full bakes the Playwright layer
    (falls back to static if Playwright is absent). The suite holds an
    exclusive lock so runs never stack. --write-only/--uninstall/--self-test.
    CI also runs it: .github/workflows/usability.yml (static on push/PR,
    browser nightly).

/graph (dashboard page)
    Selectable, editable 3D force graph of real repo data: tools, runbooks,
    scripts they invoke, code-index files/flags, API routes, stores, benchmark
    metrics, decisions and external issues. GET /api/graph assembles it;
    POST /api/graph/edit persists pos/label/note/hidden/edge_add/edge_del/reset
    to observability.db.graph_edit. No synthetic nodes; changes never touch the
    session store.

progress-review.sh
    Sentinel sibling: supervisor of the DEV LOOP's progression. One sweep reads
    next-action and records a durable PASS row on a rev/gate advance, or a FAIL
    row when the loop stalls (no advance for PROGRESS_STALL_TICKS sweeps;
    stable keys, only news trips). A stall whose next unit is itself external
    records a PASS `progress-blocked-<rev>` (not a FAIL), so an external
    blocker does not cry wolf. --once, --json, --no-log, --self-test;
    PROGRESS_STATE / PROGRESS_STALL_TICKS / PROGRESS_NEXT_JSON / LEDGER_DB seams.
    progress-review-install.sh installs the user timer (every 15 min; no sudo).

progress-review-install.sh
    Installs the user-level progress-review timer (bakes the repo path, enables
    via systemctl --user). Idempotent; --write-only, --uninstall, --self-test.

durable-agents.sh
    One command to arm/verify the five durable background agents instead of
    half-arming them one installer at a time: sentinel (5 min), notify-sink
    (service), progress-review (15 min), fts-refresh (15 min), proactive
    (15 min). --install runs the tested installers in order; --status prints
    unit present + enabled + active, and prints SKIP (not pass) when systemctl
    is absent; --dry-run lists the commands; --self-test checks the nine unit
    templates and the five installers offline.

proactive-agent.sh
    Turns NEW ADVISORY rows into owned tasks + one durable digest. Cursor-
    bounded (the first run bootstraps and creates no historical tasks); later
    runs register at most PROACTIVE_MAX_NEW alerts as tasks (owner `proactive`,
    idempotent by title), write data/observability/proactive.json and record a
    PROACTIVE ledger row. A preflight STOP runs auto-handoff. --once,
    --self-test (offline PROACTIVE_ALERTS_JSON/NEXT_JSON seams).

proactive-install.sh
    Installs the user-level proactive-agent timer (every 15 min, randomized).
    No sudo; idempotent; --write-only, --uninstall, --self-test.

fts-refresh-install.sh
    Installs the user-level FTS base refresh timer (no sudo): every 15 min it
    runs semantic-search.sh --rebuild at Nice=19/idle/CPUQuota=50%. The build is
    temp+rename, so readers never see a partial index; the dashboard's overlay
    covers new parts between sweeps (staleness bound <= 15 min). --write-only,
    --uninstall, --self-test.

loop-state.sh
    Durable checkpoint of the in-flight DEV LOOP segment, on durable-run.sh's
    job store (job `dev-loop`): --begin records the unit + rev, --end records
    the gate result (--red for a failed gate), --show prints the in-flight
    segment + last done. A fresh session resumes/skips the segment instead of
    re-deriving it; next-action.sh surfaces the in-flight unit. --begin also
    takes the E3 single-writer lease (loop-lock.sh); --end releases it.
    --self-test; DURABLE_JOB_DIR seam.

loop-lock.sh
    E3 single-writer lease for the dev loop: "one process owns storage; clients
    attach". --acquire [--unit U] [--force] takes a TTL lease (default 1800s),
    actor-tagged; --refresh bumps it; --release frees it; --status [--json]
    reports the holder; --check exits 3 when another LIVE holder owns it. A dead
    holder is reclaimed by TTL, never by replaying history; a takeover is
    explicit (--force). The critical section is flock-serialised and the file is
    written atomically, so two sessions can never both acquire. loop-state.sh
    --begin requires it and refuses a busy loop; next-action.sh surfaces the
    holder + blocks. --self-test; LOOP_LOCK_FILE/ACTOR/TTL/ NOW seams.

learn-rules.py
    Contrastive corpus learning: builds (state, action, outcome) triples from
    the tool-call log and emits advisory avoid/prefer/recovery rules to
    learned-rules.json. The guard reads them (learned advisories); nothing is
    blocked until a human promotes a rule into RULES.md / the fixed blacklist.
    --since-days N, --write, --self-test.

models.sh / models.py
    Model catalog + cost policy: models.sh wraps `opencode models --verbose`
    and pipes it to models.py, which applies models.policy.json
    (max_input_per_m_usd, allow, deny; free always pass) and returns ALLOW /
    ASK / BLOCK with a recommendation and cheaper alternatives. --json,
    --write (observability/models.json for /models). preflight.sh uses the
    verdict; nothing hard-codes a single model name.

doc-budget.sh
    Measure the agent-facing doc corpus in tokens (~bytes/4), split by ACTUAL
    session-start cost: TIER 1 (budgeted) = HANDOFF/RULES/TODO + skills/*/SKILL.md
    (what the jev-harness skill tells a fresh session to read); TIER 2 (reported
    only) = README/DESIGN/scripts/README (on-demand reference). Budget =
    DOC_BUDGET_TOKENS (default 35000) on tier 1 only. Records a content hash +
    sizes to data/observability/docs.json. --json; --fail exits 1 when tier 1 is
    over budget; --self-test offline (DOC_BUDGET_REPO is the test seam).

test-tooling.sh
    Contract test for the tooling's machine interfaces: proves every tool that
    advertises --json emits parseable JSON with the keys a wrapper reads
    (preflight, doc-budget, learn-rules, issue-solutions, audit-tool-calls,
    prompt-lint --last, models --catalog) plus logs.sh. Launches the independent
    contracts in PARALLEL (each to its own temp file) so the live-DB scans
    overlap. Never calls harness.sh. Safe from test-hygiene.

test-fixture-db.sh
    Build a small opencode.db fixture (session/message/part/todo +
    session_message, a few realistic rows) so the DB-reading tools run in ms
    instead of scanning the live 626 MB store. Used by test-tooling.sh and
    test-hygiene.sh to keep the gates fast. --out PATH (default: a temp dir);
    --self-test.

ux-audit.py
    Host-side Playwright UX audit of /explore: page height vs viewport,
    panel/tab counts, tab toggle, page errors; writes a full-page screenshot to
    logs/ux/. Needs playwright on the host.

ux-test.py
    Host-side Playwright UX TEST (assertions). For each page (/, /explore,
    /runbooks, /models, /docs) asserts: no console errors, no horizontal
    scroll at 390px, not an unscrollable wall, and on /explore every tab
    toggles its pane and the overview stays compact. Exit non-zero on failure;
    SKIP (no playwright) is not a pass. --check reports readiness + install
    commands. Screenshots to logs/ux/. Runbook "ux-test".

a11y-audit.mjs
    Offline accessibility/usability audit for served HTML (no browser, no
    network). Checks <html lang>, title, viewport, exactly one h1 with no
    skipped levels, a skip-link whose target has tabindex="-1", a named nav
    landmark, image alt text, accessible names for buttons/inputs/role
    controls, a visible :focus-visible outline (and no stray outline:none),
    prefers-reduced-motion when motion CSS exists, and WCAG contrast for the
    dark/light theme tokens. Input is files or --url; --json for machines;
    --self-test proves the checker on a good + bad fixture. Wired into
    test-dashboard.sh against the scratch build (a regression is a red gate).

ux-trace.py
    Host-side Playwright UX trace that proves the journey: injects a recorder
    before navigation (every click/drag/scroll logged with a per-step
    screenshot), then enumerates every interactive element as a hotspot.
    Persists runs/events/hotspots/findings to observability.ux.db and a
    handoff report to logs/ux/report.md. Findings: console/page errors, 390px
    overflow, page-wall height, click targets <24px, overlaps. --check,
    --self-test (gated in test-hygiene.sh), --json, --ocr (reads each shot back
    to text via tesseract; text is untrusted). Runbook "ux-trace".

chrome-cdp-attach.sh
    Run ON THE HOST to make the user's Chrome CDP-reachable on their own
    profile (logins persist) and forward the debug port. Chrome M136+ refuses
    --remote-debugging-port on the default profile and a fresh /tmp profile is
    logged out, so this stops any running Chrome (typed YES unless --yes),
    launches CDP on a non-default --user-data-dir, and --clone-default seeds
    logins. Verifies the banner, then an idempotent socat forward. Attach:
    CDP_HOST=<host-ip> CDP_PORT=<fwd> node scripts/cdp-tab.mjs ... (#62).
    --dry-run.

browser-tools-install.sh
    Installs browser_use + selenium into a venv (default ~/.venvs/browser).
    No pip/ensurepip in the image, so it builds the venv --without-pip and
    bootstraps pip. Both drive the already-open browser over CDP (RULES #62).
    Selenium's chromedriver needs libnss3/libnspr4/libdbus-1 (absent here), so
    it runs only where those exist. --venv DIR, --with-browsers, --dry-run.

browser_bench.py
    Probes each CDP driver against the live endpoint for the same op and
    writes observability/browser-drivers.json with order[] fastest-first.
    Callers take order[0] and fail over; SKIP is not PASS (#37). Measured:
    cdp_tab ~1.3s < playwright ~11s < browser_use ~25s; selenium FAIL. --json,
    --runs N, --pick (exit 2 if none).

ux-smoke.py
    Live UX smoke for the six :5099 pages through the host browser over CDP
    (RULES #62). Per page: loads, lang, one <h1>, <main>+skip, no leftover
    "loading..." after the settle wait; plus /explore empty Session-detail
    hidden on load and board Gantt+Kanban render. Writes
    observability/ux-smoke.json; --json; exit 2 on fail; SKIP is not PASS.
    --base URL, --settle S. --vision loads ?theme=light, OCRs the board with
    local tesseract, asserts it reads "gantt"+"kanban" (RULES #65/#66).

cdp-tab.mjs
    Zero-dependency Chrome DevTools Protocol client (Node fetch/WebSocket; no
    Playwright, no X11). Attaches to the browser ALREADY open (discovers the
    debug port from /proc, else CDP_PORT, else 9222) and drives the live page:
    tabs, open <url>, openauth <url>, text, eval, fill, click, waitfor, shot,
    probe. fill sets the value via the prototype setter and dispatches
    input+change (React/Vue ignore a bare assignment). Run where the browser
    runs (scripts/chrome-cdp-up.sh starts google-chrome-stable with the debug
    port). UI-only GitHub steps go here, not `gh api`. --self-test offline.

re-extract-session.sh
    Reproduce a browser-extracted session transcript log: opens the session in
    the live browser (cdp-tab.mjs openauth), pulls /session/<id>/message in
    chunks, verifies (id uniformity, reassembled length, in-page sha256)
    BEFORE writing; growth mid-pull aborts unless --allow-growth. Out defaults
    to logs/ses_<id>.txt. --check, --self-test. Gated in test-hygiene.sh.

runbook.sh
    Host-side multiple-choice runner for the runbooks at /runbooks. Reads the
    same scripts/runbooks.json the dashboard serves, so they never drift. No
    args = menu; --list = id|where|title; run <id> = one runbook. "manual"
    runbooks (browser steps, long servers, secret edits) are shown but not
    executed.

test-dashboard.sh
    End-to-end gate for dashboard.mjs: starts it on a scratch port, asserts
    the served HTML and /api/* payloads (including that the /api/stream
    snapshot carries MATERIALIZED cost+activity, not stringified promises),
    and that the inline browser script on BOTH / and /runbooks parses
    (node --check); then runs test-dashboard-ui.mjs. Exits non-zero on any
    failed assert.

test-dashboard-ui.mjs
    Headless execution test: fetches the served / page, runs its inline
    <script> in a minimal DOM shim against the live server, fires the interval
    refreshers once, asserts #session/#stats/#sessions/#activity/#config
    populate. No browser required.

thinking.sh
    Live view of what the agent is doing while "thinking": tails the opencode
    db and prints step boundaries, tool calls (state + command), reasoning
    text and answer text as written. Polls every 2s (THINKING_POLL=1 for 1s).

session-health.mjs
    Read-only, browser-independent detection of stalled/blank turns from the
    opencode db (no model call): a tool part still "running" past the
    deadline, and a recent session whose last part is a tool with no text
    after it. Interactive tools (a pending `question`, which blocks on the
    OPERATOR by design) are excluded from both — the 2026-10-17 [HIGH] stall
    flags were all `question`, a false positive. The naive "long gap" signal is
    deliberately NOT a finding (~100% user-idle false positives). Exports
    healthReport() (/api/health, /explore ▸ signals) and handoffAdvice()
    (latest input vs CONTEXT_BUDGET: ok/warn/over + an action). --json, --live,
    --self-test.

quirks.mjs
    Correlates a symptom with a vendored map of known upstream issues
    (scripts/known-issues.json) and fuzzily searches the chat DB, repo code
    and docs. matchIssues() is fuzzy + typo-tolerant ("blnak" -> "blank");
    annotateReport() is the cheap form used on every /api/health load;
    modelLedger() joins each model to its tool-error rate and blacklist-
    construct usage; adaptModel() turns that ledger into a thresholded
    verdict (ok/watch/adapt) + a recommendation (the evidence->action step,
    RULES #69) attached to each ledger row and shown per model in /api/health;
    corpusHits() (DB LIKE + doc/code scan) is CLI-only.
    --self-test, --query TEXT, --report, --check-issues, --eval (scores
    matchIssues against the frozen key scripts/quirks-eval.json; prints
    precision/recall/FPR + a sweep). Default threshold 0.5. Offline.

redact.mjs
    Strips secrets at egress: key shapes (sk-, apikey_, JWT, Bearer) and
    NAME=value assignments (API_KEY/PASSWORD/SECRET/TOKEN). Imported by
    dashboard.mjs for /api/export/session and the sessions/patterns/guard
    CSVs; `node scripts/redact.mjs` filters stdin->stdout. Defence in depth
    (no replacement for not leaking). --self-test (gated in test-hygiene.sh).

test-patterns.sh
    Read-only proof of the tool-sequence substrate behind the "patterns view
    (tool-sequence n-grams)" candidate: opens the db read-only and asserts
    tool calls are recoverable as ordered per-session sequences and countable
    as n-grams (lead() window), plus the error-tool share. Exits non-zero
    unless the method is real.

test-jev-functional.sh
    Behavioral Jev proof: invokes the jev-review MCP tool and fails unless it
    fires and returns an applicable metric with a score. Host-side; also run
    by doctor.sh --full as Tier 9.

cleanup-baks.sh
    List or remove the *.bak.* snapshots that accumulate during iteration
    (including stale .env.local.bak.*). List-only by default; --apply
    gitignores *.bak.* and removes them.

ensure-env.sh
    Idempotent .env.local self-heal (run by web.sh every start). A rerun with
    nothing to change is a strict no-op (no write, no backup, no password on
    stdout). Preserves every key present (including unknown keys, comments,
    blank lines). Regenerates OPENCODE_SERVER_PASSWORD only when missing/empty
    or --rotate; a short-present password only warns. Writes atomically, one
    backup per change; announces PASSWORD_ROTATED. --repo <dir> is the test
    seam. Gate: scripts/test-ensure-env.sh.

monitor-snapshot.sh
    One-shot repo health snapshot from the databases/logs (read-only;
    names/codes/counts only, safe to paste or store under notes/): DB/utils
    counts, guard.log/opencode.log tails, docker ps, :4096/:5099 probes, key
    names. --json, --no-docker, --db PATH, --self-test.

watch.sh
    Read-only live problem monitor (no daemon, no model call). One sweep by
    default; --loop SEC repeats. Reports gate state, session-health verdicts
    (running/dead/blank), and only NEW guard block/fix/advisory and NEW
    opencode.log ERROR/WARN lines since the last sweep. The FIRST sweep
    initialises the cursor at EOF (history is never echoed as live). State is
    two byte offsets under data/observability/.watch/. --self-test.

capabilities.mjs
    Read-only capability registry checker. For each capability in
    scripts/capabilities.json it checks the four links that silently diverge
    (guard-was-configured-but-inert class): IMPLEMENTATION (file exists),
    REGISTRATION (wired in), TEST, EVIDENCE (observed-execution marker).
    GREEN needs impl+registration+test; DEGRADED = impl present but
    wiring/tests missing; MISSING = no impl. Evidence levels per RULES.md.
    --json, --self-test. E1: run with no flags to evaluate the LIVE repo; it
    exits nonzero on any DEGRADED/MISSING not named in capabilities.json
    accepted_degraded (id -> reason), so a silently-false claim fails the gate.
    Gated in test-hygiene.sh (both the self-test and the live check).

web.sh
    Start the web UI on port 4096. Requires OPENCODE_SERVER_PASSWORD; refuses
    to start an unauthenticated server unless --insecure. Caddy publishes on
    the wildcard address, so no DHCP/tunnel IP can abort the bind; if an
    override still pins host IPs, wait_for_bind_ips() polls for them and
    ensure_caddy() re-checks the proxy.

web-install.sh
    Install and enable the user units from systemd/: opencode-web.service
    (Type=oneshot, RemainAfterExit=yes, Restart=on-failure) so web.sh runs at
    boot/login, and opencode-web-health.timer (every 2 min measured from the
    previous FINISH via OnUnitInactiveSec, so a long recovery cannot stack)
    so web-health.sh re-rotates TLS SANs and re-covers a down client path.
    Bakes the repo path; enables linger best-effort so it starts before login;
    --uninstall disables before removing so no dangling wants-symlink remains.
    --no-linger, --write-only, --uninstall, --self-test.

web-health.sh
    Redundant watchdog: runs certs-init (rotates the server cert when the
    network/LAN IP changes, then restarts caddy), probes :4096/:5099 on
    loopback plus every present Nebula/Tailscale/LAN interface, and acts only
    on a PERSISTING failure: one settle retry absorbs a caddy restart, then a
    consecutive-failure threshold (WEB_HEALTH_FAIL_THRESHOLD, default 2) and
    a recovery cooldown (WEB_HEALTH_COOLDOWN_SEC, default 600) gate the
    action, so a 2-minute timer cannot self-induce a restart loop. The action
    delegates to the checkpointed, ledger-logged scripts/recover-4096.sh
    --recover (falling back to web.sh), keeping output in logs/. --quiet,
    --self-test (offline seams: threshold + cooldown + clear). Exit 0
    healthy/recovered, 2 still down. Deferred is still 2, never a fake PASS.

diag-opencode-web.sh
    Read-only access-plane diagnosis: container state, upstream :4096/:5099
    probes inside the container, caddy exit/error evidence, declared bind IPs
    (wildcard-aware) vs host addresses, client-path probes for
    Nebula/Tailscale/LAN, published ports/listeners, adjacent failed units,
    and chat-store telemetry. Verdict REACHABLE/UPSTREAM_DOWN/PROXY_DOWN; writes
    one report to logs/diag-opencode-web-<utc>.log. Never starts or stops
    anything. --help. Exit 0 reachable, 2 upstream down, 3 proxy down.

diag-opencode-store.py
    Read-only chat-store telemetry: SQLite mode=ro + query_only, per-query
    deadline, size/WAL, core table counts, recent sessions, and stale
    running/pending tool parts. --db, --json, --integrity (opt-in quick_check;
    skipped under a live writer), --stuck-after.

web-restart.sh
    Restart the observability dashboard so :5099 serves the current checkout.
    Polls /api/rev until served==HEAD or fails loudly. Uses
    `docker compose restart opencode-web` when docker is present; otherwise
    restarts the local dashboard.mjs process.

deploy.sh
    Gated promote. rev-match is not page-works (a bad inline script can freeze
    the page while /api/rev matches HEAD), so: D2 parses served .mjs; D3 boots
    the new dashboard in a scratch process and runs test-dashboard-ui.mjs;
    only on PASS does D4 recreate the container; D5 verifies live. Failure
    prints rollback, never auto-reverts. --verify-only, --skip-gates, --port,
    --self-test.

recover-4096.sh
    Automated :4096 recovery probe: asserts containers, compose DNS, loopback
    + mesh TLS edge (401 healthy; 000/400/502 classified), dashboard, cert
    battery, authenticated data plane (secret by name only) and the session
    store (read-only). --recover adds one bounded restart + re-probe, and the
    restart is checkpointed (durable-run, job recover-4096); --resume skips a
    second restart after a crash. One RECOVERY ledger row per check. --json,
    --no-log, --db/--session/--rev, --self-test (incl. checkpoint/resume).
    Gated in test-hygiene.sh.

clipboard-preflight.sh
    The paste path as a gate, across Wayland/X11 and SSH. Detects the session
    (Wayland preferred when present; else X11 xclip/xsel) and, for a display-
    less local tty, falls back to the local X socket (DISPLAY=:0). Reads the
    clipboard TARGETS and fails (exit 3) when an image flavour is advertised,
    because opencode's paste probes hasClipboardImage and aborts the prompt on
    ImageDecodeError. --set (stdin) copies text via the chosen backend;
    --clear-text replaces an image selection with text; --targets lists raw
    flavours; --json machine contract; --self-test offline. Over SSH it points
    at `ssh-x11-setup.sh` instead of asking for a one-off `ssh -Y`. Exit 0
    usable, 3 image flavour, 2 no backend. Gated in test-hygiene.sh.

display-env.sh
    Client-side DISPLAY fix for TTY/login shells. ssh only requests X11
    forwarding when the CLIENT has DISPLAY set; a TTY login on the MacBook has
    none even though the XFCE session does. --print shows the detected
    DISPLAY/XAUTHORITY; --install adds a guarded, idempotent block to ~/.bashrc
    that fills them only for interactive shells (never overrides a graphical
    terminal); --self-test offline. macOS is skipped (XQuartz). client-setup.sh
    runs --install in setup mode so new clients get it; gated in
    test-hygiene.sh.

client-setup.sh
    One-shot client bootstrap: `git clone`, run this, then `ssh opencode-jev`
    works and keeps working. Discovers a reachable server (mesh -> Tailscale
    -> LAN; --prefer mesh|tailscale|lan reorders when the Nebula lighthouse
    roams), writes the managed ~/.ssh/config block via ssh-x11-setup.sh (X11
    forwarding, trust scoped to one Host, keepalives), checks the local X
    server (XQuartz on macOS), and installs a self-heal timer (systemd user on
    Linux, launchd on macOS) that re-discovers the server and repairs the block
    after a network change. --check reports; --write-only writes config/units
    without launching; --heal is the timer pass and reuses the saved
    candidates/alias/trust (`~/.local/state/opencode-client-setup.conf`), so a
    custom --server survives healing; --uninstall removes block + timer;
    --discover prints the chosen server; --self-test offline. Dependency-free
    (no python3; macOS bash 3.2 safe). --install-deps is best-effort (brew cask
    on macOS). Gated in test-hygiene.sh.

ssh-x11-setup.sh
    Codifies clipboard-over-SSH instead of typing `ssh -Y` after every roam.
    Emits/refreshes one managed Host block (stable Nebula 10.100.0.24, so the
    same alias works on the same LAN and across a network change) with
    ForwardX11 yes, ForwardX11Trusted yes (trust scoped to that Host, not
    globally), ServerAliveInterval/CountMax and ConnectTimeout. --print is safe
    everywhere (paste on a client with no checkout); --check inspects sshd
    X11Forwarding + the current SSH/DISPLAY; --write [FILE] edits ~/.ssh/config
    idempotently with a timestamped backup; --self-test offline (block shape +
    managed-region idempotency). Gated in test-hygiene.sh.

guard-evasion-scan.py
    Detects the RULE #8 evasion family that re-spells `2>/dev/null` to hide
    stderr: `>/dev/null 2>&1`, `&>/dev/null`, `exec 2>/dev/null`. Modes:
    --command CMD (a command about to run), --file PATH / --repo (scripts),
    --log (past tool calls recorded in data/observability/guard.log).
    Read-only; --self-test (command + file + quoted/comment). Companion to the
    live block in .opencode/plugins/blacklist-guard.js (new rules are read at
    process start) and the historical audit in audit-tool-calls.py.

node-diag.sh
    READ-ONLY, verbatim-evidence diagnostic for the MacBook (.1). Sections:
    identity (addrs/routes/rules/wifi), unreachable (network-is-unreachable,
    RTNETLINK, deauth), nebula (restart churn + errors + IPv4-listener-vs-
    IPv6-remote count), mesh (mesh-recover timer + NM dispatcher hook + peer
    map + recover.log), dns (tailscale dns status, resolv.conf, SERVFAIL lines),
    getty (serial-getty@ttyS0 storm), units (failed + priority err), coredumps.
    --since/--until/--boot for the previous-boot incident window;
    NODE_DIAG_SOURCE or --self-test for offline fixtures. Safe over SSH:
    `ssh owner@10.100.0.1 'bash -s -- --section mesh' < scripts/node-diag.sh`.

node-fix.sh
    Fixes for the non-opencode-deepseek-jev issues on .1; DRY-RUN by default,
    --apply to execute. getty: disable+mask serial-getty@ttyS0. mesh: disable
    the user mesh-recover.timer, move the NM dispatcher hook to a backup, and
    patch the stale .1 peer map 10.100.0.2 -> 10.100.0.24 (backed up). dns:
    --dns tailscale (accept-dns=true) or systemd (restore resolved stub) or
    none. units: reset-failed accounts-daemon/audit-rules/tor + restart
    accounts-daemon. Prints manual guidance for the nebula IPv4/IPv6 mismatch
    (config lives in the mesh repo) and the verify commands. --only
    getty|mesh|dns|units; --no-peer; --self-test offline.

permission-memory-self-test.mjs
    Self-test for .opencode/plugins/permission-memory.js: a bash command that
    executed once in a session is auto-allowed on an exact repeat; a deny is
    preserved; a different command or session stays ask; the repeat-allow is
    logged to guard.log. Also tests normalizeCommand/memoryKey. The plugin is
    auto-discovered; disable with PERMISSION_MEMORY=off. Node, offline.

permission-memory-lib.mjs
    Pure helpers (normalizeCommand/memoryKey) shared by the plugin and its
    self-test. Kept outside .opencode/plugins/ because the loader treats every
    named export in a plugin file as a plugin factory.

credential-fix.sh
    Turns "AI_APICallError: Invalid credential" into numbered fixes, informed
    by the last real log line (providerID/modelID) and `opencode auth list`.
    Default runs `--diagnose` and prints: failing provider/model, project
    model, authenticated providers, and the menu 1) opencode auth login,
    2) switch the project model to deepseek/deepseek-flash (backup + JSON
    validate), 3) opencode auth logout anthropic (stale after cancelling
    Claude), 4) reload (web container / CLI). The web UI denies the native
    question tool, so these are text choices. --apply N executes 2, prints 1/3/4;
    --self-test offline (parse + menu + model switch). Run this first on any
    "Invalid credential"; never guess the provider.

nebula-ipv4-only.sh
    Stops the "Listener is IPv4, but writing to IPv6 remote" error (and its
    IPv6-preference side effects) on an IPv4-only Nebula listener
    (slackhq/nebula#1227). --check shows listen.host, the allow lists, the
    recent error count and ping to 10.100.0.24; --apply (root) inserts
    lighthouse.local_allow_list/remote_allow_list "0.0.0.0/0": true, backs up
    config.yml, validates with `nebula -config ... -test`, installs, restarts
    nebula, then re-checks; --dual-stack sets listen.host "::" instead;
    --self-test offline (fixture). Restart the other nodes too so their caches
    drop IPv6. Gated in test-hygiene.sh.

overlay-status.sh
    Read-only audit of BOTH mesh planes from either box. Audits this machine
    locally, then SSHes to the peer (auto: .24 <-> .1) and audits it too, so
    one command answers "is .24 healthy, is .1 healthy, can they see each
    other?". Per host: nebula0 address, nebula service, route to the peer, ping,
    tailscale0 + tailscaled, web :5099 on the server, sshd X11Forwarding on the
    server, xclip. Role is inferred from the local nebula IPv4; --peer
    user@host overrides, --local-only skips the peer, --self-test offline.
    Surfaces ssh stderr (e.g. a host-cert principal warning) as WARN. Exit 0
    all core PASS (warnings allowed), 2 any FAIL, 3 cannot run. Read-only: no
    restarts, no writes. Gated in test-hygiene.sh.

network-change-probe.sh
    Post-roam acceptance test: enumerates loopback + Nebula 10.x + Tailscale
    100.x + default LAN, probes https :4096 (200/401 = PASS) and :5099 (200) on
    each, checks the server cert SANs (certs-init --check) and that caddy's host
    ports are wildcard (not pinned to a vanished IP). --watch records the
    current IP set and re-runs the matrix whenever the interfaces change, so
    you can start it before switching Wi-Fi/hotspot. --peer HOST is the
    client-side half: run it on the roaming box against the LAN address for
    "same network", then the Nebula address for "different network"; peer mode
    probes only those two ports and skips server-local cert/bind checks.
    --recover runs web-health on FAIL; --json; --no-docker/--no-certs;
    --self-test offline. Writes one report to logs/network-change-<utc>.log.
    Exit 0 all interfaces pass, 1 gap. Gated in test-hygiene.sh.

session-guard.sh
    The over-budget / denied-model guidance as code: reads session-health
    risks (over/warn sessions, deny-listed gateway-metered free tiers), prints
    numbered fresh-session steps, logs ADVISORY rows. FAIL means action due
    now (a routine handoff, nothing broken). --handoff runs the whole offer
    (brief + leak check + ledger). --json, --session, --no-log, --db/--rev,
    --self-test.

auto-handoff.sh
    #76 ACTED, not advised: at the budget STOP it targets the LATEST
    over-budget session (the row preflight.sh gates on), produces the redacted
    brief, and prints the paste path — no model call, no --fork/--continue.
    Idempotent (a brief already on disk is reused; --force regenerates), so a
    per-turn preflight costs nothing after the first. preflight.sh calls it on
    the budget STOP (JEV_AUTO_HANDOFF=0 disables). --session/--db/--out/
    --transcript/--json/--self-test.

handoff-brief.sh
    Deterministic carry-over brief from logs/transcript-<id>.md (goal,
    findings, recent asks, tools, open question); every field passes through
    redact.mjs. Refuses missing transcripts (points at re-extract-session.sh)
    and --fork/--continue. --model only prints the prompt + spend command
    after an ALLOW verdict; never calls a model. --out, --self-test.

session-digest.sh
    Deterministic DB-ONLY digest of ONE session (~1.5 KB): title, model,
    budget ratio, cost, last user ask, last assistant text, open todos,
    running tool, over-budget directive. Curates the critical facts for a
    fresh session instead of replaying a transcript — no model call, no
    transcript at rest. Read-only, redacted. --db, --max-bytes, --self-test.
    sentinel.sh writes one per T5/T6/T7 trip to digests/<id>.md.

subq_snap.py
    Client for SubQ's Decisions API (Snap): model subq-snap-preview, POST
    /v1/systemone, typed questions (noul/choice/score), billed on input only
    ($0.05/1M). A cheap first-pass triage gate before an expensive second
    opinion. Key SUBQ_API_KEY; seams SUBQ_MODEL, SUBQ_URL. --state/
    --state-file, --question, --type, --criteria, --true/--false, --json,
    --dry-run, --self-test.

secret-scan.sh
    Secrets-at-rest scan over logs/, observability, notes/: deepseek/jev keys,
    bearer tokens, env assignments. Report is value-free (file:line:kind).
    Exit 1 names rotate-api-keys.sh plus both revoke consoles. Called by
    handoff-brief.sh on its source transcript. --paths, --json, --quiet,
    --self-test.

scan-chat-secrets.sh
    Value-free scan of the OpenCode chat DB (part.data text/reasoning/tool
    strings): deepseek/jev keys, bearer tokens, env assignments, and
    OPENCODE_SERVER_PASSWORD. Reports session:part [kind] only. Read-only;
    defaults to the newest 5000 parts. --tls-check compares any PEM block to
    docker/certs/*.key and reports the filename/session/part on a live match
    (values never printed); --cert-dir overrides. --db, --limit, --all,
    --json, --quiet, --self-test.

env-inspect.sh
    Safe replacement for `cat .env.local`: names, presence, value LENGTHS,
    file mode, and line count only. --env, --json, --check KEY, --self-test.

secret-leak-response.sh
    Contain a credential leak (F1): audit at-rest artifacts, prove .env*/auth
    paths are ignored (walks up past the data/opencode symlink), flag root
    chrome, install a tracked .githooks/pre-commit (core.hooksPath) that
    refuses credential-shaped paths and staged secret patterns, then print the
    human-only rotation matrix. --audit, --install, --json, --self-test.

guard-env-read.sh
    Install/check the .env read-block rules in the blacklist guard: block
    cat/less/more/head/tail/nl/xxd/od/strings on .env*, and grep unless
    -c/-q (no value printed). --check, --install.

install-global-guard.sh
    Make the blacklist guard load from ANY project. The global plugin link
    must resolve to a real file; the 2026-11-10 audit found it pointing at the
    container-only /workspace path, which is DANGLING on the host, so no guard
    loaded there (a missing guard and an idle guard look identical). --check
    (PASS resolves, FAIL dangling, WARN absent), --install (link the resolved
    checkout plugin), --uninstall, --require (absent is FAIL), --self-test
    offline. Exit 0 PASS, 2 FAIL, 3 usage. Gated in test-hygiene.sh.

guard-verify.sh
    Prove jev-guard is loaded in the running web container and its backend
    answers: a read-only call ALLOWs and a destructive one DENYs. --restart,
    --recreate; the classified commands are never executed.

sentinel.sh
    Periodic threshold monitor (user timer, every 5 min): trips only on
    actionable news — T1 latest over budget, T2 latest on a deny-listed model,
    T3 new gateway-failure lines since cursor, T4 slow caddy fetch (SSE/long-
    lived streams excluded; a fetch interval overlapping a long tool span is
    NAMED as self-inflicted — LAT-2), T5 non-latest deny-listed, T6 non-latest
    over-budget, T7 a tool stuck `running`, T8 a flapping peer tunnel
    (>= SENTINEL_TUNNEL_MIN, default 4, teardown/re-handshake events for the
    nebula unit — the NEBULA-1 finding: the process is healthy, the link is
    not) — active since the last sweep.
    History only reported. Logs ADVISORY rows with a STABLE per-incident
    ledger key (a persisting condition stays ONE row via UNIQUE(source,key));
    writes a DB-only digest next to each non-latest trip. --once (default),
    --json, --no-log, --self-test. Install: sentinel-install.sh (no sudo).

sentinel-install.sh
    Installs the user-level sentinel timer (writes units with the repo path
    baked in, enables via systemctl --user). Idempotent; --write-only,
    --uninstall, --self-test (no systemd touched).

notify.sh
    Push recent sentinel FAIL flags to the webhook ($NOTIFY_WEBHOOK). Reads
    the ledger, builds JSON, POSTs; no webhook -> prints the payload and exits
    0 (SKIP). --last N, --dry-run, --self-test.

notify-setup.sh
    Scripted NOTIFY_WEBHOOK setup + probe. --url set+probe, --show, --test,
    --unset, --self-test. Validator accepts https://host/path or
    http://127.0.0.1[:port]/path (loopback http for the self-hosted sink;
    remote must be https).

notify-sink.mjs
    Self-hosted webhook receiver (zero-dep node) so alerting needs no
    third-party URL. POST /hook appends JSON to notify-sink.jsonl; GET /
    prints the last 20; GET /health -> ok. env PORT (8788), HOST (127.0.0.1),
    SINK_FILE. --self-test.

notify-selfhost.sh
    One command to self-host the sink: writes the systemd USER unit for
    notify-sink.mjs (bakes the absolute node path), enables it (host), sets
    NOTIFY_WEBHOOK=http://127.0.0.1:PORT/hook via notify-setup.sh, polls
    /health. --port N, --write-only, --self-test.

triage-alerts.py
    Triage alerts into an actionable brief: read the DURABLE ledger (source of
    truth — an alert that failed to POST is still triaged; --in FILE reads the
    delivery-log sink), de-dupe stable-key FAIL rows, classify each
    (over_budget/stall/slow_fetch/deny_listed/guidance), and print severity +
    the exact next command + the runbook. Plain selectable text (#70);
    --ledger DB, --last N, --out FILE, --json, --self-test.

durable-run.sh
    Checkpoint / resume for multi-step shell jobs: --job NAME --step ID -- CMD
    records a completed step durably (jobs/<job>.jsonl); re-running skips done
    steps and resumes after a crash (a failed step is not recorded, so it
    retries). --force, --status, --reset, --self-test.

caddy-reload.sh
    The typed Caddy sequence as a checkpointed script (durable-run): validate
    the Caddyfile -> restart caddy -> verify :5099 serves; a crash mid-way
    resumes at the next step. --dry-run, --reset, --self-test. Host-only.

rebuild-derived.sh
    Rebuild every derived artifact from storage alone: the alert brief
    (ledger -> triage-<date>.md) + the latest-session digest (store ->
    digests/<id>.md). --ledger/--db/--out, --self-test.

grafana-up.sh
    Stand up the Grafana + SQLite ops view (a read-only client of the same
    state). up + wait for /api/health, --down, --logs, --self-test.
    Host-only.

test-durable.sh
    Proves the durable properties offline (RULES #73/#74): triage reads the
    durable source, durable-run checkpoints + resumes, derived state rebuilds,
    a read-only client attaches. Wired into test-hygiene.

free-port.sh
    Find / test a free TCP port (never assume one; conflicts recur). Prints
    the first free loopback port >= START (default 3000); --check PORT (exit 0
    free / 1 busy), --owner PORT, --self-test. Used by grafana-up.sh.

snapshot-audit.sh
    Is the BTRFS snapshot system costing us? (host). Read-only: root mount,
    btrfs usage, quota/qgroups, snapper retention limits, whether locate
    indexes /.snapshots, then the exact tuning commands. --self-test.

locate-prune-snapshots.sh
    Keep heavy trees out of the locate index (updatedb walks the whole tree
    unless PRUNEPATHS prunes it; snapshots + docker/flatpak/virt bloat the db
    on a USB-HDD root). Adds the costly paths (default /.snapshots
    /var/lib/docker /var/lib/flatpak /var/lib/libvirt /mnt) idempotently with
    a timestamped backup, then rebuilds with updatedb at IDLE priority
    (ionice -c3 nice -n19). --paths, --no-updatedb, dry-run default,
    --self-test.

proc-progress.sh
    Live progress for a silent process (updatedb prints nothing and looks
    hung). Every few seconds: state/elapsed/CPU, /proc read counters, and the
    process cwd (for a tree walker, cwd IS the progress bar). Read-only;
    Ctrl-C stops the view, not the job. sudo for /proc/<pid>/io. --self-test.

ffind.sh
    File search that prefers fd and falls back to find. fd is fast,
    .gitignore-aware, no whole-tree index — the on-demand replacement for
    locate on a slow disk. FFIND_ALL=1 for fd -u -H. find stays the tool for
    -delete/-printf/exact scripts. --self-test.

latency-timeline.sh
    Gantt-style timeline of what made a session slow: part timings (read-only)
    on one axis against slow caddy fetches from the access log — serial-loop
    starvation made visible, not averaged away. Each fetch whose interval
    overlaps a long (>=1s) tool part is labelled `<- tool:<name> <dur>`
    (`attributed_to` in --json), so a burst is named, not guessed. --session
    (required), --window/--width/--min-fetch, --json, --db/--access-log,
    --self-test.

state-snapshot.sh
    Snapshot + verified restore of the state you cannot regenerate: .env.local,
    TLS certs, compose/Caddy/config (and the store with --with-db, copied via
    the sqlite backup API). Each snapshot carries a sha256 manifest; restore
    verifies checksums and snapshots current state first. 0700 dirs, secrets
    never printed. Commands snapshot/list/verify/restore, --dry-run, --keep N,
    --self-test.

extract-transcript.sh
    Transcript straight from the db (read-only) in the re-extract shape: use
    when the tab will not render or the message route stalls. Feeds
    handoff-brief.sh via logs/ses_<id>.txt. Never paste the raw file (may hold
    pasted secrets). --out/--out-dir/--max-parts/--db, --self-test.

rotate-server-password.sh
    Rotates OPENCODE_SERVER_PASSWORD (the :4096/:5099 Basic-auth password):
    backup, token_urlsafe replacement, atomic single-line rewrite (0600 kept),
    container RECREATE (env_file is read at creation), then proves new=200 and
    old=401. Neither value is ever printed. Interactive "write" gate; prints
    rollback on mismatch. Checkpointed (backup -> rewrite -> recreate ->
    verify): --fresh (default) resets, --resume skips done steps after a crash.
    ROTPW_CLIPBOARD=1 copies the new value (never printed): wl-copy on Wayland,
    else xclip, with a tty/SSH fallback to the local X socket (DISPLAY=:0) so a
    display-less shell still has a usable clipboard. --env, --self-test
    (incl. checkpoint/resume).

rotate-provider-keys.sh
    Rotate the remaining exposed credentials (SUBQ_API_KEY, ANTHROPIC_API_KEY,
    LITELLM_MASTER_KEY; DeepSeek/password have their own scripts). Hidden
    input, masked confirmation, values never printed; SUBQ also updates
    JEV_BASE_API_KEY. --self-test.

rotate-opencode-token.sh
    Rotate OPENCODE_CONSOLE_TOKEN (the token printed by `opencode debug
    config`): browser revoke checklist, hidden new-token input, atomic single
    line add/replace in .env.local (0600 kept), backup, recreate, then the
    exact opencode-go/deepseek-v4.1-flash "Reply with exactly: ROTATED" smoke.
    Values never printed. The backup is removed after a successful verified
    smoke; --keep-backup retains it. --no-recreate, --no-smoke, --env,
    --self-test.

open-rotation-pages.sh
    Open the correct key page for each credential from the F1 matrix:
    pending SUBQ (console.subq.ai), Anthropic (/settings/keys), local LiteLLM
    (:4000/ui); done DeepSeek; optional JEV/Gemini. --list, --open,
    --only a,b, --all, --dry-run, --opener xdg-open|cdp|print.

litellm-db.sh
    Create/repair the private Postgres for LiteLLM (docker/litellm-db.env,
    0600, gitignored), add LITELLM_DATABASE_URL to .env.local, start postgres
    + litellm, wait for both, and verify admin login + /v1/models. --status,
    --dry-run, --apply. Values are never printed.

red-team.sh
    Falsifiable adversarial gate: blacklist self-test (including host-secret
    reads), .env read-block rules, and live jev-guard/SubQ classification
    (ALLOW/DENY/ASK) for destructive, exfiltration, out-of-workspace, and
    quote/substitution-obfuscated commands. --offline skips the SubQ calls.
    The commands are classified, never executed.

rotate-tls.sh
    Reissue the caddy leaf key/cert with the SAME local CA, restart caddy, and
    verify the served fingerprint on :4096/:5099. --check also reports whether
    the live key matches a leaked snapshot. --apply requires --yes.

scrub-secrets.sh
    Redact secret-shaped values in logs/ and data/observability with
    redact.mjs; optionally purge snapshot dirs containing private keys/yaml
    secrets and .env.local.bak.*. Dry run by default; --apply --yes to write.
    Values are never printed.

security-posture.sh
    Read-only gate for the residual invariants: no whole-host-home mount,
    no-new-privileges + cap_drop ALL + non-root, LiteLLM loopback and an
    internal Postgres, secret-file modes, clean artifacts, TLS, and the
    offline red-team layer. --offline skips live docker checks.

verify-rotation-go.sh
    Host-side one-command proof for the 2026-11-05 rotation: preflight,
    secret-file modes, console-token presence (manual), stale .env.local.bak.*
    files, cert ignore, secret-scan, containment audit, security-posture,
    HTTPS self-heal, red-team, and the exact OpenCode Go
    "Reply with exactly: ROTATED" smoke. Never prints a value and never
    rotates; the smoke is one small paid call. --no-smoke, --no-preflight,
    --json.

rotation-progress.sh
    Read-only progress view for the OPEN rotation terminal and the background
    workers behind :4096. Reports the rotate-server-password.sh tree (pid/tty/
    state/wchan/stdin), its durable-run checkpoint, whether .env.local still
    matches .bak.rotate (cmp only, never values), the newest smoke log, the
    ROTATED proof from the chat DB, container/process/HTTP/timer state, and
    chat-store counts including stale running/pending tool parts. Writes
    nothing; --watch SEC, --json, --no-net, --host, --db, --env.

verify-from-inside.sh
    In-container self-check (no docker): opencode binary, auth.json, key env
    vars, opencode.json parse, jev-review server.js. --full adds a live "PONG"
    round-trip. Counterpart to the host-side verify-api-keys.sh.

test-sidebar-streaming.sh
    Regression test that a session appears in the sidebar while processing:
    opens the /api/event SSE stream, triggers a real session, asserts
    session.created + message.updated are emitted. Host-side; requires
    OPENCODE_SERVER_PASSWORD (or --insecure).

Work with the model
-------------------

ask.sh
    Non-interactive prompt wrapper.

        ./scripts/ask.sh "List the files in /workspace"
        ./scripts/ask.sh --dir /some/path "Summarize this directory"
        ./scripts/ask.sh --json "Return a JSON object"

    Mounts the target dir at /workspace in the container and runs
    `opencode run --model deepseek/deepseek-flash`. Returns 0 if the model
    produced output, non-zero otherwise.

Work with chat logs
-------------------

chatlog.sh
    Manage the chat logs that live in the notes dir beside the repo (default
    ../notes).

        ./scripts/chatlog.sh list -l
        ./scripts/chatlog.sh search "no fail"
        ./scripts/chatlog.sh show <file>
        ./scripts/chatlog.sh summarize <file>
        ./scripts/chatlog.sh decisions <file>
        ./scripts/chatlog.sh todos <file>
        ./scripts/chatlog.sh ask <file> "What did we conclude about X?"
        ./scripts/chatlog.sh repo-ask "How is the Dockerfile structured?"

    The ask/summarize/decisions/todos/repo-ask subcommands mount the relevant
    dir into the container and pass a prompt naming the target file; no content
    is inlined.

Verify the repository
---------------------

test-repo.sh
    Eight gates verifying the repo is in its expected final state.

        ./scripts/test-repo.sh              report
        ./scripts/test-repo.sh --archive    archive one-shots first

    Report mode is read-only: G1 required binaries; G2 .env.local both keys +
    0600; G3 opencode.json parses + expected identifiers; G4 Dockerfile build
    directives; G5 repo root only expected entries; G6 operating scripts
    present; G7 one-shots archived; G8 doctor.sh passes end-to-end.

Host checks, repo gates and local helpers
-----------------------------------------

audit-config.sh
    Compare the actual deployment settings against an "expected" spec and
    surface every drift with a remediation hint. Read-only; a human table by
    default, or --json (for the :5099 dashboard).

gate-all.sh
    Every assert in one command (implements the agents contract): lint, hygiene,
    patterns, self-tests, yaml contract, backup freshness, cert coverage, secret
    scan, opencode.json, review-diff, recall smoke, pages export. Host-only
    asserts print SKIP with the exact host command instead of failing (RULES #37).
    Exit 0 no FAIL, 2 otherwise.

review-diff.sh
    Pre-push semantic review gate over the working-tree diff (deterministic file
    selection plus an LLM pass). Degrades to SKIP when the reviewer is not
    installed — never FAIL, because a missing optional tool must not block a
    push (RULES #37). Exit 0 clean or SKIP, 2 findings.

verify-password-drift.sh
    4-gate verification that OPENCODE_SERVER_PASSWORD handling is consistent
    across web.sh, .env.local and the running container.

apply-fstab-nofail.sh / verify-fstab-nofail.sh
    Add (apply) / report-and-apply (verify) the nofail and
    x-systemd.device-timeout options to the /mnt/nvme fstab entry, then confirm
    the generated systemd mount unit reflects the change.

test-tools.sh / watch-test-tools.sh / run-with-telemetry.sh
    Exercise every script in scripts/ and report pass/fail (test-tools.sh; --full
    adds the model round-trips and the grounded chatlog summarize); watch-test-tools.sh
    tails its status file and per-test logs; run-with-telemetry.sh runs
    test-tools.sh with the watcher active so the transition timeline is preserved.

tool-census.sh
    Print one line per agentic tool/model on this host (present + version, or
    MISSING) so a tool evaluation starts from fact, not memory. Offline,
    read-only, no egress, no installs.

audit-trees.sh
    Read-only entanglement audit across local checkouts: which trees exist,
    their repo/branch/HEAD, dirty worktrees, drifted duplicate files, and which
    tree the live containers serve. Never commits, pushes, restarts or removes.
    Exit 0 clean, 1 findings, 2 usage/tool error.

net-capture.sh / net-rst.sh / ssh-audit.sh
    Reset-forensics trio. net-capture.sh takes a bounded tcpdump capture (fixed
    filter, 10 MB rotate, logs/ only) after an mtr baseline; net-rst.sh lists
    every RST with timestamp/direction/ports from a PCAP (read-only); ssh-audit.sh
    reports the target's SSH banner and algorithm lists (no credentials, no auth
    attempts). All print SKIP with the exact install/run line when the host tool
    or capability (CAP_NET_RAW) is absent.

test-jev-laya-ab.sh
    A/B the same typed-decision payload through TypeSafe Jev and a self-hosted
    Laya server (Jev-API-compatible, POST /v1/systemone); diff the answers and
    report latency. Skips the diff with the exact start commands if Laya is not
    reachable.

laya-wire.sh
    Probe for a running Laya server (docker bridge gateway, loopback, host
    addresses) and point jev-guard at it: writes JEV_BASE_URL,
    JEV_GUARD_TIMEOUT_MS=2000, JEV_MODEL=english and an optional
    JEV_BASE_API_KEY, then restarts and verifies. Rejects loopback-only servers
    (the container cannot reach the host's 127.0.0.1). Does not install Laya.
    --wire · --url · --key · --json · --self-test.

laya-install.sh
    Install laya[serve] into $HOME/.venvs/laya (prefers 3.12/3.11/3.10 over 3.14
    for torch wheels), generate a bearer key, run laya-serve as a systemd user
    unit bound to the docker bridge gateway, preload the English checkpoint,
    probe up to 4 minutes, then call laya-wire.sh --wire. Host-only.
    --port · --device · --gateway · --no-systemd.

decision-router.py
    Redundant System One router: Laya (local, free) and SubQ (remote, paid)
    both speak POST /v1/systemone, so one JEV_BASE_URL can fail over. Chooses
    by rolling reliability (observability.db), circuit state, and cost per 1M
    input tokens; records every attempt in decision_route; exposes /healthz and
    /stats. --serve · --explain · --self-test.

decision-router-install.sh
    Install decision-router.py as a systemd user unit bound to the docker
    bridge, with Laya/SubQ keys in a 0600 env file, then point jev-guard at the
    router (JEV_BASE_URL, 4 s guard timeout) and verify. Host-only.
    --port · --gateway · --no-wire · --uninstall · --self-test.

code-index.py
    Assemble, index and flag the repo's own code into data/observability/code.db
    (per-file metadata, top-level symbols, blacklist patterns, TODO/FIXME) so
    the code sits beside the chat DB. Free, local, read-only over the repo.
    --flags · --list · --grep REGEX · --json · --self-test.

recall-sessions.py
    Hermes-style keyword recall over opencode sessions (read-only, sqlite
    mode=ro): searches session titles first, then message bodies, printing
    id + directory + title + updated time as provenance.
    python3 scripts/recall-sessions.py <keyword> [--limit N]

repo-mcp.mjs
    Minimal MCP (stdio) wrapper over the repo's read-only tools
    (probe_status, recall_sessions, findings, cost) so any agent calls them as
    tools instead of pasted shell. No dependencies (Node 22). Add to
    opencode.json mcp.servers.  node scripts/repo-mcp.mjs

ocr-tesseractjs.mjs
    Local OCR via tesseract.js (WASM) — no apt/pip/API; the same engine as
    receipts-ocr's browser side. Downscales oversized images before OCR so very
    tall screenshots don't stall the detector.
    node scripts/ocr-tesseractjs.mjs <image> [lang] · --self-test

png-shrink.mjs
    Downscale a PNG to a byte budget (box filter, opaque RGB) using the
    repo-pinned pngjs (no apt/pip). Overwrites the input file.
    node scripts/png-shrink.mjs <file.png> [scale=0.75] [budget=153600]

pwa-icons.mjs
    Regenerate the 192/512 Android/PWA icons from the activity-bar mark using
    the repo-pinned pngjs. The manifest and /sw.js are served by dashboard.sh;
    Android installability also needs HTTPS with a trusted local CA.
    node scripts/pwa-icons.mjs

ux.sh
    One router for the web-probe workflow (a single verb table shared by
    interactive and unattended runs; mirrors agents/probe.yaml in order).
    Run on the host.  bash scripts/ux.sh help · bash scripts/ux.sh status

ux-findings.sh
    Guided :5099 findings control (no dashboard spelunking): fetches /api/health
    and translates each finding into plain language — what it means, whether you
    should care, and the scripted action. Reports the standout positives
    (cost, balance, rev currency, counts) too.

probe-diagnose.sh
    Scripted probe telemetry, no manual typing: sources .env.local (never prints
    it), runs the probe, then reports verdict/counts/reasons + screenshot sizes
    + live DOM markers, and prints the deterministic next action. Host; exit 0
    PASS, 2 FAIL.

hotspot-test.sh
    Phased network-change test for a client that switches to a mobile hotspot
    (the 10.100.0.1 -> phone case). Run ON THE CLIENT. --before records a
    baseline (overlay, LAN control, DNS, address signature); --after settles up
    to 20s for a re-handshake, then asserts a required overlay is reachable
    (default: Nebula OR Tailscale; --require mesh|tailscale pins it), the LAN
    control dropped (or stayed reachable on the same network), DNS resolves, and
    runs client-setup.sh --heal + --check; --auto runs before/prompt/after;
    --watch re-runs on an address change; --json machine summary. When this box
    is the Nebula lighthouse (10.100.0.1) and Nebula dies, it explains that
    moving the lighthouse behind CGNAT removes the inbound UDP anchor
    (TUNNEL-1), so Tailscale is the fallback. Optional ROAM_SSH_HOST proves SSH
    X11 forwarding still yields a DISPLAY. --self-test offline (fake seams).
    Exit 0 PASS, 2 FAIL, 3 cannot run. Gated in test-hygiene.sh.

hotspot-reconnect.sh
    Detect a lost hotspot/underlay, alert BOTH ends, and guide an interactive
    reconnect. Client: --check (one probe; 0 up, 2 down), --watch (debounced
    detect + bell/banner/notify + guidance), --watch --reconnect (try the saved
    profile/SSID in order, settle, then client-setup --heal and print `ssh -t`),
    --plan, --json, --self-test. HOTSPOT_SERVER_SSH also appends to the server
    alert log (+ wall); when the server is unreachable the line is queued and
    flushed on reconnect so both logs agree. Server: --server --watch alerts the
    server console when the client overlay (CLIENT_MESH_IP) disappears/returns.
    2026-11-10 UX: --watch hides the per-tick table (use --verbose), resolves
    DBUS_SESSION_BUS_ADDRESS from /run/user/$UID/bus, sets DISPLAY=:0 on an X11
    seat when missing, and reports a broken notification channel ONCE (not every
    tick). --no-bell / --quiet-terminal are the explicit escapes; --quiet still
    means "silence notifications". --notify-check prints the DBus/DISPLAY/daemon
     diagnosis; --notify-remote USER@HOST sends the popup over SSH into the
     CLIENT's own X11 session (the server's daemon displays on the server, not the
     client); --notify-test shows the popup with live buttons; --clear-notify
     withdraws a stale one. Server probe: a successful SSH (HOTSPOT_CLIENT_SSH) or
     Tailscale pong counts as connected before the optional :5099 port. Buttons:
     open dashboard, run check (state/link/beacon evidence), silence 1 h, dismiss
     (HOTSPOT_DISMISS_SEC, cleared on recovery), reconnect (queues + confirms),
     Fix Wi-Fi (wl) (Apply/Cancel confirmation for wifi-durable-fix.sh).
     Distinct from hotspot-test.sh: that proves a switch after the fact;
     this one watches live, alerts, and reconnects. Exit 0 up, 2 down/failed, 3
     cannot run / unsafe input. Gated in test-hygiene.sh.

wifi-durable-fix.sh
    Replace the reverse-engineered b43 driver with the vendor Broadcom wl
    driver (akmod-wl/kmod-wl), reversibly, on Fedora. --check (read-only:
    distro/kernel/driver/RPMFusion/wl availability; --json), --plan, --apply
    (RPMFusion if missing, install, blacklist b43/bcma/ssb, dracut -f, install
    and enable wifi-durable-guard.service, reboot in WIFIDF_REBOOT_DELAY),
    --rollback (remove boot config, modprobe b43, restart NetworkManager,
    optional --purge), --recover-now (stop/disable the guard, restore b43, no
    reboot), --status, --guard-check, --self-test (offline temp root with
    fakes). Auto-recovery: the guard unit runs at boot while phase is
    awaiting-reboot; if wl is not loaded and no Wi-Fi is connected within
    WIFIDF_GUARD_WAIT (600 s), it runs --rollback and reboots, restoring b43.
    The apply writes a hard boot config (`install b43 /bin/false`,
    `force_drivers+=" wl "`, omit b43/bcma/ssb/brcmsmac, modules-load wl)
    because `blacklist b43` alone did not stop b43 from binding on 2026-11-10.
    On BCM4331 the final attempt loaded wlp2s0 but never associated; --check
    now reports known_bad=yes / actionable=no and --apply refuses unless
    WIFIDF_FORCE=1. Use a USB WiFi adapter with an in-kernel driver or
    USB/Thunderbolt Ethernet for the durable fix.
    The apply also
    sets the NM connection zone (WIFIDF_NM_ZONE=trusted) and the guard adds the
    live wl interface to that zone, because the driver renames the interface and
    firewalld zone bindings are per-interface; success requires Layer 3 (a ping
    to the default gateway), not just wl+NM state. The
    hotspot notification's "Fix Wi-Fi (wl)" button opens an Apply/Cancel
    confirmation; Apply runs this detached. Gated in test-hygiene.sh.

wifi-ab-benchmark.sh
    A/B/A benchmark for the BCM4331/b43 2.4 GHz path. No Wi-Fi restart: it
    toggles Bluetooth (rfkill) A1-on/B-off/A2-on and measures per phase
    beacon-loss delta, tx-failed/rx-drop delta, ping loss/latency to
    --target, signal, and tx/rx bitrate. Verdict distinguishes BT-coexistence
    from inconclusive. --duration SEC (default 20; use 300+ for a real A/B),
    --json, --self-test offline. Needs rfkill + passwordless sudo on the
    client. Gated in test-hygiene.sh.

hardware-profiles.json
    Native hardware registry. Maps PCI IDs to name/driver/bands/known_bad_wl/
    tunables/mitigations. wifi-link-forensics.sh embeds the same key (14e4:4331
    -> Broadcom BCM4331, b43, 2.4GHz, known_bad_wl=yes) so --json reports
    hardware/pci/known_bad_wl/firmware/btcoex/qos/nohwcrypt/bluetooth.

b43-tune.sh
    Apply/revert the BCM4331/b43 2.4 GHz mitigations: `options b43 btcoex=0`,
    pin the NM connection to one 2.4 GHz BSSID (`802-11-wireless.bssid`),
    `band bg`, powersave off. --check (--json), --apply, --apply --reload
    (brief Wi-Fi drop; snapshots the old btcoex and auto-restores if no Wi-Fi
    within B43TUNE_UP_SEC), --rollback. Reversible. Gated in test-hygiene.sh.

bluetooth-off.sh
    Power off the Bluetooth RADIO (not just the service) and keep it off:
    `rfkill block bluetooth` + /etc/systemd/system/bluetooth-off.service
    (ExecStart=rfkill block bluetooth, WantedBy=multi-user.target). --check
    (--json), --apply, --rollback, --self-test. Needed because the radio stays
    powered even when bluetooth.service is disabled/masked, so b43 btcoex=1
    (and iwlwifi bt_coex) still run coexistence. Gated in test-hygiene.sh.

host-cert-sign.sh
    Re-sign this host's SSH host certificate with the principal clients actually
    use. --check lists the mesh CA files + current principals; --sign backs up
    the cert, runs ssh-keygen -s with HOSTCERT_PRINCIPALS (default
    fedora,fedora.local,10.100.0.1,192.168.4.45,100.70.43.78), and restarts
    sshd; --rollback restores the newest pre-rotate cert. The CA private key
    never leaves the host. Fixes "Certificate invalid: name is not a listed
    principal" for 10.100.0.1. Gated in test-hygiene.sh.

peer-health.sh
    One evidence-backed verdict for "is the peer down, and why?". Probes ICMP,
    SSH, TCP :5099/:4096, and Tailscale; separates REACHABILITY (state:
    healthy/degraded/down) from LINK QUALITY (link: clean/lossy, reason) using
    the peer's own wifi-link-forensics JSON. Hysteresis: --fail-threshold
    (default 3) consecutive misses before down/degraded, --recover-threshold
    (default 2) successes before healthy. Writes data/observability/peer-health.json
    (ts, state, raw, consecutive, since, incident_id, link, checks, evidence) as
    the shared source of truth for hotspot-reconnect.sh and any dashboard.
    --explain prints why (checks + evidence + conclusion), --json machine
    contract, --watch SEC print on change, --self-test offline. Exit 0 healthy,
    2 down/degraded, 3 cannot run. Gated in test-hygiene.sh.

wifi-link-forensics.sh
    Prove WHY a Wi-Fi link stalls, from the logs on BOTH ends, then apply the
    safe fixes. Local run reads driver, band, signal, powersave, the 5GHz
    capability, and counts wpa_supplicant BEACON-LOSS, deauth/firmware reloads,
    NetworkManager deactivations, Tailscale path changes, and DNS-commit
    failures over --since HOURS. --peer USER@HOST re-runs the same script on the
    other machine over SSH (stdin; nothing to install). Verdicts: beacon-loss,
    powersave-on, driver-b43, 2.4-only, path-flap, dns-commit-failure, stable.
    --fix disables powersave now and persists wifi.powersave=2 for
    NetworkManager; --dry-run prints the commands without changing anything.
    --json machine contract; --self-test offline. Exit 0 healthy, 2 link-layer
    cause proven, 3 cannot run. Gated in test-hygiene.sh.

terminal-reset.sh
    Clear leaked SGR mouse reports (the ESC[<b;x;yM tail shows as
    `35;55;16M35;55;16M...`) and a leftover alt-screen after a crashed or
    aborted TUI. Default: mouse-off + `stty sane` + `reset`. --soft emits only
    the invisible mouse/alt/cursor sequences; --install writes an idempotent,
    guarded ~/.bashrc block (interactive shells only) so the next shell
    self-heals; --uninstall removes it; --print emits the shell printf command;
    --self-test offline. client-setup runs --install in setup mode. Exit 0 ok,
    2 usage. Gated in test-hygiene.sh.

host-path-probe.sh
    Break down the :5099/:4096 hop (dns -> connect -> tls -> ttfb -> total)
    against the host URL and the loopback, repeatedly, and name the dominant
    phase. Run on the host.
    ./scripts/host-path-probe.sh [--url URL] [--n N]

ports-forward-audit.sh
    Deduce the best steps to expose :4096/:5099 off-LAN (read-only; prints a
    verdict + next commands). Firewall changes live in the eero phone app.
    Run on the host.

verify-caddy-audit.sh
    Scripted Caddy access-plane verification: container Running (not merely
    Created), published bindings on 4096/5099, access-log lines for the session
    referer + /global/event SSE outcomes, and absence of 401/403 denials.
    Host; exit 0 all-green, 2 otherwise.

enable-lan-cert.sh
    LAN path for TLS: IP SAN + caddy reload + trust + verify. Idempotent; no
    port forwarding needed (eero/phone-app untouched). Run on the host.

certs-verify.sh
    The TLS verification battery as code (everything once typed by hand during
    the BAD_CERT_DOMAIN incident, now one command) — served fingerprint == file
    fingerprint, chain/SAN/expiry, etc. --playwright adds the browser check.
    Exit 0 only if all pass.

verify-loads.sh
    Confirm post-recreate loads on the .24 host: litellm config accepted
    (fallbacks live, no config error), opencode-web picked up the repo MCP server
    + wizard skill, and the models endpoint answers. Read-only. Host.

dns-audit.sh
    Read-only DNS-forensics collector (sections A-C). Run on the FAILING box,
    paste all output back. Changes nothing: no restarts, no writes outside
    /tmp/opencode-dns.txt.

audit-a1286-network.sh
    Read-only MacBookPro A1286/A1278 / Fedora 43 / X11-XFCE network-loss forensics.
    Run on the failing box (after a reboot it still reads the previous boot).
    Prints ranked cause candidates - route/DHCP, rfkill, association, wl/
    brcmsmac, NetworkManager polkit/keyring, powersave - then the raw capture.

dns-guard.sh
    Automated DNS-recovery-loop telemetry (detection always, remediation only
    with --fix), using the ledger DB as the durable record so the next occurrence
    is a lookup, not a fresh investigation.

web-logs.sh / web-stop.sh
    Show the opencode-web container logs (-f follows) / stop the OpenCode web UI
    container. cd into docker/ first so `docker compose` finds its config.

Recovery, triage, handoff
-------------------------

09-refresh-handoff.sh
    Rebuild the CURRENT session transcript from opencode.db (no browser),
    regenerate the redacted handoff brief, and print the rotation sequence.
    Deterministic: no model call, no spend, no fork/continue.

incident-resolve.sh
    Classify recurring log signatures (tmux no-server, already-paused,
    embedding cold-load, pgrep >15, pubkey denial, guard blocks, stale
    edits) from a file, stdin, or --db; --auto resolves the safe ones.
    Self-test: ./scripts/incident-resolve.sh --self-test

triage-dirty.sh
    Classify working-tree changes: syntax, secret-scan, reference count,
    bucket, and recommendation (COMMIT/ARCHIVE/REVIEW/FIX). Exit 1 on a
    failed syntax or secret check. --staged checks only the index.

Archive
-------

archive/
    one-shot/             migration, prune, diagnose scripts
    forensics/            recovery tools from the container-loss incident
    logs/                 log files from the archived scripts
    stage-opencode-repo/  historical staging script versions
    migration-notes.txt   the Docker data-root migration record

Paths used by the tools
-----------------------

  repo root       resolved from the script's own location
  notes           sibling dir of repo; override with --dir or CHATLOG_DIR
  docker image    opencode-deepseek-jev:robust
  model           opencode-go/deepseek-v4.1-flash
  opencode.json   at repo root
  .env.local      at repo root, mode 0600, gitignored

Scripting conventions
---------------------

Every operation that can be typed is scripted, under scripts/ or
scripts/archive/one-shot/. Nothing lives only in /tmp or only in a transcript.

A response that emits multiple files does so through one script, each file via
a heredoc; the recipient pastes the whole script once. Prose comes before or
after the script, never between heredocs — the shell reads a heredoc from its
opening marker to the matching delimiter at column zero, so interleaving breaks
pasteability silently. Use a distinct delimiter per nesting level (SCRIPT_EOF,
PATCH_EOF, WATCH_EOF), on a line of its own with no leading whitespace.

  POSIX here-documents:
    https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
  Bash here-documents:
    https://www.gnu.org/software/bash/manual/html_node/Here-Documents.html
  Raymond, "The Art of Unix Programming", AW, 2003, §1.6.2 "Rule of Clarity".
