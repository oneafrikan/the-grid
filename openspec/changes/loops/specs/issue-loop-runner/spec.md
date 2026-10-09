## Purpose

A headless, capped, auditable way to run the issue-loop unattended: one fresh
model session per issue, run by a dedicated unprivileged OS user that holds no
GitHub token while the model runs, a stronger-model review on each PR, and a run
record per issue. Use case: nightly backlog grinding on a server with no
interactive session.

## ADDED Requirements

### Requirement: One capped, tokenless worker session per issue
The runner SHALL support `MODE=pr` only, SHALL process at most `MAX_ISSUES` issues per run, lowest number first, serially, each in its own worktree on branch `issue-<N>` cut from `origin/<BASE_BRANCH>`, and SHALL invoke one `claude -p` per issue inside the timeout binary with `ISSUE_TIMEOUT`, launched under `env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN`, with `--model "$WORKER_MODEL"`, `--max-budget-usd` (`MAX_BUDGET_USD`, raised to the largest `LABEL_BUDGETS` value whose label the issue carries), `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources project,local`, `--max-turns "$MAX_TURNS"` only when `claude --help` lists that flag, and `--agent <name>` only when the issue carries exactly one `role:<name>` label naming a wired agent whose `tools:` frontmatter, if present, includes `Edit` or `Write`; any other `role:` situation SHALL label the issue `blocked`, comment the reason and continue without a model call.

#### Scenario: Cap on issues per run
- **WHEN** three issues carry the opt-in label and `MAX_ISSUES=2`
- **THEN** the worker command runs exactly twice, for the two lowest-numbered issues

#### Scenario: Nothing to do
- **WHEN** no open issue carries the opt-in label
- **THEN** the runner exits 0 without invoking `claude -p`

#### Scenario: Worker command line and environment
- **WHEN** the runner invokes the worker with default configuration and `GH_TOKEN` set in the env file
- **THEN** the recorded command line contains `--model sonnet`, `--max-budget-usd 5`, `--strict-mcp-config`, `--mcp-config {"mcpServers":{}}` and `--setting-sources project,local`, wrapped by the timeout binary
- **AND** the worker process environment contains none of `GH_TOKEN`, `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`

#### Scenario: Label-specific budget
- **WHEN** `LABEL_BUDGETS="ws:rule-packs=15"` and the issue carries `ws:rule-packs`
- **THEN** the worker command line contains `--max-budget-usd 15`

#### Scenario: Turn flag probed
- **WHEN** the `claude` help output contains `--max-turns`
- **THEN** the worker command line contains `--max-turns 40`
- **AND** when the help output lacks it, the command line has no `--max-turns` and the run proceeds

#### Scenario: Role label routes to the agent
- **WHEN** issue 7 carries `role:grid-backend-dev` and that agent file exists
- **THEN** the worker command line contains `--agent grid-backend-dev`
- **AND** the run record line for issue 7 has role `grid-backend-dev`

#### Scenario: No role label
- **WHEN** issue 7 carries no `role:` label
- **THEN** the worker command line contains no `--agent` and the run record role is `issue-loop`

#### Scenario: Unwired, read-only or ambiguous role
- **WHEN** issue 7 carries `role:no-such-agent`, or `role:grid-qa-engineer` whose frontmatter is `tools: Read, Grep, Glob, Bash`, or two `role:` labels, and issue 8 is also eligible
- **THEN** no `claude -p` call is made for issue 7, it gains `blocked` and a comment naming the reason
- **AND** the worker runs for issue 8

#### Scenario: Worker cwd is the worktree, removed afterwards
- **WHEN** the worker runs for issue 7
- **THEN** its working directory is the issue-7 worktree and the main checkout's `git status --porcelain` is unchanged
- **AND** after the issue finishes the worktree directory no longer exists while branch `issue-7` still exists locally

#### Scenario: Direct mode refused headless
- **WHEN** the runner starts with `MODE=direct`
- **THEN** it exits 2 naming interactive `/loop` and invokes no `claude -p`

### Requirement: Unsafe setups and untrusted issues are refused before any model call
The runner SHALL exit 2, before changing anything and with one stderr line naming the fix, when any of these fails: required tools present; git `user.name`/`user.email` set; `LOOP_TRUSTED_ACTORS` non-empty; `LOOP_OPERATOR_HOME` exists and cannot be listed by the running user; the PreToolUse guard entry exists in `.claude/settings.json`; `claude auth status` reports logged in; a `GH_TOKEN` was read from the env file and `gh auth status` passes with it, while `gh auth status` without it fails; the login returned by `gh api user` with that token is not in `LOOP_TRUSTED_ACTORS` (the token belongs to a separate machine account); `origin` is an `https://` URL; `git ls-remote` of the base branch succeeds; a repository rule requiring a pull request applies to the base branch; reading the base branch's classic protection with the token fails with HTTP 403 (the token has no Administration access); the env file is not group/world accessible; the main checkout is clean. Before any worktree or model call for an issue, the runner SHALL require that the issue's `author_association` is `OWNER`, `MEMBER` or `COLLABORATOR`, that the actor of the last `labeled` event for the opt-in label is in `LOOP_TRUSTED_ACTORS`, and that every body editor and every `renamed` actor is in `LOOP_TRUSTED_ACTORS`; otherwise it SHALL label the issue `needs-human`, remove the opt-in label, comment which check failed, and continue.

#### Scenario: Not isolated from the operator
- **WHEN** `LOOP_OPERATOR_HOME` names a directory the running user can list
- **THEN** the runner exits 2 naming the dedicated loop user and invokes no `claude -p`

#### Scenario: Worker could reach a stored GitHub login
- **WHEN** `gh auth status` succeeds with `GH_TOKEN` and `GITHUB_TOKEN` unset
- **THEN** the runner exits 2 naming `gh auth logout`

#### Scenario: Token belongs to a trusted actor
- **WHEN** `gh api user --jq .login` with the env-file token returns a login listed in `LOOP_TRUSTED_ACTORS`
- **THEN** the runner exits 2 naming the separate machine account and invokes no `claude -p`

#### Scenario: Base branch not protected by a pull-request rule
- **WHEN** the rules endpoint for the base branch lists no `pull_request` rule
- **THEN** the runner exits 2 naming a ruleset that requires a pull request on the base branch

#### Scenario: Admin token refused
- **WHEN** reading the base branch's protection with the token succeeds or fails with anything other than HTTP 403
- **THEN** the runner exits 2 naming the fine-grained token from the README

#### Scenario: Other preflight failures
- **WHEN** any one of: `user.email` unset; the guard entry missing; `claude auth status --json` reports `"loggedIn": false`; `origin` is an SSH URL; the env file has mode 644; the main checkout has uncommitted changes
- **THEN** the runner exits 2, creates no worktree and invokes no `claude -p`

#### Scenario: Issue written by an outsider
- **WHEN** issue 7's `author_association` is `NONE` and issue 8 passes every check
- **THEN** issue 7 gains `needs-human`, loses the opt-in label and gets a comment naming the author check, with no worktree and no `claude -p`
- **AND** the worker runs for issue 8

#### Scenario: Labelled or edited by an untrusted actor
- **WHEN** the last `labeled` event for the opt-in label was made by an actor not in `LOOP_TRUSTED_ACTORS`, or the body was edited by such an actor
- **THEN** the issue gains `needs-human` and no `claude -p` call is made for it

### Requirement: The runner integrates, reviews and records; the agent never pushes
After a worker run, the runner SHALL read the first line of the worker's outcome file and SHALL push `HEAD:refs/heads/issue-<N>` with the token passed per call and with git hooks disabled (`-c core.hooksPath=/dev/null push --no-verify`), open a PR to `<BASE_BRANCH>` whose body contains `Closes #<N>`, and swap the opt-in label for `ready-for-human` (leaving the issue open) only when the line is `done`, the worktree is on `issue-<N>`, clean, and at least one commit ahead of `origin/<BASE_BRANCH>`; a `needs-human` line SHALL label the issue `needs-human`; every other case (including timeout, max-turns, a missing file or no commits) SHALL label it `blocked`, remove the opt-in label and comment the reason. For each opened PR the runner SHALL run `claude -p --model "$REVIEW_MODEL" --max-budget-usd "$REVIEW_BUDGET_USD" --tools ""` under `REVIEW_TIMEOUT` on the issue body and the PR diff (truncated with a `TRUNCATED` marker and capped at 100000 bytes on stdin) and post the result with `gh pr comment`. It SHALL write one `run-record.sh` line per processed issue (role = routed agent else `RUN_ROLE`, action `work-issue`, target `<repo>#<N>`, outcome, summed cost when known) and SHALL NOT fail when `run-record.sh` is missing.

#### Scenario: Happy path
- **WHEN** the worker for issue 7 commits once on `issue-7` and writes `done`
- **THEN** the runner pushes with a refspec ending `refs/heads/issue-7` and an argv containing `core.hooksPath=/dev/null` and `--no-verify`, and a `pre-push` hook planted in the worktree does not run; it calls `gh pr create` with `--base` the base branch, and labels the issue `ready-for-human` without closing it
- **AND** one review `claude` call with `--model opus`, `--max-budget-usd 2` and `--tools ""` and no `--agent` is made, followed by one `gh pr comment`

#### Scenario: Done without commits
- **WHEN** the worker writes `done` but `issue-7` has no commit ahead of the base
- **THEN** no push, no PR and no review happen, and the issue gains `blocked` with a comment that the loop ended without a commit

#### Scenario: Worker asks for a human
- **WHEN** the worker writes `needs-human ambiguous acceptance criteria`
- **THEN** the issue gains `needs-human`, loses the opt-in label, and the comment contains the reason

#### Scenario: Large diff is flagged
- **WHEN** the PR diff exceeds `REVIEW_DIFF_LINES`
- **THEN** the review input contains the word `TRUNCATED` and the review argv stays under 4096 bytes

#### Scenario: Two issues, two records
- **WHEN** two issues are processed with `GRID_RUN_LOG` set to a temp file
- **THEN** the file contains two JSON lines whose `target` values are `<repo>#<N>` for each issue
- **AND** with no locatable `run-record.sh` the run completes with a warning and the same exit code

### Requirement: Failure policy, single instance and clean exit
The runner SHALL continue to the next issue after a timeout (worker exit 124 or 137), a max-turns result or a failed push, SHALL stop the run with exit 1 on the first infrastructure failure (any other non-zero `claude` exit, or an error result that is not max-turns), SHALL read the env file by parsing only the keys `GH_TOKEN`, `LOOP_TRUSTED_ACTORS` and `LOOP_OPERATOR_HOME` without executing it, SHALL append `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to PATH when absent, SHALL run worker stdin from `/dev/null`, SHALL hold an absolute-path lock so a concurrent run exits 0, and SHALL remove its current worktree and the lock on SIGTERM, SIGINT or SIGHUP.

#### Scenario: Timeout moves on
- **WHEN** the worker for issue 5 exits 124 or 137 and issue 6 is also eligible
- **THEN** issue 5 is labelled `blocked` and the worker runs for issue 6

#### Scenario: Infrastructure failure stops the run
- **WHEN** the worker for the first issue exits 1
- **THEN** no worker runs for later issues, the runner exits 1, and the first issue keeps its opt-in label

#### Scenario: Env file is parsed, not executed
- **WHEN** the env file contains `GH_TOKEN=abc` and a line `$(touch pwned)`
- **THEN** every runner `gh` call sees `GH_TOKEN=abc` and no file `pwned` is created

#### Scenario: Minimal launchd or cron PATH
- **WHEN** the runner starts with `PATH=/usr/bin:/bin` and `gh`, `jq` and `claude` exist only in `$HOME/.local/bin`
- **THEN** the preflight passes

#### Scenario: Concurrent and stale locks
- **WHEN** a run is active and a second run starts
- **THEN** the second exits 0 and logs that another run holds the lock
- **AND** a lock whose recorded pid is not alive is reclaimed and the run proceeds

#### Scenario: Terminated mid-issue
- **WHEN** the runner receives SIGTERM while the worker is running
- **THEN** the issue worktree and the lock directory no longer exist afterwards
