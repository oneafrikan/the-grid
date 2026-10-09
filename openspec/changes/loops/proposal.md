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

**Phase A (10a), built interactively by the operator after `foundations` and before any overnight run:**
- `{{BASE_BRANCH}}` placeholder everywhere `main` was hard-coded.
- PR mode: one worktree per issue off `origin/<base>`, branch `issue-<N>`, PR to `<base>`, issue relabelled `ready-for-human` and left open.
- Headless runner `run-issues.sh`: up to K labelled issues per run, one `claude -p --model sonnet --max-budget-usd <cap>` per issue inside `timeout`, an Opus review step (also model- and budget-capped) posted to the PR, one `run-record.sh` line per issue, stop on first infrastructure failure.
- Role routing: an issue labelled `role:<agent>` is built by `claude -p --agent <agent>`; unwired or read-only agents are refused (issue `blocked`, run continues); the role lands in the run record; `instantiate.sh --role-labels` creates the labels.
- Isolation and trust (operator decision Q1): the runner runs as a dedicated unprivileged OS user (own HOME, clone, `claude` login; cannot read the operator's HOME). The worker model never holds a GitHub token (`env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN`, no MCP servers, project/local settings only); it commits and writes one outcome line, and the runner pushes, opens the PR and relabels. Issues pass a trust gate (author association, trusted labeller, trusted editors) before any model call. Preflight refuses to start without a PR-requiring ruleset on the base and a non-admin fine-grained token.
- Headless environment handled by the runner, not the operator: env file parsed (never sourced) for `GH_TOKEN` and the two isolation keys, PATH append for `~/.local/bin` and Homebrew dirs, `claude auth status` / `gh auth status` / `git ls-remote` preflight with a fix-naming message, no credential prompts (`GIT_TERMINAL_PROMPT=0`).
- Per-label budget: `LABEL_BUDGETS` raises the worker cap for labelled issues (the-grid: `ws:rule-packs` = $15).
- Linux profile in `instantiate.sh`: systemd user `.service` + `.timer`, a read-only linger check that warns when linger is off; launchd plist moves to the same runner.
- `scripts/lib/render-schedule.sh`: the one shared, print-only schedule renderer (daily and weekly; systemd, launchd, cron) used by this change and by `budget-and-usage`, `instincts` and `manifest-lock-install`.
- Fix the review hook (worktree cwd, `git -C ... commit` matching, comment on the PR, model choice) and `setup.sh` (re-wire the guard, merge instead of overwrite).
- Fix `git checkout -- .` leaving untracked files; create every escape label.
- Re-cut the-grid's own `loop/` instance (base `next`, PR mode) and prove the whole chain on a sandbox repo with two trivial issues.

**Phase B (10b), loop-buildable afterwards:**
- New `karpathy-loop` pattern (one stdlib Python file + a copyable example): fixed fixtures, one editable artifact, one scalar from a `score_cmd`, keep/discard, `results.tsv`, plateau/max-iter stop, promote by hand.
- New `cli-cron` pattern: a scheduled job template running any CLI agent against a prompt file, with a wall-clock cap, logs and a run record; claude and codex examples only.
- Docs: patterns table and a factory-chain runbook.

## Capabilities

### New Capabilities
- `issue-loop-pr-mode`: base-branch placeholder, direct vs PR integration, per-issue worktree, relabel flow, cleanup and label creation.
- `issue-loop-runner`: headless multi-issue runner with caps, role routing by label, Opus review step, run records and failure policy.
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
- Needs on the running machine: `bash`, `git`, `gh`, `jq`, `claude`, GNU `timeout` (`gtimeout` on macOS). No Node dependency.
- Cross-change: Phase A follows `foundations` (CI on `next`); Phase B merges after `instincts`.

## Non-goals

- No auto-merge of agent PRs; nothing reaches `main` without the operator.
- Isolation: dedicated unprivileged OS user; no container.
- No headless `direct` mode; direct pushes stay an interactive-`/loop` feature.
- No Paperclip/OpenClaw heartbeat trigger (issue #4 stays open for that).
- No scripted idea-to-looping-project chain (issue #21 stays open; runbook only).
- No agent-factory specialists inside the loop (the roadmap "compose with agent-factory" item).
- No parallel issue execution; issues run serially.
- No cloud `/schedule` integration.
- No Windows scheduler.
- No generic multi-metric or multi-artifact optimisation in `karpathy-loop`; one artifact, one scalar. No built-in judge, `init` scaffold or resume.
- No `cli-cron` presets for CLIs other than claude and codex.
- No CI wiring for `next` (owned by `foundations#2`).
- No port of any content from the private prompt-factory; only the loop shape.
