# Rule set

Canonical reference for the constraints that every script in this repository
is expected to honour.

## Provenance

This document reconstructs the rule set from citations embedded in the
scripts themselves. The numbered rules are referenced in `push_notes_v18.sh`
(header lines 12-16) and re-cited across `scripts/` and
`scripts/archive/one-shot/`. The un-numbered conventions are stated verbatim
in `scripts/README.txt` ("Scripting conventions" and "Indent control") and in
the constraint blocks that open most one-shot scripts.

Where the exact canonical wording lived outside this repository, the meaning
below is reconstructed from how each rule is used in practice. When a rule
number and a constraint overlap, both are listed.

## Numbered rules

| Rule | Meaning | Evidence of use |
| ---- | ------- | --------------- |
| #7  | No `sed`. If a text transform is unavoidable, it must be guarded and called out. | `push_notes_v18.sh` header |
| #8  | No `2>/dev/null`. Never suppress stderr. Handle the failure case explicitly instead. | `patch-ls-2devnull.sh` |
| #28 | Dependency check. Verify required tools exist (`command -v`) before using them. | `push_notes_v18.sh` deps block |
| #34 | Push-evidence (paired with #47). After a push, prove the result. | `push_notes_v18.sh` header |
| #37 | SKIP is not PASS. A skipped check must never be reported as a pass. | `push_notes_v18.sh` header |
| #38 | `printf`, not `echo`. `printf '%s\n'` for all output. | `push_notes_v18.sh` header |
| #39 | Gitignore checked before add (paired with #45). | `push_notes_v18.sh` stage block |
| #41 | UTC timestamps everywhere (`date -u`). | `push_notes_v18.sh` header |
| #45 | Gitignore checked before add (paired with #39). | `push_notes_v18.sh` header |
| #47 | Push-evidence (paired with #34). | `push_notes_v18.sh` header |
| #53 | Owner/repo parsed via `python3`, never `sed`. | `push_notes_v18.sh` remote block |
| #54 | Evidence completeness gate. A linked artifact must exist, be non-empty, and carry a structural marker. | `push_notes_v18.sh` link block |
| #55 | Raw-link HTTP-200 validation with backoff. | `push_notes_v18.sh` link block |
| #57 | End sentinel. The script ends with a sentinel line so truncation in transit is detected. | `push_notes_v18.sh` line 20 |

## General scripting conventions

Enforced across the operating scripts. Violating any of these is a review
finding, even when the script still runs.

- **No `sed`.** See #7.
- **No `2>/dev/null`.** See #8. `>/dev/null` alone is acceptable only where
  the exit status is the intent and there is no stderr worth keeping.
- **No blanket `set -e`.** Use `set -o pipefail` only. Failure handling is
  explicit per step.
- **No top-level `exit` or `return`.** All control flow lives inside a
  `main()` wrapper; the final line is `main "$@"` and its return code is the
  script's exit status.
- **No `rm -rf`.** Use `rm -f` on named files.
- **No `subprocess.run`.** Do not shell out from Python for side effects.
- **No bare `kill`.** Always signal explicitly (`kill -TERM`, `kill -KILL`).
- **`printf` only.** See #38.
- **`main()` wrapper.** Every script factors its body into `main()`.

## Logging convention

Structured, single-line, key=value records. The `log()` helper used by
`push-telemetry.sh` emits:

```
ts=<ISO-8601 UTC> level=<INFO|WARN|ERROR> phase=<phase> status=<PASS|FAIL|SKIP> msg="<text>" [key=value ...]
```

`push_notes_v18.sh` uses a compatible `[timestamp] [SUCCESS|FAILURE] op :: detail`
form. Either way the rules are the same: UTC timestamps (#41), explicit
level and pass/fail status, and no silent suppression of a failed step (#37,
#8).

## Heredoc and pasteability

From `scripts/README.txt`:

- Every operation that can be typed is scripted and lives in the repository
  under `scripts/` or `scripts/archive/`. Nothing lives only in `/tmp` or only
  in a chat transcript.
- A response that emits multiple files does so through one script, and that
  script creates each file via a heredoc. The recipient pastes the whole
  script once. Prose goes before or after the script, never between heredocs.
- Use a distinct closing delimiter per nesting level (for example
  `SCRIPT_EOF`, `PATCH_EOF`, `WATCH_EOF`). A delimiter must appear on a line
  of its own with no leading whitespace.

## Not rules

The digits `#5`, `#12`, `#9`, `#13`, `#14`, and `#5604` that appear when
grepping the notes for `#N` are Docker BuildKit step markers (`#5 [ 4/14] RUN
...`) and an npm issue number (`#5604`), not rule references. Only the numbers
in the table above are rules.
