#!/usr/bin/env bash
#
# test-jev-functional.sh — strict functional gate for the Jev integration.
#
# Unlike the exploratory test-jev-* scripts under scripts/archive/one-shot/,
# this one FAILS (returns non-zero) unless the jev-review MCP tool is actually
# invoked AND returns a correctness score. It is the "prove Jev functionally,
# not by string match" check from the audit.
#
# Host-side: requires docker and a running opencode-deepseek-web container.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
REMOTE_PROMPT="/tmp/jev-functional-prompt.txt"
TS=""
LOG=""

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '%s%s\n' '    ' "$line"
    done
}

gate_container() {
    section "GATE 0  container running"
    if ! docker inspect -f '{{.State.Status}}' "$C" | grep -q '^running$'; then
        printf 'FAIL: container %s not running\n' "$C"
        return 1
    fi
    printf 'PASS: %s running\n' "$C"
    return 0
}

gate_server_file() {
    section "GATE 1  jev-review server present"
    if docker exec "$C" test -f /opt/jev-review/dist/server.js; then
        printf 'PASS: /opt/jev-review/dist/server.js present\n'
        return 0
    fi
    printf 'FAIL: server.js missing in container\n'
    return 1
}

gate_invoke() {
    section "GATE 2  deliver prompt and run opencode"
    docker exec -i "$C" sh -c "cat > $REMOTE_PROMPT" <<'PROMPT_END'
Call the jev_review tool exactly once to review the change below. Do not
answer from your own knowledge.

Arguments:
  task: "implement a function that adds two integers"
  diff: "diff --git a/add.py b/add.py\n+def add(a, b):\n+    return a + b\n"
  files: []
  repositoryContext: "Python 3.12. No test framework configured."

After the tool returns, print the numeric score and confidence for each metric
the tool marked applicable, one per line. If a metric is not applicable, skip it.
PROMPT_END
    printf 'wrote %s inside container\n' "$REMOTE_PROMPT"
    docker exec "$C" sh -c \
        "cd /workspace && opencode run --print-logs --log-level DEBUG --model '$MODEL' \"\$(cat $REMOTE_PROMPT)\"" \
        > "$LOG" 2>&1
    printf 'saved: %s (%s lines)\n' "$LOG" "$(wc -l < "$LOG" | tr -d ' ')"
    return 0
}

gate_evidence() {
    section "GATE 3  evidence the tool fired and returned a scored result"

    local fired=0
    grep -qi 'jev_review' "$LOG" && fired=1

    local scored=0
    grep -q '"applicable":true' "$LOG" && grep -q '"score"' "$LOG" && scored=1

    if [ "$fired" -eq 1 ]; then
        printf 'PASS: jev_review was invoked\n'
    else
        printf 'FAIL: jev_review was not invoked (model answered without the tool)\n'
    fi

    if [ "$scored" -eq 1 ]; then
        printf 'PASS: tool returned a metrics result with >=1 applicable metric\n'
        printf 'applicable metrics:\n'
        grep -oE '"[a-zA-Z]+":\{"applicable":true[^}]*\}' "$LOG" | head -20 | indent
    else
        printf 'FAIL: no applicable metric with a score in the tool result\n'
        printf '\ntool-call markers:\n'
        grep -inIE 'jev_review|tool call|toolcall|mcp|tool_|metrics' "$LOG" | head -30 | indent
        printf '(end)\n'
    fi

    if [ "$fired" -eq 1 ] && [ "$scored" -eq 1 ]; then
        return 0
    fi
    return 1
}

main() {
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    LOG="/tmp/jev-functional-${TS}.log"

    printf '=== test-jev-functional.sh ===\n'
    printf 'TS: %s\n' "$TS"

    gate_container || return 1
    gate_server_file || return 1
    gate_invoke
    if gate_evidence; then
        printf '\nresult: PASS\n'
        printf 'log retained: %s\n' "$LOG"
        return 0
    fi
    printf '\nresult: FAIL\n'
    printf 'log retained: %s\n' "$LOG"
    return 1
}

main "$@"
