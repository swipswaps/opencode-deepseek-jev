#!/usr/bin/env bash
# Interactive recovery assistant for containers removed by v26's unscoped cleanup.
# Reads ~/removed-container-map.txt, walks through each affected project,
# prompts for decision, logs to ~/recovery-decisions.log.
# v2: empty input ignored, ? loops, malformed headers detected, batch mode.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

MAP_FILE="${1:-$HOME/removed-container-map.txt}"
DECISIONS_FILE="$HOME/recovery-decisions.log"
TMP_PROJECTS=$(mktemp)

prior_decision_for() {
    local path="$1"
    if [ ! -f "$DECISIONS_FILE" ]; then return 0; fi
    awk -F'\t' -v target="$path" '
        $2 == target { last = $0 }
        END {
            if (last != "") {
                split(last, f, "\t")
                print f[3] " @ " f[1]
            }
        }
    ' "$DECISIONS_FILE"
}

log_decision() {
    local path="$1" decision="$2" notes="$3"
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$decision" "$notes" >> "$DECISIONS_FILE"
}

missing_lines_for() {
    local idx="$1" path="$2"
    awk -v hdr="[$idx] $path" '
        $0 == hdr { show = 1; next }
        show && /^\[/ { exit }
        show && /MISSING/ { print }
    ' "$MAP_FILE"
}

restart_project() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "  ERROR: directory does not exist: $dir"
        return 1
    fi
    if [ ! -f "$dir/docker-compose.yml" ] && [ ! -f "$dir/compose.yml" ]; then
        echo "  ERROR: no compose file in $dir"
        return 1
    fi
    echo "  Running: (cd $dir && docker compose up -d)"
    (cd "$dir" && docker compose up -d)
    return $?
}

inspect_project() {
    local compose="$1"
    echo ""
    echo "--- inspect: $compose ---"
    if [ -f "$compose" ]; then
        echo "  file size: $(wc -l < "$compose") lines"
        echo "  --- first 80 lines ---"
        head -80 "$compose"
        echo "  --- end ---"
    else
        echo "  compose file not found at path"
    fi
    echo ""
    printf "Press Enter to return to decision prompt... "
    read -r _
}

parse_map() {
    : > "$TMP_PROJECTS"
    local idx="" path="" compose="" proj="" missing=0

    emit_current() {
        if [ -n "$path" ] && [ "${path:0:1}" = "/" ] && [ -n "$idx" ]; then
            printf '%s\t%s\t%s\t%s\t%d\n' "$idx" "$path" "$compose" "$proj" "$missing" >> "$TMP_PROJECTS"
        fi
        idx=""
        path=""
        compose=""
        proj=""
        missing=0
    }

    while IFS= read -r line; do
        case "$line" in
            \[*)
                emit_current
                idx="${line%%]*}"
                idx="${idx#[}"
                # extract everything after the first "] " or "]" and a space
                path="${line#*] }"
                # strip leading/trailing spaces
                path="${path#"${path%%[![:space:]]*}"}"
                path="${path%"${path##*[![:space:]]}"}"
                ;;
            "    compose: "*)
                compose="${line#    compose: }"
                ;;
            "    project: "*)
                proj="${line#    project: }"
                ;;
            *MISSING*)
                missing=$((missing + 1))
                ;;
            "")
                if [ -n "$idx" ]; then
                    emit_current
                fi
                ;;
        esac
    done < "$MAP_FILE"

    if [ -n "$idx" ]; then
        emit_current
    fi
}

walk_through() {
    local total
    total=$(wc -l < "$TMP_PROJECTS")
    local n=0
    while IFS=$'\t' read -r idx path compose proj missing; do
        n=$((n + 1))
        echo ""
        echo "============================================================"
        echo "Project $n of $total"
        echo "  index:   [$idx]"
        echo "  path:    $path"
        echo "  compose: $compose"
        echo "  project: $proj"
        echo "  missing items: $missing"
        local prior
        prior=$(prior_decision_for "$path")
        if [ -n "$prior" ]; then
            echo "  prior decision: $prior"
        fi
        echo "  --- missing items ---"
        missing_lines_for "$idx" "$path"
        echo "============================================================"

        while :; do
            printf "Decision [R]estart [S]kip [I]nspect [D]efer [Q]uit [?]help: "
            read -r -n 1 choice
            echo ""
            case "$choice" in
                "")
                    # empty input (Enter) — silent re-prompt
                    ;;
                R|r)
                    if restart_project "$path"; then
                        log_decision "$path" "RESTART" "ok"
                        echo "  LOGGED: RESTART"
                    else
                        log_decision "$path" "RESTART" "failed"
                        echo "  LOGGED: RESTART (failed)"
                    fi
                    break
                    ;;
                S|s)
                    log_decision "$path" "SKIP" "user"
                    echo "  LOGGED: SKIP"
                    break
                    ;;
                D|d)
                    log_decision "$path" "DEFER" "user"
                    echo "  LOGGED: DEFER"
                    break
                    ;;
                I|i)
                    inspect_project "$compose"
                    ;;
                Q|q)
                    echo "  Quitting. Progress saved to $DECISIONS_FILE"
                    rm -f "$TMP_PROJECTS"
                    return 1
                    ;;
                \?)
                    echo "  R - run docker compose up -d in project dir"
                    echo "  S - skip"
                    echo "  I - inspect compose file"
                    echo "  D - defer for later review"
                    echo "  Q - quit walk-through"
                    echo "  Enter - re-prompt without action"
                    ;;
                *)
                    echo "  Unknown: '$choice' (press ? for help)"
                    ;;
            esac
        done
    done < "$TMP_PROJECTS"
    rm -f "$TMP_PROJECTS"
    return 0
}

batch_restart() {
    local total
    total=$(wc -l < "$TMP_PROJECTS")
    echo "Batch restart: $total projects."
    printf "Type 'yes' to proceed: "
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        rm -f "$TMP_PROJECTS"
        return 1
    fi
    while IFS=$'\t' read -r idx path compose proj missing; do
        echo ""
        echo "== $path =="
        if restart_project "$path"; then
            log_decision "$path" "RESTART" "batch"
        else
            log_decision "$path" "RESTART" "batch-failed"
        fi
    done < "$TMP_PROJECTS"
    echo ""
    echo "Batch complete. See $DECISIONS_FILE"
    rm -f "$TMP_PROJECTS"
}

batch_skip() {
    local total
    total=$(wc -l < "$TMP_PROJECTS")
    while IFS=$'\t' read -r idx path compose proj missing; do
        log_decision "$path" "SKIP" "batch"
    done < "$TMP_PROJECTS"
    echo "Logged SKIP for all $total projects."
    rm -f "$TMP_PROJECTS"
}

main() {
    if [ ! -f "$MAP_FILE" ]; then
        echo "Map file not found: $MAP_FILE"
        echo "Usage: $0 [path-to-map]"
        return 1
    fi

    parse_map

    local total
    total=$(wc -l < "$TMP_PROJECTS")
    if [ "$total" -eq 0 ]; then
        echo "No affected projects found in $MAP_FILE"
        echo "First 20 lines of map for debugging:"
        head -20 "$MAP_FILE"
        rm -f "$TMP_PROJECTS"
        return 0
    fi

    echo "=== Interactive recovery assistant ==="
    echo "  map:       $MAP_FILE"
    echo "  decisions: $DECISIONS_FILE"
    echo "  projects:  $total"
    echo ""

    echo "--- affected projects ---"
    local n=0
    while IFS=$'\t' read -r idx path compose proj missing; do
        n=$((n + 1))
        printf "%3d. [%s] %s  (%d missing)\n" "$n" "$idx" "$path" "$missing"
        local prior
        prior=$(prior_decision_for "$path")
        if [ -n "$prior" ]; then
            printf "      prior: %s\n" "$prior"
        fi
    done < "$TMP_PROJECTS"
    echo ""

    printf "Mode [W]alk-through [A]ll-restart [S]kip-all [Q]uit: "
    read -r -n 1 mode
    echo ""

    case "$mode" in
        W|w) walk_through ;;
        A|a) batch_restart ;;
        S|s) batch_skip ;;
        Q|q) echo "Quit."; rm -f "$TMP_PROJECTS" ;;
        "") echo "Empty input — nothing selected."; rm -f "$TMP_PROJECTS" ;;
        *) echo "Unknown mode: '$mode'"; rm -f "$TMP_PROJECTS" ;;
    esac
}

main "$@"
