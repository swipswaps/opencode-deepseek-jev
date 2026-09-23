#!/usr/bin/env bash
set -o pipefail
C="opencode-deepseek-web"
W="/workspace"

printf '=== opencode top-level help ===\n'
docker exec -w "$W" "$C" sh -c 'opencode --help' 2>&1 | head -50

printf '\n=== opencode models (no subcommand) ===\n'
docker exec -w "$W" "$C" sh -c 'opencode models' 2>&1 | head -40

printf '\n=== sqlite table list ===\n'
sqlite3 /tmp/opencode-test.db ".tables" 2>&1

printf '\n=== sqlite schema: session ===\n'
sqlite3 /tmp/opencode-test.db ".schema session" 2>&1

printf '\n=== sqlite schema: message ===\n'
sqlite3 /tmp/opencode-test.db ".schema message" 2>&1

printf '\n=== sqlite row count: session ===\n'
sqlite3 /tmp/opencode-test.db "select count(*) from session;" 2>&1

printf '\n=== sqlite session sample (first 3) ===\n'
sqlite3 -header /tmp/opencode-test.db "select * from session limit 3;" 2>&1

printf '\n=== sqlite row count: message ===\n'
sqlite3 /tmp/opencode-test.db "select count(*) from message;" 2>&1
