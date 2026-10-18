## Purpose

Work one labelled GitHub issue per invocation, headless, with caps, and hand a verified PR to a human. Use case: an operator's own machine, own `gh` and `claude` logins, working the low-risk `ready-for-agent` backlog that gh-triage prepared. The runner never merges and never classifies. Requirements marked (B3) are built in stage B3; everything else is B1.

## ADDED Requirements

### Requirement: One issue per invocation
`loop/run-issue.sh [N]` SHALL handle exactly one issue and exit. With no argument it SHALL select the lowest-numbered open issue carrying `ISSUE_LABEL`. With `N` that issue SHALL still carry `ISSUE_LABEL`, else exit 2.

#### Scenario: Lowest number wins
- **WHEN** issues 9, 4 and 7 are open with `ready-for-agent`
- **THEN** the worker is started for issue 4 only

#### Scenario: Nothing to do
- **WHEN** no open issue carries `ISSUE_LABEL`
- **THEN** it prints one line, writes no run-record line, and exits 0

#### Scenario: Explicit number without the label
- **WHEN** `run-issue.sh 12` is run and issue 12 lacks `ISSUE_LABEL`
- **THEN** it exits 2 naming the label, and no worktree is created

### Requirement: Preflight refuses to run unsafe
Before any worktree, lock or model call it SHALL exit 2 with one stderr line naming the fix when: `MODE` is not `pr`; `VERIFY_CMD` is empty; `git`, `gh`, `jq`, `claude` or a `timeout`/`gtimeout` binary is missing; `claude auth status --json` does not report `loggedIn: true`; `gh auth status` fails; `GH_REPO` is empty; `origin/BASE_BRANCH` does not exist on the remote; `loop/hooks/guard-main-push.sh` is missing or not executable; `WORKER_PERMISSIONS` is neither `allowlist` nor `bypass`.

#### Scenario: No verify command
- **WHEN** `VERIFY_CMD` is empty in `loop/loop.conf`
- **THEN** exit 2, message contains `VERIFY_CMD`, `claude` is never called

#### Scenario: Direct mode
- **WHEN** `MODE=direct`
- **THEN** exit 2 with "headless runs are pr-only; use direct mode from an interactive /loop"

#### Scenario: Guard script missing
- **WHEN** `loop/hooks/guard-main-push.sh` is absent
- **THEN** exit 2 naming the file and "re-run instantiate.sh"

### Requirement: Lock
The runner SHALL hold a `mkdir` lock at `<git-common-dir>/issue-loop/lock` for its whole run, writing `pid`, `issue`, `started` and (when the worker starts) `worker` into it. A second invocation while the lock is held SHALL exit 0 printing the holder's pid and the lock path. The lock and the worktree SHALL be removed on every exit path including SIGINT, SIGTERM and SIGHUP.

#### Scenario: Concurrent start
- **WHEN** a run is in progress and `run-issue.sh` is started again
- **THEN** the second exits 0 with "busy" and the first is unaffected

#### Scenario: Signal
- **WHEN** SIGTERM is sent to the runner while the (stub) worker sleeps
- **THEN** no worktree under the worktree root and no lock directory remain

#### Scenario: Lock path is absolute
- **WHEN** the runner is started from a different cwd than the repo root
- **THEN** the lock is still created in the repo's git common dir

### Requirement: Caps
Every worker call SHALL pass `--model WORKER_MODEL`, `--max-budget-usd MAX_BUDGET_USD` and run under `timeout -k 30 ISSUE_TIMEOUT`. The runner SHALL NOT pass `--max-turns`. It SHALL refuse to start a new issue (exit 0, nothing touched) once `MAX_ISSUES_PER_DAY` issues have been handled today, counted from `runs.log`.

#### Scenario: Flags present
- **WHEN** a worker is started with default config
- **THEN** its logged argv contains `-p`, `--model sonnet`, `--max-budget-usd 5`, `--output-format json`, `--allowedTools`, `--settings`, `--session-id`, and neither `--max-turns` nor `--dangerously-skip-permissions`

#### Scenario: Timeout
- **WHEN** the worker exceeds `ISSUE_TIMEOUT` (exit 124 or 137)
- **THEN** the issue is relabelled `blocked` with a timeout comment, the run-record outcome is `error`, the exit status is 0

#### Scenario: Daily cap
- **WHEN** `runs.log` holds `MAX_ISSUES_PER_DAY` lines dated today
- **THEN** it exits 0 with "daily cap reached" and calls neither `gh` writes nor `claude`

### Requirement: Worker permissions and guard are per-run, not repo-wide (D4, D5)
By default (`WORKER_PERMISSIONS=allowlist`) the worker SHALL be started with `--allowedTools "$WORKER_ALLOWED_TOOLS"` and SHALL NOT receive `--dangerously-skip-permissions`; the default allowlist SHALL contain no `git push` and no `gh`. With `WORKER_PERMISSIONS=bypass` (a fallback, see proposal assumption 1) it SHALL receive `--dangerously-skip-permissions` instead. In both modes the runner SHALL write a temporary settings file containing only a PreToolUse entry for the repo's `loop/hooks/guard-main-push.sh` and pass it with `--settings`; the file SHALL be deleted on exit. The runner SHALL NOT read or write `<repo>/.claude/settings.json`.

#### Scenario: Allowlist default
- **WHEN** a worker is started with default config (stub `claude`)
- **THEN** argv has `--allowedTools` whose value contains `Edit` and `Bash(git commit:*)` and contains neither `git push` nor `gh`

#### Scenario: Bypass fallback
- **WHEN** `WORKER_PERMISSIONS=bypass`
- **THEN** argv has `--dangerously-skip-permissions` and no `--allowedTools`

#### Scenario: Repo settings untouched
- **WHEN** a run completes
- **THEN** `<repo>/.claude/settings.json` is byte-identical to before (or still absent), and the temp settings file is gone

#### Scenario: Operator's own session not blocked
- **WHEN** the repo's `.claude/settings.json` is read after `setup.sh` (default mode) and a run
- **THEN** it contains no `guard-main-push.sh` entry

#### Scenario: Allowlist proof (needs a real `claude`; decides the fallback)
- **WHEN** the opt-in e2e test runs a normal edit, test and commit task under `--allowedTools`
- **THEN** it completes with no permission prompt and no push; if it cannot under `--allowedTools` alone, `--permission-mode acceptEdits` and `--permission-mode dontAsk`, the result is recorded and the operator decides on `bypass`

### Requirement: Gates before any model call
Before a worktree is created the runner SHALL refuse the issue (relabel, comment, run-record `skipped`, exit 0) when: it also carries `severity:critical` or `severity:high`; an open PR or a remote branch `issue-N` already exists; or `TRUST_GATE=on` and the issue author's `author_association` is not OWNER, MEMBER or COLLABORATOR. A null or failed API answer SHALL count as untrusted.

#### Scenario: High severity
- **WHEN** an issue carries `ready-for-agent` and `severity:high`
- **THEN** `ready-for-agent` is removed, `ready-for-human` added, no worktree, no `claude -p` call

#### Scenario: Existing PR
- **WHEN** `gh pr list --head issue-7` returns an open PR
- **THEN** issue 7 loses `ISSUE_LABEL`, gains `ready-for-human`, and the comment links the PR

#### Scenario: Stranger's issue
- **WHEN** `TRUST_GATE=on` and the author association is NONE
- **THEN** the issue gets `needs-human`, loses `ISSUE_LABEL`, and no model is called

#### Scenario: Gate off
- **WHEN** `TRUST_GATE=off` and the author association is NONE
- **THEN** the issue proceeds to the worker

### Requirement: Context given to the worker
The worker SHALL run with cwd set to the issue worktree. Its prompt SHALL contain the issue number, title, body (cut at 60000 bytes with a marker) and the latest comment whose body starts with `## Agent Brief` and whose author association is OWNER, MEMBER or COLLABORATOR; no other comment SHALL be included. The prompt SHALL tell the worker: this session is unattended and no human is present, so check-in, confirm-scope, ask-first and pause-after-N-tool-calls rules do not apply, and ambiguity ends the run with `needs-human`; read `PURPOSE.md` and `MAP.md` first if they exist; read `GUARDRAILS.md` before editing or committing if it exists; commit only on `issue-N`; do not push, open a PR, or edit labels; write one outcome line to `$LOOP_OUTCOME_FILE`.

#### Scenario: Only trusted brief
- **WHEN** an issue has a brief comment by a collaborator and a later comment by NONE
- **THEN** the prompt includes the brief and not the later comment

#### Scenario: Charter files read in order (scripted, needs a real `claude`, opt-in `GRID_E2E=1`)
- **WHEN** a temp repo has `PURPOSE.md`, `MAP.md` and `GUARDRAILS.md`, each holding a distinct canary word, the issue asks the worker to write all three words into a file and commit, and the real runner runs it
- **THEN** the file holds all three words, and in the session transcript found by `--session-id` the first Read of `PURPOSE.md` and of `MAP.md` precede the first Edit or Write, and the first Read of `GUARDRAILS.md` precedes the first Edit, Write or `git commit` call

#### Scenario: Global check-in rules do not hang the worker (scripted, needs a real `claude`, real `~/.claude` loaded)
- **WHEN** the issue needs at least five tool calls
- **THEN** the run exits 0 with a commit, the transcript has at least five tool calls, and no assistant turn ends by asking for a go-ahead

#### Scenario: CLAUDE.md loads from the worktree (proof, needs a real `claude`)
- **WHEN** the tracked `CLAUDE.md` in a throwaway repo says to end every commit message with a canary token
- **THEN** the worker's commit message ends with it

#### Scenario: Charter files absent
- **WHEN** neither file exists
- **THEN** the run proceeds (the instruction says "if they exist")

### Requirement: Role routing
An issue with exactly one `agent:<name>` label SHALL be built with `claude -p --agent <name>`. With no such label the worker SHALL be a generic session (no `--agent`). The runner SHALL set the issue to `blocked` (comment, no model call) when: the name has characters outside `[A-Za-z0-9._-]`; two `agent:` labels are present; `<name>.md` exists in neither `${AGENTS_DIR:-$HOME/.claude/agents}` nor `<repo>/.claude/agents`; or that file's frontmatter `tools:` line names neither `Edit` nor `Write`.

#### Scenario: Builder role
- **WHEN** the issue has `agent:grid-backend-dev` and that agent file exists without a `tools:` line
- **THEN** argv contains `--agent grid-backend-dev` and the run-record role is `grid-backend-dev`

#### Scenario: Read-only role
- **WHEN** the agent file has `tools: Read, Grep, Glob, Bash`
- **THEN** the issue is `blocked` with a "read-only" comment and no model call

#### Scenario: Fallback
- **WHEN** no `agent:` label is present
- **THEN** argv has no `--agent` and the run-record role is `RUN_ROLE`

### Requirement: Worktree
The runner SHALL create `<worktree-root>/issue-N` with `git worktree add --no-track -B issue-N <path> origin/BASE_BRANCH` after fetching `BASE_BRANCH` with an explicit refspec, where `<worktree-root>` is `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}`. `SETUP_CMD`, if set, SHALL run in it under `timeout ISSUE_TIMEOUT`; failure is an issue-level `blocked`. The worktree SHALL be removed on every path; the branch SHALL be kept.

#### Scenario: Layout
- **WHEN** a worker is running for issue 5
- **THEN** its cwd is `<worktree-root>/issue-5`, outside the repo, on branch `issue-5` with no upstream

#### Scenario: Leftover directory
- **WHEN** `<worktree-root>/issue-5` already exists from a crashed run
- **THEN** it is removed and recreated

### Requirement: Runner-side verify gate
After a worker reports `done` the runner SHALL check, in order: the worktree is on `issue-N`; it is clean; it is at least one commit ahead of `origin/BASE_BRANCH`; then run `VERIFY_CMD` itself in the worktree under `timeout VERIFY_TIMEOUT` with stdin from `/dev/null`. Only exit 0 allows a push. The worker's own claim SHALL NOT substitute for this run.

#### Scenario: Red gate with a confident worker
- **WHEN** the worker writes `done` and commits, but `VERIFY_CMD` exits 1
- **THEN** nothing is pushed, no PR is opened, the issue is `blocked`, and the comment holds the last 40 lines of verify output (at most 3000 bytes)

#### Scenario: No commit
- **WHEN** the worker writes `done` with zero commits ahead
- **THEN** `blocked` with "the loop ended without a commit"

#### Scenario: Green gate
- **WHEN** `VERIFY_CMD` exits 0
- **THEN** the runner proceeds to push

#### Scenario: Verify timeout
- **WHEN** `VERIFY_CMD` exceeds `VERIFY_TIMEOUT`
- **THEN** treated as a failed gate with "verify timed out"

### Requirement: Integration is the runner's job
On a green gate the runner SHALL push with an explicit refspec `HEAD:refs/heads/issue-N` (never the base branch), open the PR with `gh pr create --base BASE_BRANCH --head issue-N`, remove `ISSUE_LABEL`, add `ready-for-human`, and comment the PR URL on the issue. It SHALL NOT close the issue and SHALL NOT call `gh pr merge`.

#### Scenario: Happy path
- **WHEN** the stub worker commits a file and writes `done` and `VERIFY_CMD` passes (temp bare origin, stub `gh`)
- **THEN** one push whose refspec ends `refs/heads/issue-N`, one `gh pr create --base next`, labels `ready-for-human`, issue still open, worktree gone, branch kept

#### Scenario: Push rejected
- **WHEN** the push fails
- **THEN** the issue is `blocked` with the first 300 bytes of git's message and no PR exists

### Requirement: Label invariant
For every exit with status 0 after an issue was selected, that issue SHALL no longer carry `ISSUE_LABEL`, and SHALL carry exactly one of `ready-for-human`, `needs-human` or `blocked` as given by the outcome table in `design.md`. A worker outcome `needs-human <reason>` SHALL map to `needs-human` with the reason (cut at 500 bytes) in the comment; a missing or unrecognised outcome line SHALL map to `blocked`.

#### Scenario: Skipped issue does not starve the queue (R10.qa.F3)
- **WHEN** issue 3 is refused by any gate and issue 4 is also labelled
- **THEN** after the first run issue 3 has no `ISSUE_LABEL`, and the next run selects issue 4

#### Scenario: Infra failure keeps the label
- **WHEN** `claude` exits 1 with no JSON
- **THEN** exit status 1, the issue keeps `ISSUE_LABEL`, no issue comment is posted, one run-record line has outcome `error`

### Requirement: Run record
The runner SHALL append exactly one `scripts/run-record.sh` line per handled issue: `--role` the agent name or `RUN_ROLE`, `--action work-issue`, `--target OWNER/REPO#N`, `--outcome` ok (PR opened), skipped (gate refusal or worker needs-human), or error (everything else), `--cost-usd` from the worker JSON when present, `--note` at most 500 bytes including the session id. A missing `run-record.sh` SHALL warn and not fail the run. No line SHALL be written for "nothing to do", "busy" or "daily cap".

#### Scenario: One line per issue
- **WHEN** a run opens a PR
- **THEN** `GRID_RUN_LOG` gains one line with outcome `ok`, target `owner/name#N`, a numeric cost

#### Scenario: Idle poll
- **WHEN** the run exits for "busy"
- **THEN** `GRID_RUN_LOG` is unchanged

### Requirement: Environment hygiene
The runner SHALL NOT enable `set -x`, SHALL NOT print its environment, SHALL NOT read or write `GH_TOKEN`/`GITHUB_TOKEN`/`CLAUDE_CODE_OAUTH_TOKEN`, and SHALL run every child with stdin from `/dev/null`. It SHALL append `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to PATH (append, never prepend).

#### Scenario: Stripped environment
- **WHEN** it is started with `env -i HOME=$HOME PATH=/usr/bin:/bin`
- **THEN** it finds `claude` installed in `$HOME/.local/bin`

#### Scenario: No secrets in output
- **WHEN** a run completes with a canary value in `GH_TOKEN`
- **THEN** the canary appears in neither stdout, stderr nor any posted comment body

### Requirement: Worker is listable and attributable
The worker SHALL be started with `--session-id <uuid>` (when a uuid source exists) and `-n issue-N`; its pid SHALL be written to `lock/worker`.

#### Scenario: Find the worker
- **WHEN** a run is in progress
- **THEN** `cat <lock>/worker` prints a live pid whose command line contains `claude`

### Requirement: Backoff on infra failure and rate limits (B3)
After an infra failure the runner SHALL write `<state>/backoff` with `fails` incremented and `until = now + min(15 min * 2^(fails-1), 6 h)`. While `now < until`, a start SHALL exit 0 with "backing off until <time>" and touch nothing. A rate-limit signal in the worker's stdout or stderr SHALL set the backoff, record outcome `stopped` with note `rate-limited`, and keep the issue label. Any run reaching an issue-level outcome SHALL delete `backoff`. Three consecutive infra failures on the same issue SHALL mark that issue `blocked` with a comment.

#### Scenario: Doubling and cap
- **WHEN** consecutive infra failures occur on different issues (so the poison rule does not fire)
- **THEN** the waits are 15, 30, 60, 120 and 240 min; the sixth and later are 6 h (the cap)

#### Scenario: Inside the window
- **WHEN** `backoff` has `until` in the future
- **THEN** exit 0, no `gh` write, no `claude` call, no run-record line

#### Scenario: Reset
- **WHEN** a run ends `blocked` or `ok`
- **THEN** `backoff` no longer exists

#### Scenario: Poison issue
- **WHEN** issue 9 fails with an infra error three runs in a row (window waited out each time)
- **THEN** issue 9 is `blocked` with a comment naming the repeated failure, and the next run selects another issue

#### Scenario: Rate limit
- **WHEN** the (stub) worker output contains a configured rate-limit pattern
- **THEN** exit 1, outcome `stopped` note `rate-limited`, the label stays, `backoff` is set

### Requirement: Stale lock reclaim (B3)
A held lock SHALL be reclaimed (atomically, via `mv` to `lock.stale.$$` then `mkdir`) when `lock/pid` names a process that does not exist (EPERM counts as existing), or names a live process whose command line does not contain `run-issue.sh`, or when `lock/` has no readable `pid` and is older than 10 minutes. Otherwise the start exits 0 as busy. Two simultaneous reclaimers SHALL NOT both win.

#### Scenario: Killed runner
- **WHEN** a runner is SIGKILLed mid-run and a new one starts
- **THEN** the new run logs "reclaimed stale lock (pid N)" and proceeds, and the leftover worktree for the old issue is removed

#### Scenario: Pid reuse
- **WHEN** `lock/pid` holds the pid of an unrelated live process
- **THEN** the lock is reclaimed

#### Scenario: Live holder
- **WHEN** `lock/pid` names a live `run-issue.sh`
- **THEN** exit 0 busy; the lock is untouched

#### Scenario: Race
- **WHEN** two starts reclaim the same stale lock simultaneously
- **THEN** exactly one proceeds and the other exits 0 busy
