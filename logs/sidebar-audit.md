# Sidebar Audit — opencode-deepseek-jev

Audit date: 2026-09-23 (UTC). Scope: `/workspace` (repo, rw) and `/workspace/notes` (chat logs, ro).

> **Headline:** in this container `/workspace/notes` **does not exist**, so the chat-log
> corpus could not be read directly. `/notes` is also absent. The notes-mount guard in
> `scripts/archive/one-shot/final-audit.sh` is fooled by the TUI service's
> `/workspace/notes:ro` line and never adds the mount to `opencode-web`, which is the
> service this audit runs in. Where chat-log content is cited below it comes from the
> captured transcript `logs/artifacts-20260923T174850Z/agent-transcript.log`, which
> recorded a prior run that *did* see `/notes`.

## 1. Project identity

This repo is a Docker-packaged coding-agent environment that wraps the OpenCode binary
around a DeepSeek "V4.1 Flash" provider plus Jev review/guard tooling.

- `README.txt` — self-contained Docker setup; prerequisites are Docker Engine,
  authenticated `gh`, a DeepSeek key (`sk-`), and a Jev key (`apikey_`); keys are cached
  in `../.env.local` (mode 0600, gitignored). Documents the process-substitution live
  streaming policy, the opencode 1.18.31 non-TTY exit-code quirk ("assert on text OK,
  not exit code"), UID handling, and secrets hygiene.
- `QUICKSTART.txt` — points operators at the Dockge UI on `http://localhost:5001`
  (`scripts/deploy-dockge.sh`, then `scripts/flatten-dockge-stacks.sh`); states the image
  built from `docker/` embeds the OpenCode binary, DeepSeek provider config, the
  `jev-guard` plugin, and the `jev-review` MCP server.
- `opencode.json` — provider `deepseek` / model `deepseek-flash` (context 1,000,000 /
  output 384,000), `"model": "deepseek/deepseek-flash"`, `"plugin": ["jev-guard"]`,
  `"skills": ["/opt/jev-review/skills"]`, and MCP server `jev-review` launched as
  `node /opt/jev-review/dist/server.js` with `JEV_API_KEY`.

In short: an opinionated, script-driven container image for running an OpenCode +
DeepSeek agent with Jev feedback, managed through Dockge.

## 2. Rule system

The requested extraction could not be run against the notes corpus:

```
grep -rhoE '#[0-9]+' /workspace/notes --include='*.txt' | sort | uniq -c | sort -rn | head -30
# grep: /workspace/notes: No such file or directory
```

The same grep over every `*.txt` in `/workspace` returns **no rows** — the rule
definitions live only in the (inaccessible) notes. Cross-reference against
`push_notes_v18.sh` (the actual location; the brief's
`scripts/archive/one-shot/push_notes_v18.sh` does not exist — the file is at the repo
root):

Rule IDs cited by `push_notes_v18.sh` (header lines 12–16 and inline markers):

| Rule | Cited meaning |
| ---- | ------------- |
| #7   | no `sed`; guarded |
| #8   | no `2>/dev/null` |
| #28  | dependency check |
| #34  | push-evidence (with #47) |
| #37  | SKIP != PASS |
| #38  | `printf` (not `echo`) |
| #39  | gitignore checked before add (with #45) |
| #41  | UTC timestamps |
| #45  | gitignore checked before add (with #39) |
| #47  | push-evidence (with #34) |
| #53  | owner/repo parsed via `python3`, never `sed` |
| #54  | evidence completeness gate |
| #55  | raw-link HTTP-200 validation with backoff |
| #57  | end sentinel |

Repo-wide search for `Rule #N` finds only five definitions/citations outside the header
(`#28`, `#53`, `#54`, `#39`, `#8`) plus two false positives (`#26588`, `#31280` are
byte/blob sizes, not rules). Consequences:

- **Cited but undefined in `/workspace`:** all fourteen rules above, plus the
  `LOGGING CONVENTION` referenced in the header. Definitions live only in `/notes`.
- **Defined but uncited:** none observed, because no definitions exist in the accessible
  corpus.
- **Consistency note:** `push_notes_v18.sh` is internally faithful to the cited rules —
  it avoids `sed`, avoids `2>/dev/null`, uses `printf`, uses `python3` for remote
  parsing, emits a `# === END ... ===` sentinel, and gates on verified HTTP 200.

## 3. JEV hits

`/workspace/notes` could not be searched (absent). In `/workspace`, case-insensitive
`jev` appears in **126 files / 2,416 lines** (node_modules excluded). Representative
hits:

- `opencode.json` — `plugin: ["jev-guard"]`, `skills: ["/opt/jev-review/skills"]`, MCP
  server `jev-review` (`node /opt/jev-review/dist/server.js`, `JEV_API_KEY`).
- `docker/Dockerfile` — `opencode plugin jev-guard@0.3.1 --global` and
  `git clone https://github.com/NiazMorshed2007/jev-review.git /opt/jev-review`
  (checked out at `3fb6042e…`, `npm ci && npm run build`).
- `docker/docker-compose.yml`, `docker/run.sh`, `docker/build.sh` — image/container name
  `opencode-deepseek-jev:robust`.
- `scripts/ask.sh`, `scripts/doctor.sh` — image name; `doctor.sh` probes the plugin list
  for `jev-guard`.
- `scripts/test-repo.sh` — gates G3/G4 for `jev-review` and the `jev-guard` install line.
- Many `.bak.*` snapshots and `scripts/archive/**` copies repeat the same strings.
- Chat-log evidence (from the prior transcript) names `jev-guard`, `jev-review MCP`, and
  a JEV API key with prefix rules (`apikey_`, `sk-`, `ts_`, `jev-`).
- `/opt/jev-review` itself is outside the repo and was not inspected this run.

## 4. Current state

### `opencode-web` service block (`docker/docker-compose.yml`, lines 45–71)

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

Note: the `opencode` **TUI** service (lines 18–43) carries the only notes mount:
`/home/owner/Documents/9e3e0363-…/notes:/workspace/notes:ro`. `opencode-web` has **no**
notes mount, which is why `/workspace/notes` is absent here.

### `docker/web-entrypoint.sh`

POSIX `sh`, `set -u`. Resolves `DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"`,
`mkdir -p`s it, and when `DEEPSEEK_API_KEY` is non-empty writes `auth.json`
(`{ deepseek: { type: "api", key: <key> } }`) via an inline `node -e` script
(JSON-safe, no sed/escaping), logging the byte size to stderr. Empty key ⇒ warning,
no file. It then `exec opencode web --hostname 0.0.0.0 --port 4096`.

### Session count

`sqlite3` is **not installed** (`command -v sqlite3` → absent; `python3` is also absent).
The equivalent query via Node's built-in SQLite against
`/workspace/data/opencode/opencode.db`:

```
session=12   message=67   part=317   project=1
```

Session count: **12** (the prior audit reported 8; the DB is live and growing). The
`opencode.db-wal` is ~4.1 MB against a ~2.9 MB main file.

## 5. Sidebar streaming question

**Does the sidebar show a session while the agent is processing? — Yes.**

Evidence:

1. The SPA bundle (`logs/artifacts-20260923T165336Z/bundle.js`, sha256 `5df904b9…`)
   contains `SSE`/`EventSource` support and string counts:
   `/api/session` ×66, `hydrate` ×17, `hydration` ×8, `session.created` ×6,
   `session.updated` ×5, `message.updated` ×4, `hydrated` ×4, `/api/session/active` ×2.
   The sidebar is hydrated from `/api/session?directory=X&project=Y` and then kept in
   sync by SSE events.
2. A session is persisted at creation time, before any completion:
   `verify-active-vs-historical` (telemetry 17:01) POSTs a session and `/api/session`
   grows 6→7 immediately, while `/api/session/active` stays empty (`{"data":{}}`) both
   before and after. So active-ness is carried by the session list + SSE, not by
   `/api/session/active` (which the bundle barely references).
3. The archived operator note captured in
   `logs/artifacts-20260923T174850Z/agent-transcript.log`
   (`/notes/fe70fd73-…_0026.txt:33,35`) states: *"As the session processes (messages
   stream in), session.updated / message.updated events keep the sidebar entry in
   sync … So yes, as the session processes, it is in the sidebar. This is what 'active'
   was getting at — but the mechanism is SSE events, not the /api/session/active
   endpoint."*

Caveat (why this was historically confusing): a 3-second capture of the idle SSE stream
(`logs/artifacts-20260923T165336Z/api-event.txt`, 96 bytes) shows only
`{"type":"server.connected"}` plus a heartbeat. The stream is silent when nothing is
happening, so an empty capture does not mean the sidebar is broken. If the sidebar is
blank while a session is processing, look at browser-side project scoping/hydration,
not at SSE delivery.

## 6. Operator next steps

- **Fix the notes-mount guard so this audit can read `/notes`.** Give `opencode-web` its
  own `/workspace/notes:ro` (absolute host source) and make the guard in
  `final-audit.sh` scope its `grep` to the `opencode-web` block (or check
  `docker inspect` mounts) instead of substring-matching the whole compose file.
- **Stop relying on tools that are not in the image.** `sqlite3` and `python3` are
  absent; several scripts (`push_notes_v18.sh`, `rotate-keys-guided.sh`,
  `test-repo.sh`, `find-sidebar-source.sh`) require them. Either bake them into
  `docker/Dockerfile` or standardize on `node --experimental-sqlite` and a Node helper,
  as this audit did.
- **Add a real sidebar-streaming test.** The archived plan calls for
  `test-sidebar-streaming.sh` (create a session, hold `/api/event` open, POST a message,
  assert `session.created`/`session.updated`/`message.updated` appear); it was never
  written. Add it so the "yes" in section 5 is continuously verified rather than
  inferred from the bundle.
- **Tame the uncommitted drift.** `git status` shows many modified tracked files plus
  ~20 untracked `*.bak.*` snapshots, a modified `logs/telemetry-2026-09-23.log`, and an
  untracked `push_notes_v18.sh` and `docker/web-entrypoint.sh`. Commit or archive these
  so "current" behavior matches HEAD.
- **Run a JEV-keyed credential rotation and prune backups.** `.env.local` plus two
  `.env.local.bak.*` files hold live DeepSeek/JEV keys (mode 0600, gitignored, but the
  backups are untracked leftovers). Rotate, then delete stale backups, and keep
  `opencode-web`'s published `0.0.0.0:4096` off untrusted networks when
  `OPENCODE_SERVER_PASSWORD` is unset.
