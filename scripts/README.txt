scripts/ — operating scripts for the OpenCode + DeepSeek + Jev environment
===========================================================================

Two tools run the environment. Two more manage the workflow.

Operate the environment
-----------------------

deploy-dockge.sh
    Start the Dockge web UI on http://localhost:5001. Idempotent.
    Dockge manages every compose stack discovered under
    $HOME/dockge-stacks.

flatten-dockge-stacks.sh
    Refresh the flat symlink directory at $HOME/dockge-stacks. Run after
    adding a new docker-compose.yml under $HOME/Documents. Dockge scans
    that directory non-recursively, so new projects need this step.

Check the environment
---------------------

doctor.sh
    Ordered health check: binaries, docker daemon, keys, provider
    liveness, image presence, and an end-to-end model round-trip.
    Fast mode (no arguments) is free.
    --full adds plugin/MCP checks, a live model call (~$1e-4), a
    Jev functional proof (Tier 9, invokes jev_review for real), and the
    repo gates (Tier 10: test-hygiene + test-patterns, both local).

    Exit 0 on success, non-zero on failure. The output is the diagnostic.

Monitor cost and activity
-------------------------

cost.sh
    DeepSeek cost accounting: totals from the opencode database (sessions,
    USD cost, input/output/reasoning/cache tokens), the DeepSeek balance
    endpoint, and a Jev usage count (jev_review invocations; TypeSafe has
    no public balance API). Reads DEEPSEEK_API_KEY from .env.local; never
    prints it. Works on the host and in the container.
    --estimate IN OUT [REASONING] projects the cost of a planned run
    using your effective blended $/token rate.

dashboard.sh
    Thin read-only observability sidecar. Serves cost cards, live activity
    (step/tool/reasoning/text), and todos on http://127.0.0.1:5099
    (DASH_PORT/DASH_HOST override). Reads the database read-only; no
    docker, no external deps. Runs on the host or in the container.
    Sessions are clickable: /api/session?id= returns the detail + parts,
    and /api/export/session?id=&format=txt|md|json downloads one session's
    chat history. /api/search?q= searches titles, text, and commands.
    /explore (alias /viz) is the visual layer: a cost treemap, a brushable
    cumulative-spend-vs-budget burn-down (linked views), a latency x cost
    scatter, and the part timeline. d3 is vendored at
    scripts/vendor/d3.min.js and served at /vendor/d3.min.js.
    /runbooks renders the operational runbooks; /api/runbooks is the data.

cost-bottlenecks.sh
    Ranks where API cost goes: totals + effective $/1k-input, top sessions
    by cost and by input tokens (context is the cost driver), worst
    effective $/1k-input, the fixed overhead of tiny sessions, and a
    per-model breakdown. Read-only; host or container. --top N.

semantic-search.sh
    Ranked full-text search across every session (SQLite FTS5/bm25) over
    text, reasoning, and tool commands. Persists an index at
    data/search/opencode-index.db (gitignored); the dashboard builds the
    same index in memory for /api/semantic. --rebuild rebuilds; --limit N
    caps results. Host or container.

ocr-image.sh
    Local OCR fallback for reading screenshots/scans when API models can't
    ingest images. Tries tesseract CLI (apt, in the image), then
    tesseract.js (npm, pinned in package.json), then PaddleOCR (pip).
    Persists each run to data/observability/ocr_run (surfaced at /api/ocr,
    /api/export/ocr, and searchable via /api/semantic).
    Usage: ./scripts/ocr-image.sh <image> [lang] | --check. Host or
    container; no API model required.

lint.sh
    Static gate: bash -n on every script, shellcheck (optional), node
    --check on JS, py_compile on Python, a subprocess.run check, a
    scan-constraints.py pass over scripts/*.sh (code vs string/comment),
    and a RULES grep (no sed, no 2>/dev/null). Exits non-zero on any
    failure; also run by test-dashboard.sh.

scan-constraints.py
    Classifier-backed scan of shell scripts for the blacklist (sed,
    2>/dev/null, rm -rf, set -e, exit 1, subprocess.run, bare kill),
    reporting each match as code / string / comment and failing only on
    code. lint.sh runs it on scripts/*.sh (archive excluded).

audit-tool-calls.py
    Audits the agent's OWN runtime tool calls (not files) for the same
    blacklist, read-only from data/opencode/opencode.db: every tool call
    is a part row whose data.state.input.command holds the command. Strips
    quoted regions so `grep 'sed'` is not counted as `sed`. Prints counts,
    sessions, samples and the sanctioned substitute (see RULES.md
    "Substitutions for the blacklist"). --recent N, --json, --fail.

prompt-lint.py
    Fuzzy classifier + preference linter for user prompts. Reads the DB
    read-only and the repo's own preference sources (RULES.md, HANDOFF.md,
    README.txt, opencode.json) to (1) classify the prompt into a repo topic,
    (2) fuzzy-match it against past user prompts (token Jaccard) so a
    repeated request is visible before it is answered again, (3) surface
    recurring error tool calls, and (4) flag blacklisted-tool mentions,
    leaked secrets, underspecified asks and missing acceptance criteria.
    Advisory; --last lints the latest prompt in the DB, --fail gates.

issue-solutions.py
    Mine the chat database for recurring errors and the command that fixed
    each, proven by the logs. Pairs an error tool call (state.status='error')
    with the next completed call in the same session, normalises the error
    into a signature, and ranks the (issue, fix) pairs. Free, local, no
    model call; read-only over data/opencode/opencode.db. --recent N,
    --top N, --json, --write (persists data/observability/solutions.json for
    the /api/solutions endpoint and the "known fixes" list on /explore),
    --self-test.

logs.sh
    Aggregate actionable telemetry, local and read-only. Sources: guard
    (data/observability/guard.log — every blacklist block/fix/warn the
    agent's "Thinking" triggered), error (opencode.db tool failures with the
    stack-trace text), event (the opencode event bus), app (~/.local/share/
    opencode/log/opencode.log), system (docker logs of opencode-web; host
    only), packet (the exact tcpdump command; not run). --source S,
    --since MIN, --tail N, --grep RE.

harness.sh
    One command for the whole state. Runs every gate (lint, test-hygiene,
    test-patterns, test-dashboard), then the live telemetry, the cost
    headline and the TODO "in flight" list, and prints a summary. --fast
    skips the slow dashboard gate; --export writes logs/harness-<UTC>.md;
    --json emits ONLY {ts,rev,passed,failed,gates[]} for a wrapper.
    Robust: a failing gate is reported and the run continues; a missing gate
    is SKIP, not pass. Exits non-zero only if a gate failed. Records
    data/observability/last-gate.json for preflight.sh.

preflight.sh
    Fail-closed spend gate. Refuses (exit 1) unless: the repo and database
    exist, .env.local has all three keys, the last harness.sh gate run passed,
    the DeepSeek balance is >= MIN_BALANCE ($1.00 default), and the model is
    deepseek-flash (config and last session). --json for a wrapper/plugin;
    --allow-pro skips the model checks. Run it before any paid session.

learn-rules.py
    Contrastive corpus learning. From the tool-call log it builds (state,
    action, outcome) triples — the error signature, the shape of the next
    call, and whether it completed — and emits advisory avoid / prefer /
    recovery rules to data/observability/learned-rules.json. The guard reads
    those and records 'learned' advisories; nothing is blocked until a human
    promotes a confirmed pattern into RULES.md / the fixed blacklist.
    --since-days N bounds the window (a rotated key must not be enforced
    forever); --write persists; --self-test.

models.sh / models.py
    Model catalog + cost policy. models.sh wraps `opencode models --verbose`
    and pipes it to models.py, which applies models.policy.json
    (max_input_per_m_usd, allow, deny; free models always pass) and returns
    ALLOW / ASK / BLOCK for the current model, with a recommendation and the
    cheaper alternatives. --json machine output; --write persists
    data/observability/models.json for the /models UI page. preflight.sh uses
    the verdict; nothing hard-codes a single model name.

doc-budget.sh
    Measure the read-first doc corpus (RULES, TODO, README, HANDOFF, DESIGN,
    scripts/README, skills) in tokens (~bytes/4), compare to DOC_BUDGET_TOKENS
    (default 35000), and record a content hash + sizes to
    data/observability/docs.json. An unchanged hash means nothing new to
    re-learn (the ECC context-budget / content-hash-cache pattern). --json;
    --fail exits 1 when over budget.

test-tooling.sh
    Contract test for the harness tooling's machine interfaces. Proves every
    tool that advertises --json emits parseable JSON with the keys a wrapper
    reads (preflight, doc-budget, learn-rules, issue-solutions,
    audit-tool-calls, prompt-lint --last, models --catalog) plus logs.sh.
    Never calls harness.sh (would recurse), so it is safe from test-hygiene.

ux-audit.py
    Host-side Playwright UX audit of /explore: reports page height vs
    viewport, panel/tab counts, tab toggle, and page errors, then writes a
    full-page screenshot to logs/ux/. Needs playwright on the host (the
    container has no browser).

ux-test.py
    Host-side Playwright UX TEST (assertions, not just a report). For each
    page (/, /explore, /runbooks, /models, /docs) it asserts: no console
    errors, no horizontal scroll at 390px, not an unscrollable wall, and on
    /explore that every tab toggles its pane and the overview stays compact.
    Exits non-zero on failure. If playwright is absent it prints SKIP (not a
    pass) and exits 0. --check reports playwright/chromium/server readiness
    with the exact install commands. Screenshots to logs/ux/. There is a
    "ux-test" runbook (host) so it is one copy-paste away.

runbook.sh
    Host-side multiple-choice runner for the runbooks shown at
    /runbooks on the dashboard. Reads the same scripts/runbooks.json the
    dashboard serves, so the two never drift. No args = interactive menu;
    --list = id|where|title; run <id> = one runbook. Runbooks flagged
    "manual" (browser steps, long-running servers, secrets edits) are
    displayed but not executed.

test-dashboard.sh
    End-to-end gate for dashboard.mjs: starts it on a scratch port and
    asserts the served HTML, the /api/* payloads, and that the inline
    browser script on BOTH / and /runbooks parses (node --check). It then
    runs test-dashboard-ui.mjs, which executes the page script in a minimal
    DOM and asserts the panes populate. Together these catch escape
    regressions and runtime client bugs that a substring grep misses.
    Exits non-zero on any failed assert.

test-dashboard-ui.mjs
    Headless execution test: fetches the served / page, runs its inline
    <script> in a minimal DOM shim against the live server, fires the
    interval refreshers once, and asserts #session/#stats/#sessions/
    #activity/#config populate. No browser required.

thinking.sh
    Live view of what the agent is doing while "thinking". Tails the
    opencode database and prints step boundaries, tool calls (with state
    and command), reasoning text, and answer text as they are written.
    Polls every 2s by default (THINKING_POLL=1 for 1s).

test-patterns.sh
    Read-only proof of the tool-sequence substrate behind the "patterns
    view (tool-sequence n-grams)" candidate. Opens the opencode database
    read-only and asserts that tool calls are recoverable as ordered
    per-session sequences and countable as n-grams (lead() window query):
    tool parts, distinct tools, >=1 bigram, and the error-tool share.
    Exits non-zero unless the tool-use method is real. Host or container;
    no writes to the database.

test-jev-functional.sh
    Behavioral Jev proof: invokes the jev-review MCP tool and fails
    (non-zero) unless it fires and returns an applicable metric with a
    score. Host-side; also run by doctor.sh --full as Tier 9.

cleanup-baks.sh
    List or remove the *.bak.* snapshot files that accumulate during
    script iteration (including stale .env.local.bak.* key backups).
    List-only by default; --apply gitignores *.bak.* and removes them.

web.sh
    Starts the web UI on port 4096. Requires OPENCODE_SERVER_PASSWORD;
    refuses to start an unauthenticated server unless --insecure is
    passed.

verify-from-inside.sh
    In-container self-check (no docker): opencode binary, auth.json,
    key env vars, opencode.json parse, jev-review server.js. --full adds
    a live "PONG" round-trip. Counterpart to the host-side
    verify-api-keys.sh.

test-sidebar-streaming.sh
    Regression test that a session appears in the sidebar while it is
    processing: opens the /api/event SSE stream, triggers a real session,
    and asserts session.created + message.updated events are emitted.
    Host-side; requires OPENCODE_SERVER_PASSWORD (or --insecure).

Work with the model
-------------------

ask.sh
    Non-interactive prompt wrapper.

        ./scripts/ask.sh "List the files in /workspace"
        ./scripts/ask.sh --dir /some/path "Summarize this directory"
        ./scripts/ask.sh --json "Return a JSON object"

    Mounts the target directory at /workspace inside the container and
    runs `opencode run --model deepseek/deepseek-flash`. Returns 0 if
    the model produced any output, non-zero otherwise.

Work with chat logs
-------------------

chatlog.sh
    Manage the chat logs that live in the notes directory beside the
    repo. Default location is ../notes relative to this script.

        ./scripts/chatlog.sh list -l
        ./scripts/chatlog.sh search "no fail"
        ./scripts/chatlog.sh show <file>
        ./scripts/chatlog.sh summarize <file>
        ./scripts/chatlog.sh decisions <file>
        ./scripts/chatlog.sh todos <file>
        ./scripts/chatlog.sh ask <file> "What did we conclude about X?"
        ./scripts/chatlog.sh repo-ask "How is the Dockerfile structured?"

    The ask/summarize/decisions/todos/repo-ask subcommands mount the
    relevant directory into the opencode container and pass a prompt
    that names the target file. The model reads the file via its own
    file access. No content is inlined into the prompt.

Verify the repository
---------------------

test-repo.sh
    Eight gates verifying the repository is in its expected final
    state and that the environment it describes is functional.

        ./scripts/test-repo.sh              report
        ./scripts/test-repo.sh --archive    archive one-shots first

    Report mode is read-only. It checks:
      G1  required binaries
      G2  .env.local with both keys, mode 0600
      G3  opencode.json parses and references the expected identifiers
      G4  docker/Dockerfile contains the expected build directives
      G5  repo root contains only expected entries
      G6  operating scripts present
      G7  one-shot scripts archived
      G8  doctor.sh passes end-to-end

Archive
-------

archive/
    one-shot/           migration, prune, diagnose scripts
    forensics/          recovery tools from the container-loss incident
    logs/               log files from the archived scripts
    stage-opencode-repo/  historical staging script versions
    migration-notes.txt   the Docker data-root migration record

Paths used by the tools
-----------------------

  repo root       resolved from the script's own location
  notes           sibling directory of repo, override with --dir or
                  CHATLOG_DIR
  docker image    opencode-deepseek-jev:robust
  model           deepseek/deepseek-flash
  opencode.json   at repo root
  .env.local      at repo root, mode 0600, gitignored

Scripting conventions
---------------------

Every operation that can be typed is scripted. Scripts live in the repo
under scripts/ or scripts/archive/one-shot/. Nothing lives only in /tmp
and nothing lives only in a chat transcript.

A response that emits multiple files does so through one script. That
script creates each file via a heredoc. The recipient pastes the whole
script once. Prose, if any, comes before the script or after it, never
between heredocs.

Rationale: the shell reads a heredoc from its opening marker to the
matching closing delimiter at column zero. Any text between the marker
and the delimiter becomes file content. Any heredoc whose closing
delimiter is not at column zero is unterminated and the entire input is
discarded. Interleaving breaks pasteability silently.

  POSIX shell, here-documents:
    https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
  Bash manual, here-documents:
    https://www.gnu.org/software/bash/manual/html_node/Here-Documents.html

  Raymond, "The Art of Unix Programming", Addison-Wesley, 2003,
  ISBN-13: 978-0131429017, §1.6.2 "Rule of Clarity": complexity is a
  cost; a pasteable script is a clear interface.

Indent control
--------------

When writing a heredoc whose content is itself a shell script, avoid
closing the outer heredoc with a delimiter that also appears inside the
inner script. Use a distinct delimiter per nesting level, e.g.
SCRIPT_EOF, PATCH_EOF, WATCH_EOF. The delimiter must appear on a line
of its own with no leading whitespace.
