# Sidebar Audit — opencode-deepseek-jev

Audit date: 2026-09-23 (UTC). Scope: `/workspace` (repo) and `/notes` (chat logs).
This report was produced by the packaged coding agent as requested by
`scripts/archive/one-shot/run-audit-via-agent.sh`.

## 1. Project identity

This repo is a Docker-packaged coding-agent environment that wraps the OpenCode
binary around a DeepSeek "V4.1 Flash" provider and the Jev review/guard tooling.
`README.txt` describes a self-contained setup whose prerequisites are Docker, an
authenticated `gh`, a DeepSeek key (`sk-`), and a Jev key (`apikey_`), with keys
cached in a mode-0600 gitignored `.env.local`. `QUICKSTART.txt` points operators at
the Dockge management UI (port 5001) and states that the image built from `docker/`
embeds the OpenCode binary, the DeepSeek provider config, the `jev-guard` plugin,
and the `jev-review` MCP server. `opencode.json` confirms this: provider
`deepseek`/model `deepseek-flash`, `plugin: ["jev-guard"]`, skills under
`/opt/jev-review/skills`, and an MCP server `jev-review` launched via
`node /opt/jev-review/dist/server.js`. In short, it is an opinionated, script-driven
container image for running an OpenCode + DeepSeek agent with Jev feedback.

## 2. Rule system

`/notes` is **not visible** in this environment (`stat /notes` -> no such file or
directory; no `notes/` directory exists under `/workspace`). It therefore could not
be grepped for the requested rule patterns, and no rule numbers were extracted from
the chat logs.

Cross-reference performed against the cited set in `push_notes_v18.sh`. The path
named in the audit brief, `scripts/archive/one-shot/push_notes_v18.sh`, **does not
exist**; the file is actually at the repo root: `/workspace/push_notes_v18.sh`.

Rules cited by `push_notes_v18.sh` (header lines 12-16, plus inline Rule #28):

| Rule | Cited meaning in the script |
| ---- | --------------------------- |
| #7   | no sed / guarded |
| #8   | no `2>/dev/null` |
| #28  | dependency check |
| #34  | push-evidence (with #47) |
| #37  | SKIP != PASS |
| #38  | printf |
| #39  | gitignore-checked before add (with #45) |
| #41  | UTC timestamps |
| #45  | gitignore-checked before add (with #39) |
| #47  | push-evidence (with #34) |
| #53  | owner/repo via python3, never sed |
| #54  | evidence completeness gate |
| #55  | raw-link HTTP-200 validation with backoff |
| #57  | end sentinel |

- **Cited but undefined:** all fourteen rules above (#7, #8, #28, #34, #37, #38,
  #39, #41, #45, #47, #53, #54, #55, #57). A repository-wide search for rule
  definitions (`Rule #`, `#7`-style anchors) in `/workspace` returned nothing: the
  definitions evidently live only in `/notes`, which is inaccessible here.
- **Defined but uncited:** none observed, because no definitions are present in the
  accessible corpus. The script also references a `LOGGING CONVENTION` that has no
  definition in `/workspace`.

## 3. JEV

`/notes` could not be grepped (not visible). In `/workspace`, case-insensitive
matches for `jev` are widespread:

- `opencode.json`: `plugin: ["jev-guard"]`, `skills: ["/opt/jev-review/skills"]`,
  and MCP server `jev-review` (`node /opt/jev-review/dist/server.js`,
  `JEV_API_KEY` env).
- `QUICKSTART.txt`: names the `jev-guard` plugin and `jev-review` MCP server.
- `README.txt`: title and prerequisites (`Jev API key`, console.typesafe.ai).
- `docker/Dockerfile`: `opencode plugin jev-guard@0.3.1 --global` and
  `git clone https://github.com/NiazMorshed2007/jev-review.git /opt/jev-review`.
- `docker/docker-compose.yml`, `docker/run.sh`, `docker/build.sh`,
  `scripts/ask.sh`, `scripts/doctor.sh`: image/container name
  `opencode-deepseek-jev:robust`; `doctor.sh` probes `model:"jev-latest"` and checks
  the plugin list for `jev-guard`.
- `scripts/test-repo.sh`: gates G3/G4 for `jev-review` and the `jev-guard` install
  line; accepts `apikey_`, `sk-`, `ts_`, `jev-` key prefixes.
- Numerous `.bak.*` snapshots and `scripts/archive/...` copies repeat the same
  strings. `/opt/jev-review` itself is outside the repo and was not inspected.

## 4. Current state

`docker/docker-compose.yml` — `opencode-web` service block:

```yaml
  opencode-web:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-web
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    working_dir: /workspace
    entrypoint: ["/workspace/docker/web-entrypoint.sh"]
    ports:
      - "4096:4096"
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
    env_file:
      - ../.env.local
    environment:
      OPENCODE_DISABLE_DEFAULT_PLUGINS: "true"
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
```

`docker/web-entrypoint.sh`: a POSIX `sh` entrypoint with `set -u`. It resolves
`DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"`, `mkdir -p`s it, and if
`DEEPSEEK_API_KEY` is non-empty writes `auth.json`
(`{ deepseek: { type: "api", key: <key> } }`) using an inline `node -e` script
(JSON-safe serialisation, no sed/escaping), logging the byte size to stderr. If the
key is empty it prints a warning and writes nothing. It then
`exec opencode web --hostname 0.0.0.0 --port 4096`.

Session count: `sqlite3` is **not installed** in this environment, so the requested
command could not run. The equivalent query via Node's built-in SQLite
(`node --experimental-sqlite`) against `/workspace/data/opencode/opencode.db`
returned:

```
session count: 8
```

The web service block does **not** mount `/notes`; only the `opencode` (TUI) service
has `- ../notes:/notes:ro` (line 31).

## 5. Open risks

- **The agent cannot read `/notes`.** The `../notes:/notes:ro` bind mount exists on
  the `opencode` (TUI) service but not on `opencode-web`, which is the service the
  audit/agent runs in. Worse, `run-audit-via-agent.sh`'s `ensure_notes_mount` guard
  greps the *whole* compose file for `/notes`, so it sees the TUI line, concludes the
  mount is "already present", and never adds it to `opencode-web`. Any workflow that
  assumes chat-log access (chatlog.sh, rule extraction) silently degrades.
- **Secrets on disk.** `.env.local` and two timestamped `.env.local.bak.*` files hold
  live DeepSeek/JEV keys (mode 0600, gitignored, but the backups are untracked
  leftovers). Rotation scripts (`rotate-keys-guided.sh`, `rotate-api-keys.sh`) mutate
  these, so a half-run rotation can leave stale/duplicate credentials.
- **Broken references and missing tooling.** The audit brief's
  `scripts/archive/one-shot/push_notes_v18.sh` does not exist (real file at repo
  root), and neither `sqlite3` nor `python3` is on PATH even though
  `push_notes_v18.sh`, `run-audit-via-agent.sh`, `rotate-keys-guided.sh`, and
  `test-repo.sh` depend on them.
- **Uncommitted drift.** `git status` shows many modified tracked files plus dozens of
  untracked `*.bak.*` snapshots; the SQLite DB carries a ~1.2 MB WAL. The repo is in a
  mid-migration state, so "current" behavior may not match HEAD.
- **Network/auth exposure.** `opencode-web` publishes `0.0.0.0:4096` and, per the
  compose comment, has no authentication when `OPENCODE_SERVER_PASSWORD` is unset;
  combined with the whole-repo `/workspace` bind and host-UID passthrough, exposing the
  port to an untrusted network grants full agent/repo access.
