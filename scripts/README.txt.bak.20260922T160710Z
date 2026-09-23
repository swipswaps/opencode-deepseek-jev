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
    --full adds plugin/MCP checks and a live model call (~$1e-4).

    Exit 0 on success, non-zero on failure. The output is the diagnostic.

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
