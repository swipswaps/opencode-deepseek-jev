---
name: repo-wizard
description: Use when the task needs steps only the human can perform (eero phone-app forwards, browser trust clicks, Chrome relaunch, credential entry) or when starting multi-file work that needs alignment first. Generates the walkthrough as scripted commands plus explicit human checkpoints, and grills until the goal is specified before any code is written.
---

# repo-wizard

Two jobs, adapted from pocock `wizard` (human-only steps) and `grill-me`
(alignment before code). Never type for the user what must be scripted —
emit the script; never script what only the human can do — emit the
checkpoint.

## 1. Human-only checkpoints (emit, do not perform)

- eero port forwards: phone app only, no LAN admin page. Emit the exact
  mapping (`443→192.168.4.24`) and the verify command
  (`bash scripts/ports-forward-audit.sh`), then stop.
- Secret entry: passwords/keys go in `.env.local` (0600) by the human.
  Scripts read env; they never print values.
- Browser trust: CA install per machine (`docker/certs-trust.sh`), Chrome
  relaunch, Basic login as `opencode`. The probe proves the result; the
  clicks stay human.

## 2. Alignment grill (before multi-file work)

Ask until each is answered: goal in one sentence; files in scope;
verification command and its expected last line; rollback (what `git`
state restores). Refuse to write code on vague scope — vagueness now is
a failed probe later.

## 3. Handoff format

Every wizard ends as: script block(s) the human pastes once, then the
verify command and its PASS line. Abruptly ending after scripts with no
verify step is a defect — the verify step is what makes the paste safe.
