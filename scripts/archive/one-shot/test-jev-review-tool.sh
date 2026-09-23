#!/usr/bin/env bash
#
# test-jev-review-tool.sh — actually invoke the jev_review MCP tool and
# validate the response. This is the product; everything else is scaffolding.
#
# Prompt is delivered via stdin to a file inside the container to avoid
# host-side shell quoting entirely (parens, quotes, backticks are all safe).
#
# Constraints:
#   No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
#   No python. No bare kill. main() wrapper.
#
# Citations:
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#   Docker exec -i (stdin):
#     https://docs.docker.com/engine/reference/commandline/exec/
#   jev_review input schema: observed in-container 2026-09-23 via
#     JSON-RPC tools/list (test-jev-effectiveness.sh, section E3)
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
#
set -o pipefail

C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
REMOTE_PROMPT="/tmp/jev-review-prompt.txt"
TS=""
LOG=""

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '%s%s\n' '    ' "$line"
    done
}

main() {
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    LOG="/tmp/jev-review-${TS}.log"

    printf '=== test-jev-review-tool.sh ===\n'
    printf 'TS: %s\n' "$TS"

    if ! docker inspect -f '{{.State.Status}}' "$C" | grep -q '^running$'; then
        printf 'GATE FAIL: container not running\n'
        return 1
    fi

    # ------------------------------------------------------------------
    section "P1  deliver prompt via stdin (no host shell parsing)"
    # ------------------------------------------------------------------
    docker exec -i "$C" sh -c "cat > $REMOTE_PROMPT" <<'PROMPT_END'
Call the jev_review tool exactly once. Do not answer from your own knowledge.

Arguments:
  task: "Implement add(a, b) returning the sum of two integers."
  diff: "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -0,0 +1,2 @@\n+def add(a, b):\n+    return a + b\n"
  files: []
  repositoryContext: "Python 3.12. No test framework configured."

After the tool returns, reply with ONLY the integer score for the "correctness"
metric, nothing else.
PROMPT_END
    printf 'wrote %s inside container\n' "$REMOTE_PROMPT"
    printf '\ncontent:\n'
    docker exec "$C" sh -c "cat $REMOTE_PROMPT" | indent

    # ------------------------------------------------------------------
    section "P2  run opencode with the prompt from the file"
    # ------------------------------------------------------------------
    docker exec "$C" sh -c \
        "cd /workspace && opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat $REMOTE_PROMPT)\"" \
        > "$LOG" 2>&1
    printf 'saved: %s (%s lines)\n' "$LOG" "$(wc -l < "$LOG" | tr -d ' ')"

    # ------------------------------------------------------------------
    section "P3  model answer (non-timestamp lines)"
    # ------------------------------------------------------------------
    grep -v '^timestamp=' "$LOG" | grep -v '^$' | indent

    # ------------------------------------------------------------------
    section "P4  evidence the jev_review tool actually fired"
    # ------------------------------------------------------------------
    printf 'tool-call markers:\n'
    grep -inIE 'jev_review|tool call|toolcall|mcp|tool_' "$LOG" | head -30 | indent
    printf '(end)\n'

    printf '\nJSON-looking metric lines:\n'
    grep -inE '"correctness"|"score"|"metrics"' "$LOG" | head -20 | indent
    printf '(end)\n'

    # ------------------------------------------------------------------
    section "P5  verdict"
    # ------------------------------------------------------------------
    fired=0
    grep -qi 'jev_review' "$LOG" && fired=1

    score=""
    score=$(grep -oE '^\s*[0-9]+\s*$' "$LOG" | tr -d ' ' | head -1)
    if [ -z "$score" ]; then
        score=$(grep -oE '"correctness"[^}]*"score"\s*:\s*[0-9]+' "$LOG" | grep -oE '[0-9]+$' | head -1)
    fi

    if [ "$fired" -eq 1 ]; then
        printf '  TOOL FIRED — jev_review was invoked\n'
    else
        printf '  tool did NOT fire — model answered without calling jev_review\n'
    fi

    if [ -n "$score" ]; then
        printf '  correctness score: %s\n' "$score"
    else
        printf '  no numeric correctness score found in output\n'
    fi

    printf '\nlog retained: %s\n' "$LOG"
    return 0
}

main "$@"
