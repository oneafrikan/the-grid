# Tasks

Phase A (groups 1 to 5) is built interactively by the operator, after
`foundations`, and merged to `next` BEFORE any overnight run. Phase B (groups 6
to 8) is loop-buildable afterwards and merges after `instincts` (cross-change merge
order). Every PR from this change targets `next`. Every model call on an
unattended path passes an explicit `--model` plus a spend cap and a timeout.
Default verify command is `bash scripts/gate.sh` unless stated. Every new bash
file: bash 3.2 compatible, `set -euo pipefail`, shellcheck-clean at `-S warning`,
commented generously, no machine-specific values. Every bats test runs in temp
dirs with `HOME` pointed at a temp dir and `GRID_RUN_LOG` at a temp file.

## 1. Phase A (interactive): PR-mode template, hooks and setup.sh

Depends on: foundations#2 (CI runs on `next`).
Files: `automation-factory/patterns/issue-loop/loop-prompt.template.md`, `automation-factory/patterns/issue-loop/setup.sh`, `automation-factory/patterns/issue-loop/hooks/post-commit-review.sh`, new `automation-factory/patterns/issue-loop/hooks/guard-main-push.sh`, new `automation-factory/patterns/issue-loop/hooks/new-agent-worktree.sh`, new `tests/helpers/stubs.bash`, new `tests/test_issue_loop_hooks.bats`, `scripts/gate.sh` (shellcheck globs only).
Acceptance: `tests/test_issue_loop_hooks.bats` passes; covers every scenario in `specs/issue-loop-hooks/spec.md` and the template scenarios in `specs/issue-loop-pr-mode/spec.md` that concern the template (mode blocks, no `git push origin main` in the pr block, clean-tree revert).
Verify: `tests/lib/bats-core/bin/bats tests/test_issue_loop_hooks.bats` then `bash scripts/gate.sh`.

- [ ] 1.1 Add `tests/helpers/stubs.bash`: function `make_stubs` creating a temp stub dir, prepending it to `PATH`, with fake `gh`, `claude`, `loginctl` and `timeout` (drops `-k N SECS`, execs the rest); each logs argv to `$STUB_LOG`; behaviour from env (`STUB_ISSUES`, `STUB_CLAUDE_EXIT`, `STUB_CLAUDE_JSON`, `STUB_CLAUDE_HELP`, `STUB_CLAUDE_LOGGED_IN` for `claude auth status --json`, `STUB_PR_NUMBER`, `STUB_LABELS`, `STUB_LINGER`); `make_stubs --claude-in-local-bin` puts the `claude` stub in `$HOME/.local/bin` instead of the stub dir; function `clean_stubs`.
- [ ] 1.2 Rewrite `loop-prompt.template.md` with `{{BASE_BRANCH}}`, the `<!-- MODE:direct -->` and `<!-- MODE:pr -->` blocks exactly as in design.md, the `reset --hard && clean -fd` revert, and the "never push {{BASE_BRANCH}}" guardrail.
- [ ] 1.3 Create `hooks/guard-main-push.sh` per design.md (token matching, `gh pr merge`, force flags, bare push on protected branch; reads `BASE_BRANCH` from `loop/loop.conf` next to the hook, default `main`).
- [ ] 1.4 Create `hooks/new-agent-worktree.sh`: `<branch>` argument, `git fetch origin <base>`, `git worktree add -B <branch> <root>/<branch> origin/<base>`, prints the path; `<root>` = `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}`; base read from `loop.conf`.
- [ ] 1.5 Fix `hooks/post-commit-review.sh` per design.md (payload `cwd`, commit regex, dedupe file, PR-then-issue posting, `--model`/`--tools ""`, `GRID_LOOP_HEADLESS` and `GRID_REVIEW_RUNNING` stand-downs, `--max-budget-usd "${GRID_REVIEW_BUDGET_USD:-1}"`).
- [ ] 1.6 Fix `setup.sh` per design.md (jq merge function for PreToolUse and PostToolUse, chmod, guard smoke test, stable on re-run).
- [ ] 1.7 Extend `run_shellcheck` in `scripts/gate.sh` to include `automation-factory/patterns/*/*.sh` and `automation-factory/patterns/*/hooks/*.sh`; fix any new warnings in existing pattern files.
- [ ] 1.8 Write `tests/test_issue_loop_hooks.bats` (guard table of command to exit code; review hook with a real temp git repo and stub `claude`/`gh`; setup.sh merge, move, re-run, foreign hook, self-test failure).

## 2. Phase A (interactive): Headless runner

Depends on: 1.
Files: new `automation-factory/patterns/issue-loop/run-issues.sh`, new `automation-factory/patterns/issue-loop/loop.conf.template`, `tests/helpers/stubs.bash` (extend), new `tests/test_issue_loop_runner.bats`.
Acceptance: `tests/test_issue_loop_runner.bats` passes and covers every scenario in `specs/issue-loop-runner/spec.md`, using a temp bare "origin", a temp clone with a `next` branch, and the stubs.
Verify: `tests/lib/bats-core/bin/bats tests/test_issue_loop_runner.bats` then `bash scripts/gate.sh`.

- [ ] 2.1 Create `loop.conf.template` with the keys and `KEY=${KEY:-value}` form from design.md (placeholders `{{GH_REPO}}` etc. filled by instantiate.sh in group 3).
- [ ] 2.2 Create `run-issues.sh` implementing the algorithm in design.md steps 1 to 6: conf sourcing, optional `GRID_LOOP_ENV` env file (`set -a`), `$HOME/.local/bin` PATH fallback, `GIT_TERMINAL_PROMPT=0`, timeout binary resolution (`GRID_TIMEOUT_BIN`, `timeout`, `gtimeout`), preflight with exit 2 (`claude auth status --json`, `gh auth status`, `git ls-remote --exit-code origin <base>`, each failure printing the fix), mkdir lock with pid and stale reclaim, issue listing with cap, existing-PR/branch skip, role routing (step a2: `role:` label, agent file lookup in `${AGENTS_DIR:-$HOME/.claude/agents}` and `$REPO_ROOT/.claude/agents`, read-only refusal by `tools:` frontmatter), worktree create/remove, optional `SETUP_CMD`, prompt assembly with runtime `{{WORKING_DIR}}` fill, worker call with the exact flag set (`[--agent ROLE] --model WORKER_MODEL --max-budget-usd MAX_BUDGET_USD`), `--max-turns` probe via `claude --help`, exit/JSON classification, GitHub-state outcome, `blocked` fallback labelling, Opus review (`--model REVIEW_MODEL --max-budget-usd REVIEW_BUDGET_USD --tools ""`, no `--agent`) with truncation marker, INFRA stderr tail to stderr, cleanup, `run-record.sh` call (role = routed agent else `RUN_ROLE`; best-effort, path resolution per design.md), summary line, exit codes 0/1/2.
- [ ] 2.3 Support `MODE=direct` (no worktree, no review, success = issue closed).
- [ ] 2.4 Extend the `gh` stub so `issue list`, `issue view --json labels,state,body`, `pr list --head`, `pr diff`, `pr comment`, `issue edit`, `issue comment` are served from env/fixture files and logged.
- [ ] 2.5 Write the bats tests: happy path with two issues (2 worker calls with `--max-budget-usd 5`, 2 review calls with `--model opus --max-budget-usd 2 --tools ""`, 2 `gh pr comment`, 2 lines in `GRID_RUN_LOG`, worktrees gone, branches kept); `MAX_ISSUES` cap; zero issues; timeout then continue; exit-1 worker stops the run with exit 1; `error_max_turns` JSON continues; silent worker gets `blocked`; dirty tree exit 2; lock contention; stale lock; `--max-turns` probe both ways; direct mode; missing run-record tolerated; `claude` only in `$HOME/.local/bin` found; `loggedIn:false` exits 2 with no `claude -p`; env file `GH_TOKEN` visible to the `gh` stub; role routing (`role:grid-backend-dev` with a temp `AGENTS_DIR/grid-backend-dev.md` → `--agent grid-backend-dev` in the worker argv and role in the run record; no label → no `--agent`; unwired name → `blocked` comment, next issue still runs; temp agent with `tools: Read, Grep, Glob, Bash` → refused, no `claude -p`; two `role:` labels → `blocked`).

## 3. Phase A (interactive): instantiate.sh, Linux profile, schedule renderers

Depends on: 1, 2.
Files: `scripts/instantiate.sh`, new `scripts/lib/render-schedule.sh`, new `tests/test_render_schedule.bats`, new `tests/test_instantiate.bats`.
Acceptance: both new test files pass and together cover every scenario in `specs/issue-loop-scheduling/spec.md` and the instantiate-related scenarios in `specs/issue-loop-pr-mode/spec.md` (base branch, modes, labels including `--role-labels`, escaping, idempotency). Tests instantiate into a temp git repo with a temp `HOME`, stubs for `gh`/`claude`, and `SYSTEMD_USER_DIR` / `LAUNCH_AGENTS_DIR` temp dirs.
Verify: `tests/lib/bats-core/bin/bats tests/test_render_schedule.bats tests/test_instantiate.bats` then `bash scripts/gate.sh`.

- [ ] 3.1 Create `scripts/lib/render-schedule.sh` with `render_systemd_service`, `render_systemd_timer`, `render_launchd_plist`, `render_crontab_line` (printf-based, pure, documented arguments), matching the unit text in design.md.
- [ ] 3.2 `instantiate.sh`: add options (`--base-branch --mode --max-issues --max-turns --issue-timeout --worker-model --review-model --setup-cmd --schedule-hour`, keep `--launchd-hour` alias), profile `linux`, profile-to-mode defaults, base-branch detection, update `usage()` and the header comment.
- [ ] 3.3 `instantiate.sh`: fill `{{BASE_BRANCH}}`; awk-select the MODE block; escape sed replacement values; copy `run-issues.sh`, shipped hooks (guard and worktree helper only in `pr` mode) instead of heredocs; render `loop/loop.conf` only if absent and print "left alone" when it differs; remove the now-dead heredoc workaround comments.
- [ ] 3.4 `instantiate.sh`: label creation for all four labels plus `role:<name>` for each `--role-labels` entry (colour 5319E7) with `--limit 200` listing; create-if-absent only.
- [ ] 3.5 `instantiate.sh`: `linux` profile writes systemd units via the renderers to `${SYSTEMD_USER_DIR:-$XDG_CONFIG_HOME/systemd/user}` (default `~/.config/systemd/user`), computes `TimeoutStartSec`, writes no `EnvironmentFile` line, prints the optional env file path and keys (`GH_TOKEN`, optional `CLAUDE_CODE_OAUTH_TOKEN`), reads `loginctl show-user "$USER" --property=Linger --value` when `loginctl` exists and warns if not `yes`, prints enable and `loginctl enable-linger` commands, executes none; `mac-mini` plist switches to the renderer, the runner command and the `io.the-grid.issue-loop.<slug>` label, written to `${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}`.
- [ ] 3.6 `instantiate.sh`: update generated `CLAUDE.md` text (base branch, runner, PR flow) for the new profiles; still never overwrites an existing `CLAUDE.md`.
- [ ] 3.7 Write both bats files (renderer determinism and directives; instantiate base branch, modes, no `main` leakage, labels create/no-op, escaping `a && b`, idempotent second run with no `wrote:` lines, linux units with no `EnvironmentFile`, linger warning from the `loginctl` stub with no `enable-linger` call, no activation commands run, `--role-labels` creates role labels, mac-mini plist, `systemd-analyze verify` when available else `skip`).

## 4. Phase A (interactive): Docs and the-grid's own loop/ instance

Depends on: 1, 2, 3.
Files: `automation-factory/patterns/issue-loop/README.md`, `automation-factory/README.md` (patterns row and roadmap wording only), `loop/` (re-cut output: `loop-prompt.template.md`, `setup.sh`, `run-issues.sh`, `loop.conf`, `hooks/*`, `README.md`), `CLAUDE.md` (one line under Key files if `loop/` wording needs it).
Acceptance: re-running the same `instantiate.sh` command a second time prints no `wrote:` lines; `bash loop/setup.sh` exits 0 with a temp `HOME`-independent check (settings written to the gitignored `.claude/settings.json`); the pattern README no longer contains the "Known issues" section or any reference to a specific personal repo; `grep -rE '/Users/|/home/' automation-factory scripts/instantiate.sh scripts/lib/render-schedule.sh loop` finds nothing.
Verify: `bash scripts/gate.sh` plus the two commands above.

- [ ] 4.1 Rewrite the pattern README: PR mode, runner, `loop.conf` reference table, Linux setup (optional env file read by the runner: `GH_TOKEN` for keyring-based `gh`, optional `CLAUDE_CODE_OAUTH_TOKEN`, `chmod 600`; `gh auth setup-git`; `loginctl enable-linger`; enabling the timer; `systemctl --user start` for a manual fire), role routing (`role:<agent>` labels, builders vs read-only roles), the fixed bugs recorded as history in two lines, no personal repo names; update the module table and roadmap (PR mode shipped).
- [ ] 4.2 Re-cut the-grid's own instance: `bash scripts/instantiate.sh issue-loop . --profile work --base-branch next --verify-cmd "bash scripts/gate.sh" --role-labels grid-backend-dev,grid-devops,grid-technical-writer,grid-sdet,grid-prompt-engineer,core-platform-engineer` (repo auto-detected from the git remote; do not pass `--repo`) with `--project-context "<existing one-liner from loop/README.md>" --review-focus "<existing>"` run from a clean tree; review the diff; keep the hand-written `loop/README.md` but update its parameters section (base `next`, PR mode, `gate.sh`, labels, runner usage).
- [ ] 4.3 Run `bash loop/setup.sh` locally and confirm `.claude/settings.json` gains PreToolUse guard and PostToolUse review entries without removing others (inspect with `jq`); do not commit `.claude/`.
- [ ] 4.4 Update `automation-factory/README.md` roadmap bullet for `instantiate.sh` to reflect shipped profiles (personal, work, mac-mini, linux).

## 5. Phase A, HUMAN: Prove the runner on a sandbox repo

Depends on: 4.
HUMAN: needs the operator at the keyboard of the Ubuntu 24.04 box (creates a GitHub repo, supplies the GitHub token, enables linger).
Files: none in the-grid (sandbox repo is throwaway) except fixes to `run-issues.sh` if 5.6 finds a mismatch; append to `design.md` Decisions only if a Decided: item turns out wrong.
Acceptance: all of these observed and pasted into the PR: a sandbox repo with `next` and two trivial issues labelled `ready-for-agent` becomes two PRs to `next`, each with an Opus review comment, issues relabelled `ready-for-human` and still open, two lines in the run log, no worktrees left; `systemctl --user start issue-loop-<slug>.service` repeats the cycle on a fresh pair of issues while the operator is logged out of desktop sessions; a `role:grid-backend-dev` issue is built with `--agent` (journal shows it) and its run record role is `grid-backend-dev`; a `role:grid-qa-engineer` issue ends `blocked` with no model call; an ambiguous issue ends `needs-human`; a failing verify command ends `blocked` with a clean tree.
Verify: the observations above; then `bash scripts/gate.sh` unchanged.

- [ ] 5.1 Operator creates the sandbox repo (private), a `next` branch, two issues ("Add a line `hello` to README.md", "Add a file `hello.txt` containing `hi`"), and runs `instantiate.sh issue-loop <clone> --profile linux --base-branch next --verify-cmd "test -f README.md" --role-labels grid-backend-dev`.
- [ ] 5.2 Operator, once, on the box: confirm `~/.local/bin/claude auth status --text` shows logged in from the credentials file (no `setup-token`); create `~/.config/the-grid/issue-loop.env` (mode 600) with `GH_TOKEN` for the automation account; run `gh auth setup-git`; `loginctl enable-linger "$USER"`. Add `CLAUDE_CODE_OAUTH_TOKEN` to the env file only if 5.4 fails on Claude auth.
- [ ] 5.3 Dry run from a non-login SSH shell (`ssh <box> 'cd <clone> && bash loop/run-issues.sh'`) so the PATH fallback and env file are exercised; inspect PRs, comments, labels, run log.
- [ ] 5.4 Fire via systemd: enable the timer, `systemctl --user start` the service on two fresh issues plus the role issues; check `journalctl --user -u <service>`.
- [ ] 5.5 Check `--agent` with `--model`: run `claude -p --agent grid-backend-dev --model haiku --max-budget-usd 0.1 --output-format json "Reply with the model you are"` and read `.modelUsage` (or equivalent) in the JSON; record which wins (agent `model:` frontmatter or `--model`). If the agent's frontmatter wins, record it as a Decided: item and set `WORKER_MODEL` to match the agents' `model:` so the cap stays explicit.
- [ ] 5.6 On claude 2.1.289, verify: `claude auth status --json` has `.loggedIn`; the `-p --output-format json` field names the runner parses (`is_error`, `subtype`, `total_cost_usd`); whether `--max-turns` is listed; that `--max-budget-usd` is honoured under a subscription login (a 0.01 cap ends the call early). Record answers in the PR description; fix `run-issues.sh` if they differ.
- [ ] 5.7 Check whether `bash scripts/gate.sh` passes inside a bare worktree of the-grid (no submodules, no venv); if not, apply the fallback in design.md Decisions to the-grid's `loop/loop.conf`.

## 6. Phase B: karpathy-loop pattern

Depends on: 5 (ordering only); merges after instincts per the cross-change order.
Files: new `automation-factory/patterns/karpathy-loop/{README.md,karpathy_loop.py}`, new `automation-factory/patterns/karpathy-loop/example/{loop.ini,program.md,artifact.txt,fixtures/input.txt,edit.sh,score.py}`, new `tests/test_karpathy_loop.bats`, `automation-factory/README.md` (patterns table row only).
Acceptance: `tests/test_karpathy_loop.bats` passes and covers every scenario in `specs/karpathy-loop/spec.md` using only stub shell commands (no model calls, no network), each test copying `example/` to a temp dir; `python3 -I -m py_compile` succeeds on the engine; `grep -E '^(import|from) ' karpathy_loop.py` shows stdlib modules only.
Verify: `tests/lib/bats-core/bin/bats tests/test_karpathy_loop.bats` then `bash scripts/gate.sh`.
Content rule: do NOT read or copy anything from any private prompt-factory repo; the shape is fully specified in design.md. Names, prompts and examples are invented and generic.

- [ ] 6.1 Implement `karpathy_loop.py run <dir> [--max-iter N]` per design.md (INI via `configparser`, `results.tsv` refusal, baseline, guard hashing, `shlex.quote` templating, per-command timeout, keep/discard/crash, plateau, exit codes 0/1/2/3, printed `cp` promotion line).
- [ ] 6.2 Write `example/` so `python3 karpathy_loop.py run <copy of example>` works offline and ends better than baseline (`edit.sh` makes a deterministic improving edit; `score.py` counts something in the artifact against `fixtures/input.txt`).
- [ ] 6.3 Write `README.md`: use cases, copy-the-example setup, ini reference, loop in text, a model-backed `edit_cmd` and a `judge.sh` `score_cmd` example, every `claude -p` line with `--model` and `--max-budget-usd`, promotion step.
- [ ] 6.4 Write the bats tests (one per spec scenario, plus a grep test for the README cap rule).

## 7. Phase B: cli-cron pattern

Depends on: 3 (uses `scripts/lib/render-schedule.sh`); merges after instincts per the cross-change order.
Files: new `automation-factory/patterns/cli-cron/{README.md,run-agent.sh,install.sh,job.conf.example,prompt.example.md,.gitignore}`, new `tests/test_cli_cron.bats`, `automation-factory/README.md` (patterns table row only).
Acceptance: `tests/test_cli_cron.bats` passes and covers every scenario in `specs/cli-agent-cron/spec.md` using shell one-liners as the "agent" and the stub `timeout` from `tests/helpers/stubs.bash`.
Verify: `tests/lib/bats-core/bin/bats tests/test_cli_cron.bats` then `bash scripts/gate.sh`.

- [ ] 7.1 Implement `run-agent.sh` per design.md (conf sourcing, `GRID_LOOP_ENV` + `~/.local/bin` fallback, preflight exit 2, lock, timeout, logs, pruning, run-record, exit codes).
- [ ] 7.2 Implement `install.sh` (`--at`, `--scheduler`, default by `uname`; `SYSTEMD_USER_DIR` / `LAUNCH_AGENTS_DIR` overrides; prints activation commands; never executes them).
- [ ] 7.3 Write `job.conf.example` (with the two commented examples from design.md, flags re-checked against `claude --help` and `codex exec --help`), `prompt.example.md`, `.gitignore` (`logs/`).
- [ ] 7.4 Write `README.md`: the pattern in one screen, caps (wall clock via `timeout`, spend via the agent's own flags), where credentials go for unattended runs (the env file), how it differs from `issue-loop`, and that Paperclip/OpenClaw triggers are out of scope (issue #4 stays open).
- [ ] 7.5 Write the bats tests.

## 8. Phase B: Docs index and factory-chain runbook

Depends on: 6, 7.
Files: `automation-factory/README.md`, new `automation-factory/docs/factory-chain.md`.
Acceptance: `automation-factory/README.md` patterns table lists issue-loop, karpathy-loop and cli-cron with one-line use cases; `factory-chain.md` is a numbered runbook that goes from empty directory to a staffed, looping project using the three existing entry points (`project-factory/scripts/cut-project.sh`, `agent-factory/deploy.py`, `scripts/instantiate.sh`), with every command copied from the real READMEs and flags checked against each script's `--help`; contains no personal data. A bats check greps the runbook for each script path and asserts the path exists.
Verify: `bash scripts/gate.sh`.

- [ ] 8.1 Update the patterns table and roadmap list in `automation-factory/README.md`.
- [ ] 8.2 Write `factory-chain.md` as a runbook only (no new script); end with "Not yet scripted: see issue #21".
- [ ] 8.3 Add the path-exists bats check to `tests/test_instantiate.bats` or a new `tests/test_factory_chain_doc.bats`.
