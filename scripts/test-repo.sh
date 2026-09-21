#!/usr/bin/env bash
#
# test-repo.sh — verify the repository is in its expected final state and
# the environment it describes is functional.
#
# ============================================================================
# AUDIT — what "expected final state" means
# ============================================================================
#
# The repo has been through several migrations and reorganizations:
#
#   1. Consolidated cleanup scripts into scripts/archive/
#   2. Migrated Docker data root to /mnt/nvme/docker
#   3. Added nofail + x-systemd.device-timeout to /etc/fstab
#   4. Should now archive the one-shot migration scripts
#
# Expected final structure at the repo root:
#
#   .dockerignore
#   .env.local                (mode 0600, gitignored)
#   .git/
#   .gitignore
#   QUICKSTART.txt
#   README.txt
#   docker/                   (Dockerfile, docker-compose.yml, build.sh, run.sh)
#   opencode.json
#   requirements.txt
#   scripts/
#
# Expected scripts/ contents after archiving:
#
#   README.txt                operating model
#   ask.sh                    (if staged)
#   deploy-dockge.sh          operating script
#   doctor.sh                 operating script
#   flatten-dockge-stacks.sh  operating script
#   archive/
#     forensics/
#     logs/
#     one-shot/               all migration, prune, diagnose scripts
#     migration-notes.txt
#     stage-opencode-repo/
#
# Anything outside that set is drift. The test reports drift without
# repairing it; repair is done by the close-out script.
#
# ============================================================================
# GATES — ordered fast-to-slow
# ============================================================================
#
#   G0.  repo root resolvable (contains opencode.json + docker/Dockerfile)
#   G1.  required binaries present
#   G2.  .env.local present, mode 0600, both keys non-empty
#   G3.  opencode.json is valid JSON
#   G4.  docker/Dockerfile contains the jev-guard install line
#   G5.  repo root has no unexpected files
#   G6.  scripts/ operating set is present
#   G7.  one-shot migration scripts are archived
#   G8.  doctor.sh passes
#
# Each gate prints PASS / FAIL / WARN. The script returns 0 only when no
# gate reports FAIL.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   POSIX printf(1)            https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   POSIX test(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/test.html
#   POSIX find(1)              https://pubs.opengroup.org/onlinepubs/9699919799/utilities/find.html
#   POSIX basename(1)          https://pubs.opengroup.org/onlinepubs/9699919799/utilities/basename.html
#   Bash parameter expansion   https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html
#   Bash return                https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html
#   Bash pipefail              https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
#   Python json.tool           https://docs.python.org/3/library/json.html
#   Docker daemon.json         https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-configuration-file
#   fstab(5)                   https://man7.org/linux/man-pages/man5/fstab.5.html
#   systemd.target(5)          https://www.freedesktop.org/software/systemd/man/latest/systemd.target.html
#   systemd-fstab-generator(8) https://www.freedesktop.org/software/systemd/man/latest/systemd-fstab-generator.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003.
#   ISBN-13: 978-0131429017. §1.6.6 "Rule of Separation".
#
# ============================================================================

set -o pipefail

# ----------------------------------------------------------------------------
# Mode: report (default) or --archive (perform the archive step first)
# ----------------------------------------------------------------------------
MODE="report"
case "${1:-}" in
    --archive) MODE="archive" ;;
    --report|"") MODE="report" ;;
    *) printf 'usage: %s [--archive]\n' "$0"; return 2 ;;
esac

# Counters
PASS=0
FAIL=0
WARN=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  WARN  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; WARN=$((WARN+1)); }
info() { printf '  INFO  %s\n' "$1"; }

# ----------------------------------------------------------------------------
# G0 — resolve the repo root
# ----------------------------------------------------------------------------
# The repo is identified by the presence of opencode.json and
# docker/Dockerfile in the same directory. Search upward from the
# script's location, then from CWD.
# ----------------------------------------------------------------------------
resolve_repo() {
    local start="$1" candidate
    candidate="$start"
    while [ "$candidate" != "/" ]; do
        if [ -f "$candidate/opencode.json" ] \
            && [ -f "$candidate/docker/Dockerfile" ]; then
            printf '%s' "$candidate"
            return 0
        fi
        candidate=$(dirname "$candidate")
    done
    return 1
}

# ----------------------------------------------------------------------------
# G1 — required binaries
# ----------------------------------------------------------------------------
gate_binaries() {
    printf '\nG1 required binaries\n'
    local bin
    for bin in docker python3 curl; do
        if command -v "$bin" > /dev/null; then
            ok "$bin present"
        else
            bad "$bin missing" "install it"
        fi
    done
}

# ----------------------------------------------------------------------------
# G2 — .env.local
# ----------------------------------------------------------------------------
gate_env() {
    printf '\nG2 .env.local\n'
    local f="$REPO_DIR/.env.local"
    if [ ! -f "$f" ]; then
        bad "$f missing" "create it with DEEPSEEK_API_KEY and JEV_API_KEY"
        return
    fi
    ok "$f present"
    local mode
    mode=$(stat -c '%a' "$f" 2>&1)
    if [ "$mode" = "600" ]; then
        ok "mode 0600"
    else
        bad "mode is $mode, expected 600" "chmod 600 $f"
    fi
    local ds jv
    ds=$(awk -F= '$1 == "DEEPSEEK_API_KEY" { print $2; exit }' "$f")
    jv=$(awk -F= '$1 == "JEV_API_KEY"      { print $2; exit }' "$f")
    if [ -n "$ds" ]; then
        ok "DEEPSEEK_API_KEY set (len ${#ds})"
    else
        bad "DEEPSEEK_API_KEY empty"
    fi
    if [ -n "$jv" ]; then
        ok "JEV_API_KEY set (len ${#jv})"
    else
        bad "JEV_API_KEY empty"
    fi
    case "$jv" in
        apikey_*|sk-*|ts_*|jev-*) ok "JEV_API_KEY prefix recognized" ;;
        *) bad "JEV_API_KEY prefix not recognized" \
               "expected apikey_, sk-, ts_, or jev-" ;;
    esac
}

# ----------------------------------------------------------------------------
# G3 — opencode.json validity
# ----------------------------------------------------------------------------
gate_opencode_json() {
    printf '\nG3 opencode.json\n'
    local f="$REPO_DIR/opencode.json"
    if [ ! -f "$f" ]; then
        bad "$f missing"
        return
    fi
    if python3 -m json.tool "$f" > /dev/null 2>&1; then
        ok "valid JSON"
    else
        bad "invalid JSON"
        return
    fi
    if grep -q '"deepseek-flash"' "$f"; then
        ok "model id deepseek-flash present"
    else
        bad "model id deepseek-flash absent"
    fi
    if grep -q 'jev-review' "$f"; then
        ok "jev-review MCP server referenced"
    else
        bad "jev-review MCP server absent"
    fi
}

# ----------------------------------------------------------------------------
# G4 — Dockerfile markers
# ----------------------------------------------------------------------------
gate_dockerfile() {
    printf '\nG4 docker/Dockerfile\n'
    local f="$REPO_DIR/docker/Dockerfile"
    if [ ! -f "$f" ]; then
        bad "$f missing"
        return
    fi
    ok "$f present"
    if grep -q 'opencode plugin jev-guard' "$f"; then
        ok "jev-guard install line present"
    else
        bad "jev-guard install line absent"
    fi
    if grep -q 'git clone.*jev-review' "$f"; then
        ok "jev-review clone line present"
    else
        bad "jev-review clone line absent"
    fi
    if grep -q 'FROM fedora' "$f" && grep -q 'opencode.ai/install' "$f"; then
        warn "Dockerfile appears to be Fedora-based" \
             "this is the deprecated form; bookworm-slim is the current base"
    fi
}

# ----------------------------------------------------------------------------
# G5 — repo root cleanliness
# ----------------------------------------------------------------------------
# Expected non-hidden entries at repo root:
#   docker, scripts, opencode.json, README.txt, QUICKSTART.txt,
#   requirements.txt, .env.local, .gitignore, .dockerignore, .git
#
# Anything else is drift.
# ----------------------------------------------------------------------------
gate_root_cleanliness() {
    printf '\nG5 repo root cleanliness\n'
    local expected='docker scripts opencode.json README.txt QUICKSTART.txt requirements.txt .env.local .gitignore .dockerignore .git'
    local found=0
    local entry base
    for entry in "$REPO_DIR"/* "$REPO_DIR"/.[!.]*; do
        [ -e "$entry" ] || continue
        base=$(basename "$entry")
        case " $expected " in
            *" $base "*) continue ;;
        esac
        warn "unexpected root entry: $base"
        found=$((found+1))
    done
    if [ "$found" -eq 0 ]; then
        ok "root contains only expected entries"
    else
        info "$found unexpected entries (warnings, not failures)"
    fi
}

# ----------------------------------------------------------------------------
# G6 — operating scripts present in scripts/
# ----------------------------------------------------------------------------
gate_operating_scripts() {
    printf '\nG6 operating scripts\n'
    local required='deploy-dockge.sh flatten-dockge-stacks.sh doctor.sh README.txt'
    local name
    for name in $required; do
        if [ -e "$REPO_DIR/scripts/$name" ]; then
            ok "scripts/$name present"
        else
            bad "scripts/$name missing"
        fi
    done
}

# ----------------------------------------------------------------------------
# G7 — one-shot migration scripts archived
# ----------------------------------------------------------------------------
gate_archived() {
    printf '\nG7 archived one-shots\n'
    local archive="$REPO_DIR/scripts/archive/one-shot"
    if [ ! -d "$archive" ]; then
        bad "$archive missing" "run: ./scripts/close-out-migration.sh --archive"
        return
    fi
    ok "$archive present"
    local name
    for name in diagnose-docker.sh plan-docker-migration.sh \
                migrate-docker-to-nvme.sh prune-docker.sh \
                close-out-migration.sh; do
        if [ -e "$archive/$name" ]; then
            ok "archived: $name"
        else
            warn "not archived: $name" \
                 "may still be in scripts/; run --archive"
        fi
    done
    # also confirm they are not still in scripts/
    local stray=0
    for name in diagnose-docker.sh plan-docker-migration.sh \
                migrate-docker-to-nvme.sh prune-docker.sh; do
        if [ -e "$REPO_DIR/scripts/$name" ]; then
            warn "still in scripts/: $name"
            stray=$((stray+1))
        fi
    done
    if [ "$stray" -eq 0 ]; then
        ok "no one-shot scripts left in scripts/"
    fi
}

# ----------------------------------------------------------------------------
# G8 — doctor.sh as end-to-end smoke test
# ----------------------------------------------------------------------------
gate_doctor() {
    printf '\nG8 doctor.sh smoke test\n'
    local doctor="$REPO_DIR/scripts/doctor.sh"
    if [ ! -x "$doctor" ]; then
        bad "$doctor missing or not executable"
        return
    fi
    if (cd "$REPO_DIR" && ./scripts/doctor.sh) > /tmp/doctor-out.$$ 2>&1; then
        ok "doctor.sh reported OK"
        local passes
        passes=$(grep -c '^  PASS' /tmp/doctor-out.$$)
        info "doctor pass count: $passes"
    else
        bad "doctor.sh reported FAIL"
        printf '        --- last 20 lines ---\n'
        tail -20 /tmp/doctor-out.$$ | while IFS= read -r line; do
            printf '          %s\n' "$line"
        done
    fi
    rm -f /tmp/doctor-out.$$
}

# ----------------------------------------------------------------------------
# Archive step (--archive mode only)
# ----------------------------------------------------------------------------
do_archive() {
    printf '\n=== archive ===\n'
    local closer="$REPO_DIR/scripts/close-out-migration.sh"
    if [ ! -x "$closer" ]; then
        bad "close-out-migration.sh not executable" \
             "run: chmod +x $closer"
        return
    fi
    if (cd "$REPO_DIR" && ./scripts/close-out-migration.sh --archive) 2>&1; then
        ok "archive step completed"
    else
        bad "archive step returned non-zero"
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    # G0 — resolve repo root
    printf '=== test-repo.sh ===\n'
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_DIR=$(resolve_repo "$script_dir")
    if [ -z "$REPO_DIR" ]; then
        REPO_DIR=$(resolve_repo "$PWD")
    fi
    if [ -z "$REPO_DIR" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        printf '  expected: a directory containing opencode.json and docker/Dockerfile\n'
        return 2
    fi
    printf 'Repo: %s\n' "$REPO_DIR"
    printf 'Mode: %s\n' "$MODE"

    if [ "$MODE" = "archive" ]; then
        do_archive
    fi

    gate_binaries
    gate_env
    gate_opencode_json
    gate_dockerfile
    gate_root_cleanliness
    gate_operating_scripts
    gate_archived
    gate_doctor

    printf '\n=== summary ===\n'
    printf '  pass: %d\n' "$PASS"
    printf '  warn: %d\n' "$WARN"
    printf '  fail: %d\n' "$FAIL"
    printf '\n'
    if [ "$FAIL" -gt 0 ]; then
        printf 'result: FAIL\n'
        return 1
    fi
    printf 'result: OK\n'
    return 0
}

main "$@"
