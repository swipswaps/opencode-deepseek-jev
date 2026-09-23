# Sidebar Audit — OpenCode + DeepSeek + JEV container

Audit date: 2026-09-23 (UTC). Scope: `/workspace` (rw) and `/workspace/notes`
(chat logs, ro, 41 files: 12 `.txt`, 28 `.png`, 1 `.py`). Auditor runs inside the
`opencode-deepseek-web` container (user `node`, host UID 1000, Node v22.23.2,
OpenCode 1.18.32). Every number below comes from a command run during this audit.

> **Mount note:** `/workspace/notes` is readable here even though the tracked
> `docker/docker-compose.yml` `opencode-web` block has no notes mount. It is provided
> by the **untracked** `docker/docker-compose.override.yml`. Audits in this container
> are therefore not reproducible from tracked files alone.

## 1. Project identity

A Docker-packaged coding-agent environment wrapping the OpenCode binary around a
DeepSeek "V4.1 Flash" provider plus Jev review/guard tooling, managed via Dockge.

- **`README.txt`** — prerequisites: Docker Engine, authenticated `gh`, a DeepSeek key
  (`sk-`, platform.deepseek.com/api_keys), a Jev key (`apikey_`,
  console.typesafe.ai/keys). Keys cached in `../.env.local` (mode 0600, gitignored).
  Documents process-substitution live streaming, the opencode 1.18.31 non-TTY
  exit-code quirk (assert on response text "OK", not exit code), `--user
  $(id -u):$(id -g)` UID handling, and secrets hygiene (no keys on argv; mode-0600
  header temp files). Staging output → `../staging.log`.
- **`QUICKSTART.txt`** — `cd scripts && ./deploy-dockge.sh`, then
  `./flatten-dockge-stacks.sh`, then open `http://localhost:5001`. The image embeds
  OpenCode, the DeepSeek provider config, the `jev-guard` plugin, and the `jev-review`
  MCP server.
- **`opencode.json`** — provider `deepseek` (`@ai-sdk/openai-compatible`,
  `baseURL https://api.deepseek.com`, `apiKey {env:DEEPSEEK_API_KEY}`); model
  `deepseek-flash` ("DeepSeek V4.1 Flash", context 1,000,000 / output 384,000);
  default `"model": "deepseek/deepseek-flash"`; `"plugin": ["jev-guard"]`;
  `"skills": ["/opt/jev-review/skills"]`; MCP server `jev-review` =
  `node /opt/jev-review/dist/server.js` with `JEV_API_KEY` from the environment.
- **`docker/Dockerfile`** — `node:22-bookworm-slim`, xdg-open no-op shim, installs
  OpenCode via `curl https://opencode.ai/install | bash`, installs
  `jev-guard@0.3.1 --global`, then clones `NiazMorshed2007/jev-review` into
  `/opt/jev-review`, checks out `3fb6042ebf07f0fdaae30d65c6393848e1a549e3`,
  `npm ci && npm run build`.

## 2. Rule system

Requested extraction, run verbatim:

```
$ grep -rhoE "#[0-9]+" /workspace/notes --include="*.txt" | sort | uniq -c | sort -rn | head -30
    390 #5
     50 #8
     42 #12
     38 #9
     32 #13
     28 #7
     20 #14
     13 #3
     12 #54
     11 #1
      9 #55
      9 #53
      8 #45
      8 #39
      8 #10
      7 #5604
      7 #34
      7 #2
      6 #6
      6 #57
      6 #41
      6 #4
      6 #38
      6 #37
      6 #18
      6 #17
      6 #11
      5 #47
      5 #15
      4 #16
```

(`grep` flags `9e3e0363-…_0013.txt` and `fe70fd73-…_0027.txt` as binary; their tokens
are counted with `-a` only.)

**The top-30 is dominated by Docker BuildKit step markers, not rule references.** Of
**779 total `#N` tokens** in the notes, **660 lines are BuildKit step lines**
(`^#5 [ 4/14] RUN …`, `#5 CACHED`). The leading `#5` (390) and the `#12`/`#9`/`#13`/`#14`
entries are all build steps; `#5604` is an npm postinstall regression (Issue #5604).

Cross-reference with **`/workspace/push_notes_v18.sh`** (header lines 12–16 cite the rules):

| Rule | Cited meaning (script header) | Count in `push_notes_v18.sh` |
| ---- | ----------------------------- | ---------------------------- |
| #7   | no `sed`; guarded             | 1 |
| #8   | no `2>/dev/null`              | 1 |
| #28  | dependency check              | 1 |
| #34  | push-evidence (with #47)      | 1 |
| #37  | SKIP != PASS                  | 1 |
| #38  | `printf` (not `echo`)         | 1 |
| #39  | gitignore checked before add (with #45) | 2 |
| #41  | UTC timestamps                | 1 |
| #45  | gitignore checked before add (with #39) | 2 |
| #47  | push-evidence (with #34)      | 1 |
| #53  | owner/repo parsed via `python3`, never `sed` | 2 |
| #54  | evidence completeness gate    | 3 |
| #55  | raw-link HTTP-200 validation with backoff | 2 |
| #57  | end sentinel                  | 1 |

- **Cited and in the top-30:** `#8`(50), `#7`(28), `#54`(12), `#55`(9), `#53`(9),
  `#45`(8), `#39`(8), `#34`(7), `#57`(6), `#41`(6), `#38`(6), `#37`(6), `#47`(5) —
  though most of those counts are build steps, not rule uses.
- **Cited but absent from the top-30:** `#28` (dependency check).

**Definitions are not in this corpus.** No standalone rules document exists among the 41
notes files — only copies of `push_notes_v18.sh` embedded in transcripts
(`9e3e0363-0237-4c38-93dc-ce25e2f1ec37_0010.txt` carries the full `# Rules:` header).
Prose `Rule #N` references total **15 lines**: `Rule #54`×6, `Rule #53`×3, `Rule #39`×3,
`Rule #28`×3. Canonical definitions live outside both `/workspace` and this corpus.

**Consistency:** `push_notes_v18.sh` is faithful to the rules it cites — no `sed`, no
`2>/dev/null`, `printf`, remote parsed with `python3`, an `# === END … ===` sentinel,
`git check-ignore` before `git add`, raw links gated on a verified HTTP 200 with backoff.

## 3. JEV references

**In `/workspace/notes` (`.txt` only):** `jev` (case-insensitive) appears in **10 files /
1,341 lines**. Token frequency (case preserved): `JEV`×693, `jev-review`×321,
`jev-guard`×250, bare `jev`×850 (includes the hyphenated compounds), `Jev`×159, plus
`jev-latest`×9, `jev-repo`×6, `jev-classifier`×6, `jev-deepseek`×4. Matching files:
`9e3e0363-…_0001/0010/0017.txt`, `6aaee6ee-…_0002/0003.txt`, `6aaeedb1-…_0004.txt`,
`0b46dfa8-…_1012/1016/1017.txt`, `fe70fd73-…_0026.txt`.

**In `/workspace`** (excluding `.git`, `node_modules`, `notes`, `data`, `logs`):
**128 files / 2,328 matching lines**. Key locations:

- `opencode.json` — `plugin: ["jev-guard"]`, `skills: ["/opt/jev-review/skills"]`, MCP
  server `jev-review` (`node /opt/jev-review/dist/server.js`, `JEV_API_KEY`).
- `docker/Dockerfile` — `opencode plugin jev-guard@0.3.1 --global` and the
  `git clone … /opt/jev-review` + pinned `git checkout 3fb6042e…` + `npm ci && npm run build`.
- `docker/docker-compose.yml`, `docker/build.sh`, `docker/run.sh` — image
  `opencode-deepseek-jev:robust` and `JEV_API_KEY` plumbing.
- `scripts/ask.sh`, `scripts/doctor.sh` — image name; `doctor.sh` probes the plugin list
  for `jev-guard` and validates the Jev key prefix (`apikey_`, `sk-`, `ts_`, `jev-`).
- `scripts/test-repo.sh` — gates G3/G4 on `jev-review` and the `jev-guard` install line.
- Numerous `*.bak.*` snapshots and `scripts/archive/**` copies repeat these strings.
- `/opt/jev-review` itself is outside the repo and was not inspected.

Recurring audit theme in the notes: the Jev integration is **installed and string-matched
but never functionally proven** — the Jev subsystem could be broken while the smoke test
still passes (`6aaee6ee-…_0002/0003.txt`).

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

The TUI service `opencode` (lines 18–43) carries a direct notes mount
(`/home/owner/Documents/9e3e0363-…/notes:/workspace/notes:ro`); the tracked web block has
none. Readability here comes solely from the **untracked**
`docker/docker-compose.override.yml`:

```yaml
services:
  opencode-web:
    volumes:
      - ..:/workspace
      - ../data/opencode:/home/node/.local/share/opencode
      - /home/owner/Documents/9e3e0363-0237-4c38-93dc-ce25e2f1ec37/notes:/workspace/notes:ro
```

### `docker/web-entrypoint.sh` (44 lines)

Writes `$XDG_DATA_HOME/opencode/auth.json` as `{ deepseek: { type: "api", key } }` using a
Node one-liner (no `sed`/shell-escaping), symlinks `/workspace` → `/home/node/workspace`
so the SPA project picker finds it, then `exec opencode web --hostname 0.0.0.0 --port 4096`.
If `DEEPSEEK_API_KEY` is empty it prints a warning and skips auth.json.

### Session count

`sqlite3` and `python3` are not installed in this image, so the count used Node's
built-in SQLite (`node --experimental-sqlite`, Node v22.23.2):

```
$ node --experimental-sqlite -e '…DatabaseSync("/workspace/data/opencode/opencode.db")…'
session=20
message=148
part=712
project=2
event=2653
```

`opencode.db` lives in `data/opencode/` (gitignored) and is live; this is a moving target
(it read `session=19 / message=137 / part=649` earlier the same day).

## 5. Sidebar streaming

**Yes — a processing session is visible in the sidebar.** The SPA subscribes to
`/api/event` (SSE); creating a session emits `session.created`, and streaming
`session.updated` / `message.updated` events keep the sidebar entry rendered and in sync
while the agent runs. Liveness is carried by the SSE stream, **not** by
`/api/session/active`.

Notes evidence — `/workspace/notes/fe70fd73-…_0026.txt`:

- L15: "The sidebar calls `/api/session?directory=X&project=Y` — not `/api/session/active`".
- L29–35: "When a session is created, the server emits a `session.created` event … As
  the session processes (messages stream in), `session.updated` / `message.updated`
  events keep the sidebar entry in sync … So yes, as the session processes, it is in the
  sidebar."
- L108/L166: a planned `test-sidebar-streaming.sh` is described as a *hypothesis to
  falsify*, not an executed pass.

**Live corroboration from the running instance.** The `event` table in `opencode.db`
records exactly this stream, including for the very session producing this audit
(`title = "OpenCode + DeepSeek + JEV container audit"`):

```
$ node --experimental-sqlite -e 'SELECT type, COUNT(*) … FROM event GROUP BY type'
message.part.updated.1 = 1886
message.updated.1      =  541
session.updated.1      =  206
session.created.1      =   20
```

That is persisted SSE history: one `session.created` and ongoing `session.updated` /
`message.updated` per session. A browser attached to `/api/event` therefore renders the
session in the sidebar for the whole processing window. Caveat: this proves the *event
stream*, not the *DOM render*; the planned regression test in section 6 would close that gap.

## 6. Operator next steps

1. **Track the notes mount.** Fold the `opencode-web` notes volume from the untracked
   `docker/docker-compose.override.yml` into the tracked `docker/docker-compose.yml` (or
   commit the override) so audits in the web container are reproducible.
2. **Recover and version the rules document.** Rules #7/#8/#28/#34/#37/#38/#39/#41/#45/
   #47/#53/#54/#55/#57 are cited everywhere but defined nowhere in the repo or the 41
   notes files; add the canonical rules doc so `#N` citations are auditable.
3. **Standardize the missing tooling.** `sqlite3` and `python3` are absent, yet
   `push_notes_v18.sh`, `doctor.sh`, and others call them; bake them into
   `docker/Dockerfile` or standardize on `node --experimental-sqlite` plus a Node helper
   (as this audit did).
4. **Add a real sidebar-streaming regression test.** Create `test-sidebar-streaming.sh`
   (open a session, hold `/api/event`, post a message, assert `session.created` /
   `session.updated` / `message.updated` appear — and ideally assert the SPA DOM entry)
   so the "yes" in section 5 stays continuously verified rather than inferred.
5. **Tame drift and secrets.** `git status --porcelain` reports **194 entries** (171
   untracked, mostly `*.bak.*` snapshots plus `push_notes_v18.sh`, `web-entrypoint.sh`,
   and `docker-compose.override.yml`). Commit or archive them, rotate the DeepSeek/JEV
   keys in `.env.local` (and delete the stale `.env.local.bak.*` copies), and keep
   `opencode-web`'s `0.0.0.0:4096` off untrusted networks when `OPENCODE_SERVER_PASSWORD`
   is unset.
