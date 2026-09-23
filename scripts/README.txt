scripts/ — operating scripts for the OpenCode + DeepSeek + Jev environment
===========================================================================

Two tools run the environment. Two more manage the workflow.

Operate the environment
-----------------------

deploy-dockge.sh
    Start the Dockge web UI on http://localhost:5001. Idempotent.
    Dockge manages every compose stack discovered under
    $HOME/dockge-stacks.

flatten-dockge-stacks.sh
    Refresh the flat symlink directory at $HOME/dockge-stacks. Run after
    adding a new docker-compose.yml under $HOME/Documents. Dockge scans
    that directory non-recursively, so new projects need this step.

Check the environment
---------------------

doctor.sh
    Ordered health check: binaries, docker daemon, keys, provider
    liveness, image presence, and an end-to-end model round-trip.
    Fast mode (no arguments) is free.
    --full adds plugin/MCP checks, a live model call (~$1e-4), and a
    Jev functional proof (Tier 9, invokes jev_review for real).

    Exit 0 on success, non-zero on failure. The output is the diagnostic.

Monitor cost and activity
-------------------------

cost.sh
    DeepSeek cost accounting: totals from the opencode database (sessions,
    USD cost, input/output/reasoning/cache tokens) plus the provider
    balance endpoint. Reads DEEPSEEK_API_KEY from .env.local; never prints
    it. Works on the host and in the container.

thinking.sh
    Live view of what the agent is doing while "thinking". Tails the
    opencode database and prints step boundaries, tool calls (with state
    and command), reasoning text, and answer text as they are written.
    Polls every 2s by default (THINKING_POLL=1 for 1s).

test-jev-functional.sh
    Behavioral Jev proof: invokes the jev-review MCP tool and fails
    (non-zero) unless it fires and returns an applicable metric with a
    score. Host-side; also run by doctor.sh --full as Tier 9.

Work with the model
-------------------

ask.sh
    Non-interactive prompt wrapper.

        ./scripts/ask.sh "List the files in /workspace"
        ./scripts/ask.sh --dir /some/path "Summarize this directory"
        ./scripts/ask.sh --json "Return a JSON object"

    Mounts the target directory at /workspace inside the container and
    runs `opencode run --model deepseek/deepseek-flash`. Returns 0 if
    the model produced any output, non-zero otherwise.

Work with chat logs
-------------------

chatlog.sh
    Manage the chat logs that live in the notes directory beside the
    repo. Default location is ../notes relative to this script.

        ./scripts/chatlog.sh list -l
        ./scripts/chatlog.sh search "no fail"
        ./scripts/chatlog.sh show <file>
        ./scripts/chatlog.sh summarize <file>
        ./scripts/chatlog.sh decisions <file>
        ./scripts/chatlog.sh todos <file>
        ./scripts/chatlog.sh ask <file> "What did we conclude about X?"
        ./scripts/chatlog.sh repo-ask "How is the Dockerfile structured?"

    The ask/summarize/decisions/todos/repo-ask subcommands mount the
    relevant directory into the opencode container and pass a prompt
    that names the target file. The model reads the file via its own
    file access. No content is inlined into the prompt.

Verify the repository
---------------------

test-repo.sh
    Eight gates verifying the repository is in its expected final
    state and that the environment it describes is functional.

        ./scripts/test-repo.sh              report
        ./scripts/test-repo.sh --archive    archive one-shots first

    Report mode is read-only. It checks:
      G1  required binaries
      G2  .env.local with both keys, mode 0600
      G3  opencode.json parses and references the expected identifiers
      G4  docker/Dockerfile contains the expected build directives
      G5  repo root contains only expected entries
      G6  operating scripts present
      G7  one-shot scripts archived
      G8  doctor.sh passes end-to-end

Archive
-------

archive/
    one-shot/           migration, prune, diagnose scripts
    forensics/          recovery tools from the container-loss incident
    logs/               log files from the archived scripts
    stage-opencode-repo/  historical staging script versions
    migration-notes.txt   the Docker data-root migration record

Paths used by the tools
-----------------------

  repo root       resolved from the script's own location
  notes           sibling directory of repo, override with --dir or
                  CHATLOG_DIR
  docker image    opencode-deepseek-jev:robust
  model           deepseek/deepseek-flash
  opencode.json   at repo root
  .env.local      at repo root, mode 0600, gitignored

Scripting conventions
---------------------

Every operation that can be typed is scripted. Scripts live in the repo
under scripts/ or scripts/archive/one-shot/. Nothing lives only in /tmp
and nothing lives only in a chat transcript.

A response that emits multiple files does so through one script. That
script creates each file via a heredoc. The recipient pastes the whole
script once. Prose, if any, comes before the script or after it, never
between heredocs.

Rationale: the shell reads a heredoc from its opening marker to the
matching closing delimiter at column zero. Any text between the marker
and the delimiter becomes file content. Any heredoc whose closing
delimiter is not at column zero is unterminated and the entire input is
discarded. Interleaving breaks pasteability silently.

  POSIX shell, here-documents:
    https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html
  Bash manual, here-documents:
    https://www.gnu.org/software/bash/manual/html_node/Here-Documents.html

  Raymond, "The Art of Unix Programming", Addison-Wesley, 2003,
  ISBN-13: 978-0131429017, §1.6.2 "Rule of Clarity": complexity is a
  cost; a pasteable script is a clear interface.

Indent control
--------------

When writing a heredoc whose content is itself a shell script, avoid
closing the outer heredoc with a delimiter that also appears inside the
inner script. Use a distinct delimiter per nesting level, e.g.
SCRIPT_EOF, PATCH_EOF, WATCH_EOF. The delimiter must appear on a line
of its own with no leading whitespace.
