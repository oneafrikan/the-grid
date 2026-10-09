## Purpose

Guarantee that a non-trivial Claude Code session on any machine with the-grid ends with a full-quality handoff document, written by the real `handoff` skill, without the operator having to remember it, without blocking session exit, and without touching the operator's other work.

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
- **THEN** the worker continues in its own session and completes its run

#### Scenario: Child session end does not respawn
- **WHEN** the hook runs with `GRID_AUTOHANDOFF_CHILD=1`
- **THEN** it exits 0 without starting a worker

#### Scenario: Guard reaches the child
- **WHEN** the worker starts the headless `claude` process
- **THEN** that process has `GRID_AUTOHANDOFF_CHILD=1` in its environment

### Requirement: Skip sessions that need no auto-handoff
The worker SHALL skip a session when the transcript shows a handoff already ran at any point (slash command, Skill tool call, or a written file ending `-handoff.md`), when it has fewer than `GRID_AUTOHANDOFF_MIN_TURNS` (default 5) human turns, or when the same session was already handed off and gained fewer than that many human turns since.

#### Scenario: Slash command seen
- **WHEN** the transcript holds a user message containing `<command-name>/handoff</command-name>`
- **THEN** the worker logs a skip and does not start `claude`

#### Scenario: Skill tool seen
- **WHEN** the transcript holds an assistant Skill tool call whose skill is `handoff`
- **THEN** the worker logs a skip

#### Scenario: Handoff file written
- **WHEN** the transcript holds a Write tool call to a path ending `-handoff.md`, followed by 10 more human turns
- **THEN** the worker logs a skip

#### Scenario: Short session skipped
- **WHEN** the transcript has 3 human turns
- **THEN** the worker logs a skip and starts nothing

#### Scenario: Tool results are not turns
- **WHEN** the transcript has 3 human messages and 40 tool-result messages
- **THEN** the turn count is 3

#### Scenario: Second end of same session skipped
- **WHEN** the worker has already handed off session S and S ends again with the same number of human turns
- **THEN** the worker logs a skip

### Requirement: Capped, verified run of the real skill that commits only its own files
The worker SHALL run `claude -p` in the session's `cwd` with a prompt beginning `/handoff`, `--model sonnet`, `--max-turns`, `--max-budget-usd`, an explicit tool allowlist without `git push`, a wall-clock timeout and a compact transcript digest file, MUST instruct the child to commit only the two handoff files by explicit path and never push, and SHALL log every decision, verify that a new `*-handoff.md` exists afterwards and record the outcome with `scripts/run-record.sh`.

#### Scenario: Invocation shape
- **WHEN** the worker spawns the child with a stub `claude` on `GRID_CLAUDE_BIN`
- **THEN** the stub receives `-p` with a prompt starting `/handoff`, `--model sonnet`, `--max-turns`, `--max-budget-usd`, `--allowedTools` with no `git push` pattern, and `--append-system-prompt-file`, and its working directory equals the payload `cwd`

#### Scenario: Commit rules are in the system prompt
- **WHEN** the test reads `hooks/lib/auto-handoff-system.md`
- **THEN** it contains `git commit -m` followed by `--`, the words `never push`, and the fallback directory variable `GRID_HANDOFF_FALLBACK_DIR`

#### Scenario: Digest is compact
- **WHEN** the transcript is larger than `GRID_AUTOHANDOFF_MAX_BYTES`
- **THEN** the digest is no larger than that cap plus a short elision marker and still contains the first and last human turns

#### Scenario: Digest drops tool results
- **WHEN** the transcript contains a tool result with a 100 KB body
- **THEN** the digest does not contain that body

#### Scenario: Wall-clock timeout
- **WHEN** the child runs past `GRID_AUTOHANDOFF_TIMEOUT`
- **THEN** it is killed and the worker logs `action=error` with `reason=timeout`

#### Scenario: Success is verified
- **WHEN** the stub child writes a `*-handoff.md` file into `LOGS/` under `cwd` or into `GRID_HANDOFF_FALLBACK_DIR`
- **THEN** the log has an `action=done` line and the run record has outcome `ok`

#### Scenario: Silent failure is detected
- **WHEN** the stub child exits 0 without writing a handoff file
- **THEN** the log has an `action=error` line and the run record has outcome `error`

#### Scenario: Skips are logged too
- **WHEN** the worker skips a session for any reason
- **THEN** the log line includes the session id and the reason and the run record has outcome `skipped`
