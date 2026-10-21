scripts/ — operating scripts for the OpenCode + DeepSeek + Jev environment
===========================================================================

Two tools run the environment; two more manage the workflow. One entry per
script: what it does, its flags/seams, and any gate. Conventions + paths are
at the end.

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
    live activity + todos; /api/session?id= (detail + parts) and
    /api/export/session?id=&format=txt|md|json (redacted); /api/search.
    /api/health is CACHED (HEALTH_TTL_MS 15s): ~7s of sync aggregation that
    would otherwise block every other request in the single Node process.
    /explore (alias /viz): cost treemap, brushable burn-down, latency×cost
    scatter, part timeline, bigram pivot (d3 + Observable Plot vendored under
    scripts/vendor/). /runbooks renders the runbooks (/api/runbooks is data).

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
    to start an unauthenticated server unless --insecure.

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
    --env, --self-test (incl. checkpoint/resume).

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
    Roaming test from a hotspot-tethered client: proves the overlay URLs survive
    a LAN switch that kills LAN-bound URLs. Run on the roaming box; read-only
    except a fresh /tmp Chrome CDP profile. Exit 0 all-green, 2 otherwise.

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

dns-guard.sh
    Automated DNS-recovery-loop telemetry (detection always, remediation only
    with --fix), using the ledger DB as the durable record so the next occurrence
    is a lookup, not a fresh investigation.

web-logs.sh / web-stop.sh
    Show the opencode-web container logs (-f follows) / stop the OpenCode web UI
    container. cd into docker/ first so `docker compose` finds its config.

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
