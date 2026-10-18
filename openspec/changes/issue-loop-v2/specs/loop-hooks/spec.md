## Purpose

The loop's hooks catch an agent's obvious mistakes and keep commits reviewed where humans look. They are mistake-catchers, not the security boundary: the boundary is that the loop only opens PRs and a human merges (branch protection on the base is the operator's to add). Known defects are listed with their disposition so none is silently re-shipped. All hook files live in `automation-factory/patterns/issue-loop/hooks/` and are copied to `<target>/loop/hooks/`.

## ADDED Requirements

### Requirement: Guard blocks the dangerous forms
`hooks/guard-main-push.sh` (PreToolUse, Bash) SHALL exit 2 with a reason on stderr for: a `git push` whose refspec, after stripping a leading `+`, anything up to the last `:` and a `refs/heads/` prefix, equals `main`, `master` or the configured `BASE_BRANCH`; a bare `git push` while the current branch is one of those; `HEAD` pushed while on one of those; `--force`, `-f` clusters, `--force-with-lease[=...]`, `--mirror`, `--all`; `gh pr merge`; and `gh api` with a word containing `/merge` or `-X`/`--method` (also `-XPUT`, `--method=PUT`) of PUT, PATCH or DELETE, case-insensitive. It SHALL exit 0 for `git push -u origin issue-12` and `git push origin issue-main-fix`. `BASE_BRANCH` SHALL be read from `loop.conf` next to the hook's parent directory, default `main`.

#### Scenario: Decision table
- **WHEN** the payload command is each of `git push origin next` (`BASE_BRANCH=next`), `git push origin HEAD:main`, `git push origin +next:next`, `git push --force origin issue-3`, `git push -fu origin issue-3`, `git push --mirror origin`, `git push --all origin`, `gh pr merge 4 --squash`, `gh api repos/o/r/pulls/4/merge -X PUT`, `gh api -X DELETE repos/o/r/git/refs/heads/next`
- **THEN** the hook exits 2 with a stderr reason

#### Scenario: Allowed forms
- **WHEN** the payload is `git push -u origin issue-12`, `git push origin issue-main-fix`, `git status`, `gh pr create --base next`
- **THEN** exit 0

#### Scenario: Bare push on the base
- **WHEN** the payload is `git push` and `cwd` is a repo checked out on the base branch
- **THEN** exit 2

### Requirement: Guard decisions do not depend on which parser is present (R10.qa.F1)
When `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` exists, the guard SHALL source it, call `grid_check_cmd_cap` and `grid_git_segments` directly in its own shell (not inside `$(...)` or a process substitution, because the parser prints nothing and returns through the `GIT_*` globals), call `grid_check_balanced`, and decide from `GIT_SUB`, `GIT_START`, `GIT_LEN` and `GIT_FLAG`. When the file is absent it SHALL use a built-in splitter. Every decision in the table above SHALL be identical on both paths.

#### Scenario: Real shared parser
- **WHEN** the decision table is run with `GRID_DIR` pointing at a checkout holding the REAL `hooks/lib/common.sh` (not a fixture)
- **THEN** every row gives the same exit code as with `GRID_DIR` pointing at an empty directory

#### Scenario: Regression on the reproduced bug
- **WHEN** `git push origin main` is run with the real parser present
- **THEN** exit 2 (on the unfixed `next` code it is exit 0)

#### Scenario: Unbalanced quote fails closed
- **WHEN** the command mentions git and has an unclosed quote, with the real parser present
- **THEN** exit 2 (the shared `grid_check_balanced` behaviour)

### Requirement: Guard normalises quoting and path-qualified commands (R10.qa.F14)
On both parser paths, words SHALL have `"`, `'` and `\` removed as the shell would, and `git`/`gh` SHALL be recognised by basename. This applies to the `gh` checks too.

#### Scenario: Quoted refspec
- **WHEN** the command is `git push origin 'main'` or `git push origin "+main:refs/heads/main"`
- **THEN** exit 2

#### Scenario: Path-qualified binaries
- **WHEN** the command is `/usr/bin/git push origin main` or `/usr/bin/gh pr merge 5` or `gh pr 'merge' 5`
- **THEN** exit 2

#### Scenario: Chained
- **WHEN** the command is `cd x && git -C y push origin HEAD:main`
- **THEN** exit 2

### Requirement: Guard known gaps are stated, not hidden
The guard's header and the pattern README SHALL state that `bash -c '...'`, `eval`, shell aliases, and scripts that call git internally are not inspected, and that the guard is a mistake-catcher.

#### Scenario: Gap pinned by a test
- **WHEN** the command is `bash -c 'git push origin main'`
- **THEN** the test asserts exit 0 and carries a comment naming it as a documented gap (so a future fix changes the test on purpose)

### Requirement: Worktree helper
`hooks/new-agent-worktree.sh <branch>` SHALL fetch `BASE_BRANCH` from `origin`, create `<root>/<branch>` with `git worktree add --no-track -B <branch> <path> origin/<base>` where `<root>` is `${LOOP_WORKTREE_ROOT:-<parent of the main checkout>/<repo-name>-loop}`, print only the path on stdout, and work when run from inside another worktree.

#### Scenario: No tracking
- **WHEN** it creates `issue-7`
- **THEN** `git -C <path> rev-parse --abbrev-ref issue-7@{upstream}` fails, so a bare `git push` cannot aim at the base

#### Scenario: From a linked worktree
- **WHEN** it is run from inside another worktree of the same repo
- **THEN** the new worktree is placed under the same `<root>` derived from the MAIN checkout

### Requirement: Post-commit review is worktree-aware and loop-safe
`hooks/post-commit-review.sh` (PostToolUse, Bash) SHALL act only when the command is a `git commit` (anchored regex tolerating `-C <dir>`, `-c k=v` and long options; `git commit-tree` and `echo "git committed"` do not match), SHALL read the repo from the payload `cwd`, and SHALL review each commit once (dedupe marker in that checkout's own git dir). It SHALL run the review detached with `--model` (default `sonnet`), `--max-budget-usd` (default 1), `--tools ""`, and stdin and stdout closed, and post the result as a comment on the open PR of the current branch, else on the issue named `#N` in the commit subject, else only to `~/.claude/hooks.log`. It SHALL exit 0 without a review when `GRID_REVIEW_RUNNING=1` (the reviewer's own session) or `GRID_LOOP_HEADLESS=1` (the runner sets it for the worker).

#### Scenario: Worktree commit
- **WHEN** the payload `cwd` is a linked worktree and the command is `git commit -m "x #5"`
- **THEN** the diff is that worktree's HEAD commit and the review is posted to issue 5 (or the PR if one is open)

#### Scenario: Not a commit
- **WHEN** the command is `git commit-tree abc` or `echo "git commit"`
- **THEN** exit 0 and `claude` is not called

#### Scenario: Same commit twice
- **WHEN** the hook fires twice for one commit
- **THEN** one review

#### Scenario: Recursion guard
- **WHEN** `GRID_REVIEW_RUNNING=1`
- **THEN** exit 0 with no `claude` call

#### Scenario: Headless worker
- **WHEN** `GRID_LOOP_HEADLESS=1`
- **THEN** exit 0 with no `claude` call

#### Scenario: Caps on the call
- **WHEN** a review runs (stub `claude`)
- **THEN** its argv contains `--model sonnet`, `--max-budget-usd 1` and `--tools ""`

### Requirement: The guard applies only to the loop worker (D4)
The guard SHALL reach a session through exactly two routes: the runner's per-run `--settings` file (worker sessions), and `setup.sh --interactive` (a repo where the operator chose to run an interactive loop session). Default `setup.sh`, `instantiate.sh` and the runner SHALL NOT write it into any `.claude/settings.json`. The pattern README SHALL say plainly that the guard is never installed in the-grid, so the operator's own merge-on-green sessions can run `gh pr merge`.

#### Scenario: Default setup leaves settings alone
- **WHEN** `setup.sh` runs (no flag) in a repo whose `.claude/settings.json` is absent
- **THEN** the file is still absent, `loop/loop-prompt.md` exists, and the guard self-test passed

#### Scenario: README states it
- **WHEN** the pattern README is read
- **THEN** it contains the sentence that the guard is not installed in the-grid's settings and why

### Requirement: setup.sh merges, never clobbers
`loop/setup.sh` SHALL, by default, render `loop/loop-prompt.md` from `loop/loop-prompt.template.md` and `loop/loop.conf` (all `{{...}}` placeholders, one MODE block kept) and run a guard self-test, and SHALL NOT touch `.claude/settings.json`. With `--interactive` it SHALL also wire `PostToolUse` to the review hook and, when the file exists, `PreToolUse` to the guard, in `<repo>/.claude/settings.json` (created if absent), by removing only hook entries whose command ends in `/<our basename>` and appending ours; entries for other tools SHALL be kept and a re-run SHALL leave the file byte-identical. With `--unwire` it SHALL remove only our entries. A `settings.json` that is not valid JSON SHALL make `--interactive`/`--unwire` exit 1 without modifying the file.

#### Scenario: Foreign hook survives
- **WHEN** `--interactive` runs and `settings.json` holds an unrelated PostToolUse hook and our review hook at an old absolute path
- **THEN** the unrelated hook remains and exactly one review entry exists, at the new path

#### Scenario: Fresh clone, then again
- **WHEN** `--interactive` runs with no `settings.json`, then again
- **THEN** the file has both entries and the second run changes no bytes

#### Scenario: `.hooks.PostToolUse` overwrite (the `main` bug)
- **WHEN** `settings.json` has another PostToolUse matcher entry and `--interactive` runs
- **THEN** it is still there afterwards

#### Scenario: Unwire
- **WHEN** `--unwire` runs after `--interactive`
- **THEN** our two entries are gone, unrelated entries remain

#### Scenario: Self-test fails loudly
- **WHEN** the guard script is replaced by one that always exits 0
- **THEN** `setup.sh` (any mode) exits non-zero; the self-test covers `git push origin <base>`, `git push origin '<base>'`, `/usr/bin/git push origin <base>` (blocked) and `git push -u origin issue-1` (allowed)

#### Scenario: Invalid JSON
- **WHEN** `settings.json` is `{not json` and `--interactive` runs
- **THEN** exit 1, file unchanged

#### Scenario: Prompt rendered from conf
- **WHEN** `loop.conf` has `BASE_BRANCH='next'` and `MODE='pr'`
- **THEN** `loop/loop-prompt.md` contains `next`, the pr block, no `MODE:` markers, no `{{`, and the tracked template is unchanged

### Requirement: Known-defect dispositions
Each defect in `_retired/issue-loop/RETIRED.md` that touches a kept piece SHALL be either fixed with a test or explicitly dropped:

| Record | Disposition |
|---|---|
| R10.qa.F1 guard fails open with real parser | fixed (this spec) |
| R10.qa.F3 skipped issue keeps opt-in label | fixed (`loop-runner`, label invariant) |
| R10.qa.F5 re-cut rewrites tracked template | fixed (template copied verbatim) |
| R10.qa.F6 `VERIFY_CMD` never executed | fixed (runner-side verify) |
| R10.qa.F12 `--max-turns` silently dropped | fixed (never passed) |
| R10.qa.F14 quoted refspecs, path-qualified git | fixed (this spec, plus `gh`) |
| R10.qa.F4 any error halts and is retried first every run | fixed in B3 (backoff, poison rule) |
| R10.qa.F9 lock edge cases | fixed in B3 (stale lock) |
| R10.qa.F10 SIGKILL orphans the worker | NOT fixed; documented; B3 stale-lock reclaim removes the old worktree |
| R10.qa.F11 unquoted `for ISSUE in $ISSUES` | gone (one issue per invocation) |
| R10.qa.F13 failed `gh pr diff` approves | gone (no runner review) |
| R10.qa.F18 `.claude/` not ignored in target | fixed: `instantiate.sh` adds `.claude/settings.json` to the target `.gitignore` if absent |
| R10.sec.* , R10.qa.F2/F7/F8/F15/F16/F17/F20 | dropped with the OS-user/App/trust-history design |

#### Scenario: Table is checked
- **WHEN** the pattern README is read
- **THEN** it contains a "Known gaps" list matching the NOT fixed and documented rows

#### Scenario: .claude ignored
- **WHEN** `instantiate.sh` runs on a target whose `.gitignore` lacks `.claude/settings.json`
- **THEN** the line is appended once; a second run adds nothing
