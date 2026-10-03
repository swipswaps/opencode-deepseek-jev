#!/usr/bin/env bash
#
# tool-census.sh — report which agentic tools/models are present on this host.
#
# WHY: tool evaluations rot. A review that says "adopt X" is worthless six
# months later if nobody recorded whether X was ever installed, which
# version, and where its weights live. This script prints one line per tool
# (present + version, or MISSING) so the next evaluation starts from fact.
# Offline. Read-only. No model calls, no egress, no installs.
#
# Tools covered (evaluated 2026-10-03, see commit message):
#   strands-decider — AWS Strands Labs 1.9B decision model (choice/yes-no
#     with calibrated confidence). Candidate for routing triage; needs a
#     local runner (ollama/llama.cpp) plus weights.
#   nimble — Nimbleway commercial web-data platform (cloud, API key).
#     Rejected for localhost work (egress + cost policy); census only.
#   ollama / llama-server — local model runners (needed by strands-decider
#     or any Laya/Jev local-judge step).
#   browser-use / playwright — live-browser stacks already used by cdp-tab
#     (CDP attach) and ux-test.py / ux-trace.py (bundled chromium).
#
# Usage: ./scripts/tool-census.sh
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

have() { command -v "$1" > /dev/null 2>&1; }

py_mod() {
    python3 -c "import $1" > /dev/null 2>&1
}

hf_weights() {
    local d="$HOME/.cache/huggingface/hub"
    [ -d "$d" ] || return 1
    find "$d" -maxdepth 1 -iname '*decider*' -o -maxdepth 1 -iname '*strands*' | head -3
}

main() {
    printf '=== tool-census.sh ===\n'
    if have strands-decider; then
        printf 'present strands-decider: %s\n' "$(strands-decider --version 2>&1 | head -1)"
    else
        printf 'MISSING strands-decider (pip install strands-decider; needs runner + weights)\n'
    fi
    if have ollama; then
        printf 'present ollama: %s\n' "$(ollama --version 2>&1 | head -1)"
    else
        printf 'MISSING ollama (local runner for 1-2B judges)\n'
    fi
    if have llama-server || have llama-cli; then
        printf 'present llama.cpp runtime\n'
    else
        printf 'MISSING llama.cpp runtime\n'
    fi
    if have nimble; then
        printf 'present nimble: %s\n' "$(nimble --version 2>&1 | head -1)"
    else
        printf 'MISSING nimble (commercial; not wanted for localhost work)\n'
    fi
    if py_mod browser_use; then
        printf 'present python browser_use\n'
    else
        printf 'MISSING python browser_use\n'
    fi
    if py_mod playwright; then
        printf 'present python playwright\n'
    else
        printf 'MISSING python playwright\n'
    fi
    local w
    w=$(hf_weights)
    if [ -n "$w" ]; then
        printf 'weights present:\n%s\n' "$w"
    else
        printf 'weights: no local decider/strands weights in ~/.cache/huggingface\n'
    fi
    if [ -d "$HOME/.cache/ms-playwright" ]; then
        printf 'present playwright browsers: %s\n' "$(ls "$HOME/.cache/ms-playwright" | head -5 | paste -sd' ')"
    else
        printf 'MISSING playwright browsers\n'
    fi
    return 0
}

main "$@"
