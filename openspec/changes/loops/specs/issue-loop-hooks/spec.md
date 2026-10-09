## Purpose

Make the issue-loop's guard hook and review hook work in worktrees and survive
clones, moves and other tools' hooks. Use case: an unattended agent that should
not push to protected branches and whose commits are reviewed where humans look
(the PR). The guard is a mistake-catcher; branch protection and token scope are
the boundary.

## ADDED Requirements

### Requirement: Guard hook ships with the pattern and setup wires it without clobbering
The pattern SHALL include `hooks/guard-main-push.sh`, a PreToolUse hook that splits the command into git segments (using `grid_git_segments` from the-grid's `hooks/lib/common.sh` when that file exists, else its own split on `;`, `&&`, `||`, `|` and newline) and exits 2 for: a push whose refspec target is `main`, `master` or the configured base branch; a bare `git push` on one of those branches; a push with `--force`, `-f`, `--force-with-lease`, `--mirror` or `--all`; `gh pr merge`; and `gh api` with a path containing `/merge` or a `-X`/`--method` of `PUT`, `PATCH` or `DELETE`. `loop/setup.sh` SHALL wire the guard under `PreToolUse` whenever the file exists and the review hook under `PostToolUse`, removing only entries whose command ends with those scripts' basenames, and SHALL exit non-zero when its guard self-test fails.

#### Scenario: Protected and dangerous forms are blocked
- **WHEN** the payload is any of `git push origin next` (with `BASE_BRANCH=next`), `git push origin HEAD:main`, `git push --force origin issue-3`, `git push --mirror origin`, `git push --all origin`, `gh pr merge 4 --squash`, `gh api repos/o/r/pulls/4/merge -X PUT`, `gh api -X DELETE repos/o/r/git/refs/heads/next`
- **THEN** the hook exits 2 and prints a reason on stderr

#### Scenario: Issue branches are allowed
- **WHEN** the payload is `git push -u origin issue-12` or `git push origin issue-main-fix`
- **THEN** the hook exits 0

#### Scenario: Bare push on a protected branch
- **WHEN** the payload is `git push` and the current branch is the base branch
- **THEN** the hook exits 2

#### Scenario: Shared segment parser used when present
- **WHEN** `hooks/lib/common.sh` defining `grid_git_segments` exists under the configured the-grid dir
- **THEN** the guard sources it and its decisions for the rows above are unchanged

#### Scenario: Foreign hooks survive and stale paths are replaced
- **WHEN** `.claude/settings.json` holds an unrelated PostToolUse hook and the review hook at an old absolute path, and `setup.sh` runs from a new location
- **THEN** the unrelated hook is still present and exactly one review-hook entry remains, pointing to the new path

#### Scenario: Re-run is stable and clones are restored
- **WHEN** `setup.sh` runs on a fresh clone with no `.claude/settings.json`, then runs again
- **THEN** the file contains the PreToolUse guard entry and is byte-identical after the second run

#### Scenario: Self-test fails loudly
- **WHEN** the guard script is replaced by one that always exits 0
- **THEN** `setup.sh` exits non-zero

### Requirement: Review hook reviews each commit once, where reviewers look, with a capped model
The review hook SHALL treat a Bash command as a commit when it contains a `git` invocation, with optional `-C <dir>`, `-c <k=v>` or long options, followed by `commit`, anchored at the start or after `;`, `&&`, `||`, `|` or `(`; SHALL read the repository directory from the payload `cwd`; SHALL skip a commit hash it has already reviewed; SHALL post to the open PR of the current branch, else to the issue `#N` in the commit subject, else only to the local log; SHALL run the reviewer with `--model` from `GRID_REVIEW_MODEL` (default `sonnet`), `--max-budget-usd` from `GRID_REVIEW_BUDGET_USD` (default `1`) and `--tools ""`; and SHALL exit 0 without a review when `GRID_LOOP_HEADLESS=1` or `GRID_REVIEW_RUNNING=1`, setting `GRID_REVIEW_RUNNING=1` for its own reviewer.

#### Scenario: Commit forms detected
- **WHEN** the command is `git -C /work/tree commit -m "x #3"` or `cd /work/tree && git commit -m "x #3"`
- **THEN** the hook queues a review

#### Scenario: Look-alikes ignored
- **WHEN** the command is `git commit-tree HEAD^{tree}` or `echo "git committed"`
- **THEN** the hook queues no review

#### Scenario: Worktree commit reviewed once
- **WHEN** the payload `cwd` is a worktree distinct from the hook's own cwd, and a second payload reports the same HEAD hash
- **THEN** the reviewed diff is the worktree's HEAD commit and only one review is queued

#### Scenario: PR preferred, issue fallback
- **WHEN** the subject references `#9`
- **THEN** the comment goes to the branch's open PR when one exists, else to issue 9

#### Scenario: Reviewer call is capped
- **WHEN** the hook starts its reviewer
- **THEN** the `claude` command line contains `--model sonnet`, `--max-budget-usd 1` and `--tools ""`

#### Scenario: Headless worker commit
- **WHEN** the payload is a commit and `GRID_LOOP_HEADLESS=1`
- **THEN** no `claude` process is started
