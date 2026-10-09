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

### Requirement: Every model call is capped
The runner SHALL pass an explicit `--model` and `--max-budget-usd` to every `claude` call (worker: `WORKER_MODEL`, `MAX_BUDGET_USD`; review: `REVIEW_MODEL`, `REVIEW_BUDGET_USD`) and run each inside the timeout binary, and SHALL add `--max-turns "$MAX_TURNS"` only when `claude --help` lists that flag.

#### Scenario: Budget always passed
- **WHEN** the runner invokes the worker with default configuration
- **THEN** the worker command line contains `--max-budget-usd 5`
- **AND** the review command line contains `--max-budget-usd 2`

#### Scenario: Turn flag supported
- **WHEN** the `claude` help output contains `--max-turns`
- **THEN** the worker command line contains `--max-turns 40`

#### Scenario: Turn flag unsupported
- **WHEN** the `claude` help output lacks `--max-turns`
- **THEN** the worker command line contains no `--max-turns` and the run still proceeds

### Requirement: Role routing by label
The runner SHALL run the worker with `--agent <name>` when the issue carries exactly one `role:<name>` label naming an agent file in the user or repo agents directory whose `tools:` frontmatter, if present, includes `Edit` or `Write`, SHALL run it without `--agent` when no such label exists, and SHALL otherwise label the issue `blocked`, comment the reason and continue without a model call.

#### Scenario: Role label routes to the agent
- **WHEN** issue 7 carries `role:grid-backend-dev` and that agent file exists
- **THEN** the worker command line contains `--agent grid-backend-dev` and `--model sonnet`
- **AND** the run record line for issue 7 has role `grid-backend-dev`

#### Scenario: No role label
- **WHEN** issue 7 carries no `role:` label
- **THEN** the worker command line contains no `--agent`
- **AND** the run record role is `issue-loop`

#### Scenario: Unwired agent
- **WHEN** issue 7 carries `role:no-such-agent` and issue 8 is also eligible
- **THEN** no `claude -p` call is made for issue 7, it gains `blocked` and a comment saying the agent is not wired
- **AND** the worker runs for issue 8

#### Scenario: Read-only agent refused as builder
- **WHEN** issue 7 carries `role:grid-qa-engineer` whose frontmatter is `tools: Read, Grep, Glob, Bash`
- **THEN** no `claude -p` call is made for issue 7 and it gains `blocked` with a comment that the role is read-only

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
- **THEN** one `claude` call with `--model opus` and `--tools ""` and no `--agent` is made
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
The runner SHALL call `run-record.sh` once per processed issue with the routed agent name as role (else `RUN_ROLE`, default `issue-loop`), action `work-issue`, target `<repo>#<N>`, the outcome and, when known, the summed cost, and SHALL NOT fail the run when `run-record.sh` is missing.

#### Scenario: Two issues, two lines
- **WHEN** two issues are processed with `GRID_RUN_LOG` set to a temp file
- **THEN** the file contains two JSON lines whose `target` values are `<repo>#<N>` for each issue

#### Scenario: Missing recorder is tolerated
- **WHEN** no `run-record.sh` can be located
- **THEN** the run completes with a warning and the same exit code as it otherwise would

### Requirement: Safe preconditions and single instance
The runner SHALL load the optional env file `GRID_LOOP_ENV` (default `~/.config/the-grid/issue-loop.env`) and add `~/.local/bin` to PATH when `claude` is not found, and SHALL exit 2 before changing anything when a required tool, `claude auth status`, `gh auth status`, `git ls-remote` of the base branch or the timeout binary fails or the main checkout is dirty, and SHALL hold a lock so a second concurrent run exits 0 immediately.

#### Scenario: Claude found in the user bin dir
- **WHEN** `claude` exists only in `$HOME/.local/bin` and PATH lacks that dir
- **THEN** the preflight passes and the worker runs that binary

#### Scenario: Not logged in
- **WHEN** `claude auth status --json` reports `"loggedIn": false`
- **THEN** the runner exits 2 with a message naming `CLAUDE_CODE_OAUTH_TOKEN` and the env file path, and invokes no `claude -p`

#### Scenario: Env file supplies the GitHub token
- **WHEN** `GRID_LOOP_ENV` points at a file containing `GH_TOKEN=abc`
- **THEN** every `gh` call the runner makes sees `GH_TOKEN=abc` in its environment

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
