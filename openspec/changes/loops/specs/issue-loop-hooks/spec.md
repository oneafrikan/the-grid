## Purpose

Make the issue-loop's safety hook and review hook work in worktrees and survive
clones, moves and other tools' hooks. Use case: an unattended agent that must not
push to protected branches and whose commits are reviewed where humans look (the PR).

## ADDED Requirements

### Requirement: Guard hook ships with the pattern
The pattern SHALL include `hooks/guard-main-push.sh`, a PreToolUse hook that exits 2 for a push to `main`, `master` or the configured base branch, for any force push, and for `gh pr merge`.

#### Scenario: Push to base is blocked
- **WHEN** the hook receives a Bash payload `git push origin next` with `BASE_BRANCH=next`
- **THEN** it exits 2 and prints a reason on stderr

#### Scenario: Issue branch push is allowed
- **WHEN** the payload is `git push -u origin issue-12`
- **THEN** it exits 0

#### Scenario: Branch names containing protected words are allowed
- **WHEN** the payload is `git push origin issue-main-fix`
- **THEN** it exits 0

#### Scenario: Force and refspec forms are blocked
- **WHEN** the payload is `git push --force origin issue-3` or `git push origin HEAD:main`
- **THEN** it exits 2

#### Scenario: Bare push on a protected branch
- **WHEN** the payload is `git push` and the current branch is the base branch
- **THEN** it exits 2

#### Scenario: Agent cannot merge
- **WHEN** the payload is `gh pr merge 4 --squash`
- **THEN** it exits 2

### Requirement: Setup re-wires the guard and merges instead of overwriting
`loop/setup.sh` SHALL wire the guard under `PreToolUse` whenever `loop/hooks/guard-main-push.sh` exists, SHALL wire the review hook under `PostToolUse`, and SHALL remove only entries whose command ends with those scripts' basenames before adding the current absolute paths.

#### Scenario: Foreign hooks survive
- **WHEN** `.claude/settings.json` already contains an unrelated PostToolUse hook and `setup.sh` runs
- **THEN** the unrelated hook is still present alongside the review hook

#### Scenario: Moved repo replaces stale paths
- **WHEN** settings contain the review hook at an old absolute path and `setup.sh` runs from a new location
- **THEN** exactly one review-hook entry remains and it points to the new path

#### Scenario: Re-run is stable
- **WHEN** `setup.sh` runs twice
- **THEN** `.claude/settings.json` is byte-identical after the second run

#### Scenario: Guard restored after clone
- **WHEN** a fresh clone has no `.claude/settings.json` and `setup.sh` runs
- **THEN** the file contains the PreToolUse guard entry

#### Scenario: Self-test fails loudly
- **WHEN** the guard script is replaced by one that always exits 0
- **THEN** `setup.sh` exits non-zero

### Requirement: Review hook detects commits in any common form
The review hook SHALL treat a Bash command as a commit when it contains a `git` invocation, with optional `-C <dir>`, `-c <k=v>` or long options, followed by `commit`, anchored at the start or after `;`, `&&`, `||`, `|` or `(`.

#### Scenario: Directory flag
- **WHEN** the command is `git -C /work/tree commit -m "x #3"`
- **THEN** the hook queues a review

#### Scenario: Chained command
- **WHEN** the command is `cd /work/tree && git commit -m "x #3"`
- **THEN** the hook queues a review

#### Scenario: Look-alikes ignored
- **WHEN** the command is `git commit-tree HEAD^{tree}` or `echo "git committed"`
- **THEN** the hook queues no review

### Requirement: Review hook uses the payload's working directory and dedupes
The review hook SHALL read the repository directory from the payload `cwd` and SHALL skip a commit hash it has already reviewed.

#### Scenario: Worktree commit reviewed
- **WHEN** the payload `cwd` is a worktree path distinct from the hook process's own cwd
- **THEN** the reviewed diff is the worktree's HEAD commit

#### Scenario: Same commit twice
- **WHEN** two payloads report the same HEAD hash
- **THEN** only one review is queued

### Requirement: Review is posted where reviewers look
The review hook SHALL post to the open PR of the current branch when one exists, else to the issue referenced by `#N` in the commit subject, else only to the local log, and SHALL run the reviewer with the model in `GRID_REVIEW_MODEL` (default `sonnet`), `--max-budget-usd` from `GRID_REVIEW_BUDGET_USD` (default `1`) and no tools.

#### Scenario: PR preferred
- **WHEN** the current branch has an open PR and the subject references `#9`
- **THEN** the comment goes to the PR, not to issue 9

#### Scenario: Reviewer call is capped
- **WHEN** the hook starts its reviewer
- **THEN** the `claude` command line contains `--model sonnet`, `--max-budget-usd 1` and `--tools ""`

#### Scenario: Issue fallback
- **WHEN** the branch has no PR and the subject references `#9`
- **THEN** the comment goes to issue 9

### Requirement: Review hook stands down in headless and nested runs
The review hook SHALL exit 0 without a review when `GRID_LOOP_HEADLESS=1` or `GRID_REVIEW_RUNNING=1` is set, and SHALL set `GRID_REVIEW_RUNNING=1` for its own reviewer process.

#### Scenario: Headless worker commit
- **WHEN** the payload is a commit and `GRID_LOOP_HEADLESS=1`
- **THEN** no `claude` process is started
