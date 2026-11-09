# Handoff — 2026-11-09 (hotspot loss / reconnect)

**Status:** the reconnect tool is written and offline-verified; the **live roam
proof is the open unit**. Code baseline `632a335` (display/ssh-roam fixes).

## What happened

An `opencode` TUI over `ssh -Y 100.119.125.16` appeared stalled. The mobile
hotspot (the underlay) had dropped.

The shared store showed the session `ses_e42dc0789ffeTn509trLN8TzBn`
("Reviewing session brief log", cwd `/home/owner/Documents/9e3e0363-…/repo`)
had **not** hung on a model call:

- the last message ended with `MessageAbortedError` ("Aborted");
- the last `bash` part output was `<shell_metadata>User aborted the
  command</shell_metadata>` for `timeout 240 bash scripts/test-hygiene.sh`;
- the event stream stopped at seq 6129; `session_input` was empty and there
  were no permission events.

So the TUI stall was the lost link / post-abort state, not an in-flight LLM
request. The store is large (`opencode.db` ≈ 994 MB, 261,562 events, WAL pinned
at 22.8 MB) but sequential I/O measured fast (30 MB in 0.01 s), so size is a
latency risk, not the cause; the pinned WAL is consistent with a stale reader.

Audit caveat: this was done from the sandbox container (`172.29.0.4`, PID 1
`opencode web`), which has **no** `ssh`/`ip`/`ping`/`nmcli`/`tailscale`; it read
the host store bind-mounted at
`/dev/sda3[/home/owner/.local/share/opencode]` → `/home/node/.local/share/opencode`.

## What was added

`scripts/hotspot-reconnect.sh` — the live watcher the repo was missing
(`hotspot-test.sh` only proves a switch *after* it happens).

- **Client:** `--check`, `--watch`, `--watch --reconnect`, `--plan`, `--json`,
  `--self-test`.
  - Debounced detection (`HOTSPOT_FAIL_THRESHOLD`, `HOTSPOT_SETTLE_SEC`) with
    three states: `up`, `overlay-down` (underlay up, tunnel down),
    `hotspot-lost` (no route + no DNS).
  - Alerts the local terminal (bell + banner + `notify-send`) and the server
    (append to the server alert log + `wall`) when reachable; when the server is
    unreachable the line is **queued** and **flushed** on the next success.
  - Interactive reconnect in order: saved `nmcli` profile → `nmcli device wifi
    connect` → `nmcli radio/networking on`, or macOS `networksetup`; typed `YES`
    unless `--yes`; then `client-setup.sh --heal` and an `ssh -t` hint.
- **Server:** `--server --watch` alerts the server console when the client
  overlay (`CLIENT_MESH_IP`, default `10.100.0.1`) disappears/returns.

Honest physics: a down client cannot push to the server, so `--server --watch`
is the timely server-side half; the queued flush makes both logs agree afterward.

Wiring: `scripts/README.txt`, `scripts/tools.json`, and a `test-hygiene.sh`
self-test entry.

## Terminal mouse-report spam (built into the system)

A second failure mode showed up on reconnect: the terminal spammed
`35;55;16M35;55;16M...`. That is the tail of an SGR mouse report
(`ESC[<35;55;16M` = pointer-motion at column 55, row 16). The TUI enabled
any-event tracking (`?1003`) and SGR encoding (`?1006`), then the abort/link
drop left them on, so the tty echoed the motion events as text. `ssh -Y` is
not the cause; `-Y` is only X11 forwarding.

Built in rather than left as a one-off paste:

- `scripts/terminal-reset.sh` — default: mouse-off + `stty sane` + `reset`;
  `--soft` emits only the invisible mouse/alt-screen/cursor sequences;
  `--print` emits the shell `printf`; `--install` / `--uninstall` manage an
  idempotent, guarded `~/.bashrc` block (interactive shells only); `--self-test`
  offline.
- `client-setup.sh` now runs `terminal-reset.sh --install` in setup mode (and
  `--uninstall` in uninstall), so a fresh client bootstrap gets the self-heal.
- Wired into `scripts/README.txt`, `scripts/tools.json`, and `test-hygiene.sh`.

The hook is silent: it sends only escape codes, never `reset`, so it does not
clear the screen on every shell start.

## Verified here (container)

- `bash -n scripts/hotspot-reconnect.sh` → rc 0.
- `bash scripts/hotspot-reconnect.sh --self-test` → **PASS** (check + lost +
  overlay-down + alert + server + reconnect + plan + json).
- Banned-token scan clean (no `sed`, `2>/dev/null`, `set -e`, `rm -rf`).
- `bash scripts/terminal-reset.sh --self-test` → **PASS** (install +
  idempotent + soft + print + uninstall).

**Not verified:** any real network path. The container has no `ip`, `nmcli`,
`ping`, `ssh`, `notify-send`, or `wall`.

## Operational model (exact commands)

Client (roaming node):

    bash scripts/hotspot-reconnect.sh --check
    bash scripts/hotspot-reconnect.sh --watch
    HOTSPOT_SSID=PhoneAp HOTSPOT_PROFILE=PhoneAp \
    HOTSPOT_SERVER_SSH=user@100.119.125.16 \
      bash scripts/hotspot-reconnect.sh --watch --reconnect

Server:

    CLIENT_MESH_IP=10.100.0.1 bash scripts/hotspot-reconnect.sh --server --watch

Verify one probe (expected: `state: up`, rc 0):

    bash scripts/hotspot-reconnect.sh --check; printf 'rc=%s\n' "$?"

## Open risks / remaining proof

1. **Live switch (client):** drop the hotspot during `--watch --reconnect`;
   confirm the bell/banner, the queued line, and a rejoin ending in
   `client-setup --heal` + `ssh -t`.
2. **Server half:** `--server --watch` against the live `10.100.0.1`; confirm
   loss/return alerts and that `wall` is visible to the logged-in user.
3. **Per-node tools differ:** `notify-send`, `wall`, `nmcli`, `networksetup`
   are guarded; the script names the layer that failed instead of hiding it.
4. **Store size:** checkpoint the WAL only with opencode stopped —
   `sqlite3 ~/.local/share/opencode/opencode.db 'PRAGMA wal_checkpoint(TRUNCATE);'`
   then re-check the `-wal` size. Never write the read-only chat store.
5. **SSH mode:** `ssh -Y` adds X11 forwarding the TUI does not need; prefer
   `ssh -t`. Use `ssh-x11-setup.sh` only for the clipboard path that truly
   needs X11.
6. **Terminal-reset hook (live):** crash/abort the TUI on the roaming node,
   open a new interactive shell, and confirm no `...M` spam;
   `grep -n terminal-reset ~/.bashrc` should show exactly one managed block.

## Handoff triage

- **Proven:** offline state machine, alerts, reconnect planner, repo wiring.
- **Unproven:** every live network path, both alert transports, and the real
  rejoin.
- **Human-only:** the physical hotspot toggle and observing the server `wall`.

## Next session prompt

Paste [`docs/HANDOFF-PROMPT-2026-11-09-hotspot.txt`](HANDOFF-PROMPT-2026-11-09-hotspot.txt)
into a fresh terminal session **on the roaming node**.
