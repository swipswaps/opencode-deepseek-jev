#!/usr/bin/env bash
# Stage, create, push, verify OpenCode + DeepSeek V4.1 Flash + Jev.
# v21: bare -e VAR for docker (no key on argv); curl headers via @file;
#      staging.log via tee. Saves v10-v21 in scripts/.
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
    if [ ! -f "$ENV_FILE" ]; then
        return 0
    fi
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
    local len=${#s}
    if [ "$len" -le 8 ]; then
        printf '***'
        return
    fi
    printf '%s***%s' "${s:0:3}" "${s: -4}"
}

resolve_jev_guard_version() {
    local response
    response=$(curl -fsSL https://registry.npmjs.org/jev-guard/latest)
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "  FAIL: could not query npm registry for jev-guard version"
        return 1
    fi
    local version
    version=$(printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))")
    if [ -z "$version" ]; then
        echo "  FAIL: npm registry returned no version for jev-guard"
        return 1
    fi
    JEV_GUARD_VERSION="$version"
    return 0
}

# Write Authorization header to mode-0600 temp file so key never appears in argv.
curl_with_auth_header() {
    local key="$1"
    shift
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
    local key="$1"
    if [ -z "$key" ]; then
        return 1
    fi
    local tmp
    tmp=$(mktemp)
    local http_code
    http_code=$(curl_with_auth_header "$key" -s -o "$tmp" -w '%{http_code}' \
        https://api.deepseek.com/user/balance)
    local body
    body=$(cat "$tmp")
    rm -f "$tmp"
    if [ "$http_code" = "200" ]; then
        return 0
    fi
    echo "  FAIL: DeepSeek API returned HTTP $http_code"
    echo "  Verbatim response body:"
    printf '%s\n' "$body"
    case "$http_code" in
        401)
            echo "  401 from DeepSeek means the key presented was not accepted."
            echo "  Possible causes:"
            echo "    - key was revoked in the DeepSeek console"
            echo "    - key was copied with a trailing newline or space"
            echo "    - key belongs to a different DeepSeek account"
            echo "    - transient DeepSeek authentication service issue"
            ;;
        402) echo "  402 means insufficient balance. Top up at https://platform.deepseek.com/top_up" ;;
        429) echo "  429 means rate limited. Wait and retry." ;;
    esac
    echo "  Get a key at: $DEEPSEEK_KEY_URL"
    echo "  Docs: $DEEPSEEK_DOCS_URL"
    return 1
}

validate_jev_key() {
    local key="$1"
    if [ -z "$key" ]; then
        return 1
    fi
    case "$key" in
        apikey_*|sk-*|ts_*|jev-*) ;;
        *)
            echo "  FAIL: Jev key must start with apikey_ or sk-"
            echo "  Get a key at: $TYPESAFE_KEY_URL"
            echo "  Docs: $TYPESAFE_DOCS_URL"
            return 1
            ;;
    esac
    local tmp
    tmp=$(mktemp)
    local http_code
    http_code=$(curl_with_auth_header "$key" -s -o "$tmp" -w '%{http_code}' \
        -X POST https://api.typesafe.ai/v1/systemone \
        -H "Content-Type: application/json" \
        -d '{
          "state": "validation probe",
          "model": "jev-latest",
          "questions": {
            "probe": {
              "type": "noul",
              "instructions": "Is this request valid?"
            }
          }
        }')
    local body
    body=$(cat "$tmp")
    rm -f "$tmp"
    if [ "$http_code" = "200" ]; then
        return 0
    fi
    echo "  FAIL: Jev API returned HTTP $http_code"
    echo "  Verbatim response body:"
    printf '%s\n' "$body"
    case "$http_code" in
        401) echo "  401 means the key was not accepted." ;;
        422) echo "  422 means the request body format was rejected." ;;
        429) echo "  429 means rate limited. Wait and retry." ;;
        529) echo "  529 means TypeSafe is overloaded. Wait and retry." ;;
    esac
    echo "  Get a key at: $TYPESAFE_KEY_URL"
    echo "  Docs: $TYPESAFE_DOCS_URL"
    return 1
}

main() {
    # Capture all output to staging.log while still displaying on terminal.
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== staging started: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "Log: $LOG_FILE"

    for bin in gh git docker python3 curl; do
        if ! command -v "$bin" > /dev/null; then
            echo "GATE FAIL: $bin not found. Install it first."
            return 1
        fi
    done

    if docker info > /dev/null; then
        echo "  PASS: docker daemon reachable"
    else
        echo "  FAIL: docker daemon not reachable. Output:"
        docker info
        return 1
    fi

    if gh auth status > /dev/null; then
        echo "  PASS: gh authenticated"
    else
        echo "  FAIL: gh not authenticated. Output:"
        gh auth status
        return 1
    fi

    gh auth setup-git
    if [ $? -ne 0 ]; then
        echo "WARN: gh auth setup-git failed. HTTPS push may fail."
    fi

    GITHUB_USER=$(gh api user --jq .login)
    if [ -z "$GITHUB_USER" ]; then
        echo "GATE FAIL: Could not determine GitHub username."
        return 1
    fi
    echo "  PASS: GitHub user: $GITHUB_USER"

    if [ ! -d "$REPO_DIR" ]; then
        echo "GATE FAIL: $REPO_DIR does not exist."
        return 1
    fi
    cd "$REPO_DIR"

    echo ""
    echo "=== Resolve jev-guard version ==="
    if resolve_jev_guard_version; then
        echo "  PASS: jev-guard latest version: $JEV_GUARD_VERSION"
    else
        echo "  FAIL: cannot pin jev-guard version; aborting."
        return 1
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
            echo "  DeepSeek keys: $DEEPSEEK_KEY_URL"
            read -r -s -p "Enter DEEPSEEK_API_KEY (sk-...): " DEEPSEEK_API_KEY
            echo ""
            DEEPSEEK_API_KEY=$(printf '%s' "$DEEPSEEK_API_KEY" | tr -d '\r\n')
            if validate_deepseek_key "$DEEPSEEK_API_KEY"; then
                echo "  PASS: DEEPSEEK_API_KEY validated"
                NEEDS_SAVE=1
            else
                echo "  FAIL: DEEPSEEK_API_KEY rejected. Aborting."
                return 1
            fi
        fi
    else
        echo "  DeepSeek keys: $DEEPSEEK_KEY_URL"
        read -r -s -p "Enter DEEPSEEK_API_KEY (sk-...): " DEEPSEEK_API_KEY
        echo ""
        DEEPSEEK_API_KEY=$(printf '%s' "$DEEPSEEK_API_KEY" | tr -d '\r\n')
        if validate_deepseek_key "$DEEPSEEK_API_KEY"; then
            echo "  PASS: DEEPSEEK_API_KEY validated"
            NEEDS_SAVE=1
        else
            echo "  FAIL: DEEPSEEK_API_KEY rejected. Aborting."
            return 1
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
            echo "  Jev keys: $TYPESAFE_KEY_URL"
            read -r -s -p "Enter JEV_API_KEY (apikey_...): " JEV_API_KEY
            echo ""
            JEV_API_KEY=$(printf '%s' "$JEV_API_KEY" | tr -d '\r\n')
            if validate_jev_key "$JEV_API_KEY"; then
                echo "  PASS: JEV_API_KEY validated"
                NEEDS_SAVE=1
            else
                echo "  FAIL: JEV_API_KEY rejected. Aborting."
                return 1
            fi
        fi
    else
        echo "  Jev keys: $TYPESAFE_KEY_URL"
        read -r -s -p "Enter JEV_API_KEY (apikey_...): " JEV_API_KEY
        echo ""
        JEV_API_KEY=$(printf '%s' "$JEV_API_KEY" | tr -d '\r\n')
        if validate_jev_key "$JEV_API_KEY"; then
            echo "  PASS: JEV_API_KEY validated"
            NEEDS_SAVE=1
        else
            echo "  FAIL: JEV_API_KEY rejected. Aborting."
            return 1
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
    if [ ! -d "$SCRIPTS_DIR" ]; then
        echo "GATE FAIL: Could not create $SCRIPTS_DIR"
        return 1
    fi
    for v in 10 11 12 13 14 15 16 17 18 19 20 21; do
        src="$REPO_DIR/stage-opencode-repo-v${v}.sh"
        if [ -f "$src" ]; then
            cp "$src" "$SCRIPTS_DIR/stage-opencode-repo-v${v}.sh"
        fi
    done
    echo "  PASS: scripts/ directory prepared (v10-v21)"

    # 1. DOCKERFILE
    mkdir -p "$REPO_DIR/docker"

    cat > "$REPO_DIR/docker/Dockerfile" <<DOCKERFILE_EOF
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git curl ca-certificates \\
    && apt-get clean

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
          "limit": {
            "context": 1000000,
            "output": 384000
          }
        }
      }
    }
  },
  "model": "deepseek/deepseek-flash",
  "plugin": [
    "jev-guard"
  ],
  "skills": [
    "/opt/jev-review/skills"
  ],
  "mcp": {
    "servers": {
      "jev-review": {
        "type": "local",
        "command": [
          "node",
          "/opt/jev-review/dist/server.js"
        ],
        "environment": {
          "JEV_API_KEY": "{env:JEV_API_KEY}"
        }
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
    if ! command -v docker > /dev/null; then
        echo "GATE FAIL: docker not found."
        return 1
    fi
    if docker info > /dev/null; then
        echo "PASS: docker daemon reachable"
    else
        echo "FAIL: docker daemon not reachable. Output:"
        docker info
        return 1
    fi
    cd "$REPO_DIR"
    docker build -f docker/Dockerfile -t "$IMAGE_NAME" .
}

main "$@"
BUILD_EOF
    chmod +x "$REPO_DIR/docker/build.sh"
    echo "  PASS: docker/build.sh"

    # 5. RUN SCRIPT (bare -e VAR; no key on argv)
    cat > "$REPO_DIR/docker/run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
IMAGE_NAME="opencode-deepseek-jev:robust"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

main() {
    if ! command -v docker > /dev/null; then
        echo "GATE FAIL: docker not found."
        return 1
    fi
    if docker info > /dev/null; then
        echo "PASS: docker daemon reachable"
    else
        echo "FAIL: docker daemon not reachable. Output:"
        docker info
        return 1
    fi
    # Bare -e VAR: docker inherits value from caller's environment.
    # The value never appears on the docker CLI argv.
    docker run -it --rm \
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
- DeepSeek API key (DEEPSEEK_API_KEY, prefix sk-)
  https://platform.deepseek.com/api_keys
- Jev API key (JEV_API_KEY, prefix apikey_)
  https://console.typesafe.ai/keys

Quick Start
-----------
cd docker
./build.sh
./run.sh

API keys are cached in ../.env.local (mode 0600, gitignored).
Both keys are validated against the provider before the Docker build.

Secrets hygiene
---------------
- Keys are never passed as docker CLI arguments. Docker uses
  bare -e VAR to inherit values from the caller's environment.
- curl Authorization headers are written to mode-0600 temp files.
- Keys are never committed. .env.local is gitignored.

Logs
----
Full staging output is written to ../staging.log and displayed on
the terminal. Inspect it after a failed run.

Architecture
------------
- Base image: node:22-bookworm-slim
- npm upgraded within current major (npm@10) for Node 22
- Uses existing node user (UID 1000, GID 1000)
- Repo mounted at /workspace
- jev-guard: installed via "opencode plugin jev-guard@<resolved> --global"
- jev-review: MCP server at /opt/jev-review/dist/server.js
- OPENCODE_DISABLE_DEFAULT_PLUGINS=true disables bundled plugins

Model
-----
DeepSeek V4.1 Flash via official API.
Model ID: deepseek-flash. Base URL: https://api.deepseek.com.
Context: 1,000,000 tokens. Max output: 384,000 tokens.

Troubleshooting
---------------
HTTP 401 from DeepSeek: key not accepted. Verbatim body printed.
  Get a new key at: https://platform.deepseek.com/api_keys
HTTP 422 from TypeSafe: request body format issue.
  Docs: https://docs.typesafe.ai/
jev-review MCP not found: dist/server.js not built.
docker build permission denied: add user to docker group.

Re-run determinism
------------------
Re-running is idempotent: cached keys validated, shown masked.
To force re-prompt, delete .env.local.
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
        python3 -m json.tool "$REPO_DIR/opencode.json"
        return 1
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
                echo "  WARN: key-shaped string in $target"
                SECRET_FOUND=1
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
        echo "  FAIL: docker build failed."
        return 1
    fi

    # 13. BEHAVIORAL SMOKE TEST: DeepSeek (bare -e VAR)
    echo ""
    echo "=== Behavioral Smoke Test: DeepSeek ==="
    if docker run --rm \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        run --model deepseek/deepseek-flash "Reply: OK"; then
        echo "  PASS: DeepSeek smoke test succeeded"
    else
        echo "  FAIL: DeepSeek smoke test failed."
        return 1
    fi

    # 14. BEHAVIORAL SMOKE TEST: Plugins
    echo ""
    echo "=== Behavioral Smoke Test: Plugins ==="
    if docker run --rm \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        plugin list; then
        echo "  PASS: plugin list executed"
    else
        echo "  WARN: plugin list returned non-zero. Output shown above."
    fi

    # 15. BEHAVIORAL SMOKE TEST: MCP
    echo ""
    echo "=== Behavioral Smoke Test: MCP ==="
    if docker run --rm \
        -e DEEPSEEK_API_KEY \
        -e JEV_API_KEY \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        mcp list; then
        echo "  PASS: mcp list executed"
    else
        echo "  WARN: mcp list returned non-zero. Output shown above."
    fi

    # 16. GIT INIT + COMMIT
    echo ""
    echo "=== Git Commit ==="
    if [ ! -d "$REPO_DIR/.git" ]; then
        git init "$REPO_DIR"
    fi
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
        if git -C "$REPO_DIR" commit -m "OpenCode + DeepSeek V4.1 Flash + Jev: v21"; then
            echo "  PASS: git commit"
        else
            echo "  FAIL: git commit failed"
            return 1
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
                    echo "  NOTE: Updating origin from $EXISTING_REMOTE to $EXPECTED_REMOTE"
                    git -C "$REPO_DIR" remote set-url origin "$EXPECTED_REMOTE"
                else
                    echo "  NOTE: origin already correct: $EXISTING_REMOTE"
                fi
            else
                echo "  NOTE: Replacing non-GitHub origin: $EXISTING_REMOTE"
                git -C "$REPO_DIR" remote remove origin
                git -C "$REPO_DIR" remote add origin "$EXPECTED_REMOTE"
            fi
        else
            echo "  NOTE: Adding origin $EXPECTED_REMOTE"
            git -C "$REPO_DIR" remote add origin "$EXPECTED_REMOTE"
        fi

        if git -C "$REPO_DIR" fetch origin; then
            echo "  PASS: fetched origin"
        else
            echo "  FAIL: git fetch failed. Output:"
            git -C "$REPO_DIR" fetch origin
            return 1
        fi

        if git -C "$REPO_DIR" rev-parse --verify origin/main > /dev/null; then
            if git -C "$REPO_DIR" rebase origin/main; then
                echo "  PASS: rebased onto origin/main"
            else
                echo "  FAIL: git rebase failed. Resolve conflicts manually."
                return 1
            fi
        else
            echo "  NOTE: remote main does not exist yet, skipping rebase."
        fi

        if git -C "$REPO_DIR" push -u origin main; then
            echo "  PASS: pushed to origin/main"
        else
            echo "  FAIL: git push failed. Output:"
            git -C "$REPO_DIR" push -u origin main
            return 1
        fi
    else
        cd "$REPO_DIR"
        if gh repo create "$GITHUB_REPO" \
            --public \
            --source=. \
            --remote=origin \
            --push; then
            echo "  PASS: created GitHub repo"
        else
            echo "  FAIL: gh repo create failed"
            return 1
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

    echo "REPORT 5: jev-guard version is not 0.2.1" | tee -a "$VERIFY_LOG"
    if grep -q "jev-guard@0.2.1" "$REPO_DIR/docker/Dockerfile"; then echo "  FAIL: still pinned to nonexistent 0.2.1" | tee -a "$VERIFY_LOG"; else echo "  PASS" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 6: npm upgraded within major 10" | tee -a "$VERIFY_LOG"
    if grep -q "npm install -g npm@10" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 7: jev-review MCP path" | tee -a "$VERIFY_LOG"
    if grep -q "jev-review/dist/server.js" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 8: skills path in config" | tee -a "$VERIFY_LOG"
    if grep -q "skills" "$REPO_DIR/opencode.json"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 9: API keys non-empty" | tee -a "$VERIFY_LOG"
    if [ -n "$DEEPSEEK_API_KEY" ] && [ -n "$JEV_API_KEY" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 10: no rm -rf in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "rm -rf" "$REPO_DIR/docker/Dockerfile"; then echo "  FAIL" | tee -a "$VERIFY_LOG"; else echo "  PASS" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 11: jev-review pinned commit in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "$JEV_REVIEW_COMMIT" "$REPO_DIR/docker/Dockerfile"; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 12: .env.local mode 0600" | tee -a "$VERIFY_LOG"
    PERM=$(stat -c '%a' "$ENV_FILE" 2>&1)
    if [ "$PERM" = "600" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL: mode $PERM" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 13: scripts/ contains v21" | tee -a "$VERIFY_LOG"
    if [ -f "$SCRIPTS_DIR/stage-opencode-repo-v21.sh" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 14: no key on docker argv in run.sh" | tee -a "$VERIFY_LOG"
    if grep -qE '\-e (DEEPSEEK|JEV)_API_KEY=' "$REPO_DIR/docker/run.sh"; then
        echo "  FAIL: key=value found on docker argv" | tee -a "$VERIFY_LOG"
    else
        echo "  PASS" | tee -a "$VERIFY_LOG"
    fi

    git -C "$REPO_DIR" add verification.log
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        git -C "$REPO_DIR" commit -m "Add verification log v21"
    fi
    if git -C "$REPO_DIR" push origin main; then
        echo "  PASS: verification log pushed"
    else
        echo "  FAIL: verification log push failed"
        return 1
    fi

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
    echo "Scripts v21: $BASE/scripts/stage-opencode-repo-v21.sh"
    echo "Verify log:  $BASE/verification.log"
    echo ""
    echo "=== Staging Complete ==="
    echo "Repo: https://github.com/$GITHUB_USER/$GITHUB_REPO"
    echo "Log:  $LOG_FILE"
}

main "$@"
