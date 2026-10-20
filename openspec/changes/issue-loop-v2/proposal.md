## Why

`main` has a small loop that ran; `next` has a large loop that never did. Both are stale in ways that matter now that the loop is meant to work the issue backlog:

- `main`: hard-coded `git push origin main`, no PR mode, no guard hook except heredoc stubs inside `instantiate.sh`, a review hook that misfires on worktrees, a `setup.sh` that overwrites `.hooks.PostToolUse`, a launchd plist running `claude --dangerously-skip-permissions -p "$(cat loop-prompt.md)"` with no caps, and `instantiate.sh` defaulting the opt-in label to `agent-ready` while gh-triage applies `ready-for-agent`.
- `next`: a 774-line runner built for a dedicated OS user, GitHub App tokens and a trust gate. The operator rejected that design (same user, same machine, own `gh` and `claude` logins). Its code was quarantined in `_retired/issue-loop/` with 32 recorded defects. `openspec/changes/loops/tasks.md:79-87` (the proof tasks) are all unchecked: none of it was ever run end to end.
- Both: the verify command is never run by anything outside the model ("never commits a red build" is prompt-only, R10.qa.F6); no backoff or rate-limit handling; no stale-lock handling.

This change keeps `main`'s simple shape, folds in the parts of `next` that are good, closes the two gaps, and adds a waker so the loop can start itself. It supersedes `openspec/changes/loops`.

## What Changes

Three stages, each its own PR(s) to `next`, all built AFTER `next` is merged into `main`. The loop cannot build itself: these are built by worktree agents and operator-merged PRs.

**B1 (runner, hooks, migration)**
- New `automation-factory/patterns/issue-loop/run-issue.sh`: one issue per invocation, headless `claude -p` (a real PID), cwd = the issue worktree. It takes the lock, cuts the worktree, routes the role from an `agent:<role>` label, runs the worker, **re-runs `VERIFY_CMD` itself outside the model**, then pushes, opens the PR, swaps labels and writes one run-record line. Caps: spend, timeout, issues per day. Refuses to run with no `VERIFY_CMD`.
- Hooks fixed: `guard-main-push.sh` (R10.qa.F1 fail-open with the real shared parser, R10.qa.F14 quoted refspecs and path-qualified `git`/`gh`), `new-agent-worktree.sh`, `post-commit-review.sh`, and `setup.sh` (self-tests the guard; with `--interactive` merges its own entries and keeps others). **The guard applies only to the loop worker**: the runner passes it via a generated `--settings` file. It is never written into the-grid's `.claude/settings.json`, so the operator's own merge-on-green sessions are never blocked.
- `loop.conf` as the single source of config (rendered once); the tracked prompt template stays verbatim (R10.qa.F5).
- `scripts/instantiate.sh`: `main`'s 539-line version as base (it stays at `scripts/instantiate.sh`; nothing comes back from `_retired/`), plus render-once `loop.conf` and label creation read from `next`'s archived 671-line version.
- Project seed: the stale `project-factory/templates/_common/prompts/autonomous-coding-loop.template.md` is replaced by a `loop/loop.conf.seed` and a short "what to define before enabling the loop"; six template docs and `project-factory/README.md:38` updated.
- Migration: restore a depersonalised `automation-factory/docs/gh-triage-to-issue-loop.md`; drop the OS-user/App/trust-gate machinery, `_retired/`, the loop parts of `docs/uplift-runbook.md`, `secure-agent-loop.md`, `test_docs_loop_secrets.bats`; edit every file that assumes the loop is retired.

**B2 (waker)**: `loop/wake.sh`, a cron poll (15-minute target; 60-minute floor until B3 is proven). If `ready-for-agent` issues exist and no run holds the lock it `exec`s `run-issue.sh`. Rendered by `scripts/lib/render-schedule.sh` (new `every:N` form, cron only) as text the operator installs; `instantiate.sh` copies `wake.sh` and prints the line in B2, not B1. The cron line stays UNINSTALLED until B3 passes. The first run is started by hand in B1.

**B3 (hardening)**: backoff on rate limits and repeated infra failures; stale-lock reclaim; poison-issue rule (three consecutive infra failures on one issue marks it `blocked`).

## Capabilities

### New Capabilities
- `loop-runner`: `run-issue.sh` end to end (selection, lock, caps, role routing, worker, runner-side verify, PR, labels, run record), plus B3 backoff and stale-lock requirements.
- `loop-hooks`: guard, worktree helper, post-commit review, `setup.sh` merge behaviour, and the known-defect dispositions.
- `loop-config-and-seed`: `loop.conf`, `instantiate.sh`, prompt templates, the project-factory seed and template docs.
- `loop-waker`: B2 cron poll and the `every:N` schedule form.
- `loop-migration`: what is restored, dropped, rewritten; merge-fallout edits; supersession of `openspec/changes/loops`.

### Modified Capabilities
None in the OpenSpec sense: `openspec/specs/` does not exist on `next` (checked), so there is no spec to modify. This change does alter existing, unspecced behaviour: `scripts/lib/render-schedule.sh` (additive `every:N`, shared with the usage and instincts schedulers), the project-factory `_common` seed, `instantiate.sh`, and it supersedes the six capabilities of the unarchived change `loops` (`issue-loop-runner`, `issue-loop-pr-mode`, `issue-loop-hooks`, `issue-loop-scheduling` replaced; `karpathy-loop`, `cli-agent-cron` deferred).

## Business-tier fit

The business tier (`docs/business-tier`, PR #280; may not exist in every worktree) makes `the-grid-<business>` a PROJECT repo. The loop must therefore instantiate against any repo with no the-grid dependency at run time: hooks fall back to a built-in parser when `~/.the-grid` is absent, `instantiate.sh` takes `--repo`, and nothing assumes the-grid's layout. The business-tier build work will itself be done by the loop later. Nothing here designs the business tier.

## Impact

- Pattern: `automation-factory/patterns/issue-loop/` (`run-issue.sh`, `wake.sh` new; `run-issues.sh` removed; hooks, `setup.sh`, templates, README rewritten).
- Scripts: `scripts/instantiate.sh` (`main`'s file, modified), `scripts/lib/render-schedule.sh` (additive `every:N`), `tests/helpers/stubs.bash` (minter stub removed). New tracked scripts and any new top-level path are added to `docs/architecture.md` in the same PR once `front-door` has landed it.
- Tests: new `tests/test_issue_loop_hooks.bats`, `test_issue_loop_runner.bats`, `test_instantiate.bats`, `test_issue_loop_waker.bats`, and an opt-in `tests/test_issue_loop_e2e.bats` (real `claude`, stub `gh`, temp bare origin; skipped unless `GRID_E2E=1`); edited `test_docs_factories.bats`, `test_gate.bats`, `test_depersonalise.bats`, `test_project_factory.bats`.
- Docs: see `specs/loop-migration/spec.md` for the full edit list.
- Needs on the running machine: `bash`, `git`, `gh` (logged in), `jq`, `claude` (logged in), GNU `timeout` (`gtimeout` on macOS). No Node.

## Non-goals

- No separate OS user, sudo step, GitHub App, installation token, `LOOP_OPERATOR_HOME` check, or isolation that stops Claude Code sessions talking to each other. Same user, same machine, the operator's own `gh` and `claude` logins.
- No auto-merge. The loop opens PRs; the guard blocks `gh pr merge`. Canon changes always need a human.
- No weekly promoter job, confirmer agent, `knowledge.py promote`, canon-PR runner or cli-cron.
- No classification in the loop. gh-triage classifies and applies the severity gate; the loop reads the Agent Brief.
- No Opus review step in the runner (Open assumption 4); no parallel issues; no direct-mode headless runs; no Windows; no systemd/launchd waker in B2.
- The guard hook is never installed into a repo's own `.claude/settings.json` by default.
- No `karpathy-loop` or `cli-agent-cron` (the unbuilt Phase B of `loops`): deferred, not deleted.
- Does not design the business tier or change A1-A3.

## Open assumptions (operator can veto)

1. **Worker permissions (D5).** The headless worker runs under an explicit `--allowedTools` allowlist (read/edit/write/glob/grep plus git add/commit/status/diff/log/show and the project's test commands via `WORKER_ALLOWED_TOOLS`), with no `git push` and no `gh`, plus the guard. `--dangerously-skip-permissions` is a FALLBACK only, selected by `WORKER_PERMISSIONS=bypass`, and only if the proof task 8.5 shows the allowlist cannot work: a normal edit-test-commit task cannot complete under any of `--allowedTools` alone, with `--permission-mode acceptEdits`, or with `--permission-mode dontAsk`, without a prompt that hangs. The fallback is the operator's call, recorded in the PR. **B1 result (RAN, 2026-10-20):** the allowlist alone completes the task, so `bypass` is not needed; see design.md, "As built".
2. **Runner owns GitHub writes.** The worker only commits; the runner verifies, pushes, opens the PR and swaps labels. Under the allowlist the worker has no `git push` or `gh` tool, so this is enforced, not convention (a Bash prefix rule can be dodged; the guard is the backstop). Under the `bypass` fallback it is convention plus the runner's post-hoc git-state check.
3. **Runner is pr-only.** `MODE=direct` stays in the interactive `/loop` template; `run-issue.sh` exits 2 on it (as `next` decided). The brief lists `MODE:pr|direct` as KEEP; this keeps it where it can be safe.
4. **No runner-side review.** Review stays in the post-commit hook for interactive sessions; the hook stands down in headless runs. Independent QA is the operator's standing process. Saves a model call per PR.
5. **Trust gate default on.** `TRUST_GATE=on` requires the issue author, and any comment the worker reads, to be OWNER/MEMBER/COLLABORATOR. Set `off` for private single-owner repos. Only the author or a writer can edit an issue, so no edit-history check (dropped from `next`).
6. **Severity defence in depth.** The runner refuses an issue that also carries `severity:critical` or `severity:high` (relabels `ready-for-human`). This reads labels; it does not classify.
7. **Daily cap replaces issues-per-run.** One issue per invocation makes "issues per run" meaningless; `MAX_ISSUES_PER_DAY` (default 5) takes its place.
8. **`mac-mini` profile.** Keeps its name; becomes pr-mode; loses its launchd plist (the waker replaces it). `personal` stays direct/interactive.
9. **`_retired/` deletion waits on the operator** confirming the GitHub-side cleanup in `_retired/issue-loop/RETIRED.md` (App deletion, ruleset replacement, sandbox repo) is done or copied elsewhere.
10. **`gh` and `claude` must authenticate inside cron.** UNVERIFIED on this machine: `gh auth status` reports the token in the keyring. B2 proves it by hand in a stripped environment; the cron line is NOT installed by B2.
11. **Waker cadence (D11).** Target poll is every 15 minutes; until B3 (backoff, stale lock) is proven the floor is 60 minutes, and the cron line stays uninstalled until B3 passes.
12. **Guard scope (D4).** The guard applies only to the loop worker, via the runner's `--settings`. For other repos `setup.sh --interactive` may wire it into that repo's local `.claude/settings.json` for an interactive loop session the operator chose; never do that in the-grid.
13. **Unattended statement (D6).** The worker prompt says the session is unattended with no human. Roles with `unattended: true` in `role.yaml` (today gh-triage, finance-manager, finance-sentinel) already carry safe-target and run-record rules; the runner does not read `role.yaml`. Whether to mark the builder roles `unattended: true` is not decided here.
