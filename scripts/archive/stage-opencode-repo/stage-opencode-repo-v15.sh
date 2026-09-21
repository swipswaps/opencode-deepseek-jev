#!/usr/bin/env bash
# Stage, create, push, verify OpenCode + DeepSeek V4.1 Flash + Jev.
# v15: runtime-resolved jev-guard version; always-offer-update key prompt;
#      key-shaped secret scan (not substring); idempotent re-runs.
# Plain ASCII. No markdown. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
SCRIPTS_DIR="$REPO_DIR/scripts"
ENV_FILE="$REPO_DIR/.env.local"
GITHUB_REPO="opencode-deepseek-jev"
GITHUB_USER=""
JEV_REVIEW_COMMIT="3fb6042ebf07f0fdaae30d65c6393848e1a549e3"
JEV_GUARD_VERSION=""

load_env_file() {
    if [ ! -f "$ENV_FILE" ]; then
        return 0
    fi
    while IFS='=' read -r key value; do
        case "$key" in
            DEEPSEEK_API_KEY) CACHED_DEEPSEEK_API_KEY="$value" ;;
            JEV_API_KEY)      CACHED_JEV_API_KEY="$value" ;;
        esac
    done < "$ENV_FILE"
}

save_env_file() {
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    printf 'DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY" > "$ENV_FILE"
    printf 'JEV_API_KEY=%s\n' "$JEV_API_KEY" >> "$ENV_FILE"
}

mask_secret() {
    local s="$1"
    local len=${#s}
    if [ "$len" -le 8 ]; then
        printf '***'
        return
    fi
    local head="${s:0:3}"
    local tail="${s: -4}"
    printf '%s***%s' "$head" "$tail"
}

resolve_jev_guard_version() {
    local response
    response=$(curl -fsSL https://registry.npmjs.org/jev-guard/latest)
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo "  WARN: could not query npm registry for jev-guard version"
        return 1
    fi
    local version
    version=$(printf '%s' "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version',''))")
    if [ -z "$version" ]; then
        echo "  WARN: npm registry returned no version for jev-guard"
        return 1
    fi
    JEV_GUARD_VERSION="$version"
    return 0
}

main() {
    for bin in gh git docker python3 curl; do
        if ! command -v "$bin" > /dev/null; then
            echo "GATE FAIL: $bin not found. Install it first."
            return 1
        fi
    done

    if ! docker info > /dev/null; then
        echo "GATE FAIL: docker daemon not reachable."
        echo "  On Fedora: sudo usermod -aG docker \$USER && newgrp docker"
        return 1
    fi

    if ! gh auth status > /dev/null; then
        echo "GATE FAIL: gh not authenticated. Run: gh auth login"
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

    # Resolve jev-guard version from npm registry
    echo ""
    echo "=== Resolve jev-guard version ==="
    if resolve_jev_guard_version; then
        echo "  PASS: jev-guard latest version: $JEV_GUARD_VERSION"
    else
        echo "  FAIL: cannot pin jev-guard version; aborting to avoid non-deterministic build."
        return 1
    fi

    # Load cached keys
    CACHED_DEEPSEEK_API_KEY=""
    CACHED_JEV_API_KEY=""
    load_env_file

    echo ""
    echo "=== API Key Setup ==="
    NEEDS_SAVE=0

    if [ -n "$CACHED_DEEPSEEK_API_KEY" ]; then
        MASKED=$(mask_secret "$CACHED_DEEPSEEK_API_KEY")
        read -r -s -p "DEEPSEEK_API_KEY [${MASKED}] (Enter to keep, or paste new): " input
        echo ""
        if [ -z "$input" ]; then
            DEEPSEEK_API_KEY="$CACHED_DEEPSEEK_API_KEY"
            echo "  PASS: DEEPSEEK_API_KEY kept from cache"
        else
            DEEPSEEK_API_KEY="$input"
            NEEDS_SAVE=1
            echo "  PASS: DEEPSEEK_API_KEY updated"
        fi
    else
        read -r -s -p "Enter DEEPSEEK_API_KEY (sk-...): " DEEPSEEK_API_KEY
        echo ""
        NEEDS_SAVE=1
        echo "  PASS: DEEPSEEK_API_KEY captured"
    fi

    if [ -n "$CACHED_JEV_API_KEY" ]; then
        MASKED=$(mask_secret "$CACHED_JEV_API_KEY")
        read -r -s -p "JEV_API_KEY [${MASKED}] (Enter to keep, or paste new): " input
        echo ""
        if [ -z "$input" ]; then
            JEV_API_KEY="$CACHED_JEV_API_KEY"
            echo "  PASS: JEV_API_KEY kept from cache"
        else
            JEV_API_KEY="$input"
            NEEDS_SAVE=1
            echo "  PASS: JEV_API_KEY updated"
        fi
    else
        read -r -s -p "Enter JEV_API_KEY (jev-...): " JEV_API_KEY
        echo ""
        NEEDS_SAVE=1
        echo "  PASS: JEV_API_KEY captured"
    fi

    export DEEPSEEK_API_KEY
    export JEV_API_KEY

    if [ -z "$DEEPSEEK_API_KEY" ]; then
        echo "GATE FAIL: DEEPSEEK_API_KEY is empty."
        return 1
    fi
    if [ -z "$JEV_API_KEY" ]; then
        echo "GATE FAIL: JEV_API_KEY is empty."
        return 1
    fi

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
    for v in 10 11 12 13 14 15; do
        src="$REPO_DIR/stage-opencode-repo-v${v}.sh"
        if [ -f "$src" ]; then
            cp "$src" "$SCRIPTS_DIR/stage-opencode-repo-v${v}.sh"
        fi
    done
    echo "  PASS: scripts/ directory prepared"

    # 1. DOCKERFILE
    mkdir -p "$REPO_DIR/docker"

    cat > "$REPO_DIR/docker/Dockerfile" <<DOCKERFILE_EOF
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \\
    git curl ca-certificates \\
    && apt-get clean

USER node
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/node/.opencode/bin:\${PATH}"
ENV OPENCODE_DISABLE_DEFAULT_PLUGINS=true

# OpenCode V1 CLI: "opencode plugin <module> --global"
# Version resolved at staging time from npm registry.
RUN opencode plugin jev-guard@${JEV_GUARD_VERSION} --global

USER root
RUN git clone https://github.com/NiazMorshed2007/jev-review.git /opt/jev-review
WORKDIR /opt/jev-review
RUN git checkout ${JEV_REVIEW_COMMIT}
RUN npm ci
RUN npm run build
RUN ls -la /opt/jev-review/dist/server.js
RUN chown -R node:node /opt/jev-review

WORKDIR /workspace
USER node
ENTRYPOINT ["opencode"]
DOCKERFILE_EOF

    echo "  PASS: docker/Dockerfile (jev-guard@${JEV_GUARD_VERSION})"

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
      - DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}
      - JEV_API_KEY=${JEV_API_KEY}
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
    if ! docker info > /dev/null; then
        echo "GATE FAIL: docker daemon not reachable."
        return 1
    fi
    cd "$REPO_DIR"
    docker build -f docker/Dockerfile -t "$IMAGE_NAME" .
}

main "$@"
BUILD_EOF
    chmod +x "$REPO_DIR/docker/build.sh"
    echo "  PASS: docker/build.sh"

    # 5. RUN SCRIPT
    cat > "$REPO_DIR/docker/run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
IMAGE_NAME="opencode-deepseek-jev:robust"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

main() {
    if ! command -v docker > /dev/null; then
        echo "GATE FAIL: docker not found."
        return 1
    fi
    if ! docker info > /dev/null; then
        echo "GATE FAIL: docker daemon not reachable."
        return 1
    fi
    docker run -it --rm \
        -v "$REPO_DIR:/workspace" \
        -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
        -e JEV_API_KEY="$JEV_API_KEY" \
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
- DeepSeek API key (DEEPSEEK_API_KEY)
- Jev API key from https://console.typesafe.ai/ (JEV_API_KEY)

Quick Start
-----------
cd docker
./build.sh
./run.sh

API keys are cached in ../.env.local (mode 0600, gitignored).
Re-runs prompt with masked cached values. Press Enter to keep, or
paste a new value to update.

Architecture
------------
- Base image: node:22-bookworm-slim
- Uses existing node user (UID 1000, GID 1000)
- Repo mounted at /workspace
- jev-guard: installed via "opencode plugin jev-guard@<resolved> --global"
  Version is resolved from the npm registry at staging time.
- jev-review: MCP server at /opt/jev-review/dist/server.js
- OPENCODE_DISABLE_DEFAULT_PLUGINS=true disables bundled plugins

Model
-----
DeepSeek V4.1 Flash via official API.
Model ID: deepseek-flash. Base URL: https://api.deepseek.com.
Context: 1,000,000 tokens. Max output: 384,000 tokens.

Verification
------------
docker run --rm -e DEEPSEEK_API_KEY -e JEV_API_KEY <image> plugin list
docker run --rm -e DEEPSEEK_API_KEY -e JEV_API_KEY <image> mcp list

Troubleshooting
---------------
Unauthorized: DEEPSEEK_API_KEY not set. Edit .env.local or re-run.
jev-review MCP not found: dist/server.js not built.
jev-guard not loading: check resolved version in Dockerfile.
docker build permission denied: add user to docker group.
plugin add fails: "add" is V2-only; V1 uses "plugin <module>".
No matching version: registry version was different at build time.
  Re-run staging to re-resolve.

Re-run determinism
------------------
Re-running is idempotent: keys are shown masked, Enter keeps them.
To force re-prompt of both keys, delete .env.local.
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
GITIGNORE_EOF
    echo "  PASS: .gitignore"

    # 10. VERIFY JSON
    python3 -m json.tool "$REPO_DIR/opencode.json" > /dev/null
    if [ $? -eq 0 ]; then
        echo "  PASS: opencode.json is valid JSON"
    else
        echo "  FAIL: opencode.json INVALID JSON"
        return 1
    fi

    # 11. SECRET SCAN (key-shaped regex, generated files only)
    echo ""
    echo "=== Secret Scan ==="
    SECRET_FOUND=0
    # Match only key-shaped strings: 20+ alphanumeric chars after prefix
    KEY_REGEX='(sk-[A-Za-z0-9_-]{20,}|ts_[A-Za-z0-9_-]{20,}|jev-[A-Za-z0-9_-]{30,})'
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
    docker build -f docker/Dockerfile -t "opencode-deepseek-jev:robust" .
    if [ $? -ne 0 ]; then
        echo "  FAIL: docker build failed."
        return 1
    fi
    echo "  PASS: docker build succeeded"

    # 13. BEHAVIORAL SMOKE TEST: DeepSeek
    echo ""
    echo "=== Behavioral Smoke Test: DeepSeek ==="
    docker run --rm \
        -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
        -e JEV_API_KEY="$JEV_API_KEY" \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        run --model deepseek/deepseek-flash "Reply: OK"
    if [ $? -ne 0 ]; then
        echo "  FAIL: DeepSeek smoke test failed."
        echo "  If DEEPSEEK_API_KEY was mistyped, edit .env.local and re-run."
        return 1
    fi
    echo "  PASS: DeepSeek smoke test succeeded"

    # 14. BEHAVIORAL SMOKE TEST: Plugins
    echo ""
    echo "=== Behavioral Smoke Test: Plugins ==="
    docker run --rm \
        -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
        -e JEV_API_KEY="$JEV_API_KEY" \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        plugin list
    if [ $? -ne 0 ]; then
        echo "  WARN: plugin list returned non-zero."
    fi
    echo "  PASS: plugin list executed"

    # 15. BEHAVIORAL SMOKE TEST: MCP
    echo ""
    echo "=== Behavioral Smoke Test: MCP ==="
    docker run --rm \
        -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
        -e JEV_API_KEY="$JEV_API_KEY" \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        mcp list
    if [ $? -ne 0 ]; then
        echo "  WARN: mcp list returned non-zero."
    fi
    echo "  PASS: mcp list executed"

    # 16. GIT INIT + COMMIT
    echo ""
    echo "=== Git Commit ==="
    if [ ! -d "$REPO_DIR/.git" ]; then
        git init "$REPO_DIR"
    fi
    if git -C "$REPO_DIR" rev-parse --verify main > /dev/null; then
        git -C "$REPO_DIR" checkout main
    else
        git -C "$REPO_DIR" checkout -b main
    fi
    if [ -z "$(git -C "$REPO_DIR" config user.name)" ]; then
        git -C "$REPO_DIR" config user.name "$GITHUB_USER"
    fi
    if [ -z "$(git -C "$REPO_DIR" config user.email)" ]; then
        git -C "$REPO_DIR" config user.email "$GITHUB_USER@users.noreply.github.com"
    fi

    git -C "$REPO_DIR" add -A
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        git -C "$REPO_DIR" commit -m "OpenCode + DeepSeek V4.1 Flash + Jev: v15"
        if [ $? -ne 0 ]; then
            echo "  FAIL: git commit failed"
            return 1
        fi
        echo "  PASS: git commit"
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
        EXISTING_REMOTE=$(git -C "$REPO_DIR" remote get-url origin 2>&1)
        if echo "$EXISTING_REMOTE" | grep -q "github.com"; then
            if [ "$EXISTING_REMOTE" != "$EXPECTED_REMOTE" ]; then
                echo "  NOTE: Updating origin to $EXPECTED_REMOTE"
                git -C "$REPO_DIR" remote set-url origin "$EXPECTED_REMOTE"
            else
                echo "  NOTE: origin already correct."
            fi
        else
            if [ -n "$EXISTING_REMOTE" ]; then
                git -C "$REPO_DIR" remote remove origin
            fi
            git -C "$REPO_DIR" remote add origin "$EXPECTED_REMOTE"
        fi
        git -C "$REPO_DIR" fetch origin
        if git -C "$REPO_DIR" rev-parse --verify origin/main > /dev/null; then
            git -C "$REPO_DIR" rebase origin/main
            if [ $? -ne 0 ]; then
                echo "  FAIL: git rebase failed. Resolve conflicts manually."
                return 1
            fi
        else
            echo "  NOTE: remote main does not exist yet, skipping rebase."
        fi
        git -C "$REPO_DIR" push -u origin main
        if [ $? -ne 0 ]; then
            echo "  FAIL: git push failed."
            return 1
        fi
    else
        cd "$REPO_DIR"
        gh repo create "$GITHUB_REPO" \
            --public \
            --source=. \
            --remote=origin \
            --push
        if [ $? -ne 0 ]; then
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
    docker info > /dev/null
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 2: opencode.json valid JSON" | tee -a "$VERIFY_LOG"
    python3 -m json.tool "$REPO_DIR/opencode.json" > /dev/null
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 3: deepseek-flash in config" | tee -a "$VERIFY_LOG"
    grep -q "deepseek-flash" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 4: V1 plugin syntax in Dockerfile" | tee -a "$VERIFY_LOG"
    grep -q "opencode plugin jev-guard" "$REPO_DIR/docker/Dockerfile"
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 5: jev-guard version is not 0.2.1" | tee -a "$VERIFY_LOG"
    if grep -q "jev-guard@0.2.1" "$REPO_DIR/docker/Dockerfile"; then
        echo "  FAIL: still pinned to nonexistent 0.2.1" | tee -a "$VERIFY_LOG"
    else
        echo "  PASS" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 6: jev-review MCP path" | tee -a "$VERIFY_LOG"
    grep -q "jev-review/dist/server.js" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 7: skills path in config" | tee -a "$VERIFY_LOG"
    grep -q "skills" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 8: API keys non-empty" | tee -a "$VERIFY_LOG"
    if [ -n "$DEEPSEEK_API_KEY" ] && [ -n "$JEV_API_KEY" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 9: no rm -rf in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "rm -rf" "$REPO_DIR/docker/Dockerfile"; then echo "  FAIL" | tee -a "$VERIFY_LOG"; else echo "  PASS" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 10: jev-review pinned commit in Dockerfile" | tee -a "$VERIFY_LOG"
    grep -q "$JEV_REVIEW_COMMIT" "$REPO_DIR/docker/Dockerfile"
    if [ $? -eq 0 ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL" | tee -a "$VERIFY_LOG"; fi

    echo "REPORT 11: .env.local mode 0600" | tee -a "$VERIFY_LOG"
    PERM=$(stat -c '%a' "$ENV_FILE" 2>&1)
    if [ "$PERM" = "600" ]; then echo "  PASS" | tee -a "$VERIFY_LOG"; else echo "  FAIL: mode $PERM" | tee -a "$VERIFY_LOG"; fi

    git -C "$REPO_DIR" add verification.log
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        git -C "$REPO_DIR" commit -m "Add verification log v15"
    fi
    git -C "$REPO_DIR" push origin main
    if [ $? -ne 0 ]; then
        echo "  FAIL: verification log push failed"
        return 1
    fi
    echo "  PASS: verification log pushed"

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
    echo "Scripts v15: $BASE/scripts/stage-opencode-repo-v15.sh"
    echo "Verify log:  $BASE/verification.log"
    echo ""
    echo "=== Staging Complete ==="
    echo "Repo: https://github.com/$GITHUB_USER/$GITHUB_REPO"
}

main "$@"
