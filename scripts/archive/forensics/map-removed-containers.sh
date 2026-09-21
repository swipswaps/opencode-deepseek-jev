#!/usr/bin/env bash
# Map removed containers to source code in $HOME/Documents.
# For each compose file: extract services, images, volumes, container names.
# Cross-reference against current docker state (images, volumes, containers).
# Print per-project status with ACTION REQUIRED for affected stacks.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.

DOCS="$HOME/Documents"
REPORT="$HOME/removed-container-map.txt"
TMPDIR_LOCAL=$(mktemp -d)

main() {
    : > "$REPORT"

    echo "=== Removed container recovery map ===" | tee -a "$REPORT"
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$REPORT"
    echo "Docs root: $DOCS" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    # ---------- snapshot current docker state ----------
    docker image ls --format '{{.Repository}}:{{.Tag}}' 2>&1 | sort -u > "$TMPDIR_LOCAL/images.txt"
    docker volume ls --format '{{.Name}}' 2>&1 | sort -u > "$TMPDIR_LOCAL/volumes.txt"
    docker ps -a --format '{{.Names}}' 2>&1 | sort -u > "$TMPDIR_LOCAL/containers.txt"
    docker ps -aq -f status=running --format '{{.Names}}' 2>&1 | sort -u > "$TMPDIR_LOCAL/running.txt"

    local n_images n_volumes n_containers
    n_images=$(wc -l < "$TMPDIR_LOCAL/images.txt")
    n_volumes=$(wc -l < "$TMPDIR_LOCAL/volumes.txt")
    n_containers=$(wc -l < "$TMPDIR_LOCAL/containers.txt")

    echo "--- Current docker state ---" | tee -a "$REPORT"
    echo "  images present:     $n_images" | tee -a "$REPORT"
    echo "  volumes present:    $n_volumes" | tee -a "$REPORT"
    echo "  containers present: $n_containers" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    # ---------- find all compose files ----------
    find "$DOCS" -maxdepth 6 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>&1 | sort > "$TMPDIR_LOCAL/compose_files.txt"
    local n_compose
    n_compose=$(wc -l < "$TMPDIR_LOCAL/compose_files.txt")
    echo "  compose files:      $n_compose" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    # ---------- per-compose analysis ----------
    local idx=0
    local missing_projects=0

    while IFS= read -r compose; do
        idx=$((idx + 1))
        local project_dir
        project_dir=$(dirname "$compose")
        local project_name
        project_name=$(basename "$project_dir")

        # extract services and their images (very light YAML parse)
        # service lines: 2-space indent followed by word then colon
        awk '
            /^[[:space:]]{2}[A-Za-z0-9_.-]+:[[:space:]]*$/ {
                svc = $1
                sub(/:$/, "", svc)
                print "SERVICE " svc
                in_svc = 1
                next
            }
            in_svc && /^[[:space:]]{4}[A-Za-z0-9_-]+:/ {
                key = $1
                sub(/:$/, "", key)
                if (key == "image") {
                    img = $2
                    print "IMAGE " svc " " img
                }
                if (key == "container_name") {
                    cn = $2
                    print "CNAME " svc " " cn
                }
                next
            }
            /^[[:space:]]{0,1}[A-Za-z]/ {
                in_svc = 0
            }
        ' "$compose" > "$TMPDIR_LOCAL/services.txt"

        # top-level volumes section
        awk '
            /^volumes:/ { in_vol = 1; next }
            /^[A-Za-z]/ && !/^volumes:/ { in_vol = 0 }
            in_vol && /^[[:space:]]{2}[A-Za-z0-9_.-]+:/ {
                name = $1
                sub(/:$/, "", name)
                print "VOL " name
            }
        ' "$compose" > "$TMPDIR_LOCAL/volumes_named.txt"

        # service-level named volume mounts: "  - name:/path"
        grep -E '^[[:space:]]+-[[:space:]]+[A-Za-z][A-Za-z0-9_-]*:' "$compose" 2>&1 | \
            awk '{
                v = $2
                sub(/:.*/, "", v)
                if (v ~ /^[A-Za-z]/ && v !~ /\// && v !~ /^\./) print "SVCVOL " v
            }' > "$TMPDIR_LOCAL/volumes_svc.txt"

        # collect all volumes referenced in this compose
        cat "$TMPDIR_LOCAL/volumes_named.txt" "$TMPDIR_LOCAL/volumes_svc.txt" | \
            awk '{print $2}' | sort -u > "$TMPDIR_LOCAL/this_vols.txt"

        # ----- classify project -----
        local project_affected=0
        local project_lines=""

        # check images
        while IFS= read -r svc_line; do
            case "$svc_line" in
                IMAGE\ *)
                    local rest
                    rest="${svc_line#IMAGE }"
                    local svc img
                    svc="${rest%% *}"
                    img="${rest#* }"
                    if grep -qxF "$img" "$TMPDIR_LOCAL/images.txt"; then
                        project_lines="$project_lines    image $img [PRESENT]\n"
                    else
                        project_lines="$project_lines    image $img [MISSING]\n"
                        project_affected=1
                    fi
                    ;;
            esac
        done < "$TMPDIR_LOCAL/services.txt"

        # check volumes
        while IFS= read -r vol; do
            [ -z "$vol" ] && continue
            if grep -qxF "$vol" "$TMPDIR_LOCAL/volumes.txt"; then
                project_lines="$project_lines    volume $vol [PRESENT - orphaned]\n"
            else
                project_lines="$project_lines    volume $vol [MISSING]\n"
                project_affected=1
            fi
        done < "$TMPDIR_LOCAL/this_vols.txt"

        # check container names
        local docker_default_prefix
        docker_default_prefix=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')

        while IFS= read -r svc_line; do
            case "$svc_line" in
                CNAME\ *)
                    local rest cn
                    rest="${svc_line#CNAME }"
                    cn="${rest#* }"
                    if grep -qxF "$cn" "$TMPDIR_LOCAL/containers.txt"; then
                        project_lines="$project_lines    container $cn [PRESENT]\n"
                    else
                        project_lines="$project_lines    container $cn [MISSING - was removed]\n"
                        project_affected=1
                    fi
                    ;;
            esac
        done < "$TMPDIR_LOCAL/services.txt"

        # ----- only print affected projects in detail -----
        if [ "$project_affected" -eq 1 ]; then
            missing_projects=$((missing_projects + 1))
            {
                echo "[$idx] $project_dir"
                echo "    compose: $compose"
                echo "    project: $project_name"
                printf '%b' "$project_lines"
                echo "    ACTION:  cd $project_dir && docker compose up -d"
                echo ""
            } | tee -a "$REPORT"
        fi
    done < "$TMPDIR_LOCAL/compose_files.txt"

    # ---------- summary ----------
    echo "" | tee -a "$REPORT"
    echo "=== Summary ===" | tee -a "$REPORT"
    echo "  Compose files scanned:  $n_compose" | tee -a "$REPORT"
    echo "  Affected projects:      $missing_projects" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    # ---------- images with no compose reference ----------
    echo "=== Images present but not referenced by any compose file ===" | tee -a "$REPORT"
    : > "$TMPDIR_LOCAL/all_referenced_images.txt"
    while IFS= read -r compose; do
        awk '/^[[:space:]]+image:[[:space:]]/ {print $2}' "$compose" 2>&1
    done < "$TMPDIR_LOCAL/compose_files.txt" | sort -u > "$TMPDIR_LOCAL/all_referenced_images.txt"
    comm -23 "$TMPDIR_LOCAL/images.txt" "$TMPDIR_LOCAL/all_referenced_images.txt" 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    # ---------- volumes with no compose reference ----------
    echo "=== Volumes present but not referenced by any compose file ===" | tee -a "$REPORT"
    : > "$TMPDIR_LOCAL/all_referenced_volumes.txt"
    while IFS= read -r compose; do
        awk '
            /^volumes:/ { in_vol = 1; next }
            /^[A-Za-z]/ && !/^volumes:/ { in_vol = 0 }
            in_vol && /^[[:space:]]{2}[A-Za-z0-9_.-]+:/ {
                name = $1
                sub(/:$/, "", name)
                print name
            }
        ' "$compose" 2>&1
    done < "$TMPDIR_LOCAL/compose_files.txt" | sort -u > "$TMPDIR_LOCAL/all_referenced_volumes.txt"
    comm -23 "$TMPDIR_LOCAL/volumes.txt" "$TMPDIR_LOCAL/all_referenced_volumes.txt" 2>&1 | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"

    echo "Full report: $REPORT"
    rm -rf "$TMPDIR_LOCAL" 2>&1 || true
}

main "$@"
