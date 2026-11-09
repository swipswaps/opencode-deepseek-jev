---
name: explain-first
description: Use whenever writing an answer, brief, alert, runbook, handoff, commit message, or any operator-facing text. Expand every acronym and abbreviation on first mention ("Service Level Objective (SLO)"), then use the short form; add a glossary for long docs. Also prefer plain language and define unfamiliar terms so the reader never needs a decoder ring.
---

# explain-first

Every answer must be readable by someone who does not already know the shorthand.

## Rules

1. **First mention expands.** Write `Service Level Objective (SLO)`, `Command-Line Interface (CLI)`, `Mean Time To Recovery (MTTR)`. After that, the short form is fine.
2. **Prefer the plain word** when the acronym adds nothing: "database", not "DB"; "warning", not "WARN".
3. **Long docs carry a glossary**: a `## Abbreviations` or `## Glossary` section listing every short form used.
4. **Never expand code.** File paths, commands, identifiers, environment variables and flags keep their exact spelling (`models.policy.json`, `OPENCODE_DB`, `--self-test`).
5. **Define jargon too**, not just acronyms: "prefix cache (the provider reuses an unchanged prompt prefix)".
6. **Check before publishing** a long doc: `./scripts/acronym-lint.py FILE` (pipe stdin with no FILE). `--strict` disables the common allowlist (`API`, `CLI`, `JSON`, ...); `--json` is for machines.

## Examples

- Bad: "Check the SLO and the DB, then run the gate."
- Good: "Check the Service Level Objective (SLO) and the database, then run the gate."
- Bad: "MTTR regressed after the roam."
- Good: "Mean Time To Recovery (MTTR) regressed after the network roam."
- Bad: "The cache-hit SLO is below target."
- Good: "The cache-hit Service Level Objective (SLO) is below target (the share of prompt tokens served from the provider's prefix cache)."

This is RULES.md #96. The lint tool proves the rule on a file; the rule applies to chat answers too.
