## Purpose

Guarantee that a non-trivial Claude Code session on any machine with the-grid ends with a full-quality handoff document, written by the real `handoff` skill, without the operator having to remember it, without blocking session exit, without touching the operator's other work, and without committing anything but the handoff itself. Where the handoff lands is fixed: the project's `LOGS` folder, nothing else. After the commit the worker pushes the current branch (2026-11-05, commit e6b0a44; before that it pushed only a private repo, and only when the handoff was the sole unpushed commit).

## ADDED Requirements

### Requirement: Machine-level, on by default, opt-out per machine
`wire.sh` SHALL keep exactly one generated `auto-handoff` SessionEnd entry in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` unless the layered manifest (baseline, then `machines/<host>.txt`, then `machines/<host>.local.txt`) ends with `-hook:auto-handoff`, in which case it MUST remove that entry, and it MUST leave every other key and hook in that file unchanged.

#### Scenario: On by default
- **WHEN** `wire.sh` runs with no `hook:` line in any manifest file
- **THEN** the user settings file has one SessionEnd command matching the generated pattern with id `auto-handoff`, and `.wired.manifest` has a `hook` row with status `wired`

#### Scenario: Machine opt-out
- **WHEN** `machines/<host>.txt` contains `-hook:auto-handoff` and `wire.sh` runs
- **THEN** no generated `auto-handoff` entry remains in the user settings file and the `hook` row has status `off`

#### Scenario: Later manifest wins
- **WHEN** the baseline contains `-hook:auto-handoff` and `machines/<host>.local.txt` contains `hook:auto-handoff`
- **THEN** the entry is present after `wire.sh` runs

#### Scenario: Hand-written user hooks survive
- **WHEN** the user settings file already holds a hand-written SessionEnd hook and other keys, and `wire.sh` runs twice
- **THEN** those are unchanged, exactly one generated entry exists, and the second run leaves the file byte-identical

#### Scenario: Check reports drift without writing
- **WHEN** the generated entry has been deleted by hand and `wire.sh --check` runs
- **THEN** it exits 1, names `auto-handoff`, and the settings file is unchanged

#### Scenario: Not a project profile
- **WHEN** `deploy_hooks.py --user --hooks pre-bash-no-bypass` runs
- **THEN** it exits non-zero because that id is not user-scope, and writes nothing

#### Scenario: Session opt-out
- **WHEN** `GRID_DISABLED_HOOKS=auto-handoff` is set and the launcher runs `auto-handoff`
- **THEN** it exits 0 without starting a worker

### Requirement: Detached spawn with a recursion guard
The `auto-handoff` hook SHALL read the SessionEnd JSON from stdin, start a fully detached worker and exit 0 without waiting, doing nothing at all when `GRID_AUTOHANDOFF_CHILD` is set, while the worker exports that variable to the child `claude -p` process.

#### Scenario: Hook returns immediately
- **WHEN** the hook receives a SessionEnd payload and the worker takes 5 seconds
- **THEN** the hook exits 0 in under 1 second and the worker is still running afterwards

#### Scenario: Worker survives its parent
- **WHEN** the hook's process exits
- **THEN** the worker continues in its own session (its process-group id differs from the hook's) and completes its run

#### Scenario: Bad payload is skipped, not spawned
- **WHEN** the hook receives non-JSON stdin, an empty `transcript_path`, a `cwd` that is not a directory, or a `session_id` such as `../x`
- **THEN** it exits 0, starts no worker and logs `action=skip reason=bad-payload`

#### Scenario: Child session end does not respawn
- **WHEN** the hook runs with `GRID_AUTOHANDOFF_CHILD=1`
- **THEN** it exits 0 without starting a worker

#### Scenario: Guard reaches the child
- **WHEN** the worker starts the headless `claude` process
- **THEN** that process has `GRID_AUTOHANDOFF_CHILD=1` in its environment

### Requirement: Skip sessions that need no auto-handoff
The worker SHALL skip a session when the transcript shows a handoff already ran at any point (slash command, Skill tool call, or a written file ending `-handoff.md`), when it has fewer than `GRID_AUTOHANDOFF_MIN_TURNS` (default 5) human turns, or when the same session was already handed off and gained fewer than that many human turns since.

#### Scenario: Slash command seen
- **WHEN** the transcript holds the captured `slash-handoff` line (a user line containing `<command-name>/handoff</command-name>`)
- **THEN** the worker logs `action=skip reason=already-ran` and does not start `claude`

#### Scenario: Skill tool seen
- **WHEN** the transcript holds the captured `assistant-skill-tool` line with skill `handoff`
- **THEN** the worker logs `action=skip reason=already-ran`

#### Scenario: Handoff file written
- **WHEN** the transcript holds a Write tool call to a path ending `-handoff.md`, followed by 10 more human turns
- **THEN** the worker logs `action=skip reason=already-ran`

#### Scenario: Mentions of a handoff are not a handoff
- **WHEN** the transcript has 6 human turns and, otherwise, only these: a `tool-result` line whose text contains `<command-name>/handoff</command-name>`, an assistant text line saying "run /handoff", a Write to `notes/handoff.md`, and a Write to `x-handoff.md` on a line with `isSidechain` true
- **THEN** the worker does not skip for `already-ran` and starts `claude`

#### Scenario: Short session skipped
- **WHEN** the transcript has 3 human turns
- **THEN** the worker logs `action=skip reason=short-session turns=3` and starts nothing

#### Scenario: Only real human turns are counted
- **WHEN** the transcript has 3 `human-string` or `human-blocks` lines, 40 `tool-result` lines, 5 `meta-user` lines, 5 `sidechain-user` lines and 5 `attachment` lines
- **THEN** the logged turn count is 3

#### Scenario: Corrupt line tolerated
- **WHEN** the transcript has 6 human turns, one garbage line in the middle and a truncated JSON line at the end
- **THEN** the worker still counts 6 turns and starts `claude`

#### Scenario: Second end of same session skipped
- **WHEN** the worker has already handed off session S and S ends again with the same number of human turns
- **THEN** the worker logs `action=skip reason=no-new-turns`

#### Scenario: Force bypasses the content checks only
- **WHEN** `GRID_AUTOHANDOFF_FORCE=1` is set and the transcript holds a `slash-handoff` line
- **THEN** the worker starts `claude`; with an unreadable transcript it still logs `reason=no-transcript`

### Requirement: Capped, verified run of the real skill that commits only its own files
The worker SHALL run `claude -p` in the session's `cwd` with a prompt beginning `/handoff` that names the target directory, `--model sonnet`, `--max-budget-usd`, `--tools Read,Write,Bash`, `--permission-mode default`, `--setting-sources user` and `--strict-mcp-config`, write access scoped by path to ONE directory (an `Edit(//<abs dir>/**)` allow rule for the resolved `LOGS` folder, never a bare `Write` or `Edit`) and read-only Bash with `Edit` and all git denied, a wall-clock timeout and a compact transcript digest file, and MUST instruct the child to write only the two handoff files and run no git. The target is always the `LOGS` folder of the project: the project is the root of the git repo containing `cwd`, else `cwd` itself; an existing `logs`, `Logs` or `LOGS` directory is reused as it is and `LOGS` is created (mode 0755) when none exists. There is no fallback directory, no per-project location table and no environment override. A `LOGS` the worker cannot use SHALL end the run with `action=error reason=target-refused why=<reason>` before any child starts, writing nothing: `cwd-root` or `git-dir` (the folder is the project root or a git directory), `home-or-root`, `sensitive-dir`, `not-a-git-work-tree` or `home-work-tree` (a symlinked `LOGS` that resolves outside the project is accepted only into another git work tree whose root is not `$HOME` or `/`), `ambiguous-case` (two casings exist), `mkdir-failed`, or `unsafe-path` (a glob metacharacter, newline or `..` in the path). The worker itself SHALL then scan every new file under `cwd` (no depth limit) and the target directory, refuse to commit (moving nothing) if any new path is outside the verified handoff pair, never move or delete anything under `.git/`, refuse to commit if `.git/config` or `.git/hooks/` changed during the child run, verify that the expected handoff files exist, secret-scan them, commit only them by explicit path in the repository that holds the files, push the current branch of that repository to its upstream with a plain `git push`, log every decision and record the outcome with `scripts/run-record.sh`. A push that cannot happen or fails SHALL leave the commit local and MUST NOT fail the handoff.

#### Scenario: Invocation shape
- **WHEN** the worker spawns the child with the stub `claude` that `make_stubs` exports as `GRID_CLAUDE`
- **THEN** the stub receives `-p` with a prompt starting `/handoff` and ending `Target directory: <abs project>/LOGS.`, `--model sonnet`, `--max-budget-usd`, `--max-turns 25`, `--tools Read,Write,Bash`, `--permission-mode default`, `--allowedTools` holding `Read`, exactly one `Edit(//<abs LOGS>/**)` rule, no `git` pattern and no bare `Write` or `Edit`, `--disallowedTools` naming `Edit` and `Bash(git:*)`, exactly one `--add-dir` (the digest directory) and `--append-system-prompt-file`, and its working directory equals the payload `cwd`

#### Scenario: Write-only rules are in the system prompt
- **WHEN** the test reads `hooks/lib/auto-handoff-system.md`
- **THEN** it is under 1500 bytes and contains `do not run git`, `never push`, `write nothing else`, `if a write is denied, stop and say so`, `the project's LOGS folder` and `run single commands only`, and neither the word `fallback` nor a URL

#### Scenario: LOGS is the target
- **WHEN** the stub child writes the two handoff files into `<repo root>/LOGS`
- **THEN** the worker commits exactly those two files, the log has `action=done reason=ok` and the run record has outcome `ok`

#### Scenario: LOGS is created when missing
- **WHEN** the project has no `logs`, `Logs` or `LOGS` directory
- **THEN** the worker creates `LOGS` before the child starts and the pair is written and committed there

#### Scenario: No git repo
- **WHEN** `cwd` is not inside a git repository
- **THEN** `<cwd>/LOGS` is the target, the files are only written, the log has `commit=none` and no `push=` field

#### Scenario: A subdirectory of a repo
- **WHEN** `cwd` is a subdirectory of a git repo
- **THEN** the repo root's `LOGS` is the target

#### Scenario: An existing Logs directory is reused
- **WHEN** the project has a `Logs` directory and no `LOGS`
- **THEN** the pair is written into `Logs` and no second directory is created in another casing

#### Scenario: A LOGS symlink into another repo
- **WHEN** `LOGS` is a symlink to a directory in another git work tree (the private-repo layout)
- **THEN** the pair is committed, and pushed, in THAT repo, and the project repo has no new commit

#### Scenario: The private fallback and the locations table are gone
- **WHEN** `GRID_HANDOFF_FALLBACK_DIR`, a `handoffs/` directory in the private repo and a `handoff-locations.md` row for the project all exist
- **THEN** none of them is read or written, the child's `--allowedTools` holds no rule for them, and the prompt names no fallback

#### Scenario: A refused LOGS writes nothing
- **WHEN** `LOGS` is a symlink to the project's `.git` directory
- **THEN** the log has `action=error reason=target-refused why=git-dir`, no child was started, nothing is written anywhere and the run record has outcome `error`

#### Scenario: Unexpected file refused
- **WHEN** the stub child writes the two handoff files and also `.git/hooks/x`
- **THEN** the worker logs `action=error reason=unexpected-file` naming `.git/hooks/x`, makes no commit, leaves `.git/hooks/x` and the two handoff files in place, and moves nothing under `.git/`

#### Scenario: Stray file blocks the commit
- **WHEN** the stub child writes the two handoff files into `LOGS/` and also `a/b/c/d/e/stray.md` under `cwd`
- **THEN** the worker logs `action=error reason=unexpected-file` naming `a/b/c/d/e/stray.md`, makes no commit, and moves nothing: `stray.md` and both handoff files stay where they were written

#### Scenario: Secret in a handoff file
- **WHEN** the stub child writes a handoff file containing a secret-shaped token
- **THEN** the worker logs `action=error reason=secret` without the token value, makes no commit, and both files are now in the machine-local quarantine directory `${GRID_STATE_DIR:-$HOME/.grid}/handoff-quarantine/`, outside every git repository

#### Scenario: Only the handoff files are committed
- **WHEN** the operator has another file staged in the repo and the stub child writes the two handoff files into `LOGS/`
- **THEN** the new commit contains exactly the two handoff files and the other file is still staged and uncommitted

#### Scenario: The handoff commit is pushed
- **WHEN** the handoff files land in a repo whose branch tracks an upstream
- **THEN** the worker pushes, the upstream holds the handoff commit, and the log has `push=yes`

#### Scenario: Other unpushed commits are published with it
- **WHEN** the branch already holds an unpushed commit before the run
- **THEN** the plain push publishes that commit too, and the log has `push=yes`

#### Scenario: No upstream
- **WHEN** the repo has a remote but the current branch has no upstream, or HEAD is detached
- **THEN** the commit stays local, the log has `push=no-upstream`, and the run still ends `action=done reason=ok`

#### Scenario: No remote
- **WHEN** the repo has no remote
- **THEN** the commit stays local, the log has `push=no-remote`, and the run still ends `action=done reason=ok`

#### Scenario: A failed push never fails the handoff
- **WHEN** the push fails (unreachable remote, rejected update, the 60 s bound)
- **THEN** the commit stays local, the log has `push=failed` and a masked `child|` line with the reason, and the run record has outcome `ok`

#### Scenario: Digest is private and removed
- **WHEN** the worker runs the child
- **THEN** the child inherits umask `0077` and the digest directory passed with `--add-dir` no longer exists after the run

#### Scenario: Digest is compact
- **WHEN** the transcript is larger than `GRID_AUTOHANDOFF_MAX_BYTES`
- **THEN** the digest is no larger than that cap plus a short elision marker and still contains the first and last human turns

#### Scenario: Digest drops tool results
- **WHEN** the transcript contains a tool result with a 100 KB body
- **THEN** the digest does not contain that body

#### Scenario: Wall-clock timeout
- **WHEN** the child runs past `GRID_AUTOHANDOFF_TIMEOUT`
- **THEN** it is killed and the worker logs `action=error reason=timeout`, and no stub process remains

#### Scenario: Success is verified
- **WHEN** the stub child writes a `*-handoff.md` file into the resolved `LOGS` folder
- **THEN** the log has an `action=done` line and the run record has outcome `ok`

#### Scenario: Silent failure is detected
- **WHEN** the stub child exits 0 without writing a handoff file
- **THEN** the log has `action=error reason=no-handoff-file` and the run record has outcome `error`

#### Scenario: A stale handoff file is not success
- **WHEN** `LOGS/` already holds a `*-handoff.md` older than the run and the stub child writes nothing
- **THEN** the log has `action=error reason=no-handoff-file`

#### Scenario: Child failure is reported
- **WHEN** the stub child exits 3
- **THEN** the log has `action=error reason=claude-exit-3`

#### Scenario: The real claude is unreachable from tests
- **WHEN** a worker test does not set `GRID_CLAUDE`
- **THEN** the worker tries the `common_setup` tripwire `/nonexistent/grid-claude-tripwire`, no model is reached, and the worker logs `action=error reason=claude-exit-127`

#### Scenario: Skips are logged too
- **WHEN** the worker skips a session for any reason
- **THEN** the log line has the shape `ts=<time> session=<id> action=skip reason=<token>` and the run record has outcome `skipped`
