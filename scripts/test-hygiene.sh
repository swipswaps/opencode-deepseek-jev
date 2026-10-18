#!/usr/bin/env bash
#
# test-hygiene.sh — gate for the blacklist tooling and the prompt linter.
#
#   scan-constraints.py   file-level blacklist scan is clean on scripts/*.sh
#   audit-tool-calls.py   reads the DB, emits valid JSON, matches its schema
#   prompt-lint.py        flags a known-bad prompt, passes a clean one,
#                         fuzzy-matches the latest prompt in the DB
#
# These are the tools that surface persisting mistakes (blacklisted runtime
# commands) and lint user prompts against known preferences. This gate proves
# they run and discriminate; it does NOT fail on runtime blacklist hits (the
# agent's echo/sed usage is reported, not enforced, until the model is clean).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

PASS=0
FAIL=0

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- diagnostic telemetry: ms= on every check line (see lint.sh) ---------
now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -z "$t" ]; then printf '%s000' "$(date +%s)"; return; fi
    local s="${t%%.*}" us="${t#*.}"
    [ -n "$us" ] || us=0
    printf '%d' "$(( s * 1000 + 10#${us:0:3} ))"
}
LAST_MS=$(now_ms)
SLOW_MS=0
SLOW_MSG=""
_stamp() {
    local n
    n=$(now_ms)
    D=$((n - LAST_MS))
    LAST_MS=$n
    if [ "$D" -gt "$SLOW_MS" ]; then SLOW_MS=$D; SLOW_MSG="$1"; fi
}
ok()  { PASS=$((PASS+1)); _stamp "$1"; printf 'ts=%s ms=%s level=INFO  status=PASS msg=%s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }
bad() { FAIL=$((FAIL+1)); _stamp "$1"; printf 'ts=%s ms=%s level=ERROR status=FAIL msg=%s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    if ! have python3; then
        printf 'FAIL: python3 required\n'
        return 1
    fi

    local db="$REPO/data/opencode/opencode.db"
    local work
    work=$(mktemp -d)

    printf '=== test-hygiene.sh ===\n'

    if python3 "$REPO/scripts/scan-constraints.py" "$REPO/scripts" \
            --exclude-dir archive --include '*.sh' --quiet > "$work/sc.txt" 2>&1; then
        ok 'scan-constraints: scripts/*.sh clean (code-level)'
    else
        bad 'scan-constraints: scripts/*.sh clean (code-level)'
        tail -6 "$work/sc.txt"
    fi

    if "$REPO/scripts/media-budget.sh" > "$work/mb.txt" 2>&1; then
        ok 'media-budget: tracked media within budget'
    else
        bad 'media-budget: tracked media within budget'
        tail -6 "$work/mb.txt"
    fi

    local fixdb=""
    if [ -x "$REPO/scripts/test-fixture-db.sh" ]; then
        fixdb="$work/live.db"
        "$REPO/scripts/test-fixture-db.sh" --out "$fixdb" > /dev/null 2>&1 || fixdb=""
    fi

    if [ -f "$db" ]; then
        if python3 "$REPO/scripts/audit-tool-calls.py" --db "${fixdb:-$db}" --json > "$work/atc.json" 2>&1; then
            ok 'audit-tool-calls: runs'
        else
            bad 'audit-tool-calls: runs'
            tail -6 "$work/atc.json"
        fi
        if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "blacklist_hits" in d and "patterns" in d and "tool_calls_scanned" in d' "$work/atc.json"; then
            ok 'audit-tool-calls: JSON schema'
        else
            bad 'audit-tool-calls: JSON schema'
        fi

        if python3 "$REPO/scripts/prompt-lint.py" --last --db "${fixdb:-$db}" --json > "$work/pl_last.json" 2>&1; then
            ok 'prompt-lint: --last runs'
        else
            bad 'prompt-lint: --last runs'
            tail -6 "$work/pl_last.json"
        fi
    else
        bad 'database present for audit-tool-calls/prompt-lint'
    fi

    if python3 "$REPO/scripts/audit-tool-calls.py" --self-test > "$work/atc_st.txt" 2>&1; then
        ok 'audit-tool-calls: self-test'
    else
        bad 'audit-tool-calls: self-test'
        cat "$work/atc_st.txt"
    fi

    if python3 "$REPO/scripts/prompt-lint.py" --self-test > "$work/pl_st.txt" 2>&1; then
        ok 'prompt-lint: self-test'
    else
        bad 'prompt-lint: self-test'
        cat "$work/pl_st.txt"
    fi

    if python3 "$REPO/scripts/issue-solutions.py" --self-test > "$work/is_st.txt" 2>&1; then
        ok 'issue-solutions: self-test'
    else
        bad 'issue-solutions: self-test'
        cat "$work/is_st.txt"
    fi

    if have node && [ -f "$REPO/scripts/blacklist-guard-self-test.mjs" ]; then
        if node "$REPO/scripts/blacklist-guard-self-test.mjs" > "$work/bg_st.txt" 2>&1; then
            ok 'blacklist-guard: self-test'
        else
            bad 'blacklist-guard: self-test'
            cat "$work/bg_st.txt"
        fi
    else
        bad 'blacklist-guard-self-test.mjs present + node'
    fi

    if [ -f "$REPO/scripts/re-extract-session.sh" ]; then
        if bash "$REPO/scripts/re-extract-session.sh" --self-test > "$work/rx_st.txt" 2>&1; then
            ok 're-extract-session: self-test (stub node + fixtures)'
        else
            bad 're-extract-session: self-test (stub node + fixtures)'
            cat "$work/rx_st.txt"
        fi
    else
        bad 're-extract-session.sh present'
    fi

    if have node && [ -f "$REPO/scripts/session-health.mjs" ]; then
        if node --experimental-sqlite "$REPO/scripts/session-health.mjs" --self-test > "$work/sh_st.txt" 2>&1; then
            ok 'session-health: self-test (offline fixtures)'
        else
            bad 'session-health: self-test (offline fixtures)'
            cat "$work/sh_st.txt"
        fi
    else
        bad 'session-health.mjs present + node'
    fi

    if have node && [ -f "$REPO/scripts/quirks.mjs" ]; then
        if node --experimental-sqlite "$REPO/scripts/quirks.mjs" --self-test > "$work/qk_st.txt" 2>&1; then
            ok 'quirks: self-test (fuzzy matcher + corpus counters)'
        else
            bad 'quirks: self-test (fuzzy matcher + corpus counters)'
            cat "$work/qk_st.txt"
        fi
    else
        bad 'quirks.mjs present + node'
    fi

    if have node && [ -f "$REPO/scripts/quirks.mjs" ]; then
        if node --experimental-sqlite "$REPO/scripts/quirks.mjs" --check-issues > "$work/qi.txt" 2>&1; then
            ok 'known-issues.json valid (offline)'
        else
            bad 'known-issues.json valid (offline)'
            cat "$work/qi.txt"
        fi
    fi

    if have node && [ -f "$REPO/scripts/rerank.mjs" ]; then
        if node --experimental-sqlite "$REPO/scripts/rerank.mjs" --self-test > "$work/rr_st.txt" 2>&1; then
            ok 'rerank: self-test (local embed + redaction-mandatory external + FTS5 pull + caps)'
        else
            bad 'rerank: self-test (local embed + redaction-mandatory external + FTS5 pull + caps)'
            cat "$work/rr_st.txt"
        fi
    else
        bad 'rerank.mjs present + node'
    fi

    # Regression: the web UI creates sessions rooted at $HOME/.opencode, not
    # /workspace, so the project-scoped plugin glob misses the guard. The
    # entrypoint must link it into the GLOBAL plugin dir. Assert the wiring is
    # present (static) and, when it exists, that the symlink resolves to the
    # repo guard (runtime).
    if grep -qF 'GUARD_DIR' "$REPO/docker/web-entrypoint.sh"; then
        ok 'web-entrypoint installs the guard globally'
    else
        bad 'web-entrypoint installs the guard globally'
    fi
    local glink="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/blacklist-guard.js"
    if [ -e "$glink" ]; then
        if [ "$(readlink -f "$glink")" = "$REPO/.opencode/plugins/blacklist-guard.js" ]; then
            ok 'global guard symlink resolves to the repo plugin'
        else
            bad 'global guard symlink resolves to the repo plugin'
        fi
    else
        ok 'global guard symlink not present yet (entrypoint creates it at start)'
    fi

    if grep -qF 'SKILL_DIR' "$REPO/docker/web-entrypoint.sh"; then
        ok 'web-entrypoint installs the skill globally'
    else
        bad 'web-entrypoint installs the skill globally'
    fi
    local slink="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/jev-harness/SKILL.md"
    if [ -e "$slink" ]; then
        if [ "$(readlink -f "$slink")" = "$REPO/.opencode/skills/jev-harness/SKILL.md" ]; then
            ok 'global skill symlink resolves to the repo skill'
        else
            bad 'global skill symlink resolves to the repo skill'
        fi
    else
        ok 'global skill symlink not present yet (entrypoint creates it at start)'
    fi

    if have node && [ -f "$REPO/scripts/redact.mjs" ]; then
        if node "$REPO/scripts/redact.mjs" --self-test > "$work/rd_st.txt" 2>&1; then
            ok 'redact: self-test (egress redaction)'
        else
            bad 'redact: self-test (egress redaction)'
            cat "$work/rd_st.txt"
        fi
    else
        bad 'redact.mjs present + node'
    fi

    if [ -f "$REPO/scripts/test-ensure-env.sh" ]; then
        if bash "$REPO/scripts/test-ensure-env.sh" > "$work/ee.txt" 2>&1; then
            ok 'ensure-env: behavior test (no-op / warn / rotate / preserve)'
        else
            bad 'ensure-env: behavior test (no-op / warn / rotate / preserve)'
            tail -6 "$work/ee.txt"
        fi
    else
        bad 'test-ensure-env.sh present'
    fi

    if have node && [ -f "$REPO/scripts/capabilities.mjs" ]; then
        if node "$REPO/scripts/capabilities.mjs" --self-test > "$work/cap_st.txt" 2>&1; then
            ok 'capabilities: self-test (GREEN/DEGRADED/MISSING)'
        else
            bad 'capabilities: self-test (GREEN/DEGRADED/MISSING)'
            cat "$work/cap_st.txt"
        fi
        # E1: the self-test proves the checker, not the claims. Run the LIVE
        # registry -- any DEGRADED/MISSING not named in accepted_degraded fails
        # closed, so a registry entry that silently goes false (drifted marker,
        # deleted wiring) breaks the gate instead of reading as a status line.
        if node "$REPO/scripts/capabilities.mjs" > "$work/cap_live.txt" 2>&1; then
            ok "capabilities: live gate ($(awk '/^  \{/{gsub(/ /,"");print}' "$work/cap_live.txt"))"
        else
            bad 'capabilities: live gate (no unaccepted DEGRADED/MISSING)'
            cat "$work/cap_live.txt"
        fi
    else
        bad 'capabilities.mjs present + node'
    fi

    if [ -f "$REPO/scripts/watch.sh" ]; then
        if bash "$REPO/scripts/watch.sh" --self-test > "$work/wt.txt" 2>&1; then
            ok 'watch: self-test (cursor init + new-detection)'
        else
            bad 'watch: self-test (cursor init + new-detection)'
            cat "$work/wt.txt"
        fi
    else
        bad 'watch.sh present'
    fi

    if [ -f "$REPO/scripts/monitor-snapshot.sh" ]; then
        if bash "$REPO/scripts/monitor-snapshot.sh" --self-test > "$work/ms.txt" 2>&1; then
            ok 'monitor-snapshot: self-test'
        else
            bad 'monitor-snapshot: self-test'
            cat "$work/ms.txt"
        fi
    else
        bad 'monitor-snapshot.sh present'
    fi

    if [ -f "$REPO/scripts/recover-4096.sh" ]; then
        if bash "$REPO/scripts/recover-4096.sh" --self-test > "$work/rc_st.txt" 2>&1; then
            ok 'recover-4096: self-test (classifier + fixture + ledger seam)'
        else
            bad 'recover-4096: self-test (classifier + fixture + ledger seam)'
            cat "$work/rc_st.txt"
        fi
    else
        bad 'recover-4096.sh present'
    fi

    if [ -f "$REPO/scripts/session-guard.sh" ]; then
        if bash "$REPO/scripts/session-guard.sh" --self-test > "$work/sg_st.txt" 2>&1; then
            ok 'session-guard: self-test (fixture + guidance + ledger seam)'
        else
            bad 'session-guard: self-test (fixture + guidance + ledger seam)'
            cat "$work/sg_st.txt"
        fi
    else
        bad 'session-guard.sh present'
    fi

    if [ -f "$REPO/scripts/handoff-brief.sh" ]; then
        if bash "$REPO/scripts/handoff-brief.sh" --self-test > "$work/hb_st.txt" 2>&1; then
            ok 'handoff-brief: self-test (fixture + redaction path)'
        else
            bad 'handoff-brief: self-test (fixture + redaction path)'
            cat "$work/hb_st.txt"
        fi
    else
        bad 'handoff-brief.sh present'
    fi

    if [ -f "$REPO/scripts/session-digest.sh" ]; then
        if bash "$REPO/scripts/session-digest.sh" --self-test > "$work/sd_st.txt" 2>&1; then
            ok 'session-digest: self-test (DB-only digest + over-budget directive)'
        else
            bad 'session-digest: self-test (DB-only digest + over-budget directive)'
            cat "$work/sd_st.txt"
        fi
    else
        bad 'session-digest.sh present'
    fi

    if [ -f "$REPO/scripts/subq_snap.py" ]; then
        if python3 "$REPO/scripts/subq_snap.py" --self-test > "$work/sq_st.txt" 2>&1; then
            ok 'subq_snap: self-test (decisions body + answer format)'
        else
            bad 'subq_snap: self-test (decisions body + answer format)'
            cat "$work/sq_st.txt"
        fi
    else
        bad 'subq_snap.py present'
    fi

    if [ -f "$REPO/scripts/secret-scan.sh" ]; then
        if bash "$REPO/scripts/secret-scan.sh" --self-test > "$work/ss_st.txt" 2>&1; then
            ok 'secret-scan: self-test (fixture + value-free report)'
        else
            bad 'secret-scan: self-test (fixture + value-free report)'
            cat "$work/ss_st.txt"
        fi
    else
        bad 'secret-scan.sh present'
    fi

    if [ -f "$REPO/scripts/sentinel.sh" ]; then
        if bash "$REPO/scripts/sentinel.sh" --self-test > "$work/sen_st.txt" 2>&1; then
            ok 'sentinel: self-test (fixture trips + cursor + ledger seam)'
        else
            bad 'sentinel: self-test (fixture trips + cursor + ledger seam)'
            cat "$work/sen_st.txt"
        fi
    else
        bad 'sentinel.sh present'
    fi

    if [ -f "$REPO/scripts/sentinel-install.sh" ]; then
        if bash "$REPO/scripts/sentinel-install.sh" --self-test > "$work/sen_ins.txt" 2>&1; then
            ok 'sentinel-install: self-test (unit bake, no systemd)'
        else
            bad 'sentinel-install: self-test (unit bake, no systemd)'
            cat "$work/sen_ins.txt"
        fi
    else
        bad 'sentinel-install.sh present'
    fi

    if [ -f "$REPO/scripts/test-durable.sh" ]; then
        if bash "$REPO/scripts/test-durable.sh" > "$work/dur_st.txt" 2>&1; then
            ok 'test-durable: durable properties (read source, checkpoint, rebuild)'
        else
            bad 'test-durable: durable properties (read source, checkpoint, rebuild)'
            cat "$work/dur_st.txt"
        fi
    else
        bad 'test-durable.sh present'
    fi

    if [ -f "$REPO/scripts/snapshot-audit.sh" ]; then
        if bash "$REPO/scripts/snapshot-audit.sh" --self-test > "$work/snap_st.txt" 2>&1; then
            ok 'snapshot-audit: self-test (btrfs/snapper probes present)'
        else
            bad 'snapshot-audit: self-test (btrfs/snapper probes present)'
            cat "$work/snap_st.txt"
        fi
    else
        bad 'snapshot-audit.sh present'
    fi

    if [ -f "$REPO/scripts/locate-prune-snapshots.sh" ]; then
        if bash "$REPO/scripts/locate-prune-snapshots.sh" --self-test > "$work/lps_st.txt" 2>&1; then
            ok 'locate-prune-snapshots: self-test (idempotent PRUNEPATHS edit)'
        else
            bad 'locate-prune-snapshots: self-test (idempotent PRUNEPATHS edit)'
            cat "$work/lps_st.txt"
        fi
    else
        bad 'locate-prune-snapshots.sh present'
    fi

    if [ -f "$REPO/scripts/nebula-restart-trace.py" ]; then
        if python3 "$REPO/scripts/nebula-restart-trace.py" --self-test > "$work/nrt_st.txt" 2>&1; then
            ok 'nebula-restart-trace: self-test (parent-chain restarter id)'
        else
            bad 'nebula-restart-trace: self-test (parent-chain restarter id)'
            cat "$work/nrt_st.txt"
        fi
    else
        bad 'nebula-restart-trace.py present'
    fi

    if [ -f "$REPO/scripts/nebula-systemd-override.sh" ]; then
        if bash "$REPO/scripts/nebula-systemd-override.sh" --self-test > "$work/nso_st.txt" 2>&1; then
            ok 'nebula-systemd-override: self-test (idempotent drop-in apply/revert)'
        else
            bad 'nebula-systemd-override: self-test (idempotent drop-in apply/revert)'
            cat "$work/nso_st.txt"
        fi
    else
        bad 'nebula-systemd-override.sh present'
    fi

    if [ -f "$REPO/scripts/proc-progress.sh" ]; then
        if bash "$REPO/scripts/proc-progress.sh" --self-test > "$work/pp_st.txt" 2>&1; then
            ok 'proc-progress: self-test (silent-process monitor)'
        else
            bad 'proc-progress: self-test (silent-process monitor)'
            cat "$work/pp_st.txt"
        fi
    else
        bad 'proc-progress.sh present'
    fi

    if [ -f "$REPO/scripts/rotate-server-password.sh" ]; then
        if bash "$REPO/scripts/rotate-server-password.sh" --self-test > "$work/rsp_st.txt" 2>&1; then
            ok 'rotate-server-password: self-test (generate + atomic rewrite)'
        else
            bad 'rotate-server-password: self-test (generate + atomic rewrite)'
            cat "$work/rsp_st.txt"
        fi
    else
        bad 'rotate-server-password.sh present'
    fi

    if [ -f "$REPO/scripts/latency-timeline.sh" ]; then
        if bash "$REPO/scripts/latency-timeline.sh" --self-test > "$work/lt_st.txt" 2>&1; then
            ok 'latency-timeline: self-test (fixture Gantt + JSON)'
        else
            bad 'latency-timeline: self-test (fixture Gantt + JSON)'
            cat "$work/lt_st.txt"
        fi
    else
        bad 'latency-timeline.sh present'
    fi

    if [ -f "$REPO/scripts/state-snapshot.sh" ]; then
        if bash "$REPO/scripts/state-snapshot.sh" --self-test > "$work/ssnap_st.txt" 2>&1; then
            ok 'state-snapshot: self-test (snapshot + verified restore + tamper catch)'
        else
            bad 'state-snapshot: self-test (snapshot + verified restore + tamper catch)'
            cat "$work/ssnap_st.txt"
        fi
    else
        bad 'state-snapshot.sh present'
    fi

    if [ -f "$REPO/scripts/extract-transcript.sh" ]; then
        if bash "$REPO/scripts/extract-transcript.sh" --self-test > "$work/ext_st.txt" 2>&1; then
            ok 'extract-transcript: self-test (DB-direct shape + caps)'
        else
            bad 'extract-transcript: self-test (DB-direct shape + caps)'
            cat "$work/ext_st.txt"
        fi
    else
        bad 'extract-transcript.sh present'
    fi

    if [ -f "$REPO/scripts/deploy.sh" ]; then
        if bash "$REPO/scripts/deploy.sh" --self-test > "$work/dep_st.txt" 2>&1; then
            ok 'deploy: self-test (serve-rev parse + UI gate present)'
        else
            bad 'deploy: self-test (serve-rev parse + UI gate present)'
            cat "$work/dep_st.txt"
        fi
    else
        bad 'deploy.sh present'
    fi

    if [ -x "$REPO/scripts/logs.sh" ]; then
        if "$REPO/scripts/logs.sh" --source packet > "$work/logs.txt" 2>&1; then
            ok 'logs.sh runs (packet)'
        else
            bad 'logs.sh runs (packet)'
            tail -4 "$work/logs.txt"
        fi
    else
        bad 'logs.sh present + executable'
    fi

    if [ -x "$REPO/scripts/harness.sh" ]; then
        if "$REPO/scripts/harness.sh" --help > "$work/harness.txt" 2>&1; then
            ok 'harness.sh runs (--help)'
        else
            bad 'harness.sh runs (--help)'
            tail -4 "$work/harness.txt"
        fi
    else
        bad 'harness.sh present + executable'
    fi

    if [ -f "$REPO/DESIGN.md" ]; then
        ok 'DESIGN.md present'
    else
        bad 'DESIGN.md present'
    fi

    if [ -f "$REPO/ECC-SKILLS.md" ]; then
        ok 'ECC-SKILLS.md present'
    else
        bad 'ECC-SKILLS.md present'
    fi

    if [ -x "$REPO/scripts/preflight.sh" ]; then
        "$REPO/scripts/preflight.sh" --json > "$work/pf.txt" 2>&1
        if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "ready" in d and "critical" in d' "$work/pf.txt"; then
            ok 'preflight.sh --json valid'
        else
            bad 'preflight.sh --json valid'
            cat "$work/pf.txt"
        fi
    else
        bad 'preflight.sh present + executable'
    fi

    if [ -x "$REPO/scripts/learn-rules.py" ]; then
        if "$REPO/scripts/learn-rules.py" --self-test > "$work/lr.txt" 2>&1; then
            ok 'learn-rules: self-test'
        else
            bad 'learn-rules: self-test'
            cat "$work/lr.txt"
        fi
    else
        bad 'learn-rules.py present + executable'
    fi

    if [ -f "$REPO/scripts/fuzzy-search.py" ]; then
        if python3 "$REPO/scripts/fuzzy-search.py" --self-test > "$work/fz.txt" 2>&1; then
            ok 'fuzzy-search: self-test'
        else
            bad 'fuzzy-search: self-test'
            cat "$work/fz.txt"
        fi
    else
        bad 'fuzzy-search.py present'
    fi

    if [ -f "$REPO/scripts/code-index.py" ]; then
        if python3 "$REPO/scripts/code-index.py" --self-test > "$work/ci.txt" 2>&1; then
            ok 'code-index: self-test'
        else
            bad 'code-index: self-test'
            cat "$work/ci.txt"
        fi
    else
        bad 'code-index.py present'
    fi

    if [ -f "$REPO/scripts/models.py" ]; then
        if python3 "$REPO/scripts/models.py" --self-test > "$work/mo.txt" 2>&1; then
            ok 'models.py: self-test'
        else
            bad 'models.py: self-test'
            cat "$work/mo.txt"
        fi
    else
        bad 'models.py present'
    fi

    if [ -f "$REPO/models.policy.json" ]; then
        if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "max_input_per_m_usd" in d' "$REPO/models.policy.json"; then
            ok 'models.policy.json valid'
        else
            bad 'models.policy.json valid'
        fi
    else
        bad 'models.policy.json present'
    fi

    if python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); p=json.load(open(sys.argv[2])); assert "gemini" in o.get("provider",{}); assert any("gemini" in m for m in p.get("allow",[]))' "$REPO/opencode.json" "$REPO/models.policy.json"; then
        ok 'gemini provider declared + policy allows it'
    else
        bad 'gemini provider declared + policy allows it'
    fi

    if [ -f "$REPO/.opencode/skills/jev-harness/SKILL.md" ]; then
        if python3 -c '
import sys, re
h = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---", h, re.S)
sys.exit(0 if (m and "name:" in m.group(1) and "description:" in m.group(1)) else 1)
' "$REPO/.opencode/skills/jev-harness/SKILL.md"; then
            ok 'project skill frontmatter valid'
        else
            bad 'project skill frontmatter valid'
        fi
    else
        bad 'project skill present (.opencode/skills/jev-harness/SKILL.md)'
    fi

    if [ -f "$REPO/.opencode/command/status.md" ]; then
        if python3 -c '
import sys, re
h = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---", h, re.S)
sys.exit(0 if (m and "description:" in m.group(1)) else 1)
' "$REPO/.opencode/command/status.md"; then
            ok 'status command frontmatter valid'
        else
            bad 'status command frontmatter valid'
        fi
    else
        bad 'status command present (.opencode/command/status.md)'
    fi

    if [ -x "$REPO/scripts/doc-budget.sh" ]; then
        "$REPO/scripts/doc-budget.sh" --json > "$work/db.txt" 2>&1
        if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "total_tokens" in d and "budget" in d' "$work/db.txt"; then
            ok 'doc-budget.sh --json valid'
        else
            bad 'doc-budget.sh --json valid'
            cat "$work/db.txt"
        fi
    else
        bad 'doc-budget.sh present + executable'
    fi

    if [ -x "$REPO/scripts/test-tooling.sh" ]; then
        if "$REPO/scripts/test-tooling.sh" > "$work/tt.txt" 2>&1; then
            ok 'test-tooling.sh passes (JSON contracts)'
        else
            bad 'test-tooling.sh passes (JSON contracts)'
            tail -6 "$work/tt.txt"
        fi
    else
        bad 'test-tooling.sh present + executable'
    fi

    if [ -f "$REPO/scripts/ux-test.py" ]; then
        if python3 "$REPO/scripts/ux-test.py" --help > "$work/uxh.txt" 2>&1; then
            ok 'ux-test.py --help'
        else
            bad 'ux-test.py --help'
            cat "$work/uxh.txt"
        fi
    else
        bad 'ux-test.py present'
    fi

    if [ -f "$REPO/scripts/ux-trace.py" ]; then
        if python3 "$REPO/scripts/ux-trace.py" --self-test > "$work/uxt_st.txt" 2>&1; then
            ok 'ux-trace: self-test'
        else
            bad 'ux-trace: self-test'
            cat "$work/uxt_st.txt"
        fi
    else
        bad 'ux-trace.py present'
    fi

    # Script catalog completeness — scripts/README.txt claims "one entry per
    # script" and tools.json is the /manage catalog. Every tracked top-level
    # scripts/*.{sh,py,mjs} must appear in at least one, or the catalog silently
    # drifts from the tree (the 2026-10-18 audit found 30 missing). SKIP (no git)
    # is reported, never a silent pass.
    if command -v git > /dev/null && git -C "$REPO" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        git -C "$REPO" ls-files scripts > "$work/tracked.txt"
        python3 - "$REPO" "$work/tracked.txt" > "$work/catalog.txt" <<'PY'
import os, re, sys
repo, tracked = sys.argv[1], sys.argv[2]
names = []
for line in open(tracked, encoding="utf-8"):
    p = line.strip()
    rest = p[len("scripts/"):] if p.startswith("scripts/") else ""
    if rest and "/" not in rest and re.search(r"\.(sh|py|mjs)$", rest):
        names.append(rest)
readme = open(os.path.join(repo, "scripts/README.txt"), encoding="utf-8", errors="replace").read()
tools_path = os.path.join(repo, "scripts/tools.json")
tools = open(tools_path, encoding="utf-8", errors="replace").read() if os.path.exists(tools_path) else ""
missing = [n for n in names if n not in readme and n not in tools]
print("count=%d missing=%d" % (len(names), len(missing)))
for n in missing:
    print("  - " + n)
sys.exit(1 if missing else 0)
PY
        local cat_rc=$?
        if [ "$cat_rc" -eq 0 ]; then
            ok "script catalog complete ($(awk -F' ' '/^count=/{print $1}' "$work/catalog.txt"))"
        else
            bad 'script catalog complete (every tracked script documented)'
            cat "$work/catalog.txt"
        fi
    else
        printf 'ts=%s level=WARN status=SKIP script catalog (no git worktree)\n' "$(date -u +%H:%M:%S)"
    fi

    rm -f "$work"/*.txt "$work"/*.json "$work/live.db"
    rmdir "$work"

    if [ -n "$SLOW_MSG" ]; then
        printf 'slowest: %s (%sms)\n' "$SLOW_MSG" "$SLOW_MS"
    fi
    printf '\n=== result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
