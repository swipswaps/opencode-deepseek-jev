#!/usr/bin/env bash
# Complete the repository reorganization.
# Fixes three bugs from fix-and-reorganize.sh:
#   1. REPO_ROOT resolution: walk up one level if invoked from scripts/
#   2. version-strip exclusion: skip AICode snapshot trees
#   3. symbolic-name disambiguation: use parent UUID prefix, not -N suffix
# Also: relocate mislocated README, archive remaining stragglers.
# Plain ASCII. No sed. No rm -rf. No set -e. No return 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# If the script lives in scripts/, the repo root is one level up.
case "$SCRIPT_DIR" in
    */scripts) REPO_ROOT="$(dirname "$SCRIPT_DIR")" ;;
    *)         REPO_ROOT="$SCRIPT_DIR" ;;
esac

DOCS="$HOME/Documents"
FLAT_DIR="$HOME/dockge-stacks"
ARCHIVE_STAGING="$REPO_ROOT/scripts/archive/stage-opencode-repo"
ARCHIVE_FORENSICS="$REPO_ROOT/scripts/archive/forensics"
LOG="$REPO_ROOT/scripts/finish-reorganize.log"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

main() {
    mkdir -p "$ARCHIVE_STAGING" "$ARCHIVE_FORENSICS" "$REPO_ROOT/scripts"
    : > "$LOG"

    echo "=== Finish reorganize ===" | tee -a "$LOG"
    echo "Script:    $SCRIPT_PATH" | tee -a "$LOG"
    echo "Repo root: $REPO_ROOT" | tee -a "$LOG"
    echo "Flat dir:  $FLAT_DIR" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # -------- STEP 1: relocate misplaced README --------
    echo "=== Step 1: fix README location ===" | tee -a "$LOG"
    local misplaced="$REPO_ROOT/scripts/scripts/README.txt"
    local correct="$REPO_ROOT/scripts/README.txt"
    if [ -f "$misplaced" ]; then
        if [ -f "$correct" ]; then
            echo "  correct README already exists; removing misplaced one" | tee -a "$LOG"
            rm -f "$misplaced"
        else
            mv "$misplaced" "$correct"
            echo "  moved $misplaced -> $correct" | tee -a "$LOG"
        fi
    fi
    if [ -d "$REPO_ROOT/scripts/scripts" ]; then
        rmdir "$REPO_ROOT/scripts/scripts" 2>&1 | tee -a "$LOG" || true
        if [ ! -d "$REPO_ROOT/scripts/scripts" ]; then
            echo "  removed empty scripts/scripts/" | tee -a "$LOG"
        else
            echo "  WARN: scripts/scripts/ not empty:" | tee -a "$LOG"
            ls -la "$REPO_ROOT/scripts/scripts/" 2>&1 | tee -a "$LOG"
        fi
    fi
    echo "" | tee -a "$LOG"

    # -------- STEP 2: archive remaining staging scripts --------
    echo "=== Step 2: archive remaining staging scripts ===" | tee -a "$LOG"
    local moved=0
    for v in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26; do
        for candidate in "$REPO_ROOT/stage-opencode-repo-v${v}.sh" "$REPO_ROOT/scripts/stage-opencode-repo-v${v}.sh"; do
            if [ -f "$candidate" ]; then
                mv "$candidate" "$ARCHIVE_STAGING/"
                echo "  archived: $(basename "$candidate")" | tee -a "$LOG"
                moved=$((moved + 1))
            fi
        done
    done
    echo "  total moved this run: $moved" | tee -a "$LOG"
    echo "  v27 staging script preserved at repo root" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # -------- STEP 3: archive remaining forensics scripts --------
    echo "=== Step 3: archive remaining forensics scripts ===" | tee -a "$LOG"
    for name in map-removed-containers.sh investigate-removed-containers.sh recover-deleted-docker-configs.sh interactive-recovery.sh; do
        for candidate in "$REPO_ROOT/$name" "$REPO_ROOT/scripts/$name"; do
            if [ -f "$candidate" ]; then
                mv "$candidate" "$ARCHIVE_FORENSICS/"
                echo "  archived: $candidate" | tee -a "$LOG"
            fi
        done
    done
    echo "" | tee -a "$LOG"

    # -------- STEP 4: rebuild flat symlinks with UUID prefix --------
    echo "=== Step 4: rebuild flat symlinks with disambiguation ===" | tee -a "$LOG"
    mkdir -p "$FLAT_DIR"

    local removed=0
    for existing in "$FLAT_DIR"/*; do
        if [ -L "$existing" ]; then
            rm -f "$existing"
            removed=$((removed + 1))
        fi
    done
    echo "  removed old symlinks: $removed" | tee -a "$LOG"

    local linked=0
    local skipped=0

    while IFS= read -r line; do
        case "$line" in
            /*) ;;
            *) continue ;;
        esac
        [ -f "$line" ] || continue

        local dir
        dir=$(dirname "$line")

        # exclude AICode snapshot trees
        case "$dir" in
            */scripts/AICode/*) skipped=$((skipped + 1)); continue ;;
        esac

        # build name: <basename>-<uuid-prefix>
        # extract the first UUID-looking token from the path
        local base
        base=$(basename "$dir")
        local uuid=""
        local rest="$dir"
        while [ -n "$rest" ] && [ "$rest" != "/" ]; do
            local seg
            seg=$(basename "$rest")
            case "$seg" in
                [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*)
                    uuid="${seg%%-*}"
                    break
                    ;;
            esac
            rest=$(dirname "$rest")
        done

        local sane
        sane=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | head -c 50)
        sane="${sane%-}"

        local name
        if [ -n "$uuid" ]; then
            name="${sane}-${uuid}"
        else
            name="$sane"
        fi

        # if this exact name exists, fall back to full-path hash
        if [ -e "$FLAT_DIR/$name" ]; then
            local hash
            hash=$(printf '%s' "$dir" | sha256sum | head -c 8)
            name="${sane}-${hash}"
        fi

        ln -s "$dir" "$FLAT_DIR/$name"
        if [ $? -eq 0 ]; then
            echo "  LINK $name -> $dir" | tee -a "$LOG"
            linked=$((linked + 1))
        fi
    done < <(find "$DOCS" -maxdepth 8 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>&1)

    echo "" | tee -a "$LOG"
    echo "  symlinks created: $linked" | tee -a "$LOG"
    echo "  AICode snapshots skipped: $skipped" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # -------- STEP 5: restart Dockge --------
    echo "=== Step 5: restart Dockge ===" | tee -a "$LOG"
    if [ -f "$HOME/dockge/docker-compose.yml" ]; then
        (cd "$HOME/dockge" && docker compose up -d 2>&1 | tee -a "$LOG")
        echo "  PASS: Dockge restarted" | tee -a "$LOG"
    else
        echo "  SKIP: $HOME/dockge/docker-compose.yml not found" | tee -a "$LOG"
    fi
    echo "" | tee -a "$LOG"

    # -------- STEP 6: report current repo layout --------
    echo "=== Step 6: current repo layout ===" | tee -a "$LOG"
    echo "--- repo root ---" | tee -a "$LOG"
    ls -la "$REPO_ROOT" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "--- scripts/ ---" | tee -a "$LOG"
    ls -la "$REPO_ROOT/scripts" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "--- scripts/archive/stage-opencode-repo/ ---" | tee -a "$LOG"
    ls -la "$ARCHIVE_STAGING" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "--- scripts/archive/forensics/ ---" | tee -a "$LOG"
    ls -la "$ARCHIVE_FORENSICS" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # -------- STEP 7: flat directory preview --------
    echo "=== Step 7: flat directory ($linked entries) ===" | tee -a "$LOG"
    for f in "$FLAT_DIR"/*; do
        if [ -L "$f" ]; then
            printf "  %-45s -> %s\n" "$(basename "$f")" "$(readlink "$f")" | tee -a "$LOG"
        fi
    done
    echo "" | tee -a "$LOG"

    echo "=== Done ===" | tee -a "$LOG"
    echo "Log: $LOG" | tee -a "$LOG"
}

main "$@"
