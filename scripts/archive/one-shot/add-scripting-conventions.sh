#!/usr/bin/env bash
#
# add-scripting-conventions.sh — append the repo's scripting conventions
# to scripts/README.txt. Idempotent: if the section is already present,
# the script reports that and exits.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# The session has repeatedly failed at the same boundary: a response that
# emits multiple files interleaves the heredocs with prose. The shell
# reads a heredoc from its opening marker to its matching closing
# delimiter at column zero. Any paragraph between the two is treated as
# file content; any heredoc whose delimiter is not at column zero is
# unterminated and the entire input is discarded.
#
#   POSIX shell, here-documents:
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
#   Bash manual, here-documents:
#     https://www.gnu.org/software/bash/manual/html_node/Here-Documents.html
#
# The user's rule: "If it can be typed, it MUST be scripted!" extends to
# the shape of the response itself. One script, one paste. Multiple
# files inside the script. No prose between heredocs.
#
#   Raymond, "The Art of Unix Programming", Addison-Wesley, 2003,
#   ISBN-13: 978-0131429017, §1.6.2 "Rule of Clarity": a clear interface
#   is one the recipient can act on without interpretation.
#
# ============================================================================

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
[ -z "$REPO_DIR" ] && REPO_DIR=$(resolve_repo "$PWD")

README="$REPO_DIR/scripts/README.txt"
TS=$(date -u +%Y%m%dT%H%M%SZ)

main() {
    printf '=== add-scripting-conventions.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'File: %s\n\n' "$README"

    if [ ! -f "$README" ]; then
        printf 'GATE FAIL: %s not found\n' "$README"
        return 1
    fi
    printf '  PASS: README present\n'

    if grep -q '^Scripting conventions$' "$README"; then
        printf '  PASS: section already present; nothing to do\n'
        return 0
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$README" "$README.bak.${TS}"
        printf '  backup: %s.bak.%s\n' "$README" "$TS"

        cat >> "$README" <<'SECTION_EOF'

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
SECTION_EOF

        printf '  section appended\n'
    else
        printf '  would append a "Scripting conventions" section\n'
    fi

    printf '\n=== summary ===\n'
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply.\n'
    else
        printf '\n  APPLIED. backup: %s.bak.%s\n' "$README" "$TS"
    fi
    return 0
}

main "$@"
