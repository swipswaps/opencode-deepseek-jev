#!/usr/bin/env bash
# Scan every shell script under scripts/ for the forbidden patterns.
set -o pipefail

ROOT="scripts"
PATTERNS='2>/dev/null|\bsed\b|rm -rf|set -e\b|exit 1\b|subprocess\.run|kill [0-9]+'

printf 'Scanning %s for forbidden patterns...\n\n' "$ROOT"

found=0
while IFS= read -r f; do
    case "$f" in
        *.sh) ;;
        *) continue ;;
    esac
    hits=$(grep -nE "$PATTERNS" "$f" 2>&1)
    if [ -n "$hits" ]; then
        printf '=== %s ===\n' "$f"
        printf '%s\n' "$hits"
        printf '\n'
        found=$((found+1))
    fi
done < <(find "$ROOT" -type f -name '*.sh' 2>&1)

if [ "$found" -eq 0 ]; then
    printf 'PASS: no forbidden patterns found in any .sh under %s\n' "$ROOT"
else
    printf 'Found forbidden patterns in %d file(s)\n' "$found"
fi
