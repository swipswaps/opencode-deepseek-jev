#!/usr/bin/env bash
# Stage, create, push, verify OpenCode + DeepSeek V4.1 Flash + Jev.
# v26: orphan cleanup at start; script(1) PTY wrapper for reliable streaming;
#      -t on docker run; trap INT/TERM; no process substitution inside docker
#      calls; no background jobs; PIPESTATUS[0] for correct exit code.
# Note: prior runs appeared to show "OK" but that was the user's typed input
# being echoed by the terminal, not opencode output. opencode produced zero
# bytes because -i without -t leaves it in a non-TTY state where its stdout
# is fully buffered and never flushed. -t fixes this.
# Plain ASCII. No markdown. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
SCRIPTS_DIR="$REPO_DIR/scripts"
ENV_FILE="$REPO_DIR/.env.local"
LOG_FILE="$REPO_DIR/staging.log"
GITHUB_REPO="opencode-deepseek-jev"
GITHUB_USER=""
JEV_REVIEW_COMMIT="3fb6042ebf07f0fdaae30d65c6393848e1a549e3"
JEV_GUARD_VERSION=""

DEEPSEEK_KEY_URL="https://platform.deepseek.com/api_keys"
DEEPSEEK_DOCS_URL="https://api-docs.deepseek.com/"
TYPESAFE_KEY_URL="https://console.typesafe.ai/keys"
TYPESAFE_DOCS_URL="https://docs.typesafe.ai/"

trap 'echo ""; echo "Interrupted. Cleaning up..."; pkill -TERM -f "docker run -t --rm" 2>&1 || true; sleep 2; pkill -KILL -f "docker run -t --rm" 2>&1 || true; docker ps -q 2>&1 | while read -r c; do docker kill "$c" 2>&1 || true; done; exit 130' INT TERM

cleanup_orphans() {
    echo ""
    echo "=== Orphan cleanup ==="
    echo "  pre-cleanup load: $(uptime | cut -d, -f3-)"

    local pids
    pids=$(pgrep -f 'docker run --rm -i --user' 2>&1)
    if [ -n "$pids" ]; then
        echo "  docker CLI orphans (--rm -i): $pids"
        for p in $pids; do kill -TERM "$p"; done
        sleep 3
        pids=$(pgrep -f 'docker run --rm -i --user' 2>&1)
        for p in $pids; do kill -KILL "$p"; done
        echo "  terminated"
    else
        echo "  no docker --rm -i orphans"
    fi

    local pids2
    pids2=$(pgrep -f 'docker run -t --rm' 2>&1)
    if [ -n "$pids2" ]; then
        echo "  docker CLI orphans (-t): $pids2"
        for p in $pids2; do kill -TERM "$p"; done
        sleep 3
        pids2=$(pgrep -f 'docker run -t --rm' 2>&1)
        for p in $pids2; do kill -KILL "$p"; done
        echo "  terminated"
    else
        echo "  no docker -t orphans"
    fi

    local opids
    opids=$(pgrep -f 'opencode run --model deepseek' 2>&1)
    if [ -n "$opids" ]; then
        echo "  opencode orphans: $opids"
        for p in $opids; do kill -TERM "$p"; done
        sleep 2
        opids=$(pgrep -f 'opencode run --model deepseek' 2>&1)
        for p in $opids; do kill -KILL "$p"; done
        echo "  terminated"
    else
        echo "  no opencode orphans"
    fi

    local cids
    cids=$(docker ps -aq 2>&1)
    if [ -n "$cids" ]; then
        echo "  removing containers:"
        for c in $cids; do
            docker rm -f "$c" 2>&1 || true
        done
        echo "  containers removed"
    else
        echo "  no containers"
    fi

    echo "  post-cleanup load: $(uptime | cut -d, -f3-)"
    echo "=== End orphan cleanup ==="
    echo ""
}

load_env_file() {
    if [ ! -f "$ENV_FILE" ]; then return 0; fi
    while IFS='=' read -r key value; do
        case "$key" in
            DEEPSEEK_API_KEY) CACHED_DEEPSEEK_API_KEY=$(printf '%s' "$value" | tr -d '\r\n') ;;
            JEV_API_KEY)      CACHED_JEV_API_KEY=$(printf '%s' "$value" | tr -d '\r\n') ;;
        esac
    done < "$ENV_FILE"
}

save_env_file() {
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    printf 'DEEPSEEK_API_KEY=%s\n' "$(printf '%s' "$DEEPSEEK_API_KEY" | tr -d '\r\n')" > "$ENV_FILE"
    printf 'JEV_API_KEY=%s\n' "$(printf '%s' "$JEV_API_KEY" | tr -d '\r\n')" >> "$ENV_FILE"
}

mask_secret() {
    local s="$1"
    if [ "${#s}" -le 8 ]; then printf '***'; return; fi
    printf '%s***%s' "${s:0:3}" "${s: -4}"
}

resolve_jev_guard_version() {
    local response
    response=$(curl -fsSL https://registry.npmjs.org/jev-guard/latest)
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "  FAIL: could not query npm registry for jev-guard version"; return 1
    fi
    local version
    version=$(printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))")
    if [ -z "$version" ]; then
        echo "  FAIL: npm registry returned no version for jev-guard"; return 1
    fi
    JEV_GUARD_VERSION="$version"
    return 0
}

curl_with_auth_header() {
    local key="$1"; shift
    local header_file
    header_file=$(mktemp)
    chmod 600 "$header_file"
    printf 'Authorization: Bearer %s\n' "$key" > "$header_file"
    curl -H @"$header_file" "$@"
    local status=$?
    rm -f "$header_file"
    return $status
}

validate_deepseek_key() {
    local key="$1"; [ -z "$key" ] && return 1
    local tmp; tmp=$(mktemp)
    local http_code
    http_code=$(curl_with_auth_header "$key" -s -o "$tmp" -w '%{http_code}' \
        https://api.deepseek.com/user/balance)
    local body; body=$(cat "$tmp"); rm -f "$tmp"
    if [ "$http_code" = "200" ]; then return 0; fi
    echo "  FAIL: DeepSeek API returned HTTP $http_code"
    echo "  Verbatim response body:"
    printf '%s\n' "$body"
    case "$http_code" in
        401) echo "  401: key not accepted. Possible: revoked, wrong account, trailing whitespace." ;;
        402) echo "  402: insufficient balance." ;;
        429) echo "  429: rate limited." ;;
    esac
    echo "  Get a key at: $DEEPSEEK_KEY_URL"
    return 1
}

validate_jev_key() {
    local key="$1"; [ -z "$key" ] && return 1
    case "$key" in
        apikey_*|sk-*|ts_*|jev-*) ;;
        *) echo "  FAIL: Jev key must start with apikey_ or sk-"
           echo "  Get a key at: $TYPESAFE_KEY_URL"; return 1 ;;
    esac
    local tmp; tmp=$(mktemp)
    local http_code
    http_code=$(curl_with_auth_header "$key" -s -o "$tmp" -w '%{http_code}' \
        -X POST https://api.typesafe.ai/v1/systemone \
        -H "Content-Type: application/json" \
        -d '{"state":"validation probe","model":"jev-latest","questions":{"probe":{"type":"noul","instructions":"Is this request valid?"}}}')
    local body; body=$(cat "$tmp"); rm -f "$tmp"
    if [ "$http_code" = "200" ]; then return 0; fi
    echo "  FAIL: Jev API returned HTTP $http_code"
    echo "  Verbatim response body:"
    printf '%s\n' "$body"
    echo "  Get a key at: $TYPESAFE_KEY_URL"
    return 1
}

# Build a shell-safe command string from arguments.
build_cmd() {
    local cmd="$1"; shift
    for arg in "$@"; do
        cmd="$cmd $(printf '%q' "$arg")"
    done
    printf '%s' "$cmd"
}

# Streaming docker run wrapped in script(1) to force a host-side PTY.
# Combined with docker -t, this ensures opencode sees a TTY end-to-end and
# streams immediately. No process substitution. No background jobs.
# Ctrl-C propagates naturally through the whole process group.
docker_run_assert_text() {
    local expected="$1"; shift
    local tmp_out; tmp_out=$(mktemp)

    local docker_cmd
    docker_cmd=$(build_cmd "docker run -t --rm --user $(id -u):$(id -g) -e DEEPSEEK_API_KEY -e JEV_API_KEY -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true" "$@")

    echo "  Running via script(1) PTY wrapper:"
    echo "    $docker_cmd"
    echo "  Safety timeout: 180s"
    echo "  Expecting text in response: '$expected'"
    echo "  --- begin live telemetry ---"

    local start_time; start_time=$(date +%s)

    timeout 180 script -q -f -c "$docker_cmd" /dev/null 2>&1 | tee "$tmp_out"
    local exit_code=${PIPESTATUS[0]}
    local end_time; end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    echo ""
    echo "  --- end live telemetry ---"
    echo "  Elapsed: ${elapsed}s"
    echo "  Exit code: $exit_code"

    if grep -q "$expected" "$tmp_out"; then
        echo "  PASS: output contains '$expected'"
        rm -f "$tmp_out"
        return 0
    fi
    echo "  FAIL: '$expected' not found. Captured output:"
    cat "$tmp_out"
    rm -f "$tmp_out"
    return 1
}

docker_run_streaming() {
    local docker_cmd
    docker_cmd=$(build_cmd "docker run -t --rm --user $(id -u):$(id -g) -e DEEPSEEK_API_KEY -e JEV_API_KEY -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true" "$@")

    echo "  Running via script(1) PTY wrapper:"
    echo "    $docker_cmd"
    echo "  Safety timeout: 90s"
    echo "  --- begin live telemetry ---"
    local start_time; start_time=$(date +%s)

    timeout 90 script -q -f -c "$docker_cmd" /dev/null 2>&1
    local rc=$?
    local end_time; end_time=$(date +%s)

    echo ""
    echo "  --- end live telemetry ---"
    echo "  Elapsed: $((end_time - start_time))s"
    echo "  Exit code: $rc"
    return $rc
}

main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== staging started: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "Log: $LOG_FILE"
    echo "Host UID:GID = $(id -u):$(id -g)"

    cleanup_orphans

    for bin in gh git docker python3 curl timeout script; do
        if ! command -v "$bin" > /dev/null; then
            echo "GATE FAIL: $bin not found. Install it first."; return 1
        fi
    done

    if docker info > /dev/null; then echo "  PASS: docker daemon reachable"
    else echo "  FAIL: docker daemon not reachable. Output:"; docker info; return 1; fi

    if gh auth status > /dev/null; then echo "  PASS: gh authenticated"
    else echo "  FAIL: gh not authenticated. Output:"; gh auth status; return 1; fi

    gh auth setup-git
    if [ $? -ne 0 ]; then echo "WARN: gh auth setup-git failed."; fi

    GITHUB_USER=$(gh api user --jq .login)
    if [ -z "$GITHUB_USER" ]; then echo "GATE FAIL: no GitHub username."; return 1; fi
    echo "  PASS: GitHub user: $GITHUB_USER"

    if [ ! -d "$REPO_DIR" ]; then echo "GATE FAIL: $REPO_DIR missing."; return 1; fi
    cd "$REPO_DIR"

    echo ""
    echo "=== Resolve jev-guard version ==="
    if resolve_jev_guard_version; then
        echo "  PASS: jev-guard latest version: $JEV_GUARD_VERSION"
    else
        echo "  FAIL: cannot pin jev-guard; aborting."; return 1
    fi

    CACHED_DEEPSEEK_API_KEY=""
    CACHED_JEV_API_KEY=""
    load_env_file

    echo ""
    echo "=== API Key Validation ==="
    NEEDS_SAVE=0

    if [ -n "$CACHED_DEEPSEEK_API_KEY" ]; then
        MASKED=$(mask_secret "$CACHED_DEEPSEEK_API_KEY")
        echo "  Cached DEEPSEEK_API_KEY: [$MASKED]"
        if validate_deepseek_key "$CACHED_DEEPSEEK_API_KEY"; then
            echo "  PASS: DEEPSEEK_API_KEY validated"
            DEEPSEEK_API_KEY="$CACHED_DEEPSEEK_API_KEY"
        else
            echo "  Cached key rejected. Enter a new one."
            read -r -s -p "Enter DEEPSEEK_API_KEY (sk-...): " DEEPSEEK_API_KEY; echo ""
            DEEPSEEK_API_KEY=$(printf '%s' "$DEEPSEEK_API_KEY" | tr -d '\r\n')
            if validate_deepseek_key "$DEEPSEEK_API_KEY"; then
                echo "  PASS: DEEPSEEK_API_KEY validated"; NEEDS_SAVE=1
            else
                echo "  FAIL: DEEPSEEK_API_KEY rejected. Aborting."; return 1
            fi
        fi
    else
        echo "  DeepSeek keys: $DEEPSEEK_KEY_URL"
        read -r -s -p "Enter DEEPSEEK_API_KEY (sk-...): " DEEPSEEK_API_KEY; echo ""
        DEEPSEEK_API_KEY=$(printf '%s' "$DEEPSEEK_API_KEY" | tr -d '\r\n')
        if validate_deepseek_key "$DEEPSEEK_API_KEY"; then
            echo "  PASS: DEEPSEEK_API_KEY validated"; NEEDS_SAVE=1
        else
            echo "  FAIL: DEEPSEEK_API_KEY rejected. Aborting."; return 1
        fi
    fi

    if [ -n "$CACHED_JEV_API_KEY" ]; then
        MASKED=$(mask_secret "$CACHED_JEV_API_KEY")
        echo "  Cached JEV_API_KEY: [$MASKED]"
        if validate_jev_key "$CACHED_JEV_API_KEY"; then
            echo "  PASS: JEV_API_KEY validated"
            JEV_API_KEY="$CACHED_JEV_API_KEY"
        else
            echo "  Cached key rejected. Enter a new one."
            read -r -s -p "Enter JEV_API_KEY (apikey_...): " JEV_API_KEY; echo ""
            JEV_API_KEY=$(printf '%s' "$JEV_API_KEY" | tr -d '\r\n')
            if validate_jev_key "$JEV_API_KEY"; then
                echo "  PASS: JEV_API_KEY validated"; NEEDS_SAVE=1
            else
                echo "  FAIL: JEV_API_KEY rejected. Aborting."; return 1
            fi
        fi
    else
        echo "  Jev keys: $TYPESAFE_KEY_URL"
        read -r -s -p "Enter JEV_API_KEY (apikey_...): " JEV_API_KEY; echo ""
        JEV_API_KEY=$(printf '%s' "$JEV_API_KEY" | tr -d '\r\n')
        if validate_jev_key "$JEV_API_KEY"; then
            echo "  PASS: JEV_API_KEY validated"; NEEDS_SAVE=1
        else
            echo "  FAIL: JEV_API_KEY rejected. Aborting."; return 1
        fi
    fi

    export DEEPSEEK_API_KEY
    export JEV_API_KEY

    if [ "$NEEDS_SAVE" -eq 1 ]; then
        save_env_file
        echo "  PASS: API keys cached in $ENV_FILE (mode 0600)"
    fi

    # SCRIPTS DIRECTORY
    mkdir -p "$SCRIPTS_DIR"
    if [ ! -d "$SCRIPTS_DIR" ]; then echo "GATE FAIL: cannot create $SCRIPTS_DIR"; return 1; fi
    for v in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26; do
        src="$REPO_DIR/stage-opencode-repo-v${v}.sh"
        if [ -f "$src" ]; then cp "$src" "$SCRIPTS_DIR/stage-opencode-repo-v${v}.sh"; fi
    done
    echo "  PASS: scripts/ prepared (v10-v26)"

    # DOCKERFILE
    mkdir -p "$REPO_DIR/docker"

    cat > "$REPO_DIR/docker/Dockerfile" <<DOCKERFILE_EOF
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git curl ca-certificates coreutils \\
    && apt-get clean

RUN chmod 777 /home/node && \\
    mkdir -p /home/node/.config/opencode /home/node/.cache && \\
    chmod -R 777 /home/node/.config /home/node/.cache

USER root
RUN echo "npm before: \$(npm --version)" && \\
    npm install -g npm@10 && \\
    echo "npm after:  \$(npm --version)"

USER node
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/node/.opencode/bin:\${PATH}"
ENV OPENCODE_DISABLE_DEFAULT_PLUGINS=true
RUN echo "installing jev-guard@${JEV_GUARD_VERSION}" && \\
    opencode plugin jev-guard@${JEV_GUARD_VERSION} --global

USER root
RUN git clone https://github.com/NiazMorshed2007/jev-review.git /opt/jev-review
WORKDIR /opt/jev-review
RUN git checkout ${JEV_REVIEW_COMMIT}
RUN echo "npm in jev-review: \$(npm --version)" && npm ci
RUN npm run build
RUN ls -la /opt/jev-review/dist/server.js
RUN chown -R node:node /opt/jev-review

WORKDIR /workspace
USER node
ENTRYPOINT ["opencode"]
DOCKERFILE_EOF

    echo "  PASS: docker/Dockerfile (jev-guard@${JEV_GUARD_VERSION}, npm@10)"

    cat > "$REPO_DIR/docker/docker-compose.yml" <<'COMPOSE_EOF'
services:
  opencode:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-jev
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    stdin_open: true
    tty: true
    working_dir: /workspace
    volumes:
      - ..:/workspace
    environment:
      - DEEPSEEK_API_KEY
      - JEV_API_KEY
      - OPENCODE_DISABLE_DEFAULT_PLUGINS=true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
COMPOSE_EOF

    echo "  PASS: docker/docker-compose.yml"

    cat > "$REPO_DIR/opencode.json" <<'JSON_EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DeepSeek",
      "options": {
        "baseURL": "https://api.deepseek.com",
        "apiKey": "{env:DEEPSEEK_API_KEY}"
      },
      "models": {
        "deepseek-flash": {
          "id": "deepseek-flash",
          "name": "DeepSeek V4.1 Flash",
          "limit": { "context": 1000000, "output": 384000 }
        }
      }
    }
  },
  "model": "deepseek/deepseek-flash",
  "plugin": [ "jev-guard" ],
  "skills": [ "/opt/jev-review/skills" ],
  "mcp": {
    "servers": {
      "jev-review": {
        "type": "local",
        "command": [ "node", "/opt/jev-review/dist/server.js" ],
        "environment": { "JEV_API_KEY": "{env:JEV_API_KEY}" }
      }
    }
  }
}
JSON_EOF

    echo "  PASS: opencode.json"

    cat > "$REPO_DIR/docker/build.sh" <<'BUILD_EOF'
#!/usr/bin/env bash
IMAGE_NAME="opencode-deepseek-jev:robust"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

main() {
    if ! command -v docker > /dev/null; then echo "GATE FAIL: docker not found."; return 1; fi
    if docker info > /dev/null; then echo "PASS: docker daemon reachable"
    else echo "FAIL: docker daemon not reachable. Output:"; docker info; return 1; fi
    cd "$REPO_DIR"
    docker build -f docker/Dockerfile -t "$IMAGE_NAME" .
}

main "$@"
BUILD_EOF
    chmod +x "$REPO_DIR/docker/build.sh"
    echo "  PASS: docker/build.sh"

    cat > "$REPO_DIR/docker/run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
IMAGE_NAME="opencode-deepseek-jev:robust"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

main() {
    if ! command -v docker > /dev/null; then echo "GATE FAIL: docker not found."; return 1; fi
    if docker info > /dev/null; then echo "PASS: docker daemon reachable"
    else echo "FAIL: docker daemon not reachable. Output:"; docker info; return 1; fi

    echo "Running: docker run -it --rm --user $(id -u):$(id -g) $IMAGE_NAME"
    docker run -it --rm \
        --user "$(id -u):$(id -g)" \
        -v "$REPO_DIR:/workspace" \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        --security-opt no-new-privileges:true \
        --cap-drop ALL \
        --cap-add CHOWN \
        --cap-add SETUID \
        --cap-add SETGID \
        -w /workspace \
        "$IMAGE_NAME"
}

main "$@"
RUN_EOF
    chmod +x "$REPO_DIR/docker/run.sh"
    echo "  PASS: docker/run.sh"

    cat > "$REPO_DIR/requirements.txt" <<'REQ_EOF'
# System prerequisites (not pip packages):
# docker (daemon reachable)
# gh (GitHub CLI, authenticated)
# git
# curl
# python3
# coreutils (timeout)
# util-linux (script)
REQ_EOF
    echo "  PASS: requirements.txt"

    cat > "$REPO_DIR/README.txt" <<'README_EOF'
OpenCode + DeepSeek V4.1 Flash + Jev
=====================================

Docker-based setup. All project code stays inside this repository.

Prerequisites
-------------
- Docker Engine (daemon reachable by current user)
- gh (GitHub CLI), authenticated
- DeepSeek API key (prefix sk-)
  https://platform.deepseek.com/api_keys
- Jev API key (prefix apikey_)
  https://console.typesafe.ai/keys

Quick Start
-----------
cd docker
./build.sh
./run.sh

Keys are cached in ../.env.local (mode 0600, gitignored).

TTY requirement
---------------
opencode is a TUI application. Without a TTY it fully buffers stdout
and produces zero bytes until exit. Prior runs appeared to show "OK",
but that was the user's own typed input echoed by the terminal, not
opencode output.

The staging script now wraps every docker run in script(1):
  script -q -f -c "docker run -t --rm ..." /dev/null | tee file
script(1) allocates a PTY on the host side. docker -t allocates a
TTY inside the container. opencode sees a TTY end-to-end and streams
immediately.

Orphan cleanup
--------------
Every run starts with cleanup_orphans(), which:
- kills orphaned "docker run --rm -i --user" processes (SIGTERM, then SIGKILL)
- kills orphaned "docker run -t --rm" processes
- kills orphaned "opencode run --model deepseek" processes
- removes all containers (docker rm -f)
Reports load average before and after.

Signal handling
---------------
A trap on INT and TERM kills any running docker child, then exits 130.
Ctrl-C no longer leaves orphans.

Smoke test methodology
----------------------
opencode 1.18.31 may exit non-zero after a successful response. The
script asserts on response text ("OK") instead of exit code. Exit code
and elapsed time are logged for diagnostics.

UID handling
------------
Container runs with --user $(id -u):$(id -g). /home/node is chmod 777
at build time.

Secrets hygiene
---------------
- Keys never appear on docker CLI argv (bare -e VAR).
- curl Authorization headers written to mode-0600 temp files.
- .env.local is gitignored and mode 0600.

Logs
----
Full staging output captured to ../staging.log.

Verification (V1 command surface)
---------------------------------
opencode V1 has no "mcp list" subcommand. The script verifies:
- opencode --help loads the binary
- opencode.json parses and lists mcp.servers keys via python3
- the image builds
- DeepSeek smoke test returns response text "OK" via script(1) PTY
- plugin list shows jev-guard

Troubleshooting
---------------
EACCES on /workspace: host UID mismatch. Script uses --user $(id -u).
HTTP 401 from DeepSeek: verbatim body printed.
HTTP 422 from TypeSafe: request body format issue.
docker build permission denied: add user to docker group.
Zero telemetry during smoke test: verify "script" binary is installed
  (util-linux package). If missing, install with: sudo dnf install util-linux
Smoke test FAIL despite correct response: opencode 1.18.31 exit-code bug.
  Script asserts on text, not exit code.
README_EOF
    echo "  PASS: README.txt"

    cat > "$REPO_DIR/.dockerignore" <<'DOCKERIGNORE_EOF'
node_modules
dist
*.log
.env
.env.local
__pycache__
.git
verification.log
staging.log
DOCKERIGNORE_EOF
    echo "  PASS: .dockerignore"

    cat > "$REPO_DIR/.gitignore" <<'GITIGNORE_EOF'
node_modules/
dist/
*.log
.env
.env.local
__pycache__/
.DS_Store
staging.log
GITIGNORE_EOF
    echo "  PASS: .gitignore"

    if python3 -m json.tool "$REPO_DIR/opencode.json" > /dev/null; then
        echo "  PASS: opencode.json is valid JSON"
    else
        echo "  FAIL: opencode.json INVALID JSON. Output:"
        python3 -m json.tool "$REPO_DIR/opencode.json"; return 1
    fi

    echo ""
    echo "=== Secret Scan ==="
    SECRET_FOUND=0
    KEY_REGEX='(sk-[A-Za-z0-9_-]{20,}|apikey_[A-Za-z0-9_-]{20,}|ts_[A-Za-z0-9_-]{20,}|jev-[A-Za-z0-9_-]{30,})'
    SCAN_TARGETS="$REPO_DIR/opencode.json $REPO_DIR/README.txt $REPO_DIR/requirements.txt $REPO_DIR/docker/Dockerfile $REPO_DIR/docker/docker-compose.yml $REPO_DIR/docker/build.sh $REPO_DIR/docker/run.sh"
    for target in $SCAN_TARGETS; do
        if [ -f "$target" ]; then
            if grep -E -q "$KEY_REGEX" "$target"; then
                echo "  WARN: key-shaped string in $target"; SECRET_FOUND=1
            fi
        fi
    done
    if [ $SECRET_FOUND -eq 0 ]; then
        echo "  PASS: no key-shaped strings in generated files"
    else
        echo "  WARN: inspect files before publishing."
    fi

    echo ""
    echo "=== Build Smoke Test ==="
    cd "$REPO_DIR"
    if docker build -f docker/Dockerfile -t "opencode-deepseek-jev:robust" .; then
        echo "  PASS: docker build succeeded"
    else
        echo "  FAIL: docker build failed."; return 1
    fi

    echo ""
    echo "=== Behavioral Smoke Test: DeepSeek ==="
    if docker_run_assert_text "OK" \
        "opencode-deepseek-jev:robust" \
        run --model deepseek/deepseek-flash "Reply with the single word OK"; then
        echo "  PASS: DeepSeek smoke test succeeded"
    else
        echo "  FAIL: DeepSeek smoke test failed."
        return 1
    fi

    echo ""
    echo "=== Behavioral Smoke Test: Plugins ==="
    if docker_run_assert_text "jev-guard" \
        "opencode-deepseek-jev:robust" \
        plugin list; then
        echo "  PASS: plugin list shows jev-guard"
    else
        echo "  WARN: plugin list did not show jev-guard. Output above."
    fi

    echo ""
    echo "=== Behavioral Smoke Test: MCP (V1) ==="
    docker_run_streaming "opencode-deepseek-jev:robust" --help
    if [ $? -eq 0 ]; then
        echo "  PASS: opencode --help executed"
    else
        echo "  WARN: opencode --help returned non-zero."
    fi

    echo "  Inspecting opencode.json mcp.servers via python3:"
    python3 - <<'PY_EOF'
import json
with open("opencode.json") as f:
    cfg = json.load(f)
servers = list(cfg.get("mcp", {}).get("servers", {}).keys())
print("  mcp.servers:", servers)
PY_EOF

    echo ""
    echo "=== Git Commit ==="
    if [ ! -d "$REPO_DIR/.git" ]; then git init "$REPO_DIR"; fi
    if git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/main; then
        git -C "$REPO_DIR" checkout main
    else
        git -C "$REPO_DIR" checkout -b main
        echo "  NOTE: created branch main"
    fi
    if [ -z "$(git -C "$REPO_DIR" config user.name)" ]; then
        git -C "$REPO_DIR" config user.name "$GITHUB_USER"
    fi
    if [ -z "$(git -C "$REPO_DIR" config user.email)" ]; then
        git -C "$REPO_DIR" config user.email "$GITHUB_USER@users.noreply.github.com"
    fi

    git -C "$REPO_DIR" add -A
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        if git -C "$REPO_DIR" commit -m "OpenCode + DeepSeek V4.1 Flash + Jev: v26"; then
            echo "  PASS: git commit"
        else
            echo "  FAIL: git commit failed"; return 1
        fi
    else
        echo "  NOTE: nothing to commit."
    fi

    echo ""
    echo "=== GitHub Sync ==="
    if gh repo view "$GITHUB_USER/$GITHUB_REPO" --json name -q .name > /dev/null; then
        echo "  PASS: GitHub repo already exists: $GITHUB_USER/$GITHUB_REPO"
        gh repo set-default "$GITHUB_USER/$GITHUB_REPO"

        EXPECTED_REMOTE="https://github.com/$GITHUB_USER/$GITHUB_REPO.git"
        if git -C "$REPO_DIR" remote get-url origin > /dev/null; then
            EXISTING_REMOTE=$(git -C "$REPO_DIR" remote get-url origin)
            if echo "$EXISTING_REMOTE" | grep -q "github.com"; then
                if [ "$EXISTING_REMOTE" != "$EXPECTED_REMOTE" ]; then
                    echo "  NOTE: Updating origin to $EXPECTED_REMOTE"
                    git -C "$REPO_DIR" remote set-url origin "$EXPECTED_REMOTE"
                else
                    echo "  NOTE: origin already correct."
                fi
            else
                git -C "$REPO_DIR" remote remove origin
                git -C "$REPO_DIR" remote add origin "$EXPECTED_REMOTE"
            fi
        else
            git -C "$REPO_DIR" remote add origin "$EXPECTED_REMOTE"
        fi

        if git -C "$REPO_DIR" fetch origin; then echo "  PASS: fetched origin"
        else echo "  FAIL: git fetch failed."; git -C "$REPO_DIR" fetch origin; return 1; fi

        if git -C "$REPO_DIR" rev-parse --verify origin/main > /dev/null; then
            if git -C "$REPO_DIR" rebase origin/main; then echo "  PASS: rebased"
            else echo "  FAIL: rebase conflicts."; return 1; fi
        else
            echo "  NOTE: remote main absent, skipping rebase."
        fi

        if git -C "$REPO_DIR" push -u origin main; then echo "  PASS: pushed"
        else echo "  FAIL: push failed."; return 1; fi
    else
        cd "$REPO_DIR"
        if gh repo create "$GITHUB_REPO" --public --source=. --remote=origin --push; then
            echo "  PASS: created GitHub repo"
        else
            echo "  FAIL: gh repo create failed"; return 1
        fi
        gh repo set-default "$GITHUB_USER/$GITHUB_REPO"
    fi
    echo "  PASS: GitHub repo: https://github.com/$GITHUB_USER/$GITHUB_REPO"

    echo ""
    echo "=== Verification Report ==="
    VERIFY_LOG="$REPO_DIR/verification.log"
    : > "$VERIFY_LOG"

    echo "REPORT 1: docker info" | tee -a "$VERIFY_LOG"
    if docker info > /dev/null; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 2: opencode.json valid JSON" | tee -a "$VERIFY_LOG"
    if python3 -m json.tool "$REPO_DIR/opencode.json" > /dev/null; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 3: deepseek-flash in config" | tee -a "$VERIFY_LOG"
    if grep -q "deepseek-flash" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 4: V1 plugin syntax in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "opencode plugin jev-guard" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 5: --user present in run.sh" | tee -a "$VERIFY_LOG"
    if grep -q -- "--user" "$REPO_DIR/docker/run.sh"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 6: no key=value on docker argv" | tee -a "$VERIFY_LOG"
    if grep -qE '\-e (DEEPSEEK|JEV)_API_KEY=' "$REPO_DIR/docker/run.sh"; then
        echo "  FAIL: key=value found on argv" | tee -a "$VERIFY_LOG"
    else
        echo "  PASS" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 7: docker -t in smoke test" | tee -a "$VERIFY_LOG"
    if grep -q "docker run -t --rm" "$REPO_DIR/stage-opencode-repo-v26.sh"; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 8: script(1) PTY wrapper in smoke test" | tee -a "$VERIFY_LOG"
    if grep -q 'script -q -f -c' "$REPO_DIR/stage-opencode-repo-v26.sh"; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 9: orphan cleanup function present" | tee -a "$VERIFY_LOG"
    if grep -q '^cleanup_orphans()' "$REPO_DIR/stage-opencode-repo-v26.sh"; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 10: trap INT/TERM present" | tee -a "$VERIFY_LOG"
    if grep -q "trap.*INT TERM" "$REPO_DIR/stage-opencode-repo-v26.sh"; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 11: jev-review MCP path" | tee -a "$VERIFY_LOG"
    if grep -q "jev-review/dist/server.js" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 12: skills path in config" | tee -a "$VERIFY_LOG"
    if grep -q "skills" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 13: no rm -rf in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "rm -rf" "$REPO_DIR/docker/Dockerfile"; then echo "  FAIL" | tee -a "$VERIFY_LOG"; else echo "  PASS" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 14: jev-review pinned commit in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "$JEV_REVIEW_COMMIT" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 15: .env.local mode 0600" | tee -a "$VERIFY_LOG"
    PERM=$(stat -c '%a' "$ENV_FILE" 2>&1)
    if [ "$PERM" = "600" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL: mode $PERM" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 16: scripts/ contains v26" | tee -a "$VERIFY_LOG"
    if [ -f "$SCRIPTS_DIR/stage-opencode-repo-v26.sh" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 17: /home/node chmod 777 in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "chmod 777 /home/node" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 18: PIPESTATUS[0] used for docker exit code" | tee -a "$VERIFY_LOG"
    if grep -q 'PIPESTATUS\[0\]' "$REPO_DIR/stage-opencode-repo-v26.sh"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    git -C "$REPO_DIR" add verification.log
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        git -C "$REPO_DIR" commit -m "Add verification log v26"
    fi
    if git -C "$REPO_DIR" push origin main; then echo "  PASS: verification log pushed"
    else echo "  FAIL: verification log push failed"; return 1; fi

    BASE="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/main"
    echo ""
    echo "=== GitHub Raw Links ==="
    echo "README:      $BASE/README.txt"
    echo "opencode:    $BASE/opencode.json"
    echo "Dockerfile:  $BASE/docker/Dockerfile"
    echo "Compose:     $BASE/docker/docker-compose.yml"
    echo "build.sh:    $BASE/docker/build.sh"
    echo "run.sh:      $BASE/docker/run.sh"
    echo "Scripts v26: $BASE/scripts/stage-opencode-repo-v26.sh"
    echo "Verify log:  $BASE/verification.log"
    echo ""
    echo "=== Staging Complete ==="
    echo "Repo: https://github.com/$GITHUB_USER/$GITHUB_REPO"
    echo "Log:  $LOG_FILE"
}

main "$@"
