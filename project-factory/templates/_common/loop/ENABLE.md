# Enabling the issue-loop

The loop is **off** in this project. Nothing here runs, schedules or grinds your backlog until you turn it on. It is opt-in per project.

When on, it works GitHub issues labelled `ready-for-agent`, one per run, in a throwaway worktree. It **opens pull requests and never merges**: a human reviews and merges. It refuses to run at all without a `VERIFY_CMD`.

## Define these first

Edit `loop/loop.conf.seed` (it seeds the real config), then cut the loop in:

1. `VERIFY_CMD`: the check that must pass before anything is pushed (the runner runs it itself, not the model). No value, no loop.
2. `BASE_BRANCH`: the branch PRs target. Blank is detected from `origin/HEAD`, else `main`.
3. `MODE`: `pr` (the default and the only mode the headless runner accepts).
4. `ISSUE_LABEL`: the label that opts an issue in (default `ready-for-agent`).
5. The three caps: `MAX_BUDGET_USD` (spend per issue), `ISSUE_TIMEOUT` (seconds per issue), `MAX_ISSUES_PER_DAY`.
6. `SETUP_CMD`: whatever a fresh worktree needs before work starts (dependencies, a database). Project specific; blank if nothing.

Also put branch protection on the base branch. The loop is not the security boundary, review of the PR is.

## Turn it on

From a checkout of the-grid:

```
bash <the-grid checkout>/scripts/instantiate.sh issue-loop . --profile work
```

Then start the first run by hand from this repo: `bash loop/run-issue.sh`. See the pattern README in the-grid (`automation-factory/patterns/issue-loop/README.md`) for what the runner does and what the worker can and cannot do.
