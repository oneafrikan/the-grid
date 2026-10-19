# RETIRED - do not deploy

The uplift issue-loop instance is **retired**. It is kept here, quarantined and unchanged,
so a revert is clean and the history stays readable. Nothing under `_retired/` is linted by
`scripts/gate.sh`, collected by bats, wired, or run by CI.

## Status

- Retired 2026-10-12 (remediation decision D01 = B, quarantine).
- Not deployed anywhere. Uplift work is now built by worktree agents that open PRs to `next`,
  which a human merges.
- The `next` branch itself was retired 2026-10-19 (merged to `main`, PR #286); read `next` as `main`.
- The factory **pattern** is not retired: `automation-factory/patterns/issue-loop/` and
  `automation-factory/` stay as shipped (they work and are used elsewhere). Only this
  repository's own running instance of the loop is retired.
- `scripts/lib/render-schedule.sh` stays where it is: the usage and instincts schedulers
  share it.
- `openspec/changes/loops/` stays as history.

## Why

- Root cause: the headless worker runs as the same OS user as the runner, shares the runner's
  `.git`, and has no sandbox. Every other finding below follows from that, or from guard code
  that only holds against a cooperative worker.
- The loop was abandoned as a design, so fixing 32 findings in it was not worth the effort.

## What moved where

| From | To |
|---|---|
| `loop/**` | `_retired/issue-loop/loop/` |
| `scripts/instantiate.sh` | `_retired/issue-loop/scripts/instantiate.sh` |
| `scripts/lib/gh-app-token.sh` | `_retired/issue-loop/scripts/lib/gh-app-token.sh` |
| `tests/test_issue_loop_hooks.bats`, `tests/test_issue_loop_runner.bats`, `tests/test_gh_app_token.bats`, `tests/test_instantiate.bats` | `_retired/issue-loop/tests/` |

File contents were not edited (moved with `git mv`). **Tests are archived, not run, and the
paths inside them (and inside the scripts) are stale.** Note that `instantiate.sh` was the only
tool that cut the pattern into a target repo, so the pattern cannot be cut with a single command
until it is moved back.

To revive: move the files back to the paths above, then fix the known defects below first. Do
not revive without fixing them.

## Known defects (not fixed; the code is retired)

| Record | Severity | Defect |
|---|---|---|
| R10.qa.F1 | high | guard hook fails open when the real shared parser is present; 27 of 35 instantiate tests fail with `GRID_DIR` exported |
| R10.qa.F2 | medium | "planted hooks never run with the token" is false for `git fetch` (merged with R10.sec.F3) |
| R10.qa.F3 | medium | a skipped issue keeps the opt-in label and starves the queue |
| R10.qa.F4 | medium | any `is_error` result other than max-turns halts the run and is retried first every run |
| R10.qa.F5 | medium | `instantiate.sh` re-cut rewrites the tracked prompt template |
| R10.qa.F6 | medium | `VERIFY_CMD` is never executed; "never commits a red build" is prompt-only (related to R10.sec.F7) |
| R10.qa.F7 | low | role and budget labels are not covered by the trust gate (merged with R10.sec.F12) |
| R10.qa.F8 | low | body-edit history check fails open on a null response |
| R10.qa.F9 | low | lock edge cases (pid-less lock, EPERM, pid reuse) |
| R10.qa.F10 | low | SIGKILL leaves the worker orphaned |
| R10.qa.F11 | low | unquoted `for ISSUE in $ISSUES` globs |
| R10.qa.F12 | low | `--max-turns` is silently dropped |
| R10.qa.F13 | low | a failed `gh pr diff` yields an approve on an empty diff |
| R10.qa.F14 | low | guard splitter bypasses (quoted refspecs, path-qualified git) |
| R10.qa.F15 | low | env-file and tool-path handling gives misleading preflight results |
| R10.qa.F16 | low | infra failure after the PR landed is recorded as `error` and halts the run |
| R10.qa.F17 | low | preflight does not prove git can authenticate over https (unreproduced) |
| R10.qa.F18 | low | `instantiate.sh` does not ignore `.claude/` in a target repo |
| R10.qa.F19 | low | docs present the loop as live; mirror drift not gated (merged with R25.qa.F6) |
| R10.qa.F20 | low | unbounded worker output (unreproduced) |
| R10.sec.F2 | medium | runner hands the live token to `git` against a repo config the worker can write |
| R10.sec.F3 | medium | hooks-off protection covers push only |
| R10.sec.F4 | medium | no process containment; a leftover worker can read the token from `/proc` |
| R10.sec.F5 | medium | worker can tamper with the loop's own checkout and pass the clean-tree preflight |
| R10.sec.F6 | medium | App JWT passed in `curl` arguments, visible in `ps` |
| R10.sec.F7 | medium | runner pushes worker output to a public repo with no content scan |
| R10.sec.F8 | medium | preflight compensating controls weaker than documented |
| R10.sec.F9 | medium | worker has no sandbox, no deny rules, unrestricted network |
| R10.sec.F10 | low | installation token never revoked |
| R10.sec.F11 | low | `linux` profile service unit has no sandboxing directives |
| R10.sec.F12 | low | trust gate scope gaps (author, role/budget labels, read-before-gate) |
| R25.qa.F6 | medium | no doc said the loop was abandoned; docs carried disproved claims (addressed by the banners) |

Four of these (R10.qa.F17, R10.qa.F20, the R10.qa.F4 subtype, the R10.sec.F9 hooks question)
were never reproduced; they are recorded only.

## GitHub-side cleanup (operator only, not done by this change)

Do these in this order. They cannot be checked offline.

1. Delete the loop's GitHub App: in the App's settings, delete every private key first, then
   "Delete GitHub App" (also uninstall it under "Install App" if listed). Search other machines
   and backups for stray copies of the key file.
2. Only after branch protection on `main` and `next` has been put in place: **replace** (do not
   just delete) the ruleset `next-needs-pr`. Deleting it alone also drops no-force-push and
   no-delete on `next`.
3. Delete the repository `grid-loop-sandbox` (Settings > General > Danger Zone).
4. Confirm with `gh api repos/<owner>/<repo>/rulesets` and
   `gh api repos/<owner>/<repo>/rules/branches/main` (the second must show rules once
   protection is in place).

Also on each machine that ran the loop: remove the loop hook entries (`loop/hooks/*`) from the
gitignored `.claude/settings.json`, and any systemd/launchd/cron entry for the loop runner.
