## Purpose

Guarantee that a non-trivial Claude Code session ends with a full-quality handoff document, written by the real `handoff` skill, without the user having to remember it and without blocking session exit.

## ADDED Requirements

### Requirement: Detached spawn with a recursion guard
The `session-end-auto-handoff` hook SHALL read the SessionEnd JSON from stdin, start a fully detached worker and exit 0 without waiting, doing nothing at all when `GRID_AUTOHANDOFF_CHILD` is set, while the worker exports that variable to the child `claude -p` process.

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
The worker SHALL skip a session when the transcript shows `/handoff` was already run (slash command, Skill tool call, or a written file ending `-handoff.md`), when it has fewer than `GRID_AUTOHANDOFF_MIN_TURNS` (default 5) human turns, or when the same session was already handed off and gained fewer than that many human turns since.

#### Scenario: Slash command seen
- **WHEN** the transcript holds a user message containing `<command-name>/handoff</command-name>`
- **THEN** the worker logs a skip and does not start `claude`

#### Scenario: Skill tool seen
- **WHEN** the transcript holds an assistant Skill tool call whose skill is `handoff`
- **THEN** the worker logs a skip

#### Scenario: Handoff file written
- **WHEN** the transcript holds a Write tool call to a path ending `-handoff.md`
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

### Requirement: Same handoff, run by the real skill
The worker SHALL run `claude -p` in the session's `cwd` with `--model sonnet`, a prompt beginning `/handoff`, `--max-turns`, an explicit tool allowlist and a wall-clock timeout, supplying a compact transcript digest as a file.

#### Scenario: Invocation shape
- **WHEN** the worker spawns the child with a stub `claude` on `GRID_CLAUDE_BIN`
- **THEN** the stub receives `-p` with a prompt starting `/handoff`, `--model sonnet`, `--max-turns`, `--allowedTools`, and its working directory equals the payload `cwd`

#### Scenario: Digest is compact
- **WHEN** the transcript is larger than `GRID_AUTOHANDOFF_MAX_BYTES`
- **THEN** the digest is no larger than that cap plus a short elision marker and still contains the first and last human turns

#### Scenario: Digest drops tool results
- **WHEN** the transcript contains a tool result with a 100 KB body
- **THEN** the digest does not contain that body

#### Scenario: Wall-clock timeout
- **WHEN** the child runs past `GRID_AUTOHANDOFF_TIMEOUT`
- **THEN** it is killed and the worker logs an error

### Requirement: Auditable, verified and profile-gated
The worker SHALL log every decision under `GRID_HOOK_LOG_DIR`, verify that a new `*-handoff.md` file exists after the child exits and record the outcome with `scripts/run-record.sh`, and the hook is emitted only for the `strict` profile or when listed in `hooks.enable`.

#### Scenario: Success is verified
- **WHEN** the stub child writes a `*-handoff.md` file into `LOGS/`
- **THEN** the log has an action=done line and the run record has outcome ok

#### Scenario: Silent failure is detected
- **WHEN** the stub child exits 0 without writing a handoff file
- **THEN** the log has an action=error line and the run record has outcome error

#### Scenario: Skips are logged too
- **WHEN** the worker skips a session for any reason
- **THEN** the log line includes the session id and the reason

#### Scenario: Standard omits it
- **WHEN** the profile is `standard`
- **THEN** no SessionEnd entry is emitted

#### Scenario: Strict includes it
- **WHEN** the profile is `strict`
- **THEN** a SessionEnd entry for the hook is emitted with a 5 second timeout
