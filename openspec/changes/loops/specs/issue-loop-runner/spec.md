## Purpose

A headless, capped, auditable way to run the issue-loop unattended: one fresh
model session per issue, a stronger-model review on each PR, and a run record per
issue. Use case: nightly backlog grinding on a server with no interactive session.

## ADDED Requirements

### Requirement: One capped worker session per issue
The runner SHALL process at most `MAX_ISSUES` issues per run, lowest number first, serially, and SHALL invoke one `claude -p --model "$WORKER_MODEL"` per issue inside the `timeout` binary with `ISSUE_TIMEOUT` seconds.

#### Scenario: Cap on issues per run
- **WHEN** three issues carry the opt-in label and `MAX_ISSUES=2`
- **THEN** the worker command runs exactly twice, for the two lowest-numbered issues

#### Scenario: Worker is a bounded Sonnet call
- **WHEN** the runner invokes the worker for an issue
- **THEN** the recorded command line contains `--model sonnet` and is wrapped by the timeout binary with the configured seconds

#### Scenario: Nothing to do
- **WHEN** no open issue carries the opt-in label
- **THEN** the runner exits 0 without invoking `claude`

### Requirement: Turn cap only where supported
The runner SHALL pass `--max-turns "$MAX_TURNS"` to `claude` only when `claude --help` lists that flag, and SHALL pass `--max-budget-usd "$MAX_BUDGET_USD"` only when that variable is non-empty.

#### Scenario: Flag supported
- **WHEN** the `claude` help output contains `--max-turns`
- **THEN** the worker command line contains `--max-turns 40`

#### Scenario: Flag unsupported
- **WHEN** the `claude` help output lacks `--max-turns`
- **THEN** the worker command line contains no `--max-turns` and the run still proceeds

### Requirement: Isolated worktree per issue
In `pr` mode the runner SHALL create a worktree for each issue on branch `issue-<N>` from `origin/<BASE_BRANCH>` and run the worker inside it, never in the main checkout.

#### Scenario: Worker cwd is the worktree
- **WHEN** the worker runs for issue 7 in `pr` mode
- **THEN** its working directory is the issue-7 worktree
- **AND** the main checkout's `git status --porcelain` is unchanged

#### Scenario: Worktree removed after the issue
- **WHEN** an issue finishes in any outcome
- **THEN** its worktree directory no longer exists
- **AND** the branch `issue-<N>` still exists locally

### Requirement: Opus review posted to the PR
After a worker run that leaves an open PR, the runner SHALL run `claude -p --model "$REVIEW_MODEL" --tools ""` on the PR diff (truncated to `REVIEW_DIFF_LINES` with an explicit marker) under `REVIEW_TIMEOUT`, and SHALL post the result with `gh pr comment`.

#### Scenario: Review comment posted
- **WHEN** the worker leaves an open PR for issue 7
- **THEN** one `claude` call with `--model opus` and `--tools ""` is made
- **AND** one `gh pr comment` call is made on that PR

#### Scenario: No PR, no review
- **WHEN** the worker leaves no PR
- **THEN** no review call and no `gh pr comment` call is made

#### Scenario: Large diff is flagged
- **WHEN** the PR diff exceeds `REVIEW_DIFF_LINES`
- **THEN** the review input contains the word `TRUNCATED`

### Requirement: Outcome comes from GitHub state
The runner SHALL derive each issue's outcome from observable state: an open PR is `ok`, a `needs-human` label is `skipped`, a `blocked` label or no change is `error`, and in the last case SHALL add `blocked`, remove the opt-in label and comment the reason.

#### Scenario: Worker silently did nothing
- **WHEN** the worker exits 0 but no PR exists and no label changed
- **THEN** the issue gains `blocked` and loses the opt-in label
- **AND** a comment states the loop ended without a PR

### Requirement: Issue-level failures continue, infrastructure failures stop
The runner SHALL continue to the next issue after a timeout, a max-turns exhaustion, a verify failure or an ambiguous issue, and SHALL stop the whole run with exit code 1 on the first infrastructure failure, defined as a non-zero `claude` exit other than 124 or an error result that is not max-turns.

#### Scenario: Timeout moves on
- **WHEN** the worker for issue 5 exits 124 and issue 6 is also eligible
- **THEN** issue 5 is labelled `blocked` and the worker runs for issue 6

#### Scenario: Auth failure stops the run
- **WHEN** the worker for the first issue exits 1
- **THEN** no worker runs for later issues
- **AND** the runner exits 1
- **AND** the first issue keeps its opt-in label

### Requirement: Run record per issue
The runner SHALL call `run-record.sh` once per processed issue with role `issue-loop`, action `work-issue`, target `<repo>#<N>`, the outcome and, when known, the summed cost, and SHALL NOT fail the run when `run-record.sh` is missing.

#### Scenario: Two issues, two lines
- **WHEN** two issues are processed with `GRID_RUN_LOG` set to a temp file
- **THEN** the file contains two JSON lines whose `target` values are `<repo>#<N>` for each issue

#### Scenario: Missing recorder is tolerated
- **WHEN** no `run-record.sh` can be located
- **THEN** the run completes with a warning and the same exit code as it otherwise would

### Requirement: Safe preconditions and single instance
The runner SHALL exit 2 before changing anything when a required tool, authentication or the timeout binary is missing or the main checkout is dirty, and SHALL hold a lock so a second concurrent run exits 0 immediately.

#### Scenario: Dirty tree
- **WHEN** the main checkout has uncommitted changes
- **THEN** the runner exits 2 and creates no worktree

#### Scenario: Concurrent run
- **WHEN** a run is already active and a second run starts
- **THEN** the second exits 0 and logs that another run holds the lock

#### Scenario: Stale lock is reclaimed
- **WHEN** the lock directory exists but its recorded pid is not alive
- **THEN** the runner reclaims the lock and proceeds

### Requirement: Direct mode is supported without worktrees
In `direct` mode the runner SHALL run the worker in the main checkout, SHALL skip the Opus review step, and SHALL judge success by the issue being closed.

#### Scenario: Direct mode
- **WHEN** `MODE=direct` and one issue is processed
- **THEN** no worktree is created and no `gh pr` call is made
