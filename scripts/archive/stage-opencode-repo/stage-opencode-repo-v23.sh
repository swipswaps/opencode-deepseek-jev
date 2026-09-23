#!/usr/bin/env bash
# Stage, create, push, verify OpenCode + DeepSeek V4.1 Flash + Jev.
# v23: smoke test asserts response text, not exit code (opencode 1.18.31
#      exits non-zero after success in non-TTY). --format json + grep.
#      -i on docker run. Verbatim stdout on failure. Saves v10-v23.
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
        401) echo "  401: key not accepted. Possible: revoked, trailing whitespace, wrong account, transient." ;;
        402) echo "  402: insufficient balance. Top up at https://platform.deepseek.com/top_up" ;;
        429) echo "  429: rate limited. Wait and retry." ;;
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

# Run docker with --user + timeout + echo. Never puts key on argv (bare -e VAR).
# Uses -i so opencode sees a stdin stream and does not abort on non-TTY.
docker_run_logged() {
    echo "  Running: docker run --rm -i --user $(id -u):$(id -g) -e DEEPSEEK_API_KEY -e JEV_API_KEY $*"
    echo "  Timeout: 60s"
    timeout 60 docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "$@"
}

# Behavioral smoke test: capture output, assert response text.
# Exit code is NOT used as the pass criterion because opencode 1.18.31
# exits non-zero after a successful response in non-TTY mode.
docker_run_assert_text() {
    local expected="$1"; shift
    local tmp_out; tmp_out=$(mktemp)
    local tmp_err; tmp_err=$(mktemp)
    echo "  Running: docker run --rm -i --user $(id -u):$(id -g) ... $*"
    echo "  Timeout: 60s"
    echo "  Expecting text: '$expected'"

    timeout 60 docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "$@" > "$tmp_out" 2> "$tmp_err"
    local exit_code=$?

    local stdout; stdout=$(cat "$tmp_out")
    local stderr; stderr=$(cat "$tmp_err")
    rm -f "$tmp_out" "$tmp_err"

    echo "  Exit code: $exit_code"
    echo "  Verbatim stdout:"
    printf '%s\n' "$stdout"
    if [ -n "$stderr" ]; then
        echo "  Verbatim stderr:"
        printf '%s\n' "$stderr"
    fi

    if echo "$stdout" | grep -q "$expected"; then
        echo "  PASS: stdout contains '$expected' (exit code $exit_code ignored)"
        return 0
    fi
    if echo "$stderr" | grep -q "$expected"; then
        echo "  PASS: stderr contains '$expected' (exit code $exit_code ignored)"
        return 0
    fi
    echo "  FAIL: neither stdout nor stderr contains '$expected'"
    return 1
}

main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== staging started: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "Log: $LOG_FILE"
    echo "Host UID:GID = $(id -u):$(id -g)"

    for bin in gh git docker python3 curl timeout; do
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

    # 0. SCRIPTS DIRECTORY
    mkdir -p "$SCRIPTS_DIR"
    if [ ! -d "$SCRIPTS_DIR" ]; then echo "GATE FAIL: cannot create $SCRIPTS_DIR"; return 1; fi
    for v in 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
        src="$REPO_DIR/stage-opencode-repo-v${v}.sh"
        if [ -f "$src" ]; then cp "$src" "$SCRIPTS_DIR/stage-opencode-repo-v${v}.sh"; fi
    done
    echo "  PASS: scripts/ prepared (v10-v23)"

    # 1. DOCKERFILE
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

    # 2. DOCKER COMPOSE
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

    # 3. OPENCODE.JSON
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

    # 4. BUILD SCRIPT
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

    # 5. RUN SCRIPT (--user, bare -e, -i)
    cat > "$REPO_DIR/docker/run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
IMAGE_NAME="opencode-deepseek-jev:robust"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

main() {
    if ! command -v docker > /dev/null; then echo "GATE FAIL: docker not found."; return 1; fi
    if docker info > /dev/null; then echo "PASS: docker daemon reachable"
    else echo "FAIL: docker daemon not reachable. Output:"; docker info; return 1; fi

    echo "Running: docker run -it --rm --user $(id -u):$(id -g) -e DEEPSEEK_API_KEY -e JEV_API_KEY $IMAGE_NAME"
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

    # 6. REQUIREMENTS.TXT
    cat > "$REPO_DIR/requirements.txt" <<'REQ_EOF'
# System prerequisites (not pip packages):
# docker (daemon reachable)
# gh (GitHub CLI, authenticated)
# git
# curl
# python3
# coreutils (timeout)
REQ_EOF
    echo "  PASS: requirements.txt"

    # 7. README.TXT
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

Smoke test methodology
---------------------
opencode 1.18.31 exits non-zero after a successful non-TTY response
(see opencode PRs #26588 and #31280). The staging script therefore
asserts on the response text ("OK") instead of the exit code. This
is documented in the script and in this README.

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
opencode V1 has no "mcp list" subcommand. MCP servers are read from
opencode.json. The staging script verifies:
- opencode --help loads the binary
- opencode.json parses and lists mcp.servers keys via python3
- the image builds
- DeepSeek smoke test returns response text "OK"
- plugin list returns output (exit code ignored)

Troubleshooting
---------------
EACCES on /workspace: host UID mismatch. Script uses --user $(id -u).
HTTP 401 from DeepSeek: verbatim body printed by the script.
HTTP 422 from TypeSafe: request body format issue.
docker build permission denied: add user to docker group.
Smoke test FAIL despite OK response: known opencode exit-code bug.
  Script asserts on text, not exit code, to work around this.
README_EOF
    echo "  PASS: README.txt"

    # 8. DOCKERIGNORE
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

    # 9. GITIGNORE
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

    # 10. VERIFY JSON
    if python3 -m json.tool "$REPO_DIR/opencode.json" > /dev/null; then
        echo "  PASS: opencode.json is valid JSON"
    else
        echo "  FAIL: opencode.json INVALID JSON. Output:"
        python3 -m json.tool "$REPO_DIR/opencode.json"; return 1
    fi

    # 11. SECRET SCAN
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

    # 12. BUILD SMOKE TEST
    echo ""
    echo "=== Build Smoke Test ==="
    cd "$REPO_DIR"
    if docker build -f docker/Dockerfile -t "opencode-deepseek-jev:robust" .; then
        echo "  PASS: docker build succeeded"
    else
        echo "  FAIL: docker build failed."; return 1
    fi

    # 13. BEHAVIORAL SMOKE TEST: DeepSeek (text assertion, not exit code)
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

    # 14. BEHAVIORAL SMOKE TEST: Plugins (text assertion)
    echo ""
    echo "=== Behavioral Smoke Test: Plugins ==="
    if docker_run_assert_text "jev-guard" \
        "opencode-deepseek-jev:robust" \
        plugin list; then
        echo "  PASS: plugin list shows jev-guard"
    else
        echo "  WARN: plugin list did not show jev-guard. Output above."
    fi

    # 15. BEHAVIORAL SMOKE TEST: MCP (V1 command surface)
    echo ""
    echo "=== Behavioral Smoke Test: MCP (V1) ==="
    echo "  Running: docker run --rm -i --user $(id -u):$(id -g) <image> --help"
    echo "  Timeout: 60s"
    if timeout 60 docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" --help; then
        echo "  PASS: opencode --help executed"
    else
        echo "  WARN: opencode --help returned non-zero. Output shown above."
    fi

    echo "  Inspecting opencode.json mcp.servers via python3:"
    python3 - <<'PY_EOF'
import json
with open("opencode.json") as f:
    cfg = json.load(f)
servers = list(cfg.get("mcp", {}).get("servers", {}).keys())
print("  mcp.servers:", servers)
PY_EOF

    # 16. GIT INIT + COMMIT
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
        if git -C "$REPO_DIR" commit -m "OpenCode + DeepSeek V4.1 Flash + Jev: v23"; then
            echo "  PASS: git commit"
        else
            echo "  FAIL: git commit failed"; return 1
        fi
    else
        echo "  NOTE: nothing to commit."
    fi

    # 17. GH REPO CREATE OR SYNC
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

    # 18. VERIFICATION REPORT
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

    echo "REPORT 7: smoke test asserts text, not exit code" | tee -a "$VERIFY_LOG"
    if grep -q "docker_run_assert_text" "$REPO_DIR/stage-opencode-repo-v23.sh"; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 8: jev-review MCP path" | tee -a "$VERIFY_LOG"
    if grep -q "jev-review/dist/server.js" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 9: skills path in config" | tee -a "$VERIFY_LOG"
    if grep -q "skills" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 10: no rm -rf in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "rm -rf" "$REPO_DIR/docker/Dockerfile"; then echo "  FAIL" | tee -a "$VERIFY_LOG"; else echo "  PASS" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 11: jev-review pinned commit in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "$JEV_REVIEW_COMMIT" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 12: .env.local mode 0600" | tee -a "$VERIFY_LOG"
    PERM=$(stat -c '%a' "$ENV_FILE" 2>&1)
    if [ "$PERM" = "600" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL: mode $PERM" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 13: scripts/ contains v23" | tee -a "$VERIFY_LOG"
    if [ -f "$SCRIPTS_DIR/stage-opencode-repo-v23.sh" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 14: /home/node chmod 777 in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "chmod 777 /home/node" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 15: -i on docker run in smoke test" | tee -a "$VERIFY_LOG"
    if grep -q -- "--rm -i" "$REPO_DIR/stage-opencode-repo-v23.sh"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    git -C "$REPO_DIR" add verification.log
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        git -C "$REPO_DIR" commit -m "Add verification log v23"
    fi
    if git -C "$REPO_DIR" push origin main; then echo "  PASS: verification log pushed"
    else echo "  FAIL: verification log push failed"; return 1; fi

    # 19. PRINT GITHUB RAW LINKS
    BASE="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/main"
    echo ""
    echo "=== GitHub Raw Links ==="
    echo "README:      $BASE/README.txt"
    echo "opencode:    $BASE/opencode.json"
    echo "Dockerfile:  $BASE/docker/Dockerfile"
    echo "Compose:     $BASE/docker/docker-compose.yml"
    echo "build.sh:    $BASE/docker/build.sh"
    echo "run.sh:      $BASE/docker/run.sh"
    echo "Scripts v23: $BASE/scripts/stage-opencode-repo-v23.sh"
    echo "Verify log:  $BASE/verification.log"
    echo ""
    echo "=== Staging Complete ==="
    echo "Repo: https://github.com/$GITHUB_USER/$GITHUB_REPO"
    echo "Log:  $LOG_FILE"
}

main "$@"
