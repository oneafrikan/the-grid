## Why

The issue-loop pattern only works unattended on one machine type: it hard-codes
`git push origin main`, has no PR mode, no model choice, no turn/time/issue caps,
never writes a run record, and schedules only through macOS launchd. Its review
hook misfires on worktrees, and `setup.sh` loses the push guard and clobbers other
hooks. The uplift needs a trustworthy overnight builder (Sonnet builds, Opus
reviews, PRs land on `next`) before any other workstream can use it. Two further
reusable shapes, a metric-driven improvement loop and a scheduled CLI agent, are
currently locked inside private or one-off code.

## What Changes

Two phases in one change.

**Phase A (10a), built interactively with Gareth before any overnight run:**
- `{{BASE_BRANCH}}` placeholder everywhere `main` was hard-coded.
- PR mode: one worktree per issue off `origin/<base>`, branch `issue-<N>`, PR to `<base>`, issue relabelled `ready-for-human` and left open.
- Headless runner `run-issues.sh`: up to K labelled issues per run, one capped `claude -p --model sonnet` per issue inside `timeout`, an Opus review step posted to the PR, one `run-record.sh` line per issue, stop on first infrastructure failure.
- Linux profile in `instantiate.sh`: systemd user `.service` + `.timer`; launchd plist moves to the same runner.
- Fix the review hook (worktree cwd, `git -C ... commit` matching, comment on the PR, model choice) and `setup.sh` (re-wire the guard, merge instead of overwrite).
- Fix `git checkout -- .` leaving untracked files; create every escape label.
- Re-cut the-grid's own `loop/` instance (base `next`, PR mode) and prove the whole chain on a sandbox repo with two trivial issues.

**Phase B (10b), loop-buildable afterwards:**
- New `karpathy-loop` pattern: fixed fixtures, one editable artifact, one scalar metric, keep/discard, `results.tsv`, plateau/max-iter stop, promote by hand.
- New `cli-cron` pattern: a scheduled job template running any CLI agent against a prompt file, with caps and run-record logging.
- Docs: patterns table and a factory-chain runbook.

## Capabilities

### New Capabilities
- `issue-loop-pr-mode`: base-branch placeholder, direct vs PR integration, per-issue worktree, relabel flow, cleanup and label creation.
- `issue-loop-runner`: headless multi-issue runner with caps, Opus review step, run records and failure policy.
- `issue-loop-hooks`: guard hook shipped in the pattern; review hook and `setup.sh` wiring fixes.
- `issue-loop-scheduling`: Linux systemd user timer profile, launchd on the same runner, shared unit renderers.
- `karpathy-loop`: generic metric-driven artifact improvement loop.
- `cli-agent-cron`: scheduled headless run of any CLI agent with caps and logging.

### Modified Capabilities

None. `openspec/specs/` is empty; this change introduces the first specs.

## Impact

- `automation-factory/patterns/issue-loop/` (template, setup.sh, hooks, new runner and conf), `scripts/instantiate.sh`, new `scripts/lib/render-schedule.sh`, `loop/` (the-grid's own instance), `tests/`.
- New dirs `automation-factory/patterns/karpathy-loop/` and `automation-factory/patterns/cli-cron/`.
- Folds in issue #4 partially (a scheduled headless Claude Code run with PR/run-record handoff; Paperclip wiring stays open) and issue #21 partially (documented runbook only; no chain script).
- Needs on the running machine: `bash`, `git`, `gh`, `jq`, `claude`, GNU `timeout` (`gtimeout` on macOS).

## Non-goals

- No auto-merge of agent PRs; nothing reaches `main` without Gareth.
- No Docker or container sandbox; isolation is worktree + guard hook + dedicated token.
- No Paperclip/OpenClaw heartbeat trigger (issue #4 stays open for that).
- No scripted idea-to-looping-project chain (issue #21 stays open; runbook only).
- No agent-factory specialists inside the loop (the roadmap "compose with agent-factory" item).
- No parallel issue execution; issues run serially.
- No cloud `/schedule` integration.
- No Windows scheduler.
- No generic multi-metric or multi-artifact optimisation in `karpathy-loop`; one artifact, one scalar.
- No port of any content from the private prompt-factory; only the loop shape.
