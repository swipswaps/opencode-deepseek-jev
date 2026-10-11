---
name: typed-must-be-scripted
description: Use when the operator pastes shell commands, or asks for reusable tooling, in any repo. The standing rule is: if it can be typed, it MUST be scripted. Every pasted command becomes a constraint-compliant script with telemetry-first output, verification, and per-repo commit — never a one-off paste.
---

# typed-must-be-scripted

The operator's standing principle: **if it can be typed, it MUST be scripted.**
A pasted command that works once and vanishes is a liability; a script that
prints its own evidence is an asset. Apply on every paste, in every repo.

## 1. Convert (paste -> script, same turn)

1. Take the pasted command(s) as the spec — never retype them at the operator.
2. Write `<repo>/scripts/<verb>-<noun>.sh` (new behavior) or extend the
   owning script (existing behavior). Python helpers go beside it.
3. Constraints (enforced by `check_constraints.sh` where present, else by hand):
   no `sed`, no `2>/dev/null`, no `set -e`, no `subprocess.run`
   (`subprocess.Popen` + `communicate`), `printf` only, `main()` wrapper,
   exits 0/1/2 (or the repo's documented set). `oldString` must match current
   file bytes — re-read before every edit.
4. `bash -n` the result before reporting it. A script that doesn't parse
   doesn't exist.

## 2. Telemetry first, prose never

- Every script prints measured state before acting: current SSID/IP/gateway,
  unit states, counters before/after, DB rows written. `telemetry()` blocks
  beat paragraphs.
- Never suppress stderr: no `2>/dev/null`, no `head`-truncated proof,
  no "should work". A claim without a row/line is a guess — label it so.
- Destructive steps (deletes, restarts, re-signs) require typed confirmation
  (`YES`) and a trap that restores prior state on ANY exit, Ctrl-C included.
  Forwards/rules are never auto-deleted; snapshots print before mutation.

## 3. Verify where it runs

- Syntax/format checks run wherever the author is; behavioral proof runs
  where the hardware is (roam proofs on the roaming node, never the bench).
- Cross-host files are shipped explicitly (`scp` over the proven path),
  never assumed present — `command not found` means wrong host or stale
  checkout: verify with `hostname; pwd; ls <file>` first.
- Split-state traps: under `sudo`, `HOME=/root` redirects DB fallbacks
  (`/var/lib/...`, root-home). Pin state paths (`MESH_INVENTORY_DB`,
  explicit `--db`) so privileged and unprivileged runs share one history.

## 4. Land per-repo

- `git add` + `git commit` per phase, per repo, isolated from other work.
  Uncommitted helper scripts on host A never exist on host B — ship or commit.
- Surface in the local UI where one exists (`tools.json` entry for `:5099`
  `/manage`, runbook, or `/models` note) so the next session finds it by
  browsing, not by memory.
- Report: telemetry rows, files changed, verification commands and their
  output, what remains unproven and its exact next probe.
