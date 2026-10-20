# Plans as pull requests

These are PR-ready bodies. Each file has a title, a summary, the exact files,
a falsifiable test plan, risks, and the host-only steps. To open one as a real
pull request from a branch:

    git switch -c <branch>
    # apply the change described in the body
    git add -A && git commit -m "<title>"
    git push -u origin <branch>
    gh pr create --repo swipswaps/opencode-deepseek-jev \
      --title "<title>" --body-file docs/plans/<file>.md

| PR | Status | Scope |
|---|---|---|
| `PR-01-a11y-hardening.md` | **implemented** in this tree | offline WCAG-basics audit + dashboard fixes |
| `PR-02-media-refresh.md` | **implemented + captured on host** | README screenshots/`.webm` for the newest panels |
| `PR-03-pi-durable-automation.md` | **implemented** (host arming pending) | one command to arm the three durable agents |

Evidence for the tool/UX audit that motivated these is in `TOOL-AUDIT.md`.
Branch-per-PR artifacts (branches, compare URLs, `gh pr create` commands):
`PR-INDEX.md`.
