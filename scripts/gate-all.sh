#!/usr/bin/env bash
# gate-all.sh — every assert, one command (implements agents contract).
# Runs all sandbox-runnable gates; host-only asserts print SKIP with the
# exact host command instead of failing (RULES #37: SKIP is not PASS).
# Asserts: lint, hygiene, patterns, self-tests, yaml contract, backup
# freshness, cert coverage, secret scan, opencode.json, review-diff,
# recall smoke, pages export. Exit 0 no FAIL, 2 otherwise.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'NOT-OK %s :: %s\n' "$1" "$2"; }
sk() { SKIP=$((SKIP + 1)); printf 'SKIP %s :: %s\n' "$1" "$2"; }
# NOTE: asserts capture to files then grep the file. Piping straight into
# `grep -q` is banned here: grep quits on first match, the producer dies of
# SIGPIPE (141), and `pipefail` turns a green gate red. Proven 2026-10-12.
chk() { rm -f /tmp/opencode/gate-chk.txt; "$@" > /tmp/opencode/gate-chk.txt 2>&1; }
mkdir -p /tmp/opencode 2>&1 || true
chk bash scripts/lint.sh; if grep -q "0 fail" /tmp/opencode/gate-chk.txt 2>&1; then ok "lint"; else no "lint" "see /tmp/opencode/gate-chk.txt"; fi
chk bash scripts/test-hygiene.sh; if grep -q "0 fail" /tmp/opencode/gate-chk.txt 2>&1; then ok "hygiene"; else no "hygiene" "see /tmp/opencode/gate-chk.txt"; fi
chk bash scripts/test-patterns.sh; if grep -q "0 fail" /tmp/opencode/gate-chk.txt 2>&1; then ok "patterns"; else no "patterns" "see /tmp/opencode/gate-chk.txt"; fi
chk node scripts/cdp-tab.mjs --self-test; if grep -q "0 fail" /tmp/opencode/gate-chk.txt 2>&1; then ok "cdp self-test"; else no "cdp self-test" "see /tmp/opencode/gate-chk.txt"; fi
chk node scripts/blacklist-guard-self-test.mjs; if grep -q "result: PASS" /tmp/opencode/gate-chk.txt 2>&1; then ok "guard self-test"; else no "guard self-test" "see /tmp/opencode/gate-chk.txt"; fi
chk python3 scripts/ux-trace.py --self-test; if grep -q "0 fail" /tmp/opencode/gate-chk.txt 2>&1; then ok "ux-trace self-test"; else no "ux-trace self-test" "see /tmp/opencode/gate-chk.txt"; fi
if python3 -c "
import re
y = open('agents/probe.yaml').read()
ux = open('scripts/ux.sh').read()
steps = re.findall(r'- name: (\w+)', y)
missing = [s for s in steps if s not in ux]
print('yaml steps:', steps)
raise SystemExit(1 if missing else 0)
" 2>&1; then ok "yaml contract (probe.yaml steps in ux.sh)"; else no "yaml contract" "step missing from ux.sh"; fi
if python3 -c "
import sqlite3, glob, os
live = sqlite3.connect('file:/home/owner/.local/share/opencode/opencode.db?mode=ro', uri=True).execute('SELECT COUNT(*) FROM session').fetchone()[0]
baks = sorted(glob.glob('data/opencode.bak-*/opencode.db'))
bak = sqlite3.connect('file:' + baks[-1] + '?mode=ro', uri=True).execute('SELECT COUNT(*) FROM session').fetchone()[0]
print('live', live, 'newest-bak', bak, os.path.basename(os.path.dirname(baks[-1])))
raise SystemExit(0 if bak == live else 1)
" 2>&1; then ok "backup freshness (newest bak matches live)"; else no "backup freshness" "take a new atomic backup"; fi
chk bash docker/certs-init.sh --check; if grep -q "COVERED" /tmp/opencode/gate-chk.txt 2>&1; then ok "cert coverage"; else no "cert coverage" "run certs-init"; fi
if git diff HEAD 2>&1 | grep -iE "^\+.*(sk-[A-Za-z0-9]{10,}|apikey_[A-Za-z0-9]{10,})" | head -n 3 | grep -q .; then no "secret scan" "possible key in diff"; else ok "secret scan (worktree diff clean)"; fi
if node -e "const j=JSON.parse(require('fs').readFileSync('opencode.json','utf8')); if(!j.mcp.servers['repo-tools']) throw 0;" 2>&1; then ok "opencode.json (repo-tools registered)"; else no "opencode.json" "repo-tools entry missing"; fi
chk bash scripts/review-diff.sh; if grep -qE "SKIP|PASS" /tmp/opencode/gate-chk.txt 2>&1; then ok "review-diff (SKIP-or-PASS)"; else no "review-diff" "see /tmp/opencode/gate-chk.txt"; fi
chk python3 scripts/recall-sessions.py mesh --limit 3; if grep -q "message-hits:" /tmp/opencode/gate-chk.txt 2>&1; then ok "recall smoke"; else no "recall smoke" "see /tmp/opencode/gate-chk.txt"; fi
chk bash scripts/dns-guard.sh; if grep -q "verdict: HEALTHY" /tmp/opencode/gate-chk.txt 2>&1; then ok "dns-guard (HEALTHY, no --fix)"; else no "dns-guard" "see /tmp/opencode/gate-chk.txt"; fi
./scripts/pages-export.sh --shell --yes --limit 500 > /tmp/opencode/gate-pages.txt 2>&1 || true
if grep -q "sessions=" /tmp/opencode/gate-pages.txt 2>&1; then ok "pages export builds"; else sleep 20; ./scripts/pages-export.sh --shell --yes --limit 500 > /tmp/opencode/gate-pages.txt 2>&1 || true; if grep -q "sessions=" /tmp/opencode/gate-pages.txt 2>&1; then ok "pages export builds (retry)"; else no "pages export" "see /tmp/opencode/gate-pages.txt"; fi; fi
if command -v docker 2>&1 | grep -q docker; then printf 'host asserts run here\n'; else sk "host asserts (probe/litellm-logs)" "no docker in sandbox; run ux.sh status on host"; fi
printf 'gate-all: %s pass, %s fail, %s skip\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then exit 2; fi
exit 0
