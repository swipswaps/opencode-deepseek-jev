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
  https://console.typesafe.ai/settings/keys

Quick Start
-----------
cd docker
./build.sh
./run.sh

API keys are cached in ../.env.local (mode 0600, gitignored).

Both keys are validated before the Docker build:
- DeepSeek: GET https://api.deepseek.com/user/balance must return 200
- Jev: POST https://api.typesafe.ai/v1/systemone with a minimal
  noul question (type + instructions) must return 200

If a cached key fails, the script prompts for a new value once.
If the new value also fails, the script aborts. No retry loop,
no server spam.

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

Verification
------------
docker run --rm -e DEEPSEEK_API_KEY -e JEV_API_KEY <image> plugin list
docker run --rm -e DEEPSEEK_API_KEY -e JEV_API_KEY <image> mcp list

Troubleshooting
---------------
Authentication Fails (DeepSeek): key invalid or revoked. Get a new key at
  https://platform.deepseek.com/api_keys
Jev key rejected: must start with apikey_ or sk-. Get a key at
  https://console.typesafe.ai/settings/keys
  Docs: https://docs.typesafe.ai/
HTTP 422 from TypeSafe: request format issue. The probe uses the
  documented format: {"type":"noul","instructions":"..."}.
jev-review MCP not found: dist/server.js not built.
jev-guard not loading: check resolved version in Dockerfile.
docker build permission denied: add user to docker group.

Re-run determinism
------------------
Re-running is idempotent: cached keys are validated and shown masked.
To force re-prompt, delete .env.local.
