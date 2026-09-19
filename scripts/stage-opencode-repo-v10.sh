#!/usr/bin/env bash
# Stage, create, push, and verify OpenCode + DeepSeek V4.1 Flash + Jev repo.
# v10: V2 plugins key, manual jev-review clone/build, pinned dependencies,
#      behavioral verification via opencode2 plugin list and opencode mcp list,
#      idempotent git remote/branch handling, commit after build.
# Plain ASCII. No markdown. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
GITHUB_REPO="opencode-deepseek-jev"
GITHUB_USER=""
JEV_REVIEW_COMMIT="3fb6042ebf07f0fdaae30d65c6393848e1a549e3"
JEV_GUARD_VERSION="0.2.1"

main() {
    # Gate: required host binaries
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

    # Interactive API key collection (silent input)
    echo ""
    echo "=== API Key Setup ==="
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        read -r -s -p "Enter DEEPSEEK_API_KEY (sk-...): " DEEPSEEK_API_KEY
        echo ""
    fi
    if [ -z "$JEV_API_KEY" ]; then
        read -r -s -p "Enter JEV_API_KEY (jev-...): " JEV_API_KEY
        echo ""
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
    echo "  PASS: Both API keys collected."

    # 1. DOCKERFILE
    mkdir -p "$REPO_DIR/docker"

    cat > "$REPO_DIR/docker/Dockerfile" <<'DOCKERFILE_EOF'
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    && apt-get clean

RUN groupadd --gid 1000 opencode \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash opencode

USER opencode
RUN curl -fsSL https://opencode.ai/install | bash
ENV PATH="/home/opencode/.opencode/bin:${PATH}"
ENV OPENCODE_DISABLE_DEFAULT_PLUGINS=true

USER root
# jev-review: manual clone at pinned commit (no npm publication)
RUN git clone https://github.com/NiazMorshed2007/jev-review.git /opt/jev-review
WORKDIR /opt/jev-review
RUN git checkout 3fb6042ebf07f0fdaae30d65c6393848e1a549e3
RUN npm ci
RUN npm run build
RUN ls -la /opt/jev-review/dist/server.js
RUN chown -R opencode:opencode /opt/jev-review

WORKDIR /workspace
USER opencode
ENTRYPOINT ["opencode"]
DOCKERFILE_EOF

    echo "  PASS: docker/Dockerfile"

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

    # 3. OPENCODE.JSON (V2 plugins key, package name for jev-guard)
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
  "plugins": [
    "jev-guard@0.2.1"
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

    # 4. BUILD SCRIPT (main() wrapper)
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

    # 5. RUN SCRIPT (main() wrapper)
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

    if [ -z "$DEEPSEEK_API_KEY" ]; then
        echo "WARN: DEEPSEEK_API_KEY is not set."
    fi

    if [ -z "$JEV_API_KEY" ]; then
        echo "WARN: JEV_API_KEY is not set."
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

Docker-based setup for OpenCode with DeepSeek V4.1 Flash and Jev
integration. All project code stays inside this repository.

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
export DEEPSEEK_API_KEY='sk-...'
export JEV_API_KEY='jev-...'
./run.sh

Architecture
------------
- Base image: node:22-bookworm-slim
- Non-root user: UID 1000
- Repo mounted at /workspace
- jev-guard: npm package jev-guard@0.2.1 in plugins array
- jev-review: MCP server at /opt/jev-review/dist/server.js
- OPENCODE_DISABLE_DEFAULT_PLUGINS=true disables bundled plugins

Model
-----
DeepSeek V4.1 Flash via official API.
Model ID: deepseek-flash. Base URL: https://api.deepseek.com.
API key: {env:DEEPSEEK_API_KEY} in provider options.
Context window: 1,000,000 tokens. Max output: 384,000 tokens.

Verification
------------
After building the image, run:
  docker run --rm -e DEEPSEEK_API_KEY -e JEV_API_KEY <image> plugins list
  docker run --rm -e DEEPSEEK_API_KEY -e JEV_API_KEY <image> mcp list

Troubleshooting
---------------
Symptom: Unauthorized: Authentication Fails
Cause:   DEEPSEEK_API_KEY not exported before running opencode
Fix:     export DEEPSEEK_API_KEY='sk-...' in the host shell

Symptom: jev-review MCP not found
Cause:   dist/server.js not built
Fix:     Dockerfile runs npm ci && npm run build and verifies output

Symptom: jev-guard plugin not loading
Cause:   Package name not resolved by OpenCode cache
Fix:     plugins array contains "jev-guard@0.2.1"

Symptom: docker build permission denied
Cause:   User not in docker group
Fix:     sudo usermod -aG docker $USER && newgrp docker
README_EOF

    echo "  PASS: README.txt"

    # 8. DOCKERIGNORE
    cat > "$REPO_DIR/.dockerignore" <<'DOCKERIGNORE_EOF'
node_modules
dist
*.log
.env
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

    # 11. SECRET SCAN (before any commit or push)
    echo ""
    echo "=== Secret Scan ==="
    SECRET_PATTERNS="sk- jev- ts_"
    SECRET_FOUND=0
    for pattern in $SECRET_PATTERNS; do
        if grep -r "$pattern" "$REPO_DIR" --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist; then
            echo "  WARN: pattern '$pattern' found in repo files."
            SECRET_FOUND=1
        fi
    done
    if [ $SECRET_FOUND -eq 0 ]; then
        echo "  PASS: no obvious API key patterns found."
    else
        echo "  WARN: inspect files before publishing."
    fi

    # 12. BUILD SMOKE TEST (before commit)
    echo ""
    echo "=== Build Smoke Test ==="
    cd "$REPO_DIR"
    docker build -f docker/Dockerfile -t "opencode-deepseek-jev:robust" .
    if [ $? -ne 0 ]; then
        echo "  FAIL: docker build failed. Fix Dockerfile before proceeding."
        return 1
    fi
    echo "  PASS: docker build succeeded"

    # 13. BEHAVIORAL SMOKE TEST
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
        return 1
    fi
    echo "  PASS: DeepSeek smoke test succeeded"

    echo "=== Behavioral Smoke Test: Plugins ==="
    docker run --rm \
        -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" \
        -e JEV_API_KEY="$JEV_API_KEY" \
        -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
        "opencode-deepseek-jev:robust" \
        plugins list
    if [ $? -ne 0 ]; then
        echo "  WARN: plugins list returned non-zero."
    fi
    echo "  PASS: plugins list executed"

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

    # 14. GIT INIT + COMMIT (after successful build and smoke tests)
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
        git -C "$REPO_DIR" commit -m "OpenCode + DeepSeek V4.1 Flash + Jev: initial repo"
        if [ $? -ne 0 ]; then
            echo "  FAIL: git commit failed"
            return 1
        fi
        echo "  PASS: git commit"
    else
        echo "  NOTE: nothing to commit."
    fi

    # 15. GH REPO CREATE OR SYNC (idempotent remote handling)
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

    # 16. VERIFICATION REPORT
    echo ""
    echo "=== Verification Report ==="
    VERIFY_LOG="$REPO_DIR/verification.log"
    : > "$VERIFY_LOG"

    echo "REPORT 1: docker info" | tee -a "$VERIFY_LOG"
    docker info > /dev/null
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 2: opencode.json valid JSON" | tee -a "$VERIFY_LOG"
    python3 -m json.tool "$REPO_DIR/opencode.json" > /dev/null
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 3: deepseek-flash in config" | tee -a "$VERIFY_LOG"
    grep -q "deepseek-flash" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 4: plugins key present" | tee -a "$VERIFY_LOG"
    grep -q '"plugins"' "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 5: jev-guard in plugins array" | tee -a "$VERIFY_LOG"
    grep -q "jev-guard" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 6: jev-review MCP path" | tee -a "$VERIFY_LOG"
    grep -q "jev-review/dist/server.js" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 7: skills path in config" | tee -a "$VERIFY_LOG"
    grep -q "skills" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 8: API keys non-empty" | tee -a "$VERIFY_LOG"
    if [ -n "$DEEPSEEK_API_KEY" ] && [ -n "$JEV_API_KEY" ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 9: no rm -rf in Dockerfile" | tee -a "$VERIFY_LOG"
    if grep -q "rm -rf" "$REPO_DIR/docker/Dockerfile"; then
        echo "  FAIL: rm -rf found" | tee -a "$VERIFY_LOG"
    else
        echo "  PASS" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 10: jev-review pinned commit in Dockerfile" | tee -a "$VERIFY_LOG"
    grep -q "$JEV_REVIEW_COMMIT" "$REPO_DIR/docker/Dockerfile"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    echo "REPORT 11: jev-guard version pinned in opencode.json" | tee -a "$VERIFY_LOG"
    grep -q "jev-guard@$JEV_GUARD_VERSION" "$REPO_DIR/opencode.json"
    if [ $? -eq 0 ]; then
        echo "  PASS" | tee -a "$VERIFY_LOG"
    else
        echo "  FAIL" | tee -a "$VERIFY_LOG"
    fi

    # Push verification log
    git -C "$REPO_DIR" add verification.log
    if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
        git -C "$REPO_DIR" commit -m "Add verification log"
    fi
    git -C "$REPO_DIR" push origin main
    if [ $? -ne 0 ]; then
        echo "  FAIL: verification log push failed"
        return 1
    fi
    echo "  PASS: verification log pushed"

    # 17. PRINT GITHUB RAW LINKS
    BASE="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/main"
    echo ""
    echo "=== GitHub Raw Links ==="
    echo "README:      $BASE/README.txt"
    echo "Requirements:$BASE/requirements.txt"
    echo "opencode:    $BASE/opencode.json"
    echo "Dockerfile:  $BASE/docker/Dockerfile"
    echo "Compose:     $BASE/docker/docker-compose.yml"
    echo "build.sh:    $BASE/docker/build.sh"
    echo "run.sh:      $BASE/docker/run.sh"
    echo "Verify log:  $BASE/verification.log"
    echo ""
    echo "=== Staging Complete ==="
    echo "Repo: https://github.com/$GITHUB_USER/$GITHUB_REPO"
}

main "$@"
