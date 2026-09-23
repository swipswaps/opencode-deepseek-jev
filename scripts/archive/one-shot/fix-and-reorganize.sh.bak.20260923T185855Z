#!/usr/bin/env bash
# Fix Dockge-side issues (obsolete version field, cluttered symlinks) and
# reorganize the repo (archive dead scripts, keep the current operating set).
#
# Actions:
#   1. Strip obsolete "version:" from every compose file, with backups.
#   2. Rebuild ~/dockge-stacks symlinks: clean names, no scripts/AICode noise.
#   3. Archive old staging scripts and one-shot forensics scripts.
#   4. Write scripts/README.txt describing the new layout.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS="$HOME/Documents"
FLAT_DIR="$HOME/dockge-stacks"
DOCKGE_DIR="$HOME/dockge"
ARCHIVE_STAGING="$REPO_DIR/scripts/archive/stage-opencode-repo"
ARCHIVE_FORENSICS="$REPO_DIR/scripts/archive/forensics"
LOG="$REPO_DIR/fix-and-reorganize.log"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

main() {
    : > "$LOG"
    echo "=== Fix and reorganize ===" | tee -a "$LOG"
    echo "Timestamp: $TIMESTAMP" | tee -a "$LOG"
    echo "Repo:      $REPO_DIR" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ---------- STEP 1: strip obsolete version: from compose files ----------
    echo "=== Step 1: strip obsolete version: from compose files ===" | tee -a "$LOG"
    local compose_file
    local stripped=0
    local skipped=0

    while IFS= read -r compose_file; do
        case "$compose_file" in
            /*) ;;
            *) continue ;;
        esac
        [ -f "$compose_file" ] || continue

        # check if the file has a top-level version: line
        if grep -qE '^version:[[:space:]]*["'"'"']?[0-9]' "$compose_file" 2>&1; then
            # back up once
            local backup="$compose_file.bak-$TIMESTAMP"
            if [ ! -f "$backup" ]; then
                cp "$compose_file" "$backup"
            fi
            # strip via python3 (file I/O only, no subprocess)
            python3 - "$compose_file" <<'PY_EOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
new = re.sub(r'^version:[^\n]*\n', '', content, count=1, flags=re.MULTILINE)
if new != content:
    with open(path, 'w') as f:
        f.write(new)
    print("STRIPPED " + path)
else:
    print("NOCHANGE " + path)
PY_EOF
            stripped=$((stripped + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < <(find "$DOCS" -maxdepth 8 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>&1)

    echo "  files processed: $stripped" | tee -a "$LOG"
    echo "  files already clean: $skipped" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ---------- STEP 2: rebuild flat symlinks ----------
    echo "=== Step 2: rebuild flat symlinks ===" | tee -a "$LOG"
    mkdir -p "$FLAT_DIR"

    # remove existing symlinks (only symlinks, never real files)
    local removed=0
    for existing in "$FLAT_DIR"/*; do
        if [ -L "$existing" ]; then
            rm -f "$existing"
            removed=$((removed + 1))
        fi
    done
    echo "  removed old symlinks: $removed" | tee -a "$LOG"

    # re-scan and create clean links
    local linked=0
    local skipped_aicode=0

    while IFS= read -r line; do
        case "$line" in
            /*) ;;
            *) continue ;;
        esac
        [ -f "$line" ] || continue

        local dir
        dir=$(dirname "$line")

        # exclude backup snapshot trees
        case "$dir" in
            */scripts/AICode/*) skipped_aicode=$((skipped_aicode + 1)); continue ;;
        esac

        local base
        base=$(basename "$dir")
        # sanitize: lowercase, replace non-alnum with '-'
        local sane
        sane=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | head -c 60)
        # drop trailing dashes
        sane="${sane%-}"
        [ -z "$sane" ] && sane="stack"

        # disambiguate: check if a symlink with this name already exists
        local candidate="$sane"
        local i=2
        while [ -e "$FLAT_DIR/$candidate" ]; do
            candidate="${sane}-${i}"
            i=$((i + 1))
        done

        local link_path="$FLAT_DIR/$candidate"
        ln -s "$dir" "$link_path"
        if [ $? -eq 0 ]; then
            echo "  LINK $candidate -> $dir" | tee -a "$LOG"
            linked=$((linked + 1))
        else
            echo "  FAIL $candidate -> $dir" | tee -a "$LOG"
        fi
    done < <(find "$DOCS" -maxdepth 8 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>&1)

    echo "" | tee -a "$LOG"
    echo "  symlinks created: $linked" | tee -a "$LOG"
    echo "  AICode snapshots skipped: $skipped_aicode" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ---------- STEP 3: archive dead scripts ----------
    echo "=== Step 3: archive dead scripts ===" | tee -a "$LOG"
    mkdir -p "$ARCHIVE_STAGING" "$ARCHIVE_FORENSICS"

    local moved_staging=0
    for v in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26; do
        local f="$REPO_DIR/stage-opencode-repo-v${v}.sh"
        if [ -f "$f" ]; then
            mv "$f" "$ARCHIVE_STAGING/"
            moved_staging=$((moved_staging + 1))
        fi
        local g="$REPO_DIR/scripts/stage-opencode-repo-v${v}.sh"
        if [ -f "$g" ]; then
            mv "$g" "$ARCHIVE_STAGING/"
        fi
    done
    echo "  staging scripts archived: $moved_staging" | tee -a "$LOG"

    for name in map-removed-containers.sh investigate-removed-containers.sh recover-deleted-docker-configs.sh interactive-recovery.sh; do
        local f="$REPO_DIR/$name"
        if [ -f "$f" ]; then
            mv "$f" "$ARCHIVE_FORENSICS/"
            echo "  archived: $name" | tee -a "$LOG"
        fi
        local g="$REPO_DIR/scripts/$name"
        if [ -f "$g" ]; then
            mv "$g" "$ARCHIVE_FORENSICS/"
        fi
    done
    echo "" | tee -a "$LOG"

    # ---------- STEP 4: write scripts/README.txt ----------
    echo "=== Step 4: write scripts/README.txt ===" | tee -a "$LOG"
    local readme="$REPO_DIR/scripts/README.txt"
    cat > "$readme" <<README_EOF
Repository scripts
==================

Active operating scripts
------------------------

deploy-dockge.sh
    Install and start Dockge. Reads compose files from
    \$HOME/dockge-stacks. Web UI on http://localhost:5001.

flatten-dockge-stacks.sh
    Discover every compose file under \$HOME/Documents and create a
    symlink in \$HOME/dockge-stacks. Required because Dockge scans a
    directory non-recursively.

fix-and-reorganize.sh
    Strip obsolete "version:" from compose files; rebuild clean
    symlink names; archive dead scripts. Idempotent. Re-runnable.

stage-opencode-repo-v27.sh
    Build and publish the OpenCode + DeepSeek V4.1 Flash + Jev Docker
    environment. Superseded only by a v28 if the image changes.

Archived (see scripts/archive/)
-------------------------------

archive/stage-opencode-repo/v10-v26
    Historical iterations of the staging script. Kept for reference.
    v27 is the only version that should be run.

archive/forensics/
    One-shot recovery tools written before Dockge was deployed:
      - map-removed-containers.sh
      - investigate-removed-containers.sh
      - recover-deleted-docker-configs.sh
      - interactive-recovery.sh
    Dockge's stack tile grid replaces the interactive script entirely.

Operating model
---------------

1. Add a new project: create docker-compose.yml under \$HOME/Documents
2. Refresh Dockge's view: run scripts/flatten-dockge-stacks.sh
3. Manage the stack: click its tile at http://localhost:5001

Volume name caveat
------------------

When a compose file lives behind a symlink, Docker Compose derives the
project name from the SYMLINK basename, not the target directory. Named
volumes become <symlink-name>_<volume-name>. If you rename a symlink,
its named volumes are recreated empty under the new prefix. The old
volumes remain as orphans in docker volume ls. Inspect them before
deleting.

To pin a project name regardless of the symlink:
    Add "name: <explicit-name>" as the first top-level key of the
    compose file. Compose v2 honours it over the directory name.
README_EOF

    echo "  wrote $readme" | tee -a "$LOG"
    echo "" | tee -a "$LOG"

    # ---------- STEP 5: restart Dockge ----------
    echo "=== Step 5: restart Dockge ===" | tee -a "$LOG"
    if [ -f "$DOCKGE_DIR/docker-compose.yml" ]; then
        (cd "$DOCKGE_DIR" && docker compose up -d 2>&1 | tee -a "$LOG")
        local rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "  PASS: Dockge restarted" | tee -a "$LOG"
        else
            echo "  FAIL: docker compose up -d returned $rc" | tee -a "$LOG"
        fi
    else
        echo "  SKIP: $DOCKGE_DIR/docker-compose.yml not found" | tee -a "$LOG"
    fi
    echo "" | tee -a "$LOG"

    # ---------- SUMMARY ----------
    echo "=== Done ===" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Reload http://localhost:5001" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "The sidebar should now show:" | tee -a "$LOG"
    echo "  - clean symlink names (no hash prefixes)" | tee -a "$LOG"
    echo "  - no scripts/AICode duplicates" | tee -a "$LOG"
    echo "  - no obsolete version warnings when starting a stack" | tee -a "$LOG"
    echo "" | tee -a "$LOG"
    echo "Log: $LOG" | tee -a "$LOG"
}

main "$@"
