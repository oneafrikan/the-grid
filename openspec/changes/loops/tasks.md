# Tasks

Phase A (groups 1 to 5) is built interactively with Gareth and merged to `next`
BEFORE any overnight run. Phase B (groups 6 to 8) is loop-buildable afterwards.
Default verify command is `bash scripts/gate.sh` unless stated. Every new bash
file: bash 3.2 compatible, `set -euo pipefail`, shellcheck-clean at `-S warning`,
commented generously, no machine-specific values. Every bats test runs in temp
dirs with `HOME` pointed at a temp dir and `GRID_RUN_LOG` at a temp file.

## 1. Phase A (interactive): PR-mode template, hooks and setup.sh

Depends on: none.
Files: `automation-factory/patterns/issue-loop/loop-prompt.template.md`, `automation-factory/patterns/issue-loop/setup.sh`, `automation-factory/patterns/issue-loop/hooks/post-commit-review.sh`, new `automation-factory/patterns/issue-loop/hooks/guard-main-push.sh`, new `automation-factory/patterns/issue-loop/hooks/new-agent-worktree.sh`, new `tests/helpers/stubs.bash`, new `tests/test_issue_loop_hooks.bats`, `scripts/gate.sh` (shellcheck globs only).
Acceptance: `tests/test_issue_loop_hooks.bats` passes; covers every scenario in `specs/issue-loop-hooks/spec.md` and the template scenarios in `specs/issue-loop-pr-mode/spec.md` that concern the template (mode blocks, no `git push origin main` in the pr block, clean-tree revert).
Verify: `tests/lib/bats-core/bin/bats tests/test_issue_loop_hooks.bats` then `bash scripts/gate.sh`.

- [ ] 1.1 Add `tests/helpers/stubs.bash`: function `make_stubs` creating a temp stub dir, prepending it to `PATH`, with fake `gh`, `claude`, and `timeout` (drops `-k N SECS`, execs the rest); each logs argv to `$STUB_LOG`; behaviour from env (`STUB_ISSUES`, `STUB_CLAUDE_EXIT`, `STUB_CLAUDE_JSON`, `STUB_CLAUDE_HELP`, `STUB_PR_NUMBER`, `STUB_LABELS`); function `clean_stubs`.
- [ ] 1.2 Rewrite `loop-prompt.template.md` with `{{BASE_BRANCH}}`, the `<!-- MODE:direct -->` and `<!-- MODE:pr -->` blocks exactly as in design.md, the `reset --hard && clean -fd` revert, and the "never push {{BASE_BRANCH}}" guardrail.
- [ ] 1.3 Create `hooks/guard-main-push.sh` per design.md (token matching, `gh pr merge`, force flags, bare push on protected branch; reads `BASE_BRANCH` from `loop/loop.conf` next to the hook, default `main`).
- [ ] 1.4 Create `hooks/new-agent-worktree.sh`: `<branch>` argument, `git fetch origin <base>`, `git worktree add -B <branch> <root>/<branch> origin/<base>`, prints the path; `<root>` = `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}`; base read from `loop.conf`.
- [ ] 1.5 Fix `hooks/post-commit-review.sh` per design.md (payload `cwd`, commit regex, dedupe file, PR-then-issue posting, `--model`/`--tools ""`, `GRID_LOOP_HEADLESS` and `GRID_REVIEW_RUNNING` stand-downs).
- [ ] 1.6 Fix `setup.sh` per design.md (jq merge function for PreToolUse and PostToolUse, chmod, guard smoke test, stable on re-run).
- [ ] 1.7 Extend `run_shellcheck` in `scripts/gate.sh` to include `automation-factory/patterns/*/*.sh` and `automation-factory/patterns/*/hooks/*.sh`; fix any new warnings in existing pattern files.
- [ ] 1.8 Write `tests/test_issue_loop_hooks.bats` (guard table of command to exit code; review hook with a real temp git repo and stub `claude`/`gh`; setup.sh merge, move, re-run, foreign hook, self-test failure).

## 2. Phase A (interactive): Headless runner

Depends on: 1.
Files: new `automation-factory/patterns/issue-loop/run-issues.sh`, new `automation-factory/patterns/issue-loop/loop.conf.template`, `tests/helpers/stubs.bash` (extend), new `tests/test_issue_loop_runner.bats`.
Acceptance: `tests/test_issue_loop_runner.bats` passes and covers every scenario in `specs/issue-loop-runner/spec.md`, using a temp bare "origin", a temp clone with a `next` branch, and the stubs.
Verify: `tests/lib/bats-core/bin/bats tests/test_issue_loop_runner.bats` then `bash scripts/gate.sh`.

- [ ] 2.1 Create `loop.conf.template` with the keys and `KEY=${KEY:-value}` form from design.md (placeholders `{{GH_REPO}}` etc. filled by instantiate.sh in group 3).
- [ ] 2.2 Create `run-issues.sh` implementing the algorithm in design.md steps 1 to 6: conf sourcing, timeout binary resolution (`GRID_TIMEOUT_BIN`, `timeout`, `gtimeout`), preflight with exit 2, mkdir lock with pid and stale reclaim, issue listing with cap, existing-PR/branch skip, worktree create/remove, optional `SETUP_CMD`, prompt assembly with runtime `{{WORKING_DIR}}` fill, worker call with the exact flag set, `--max-turns` probe via `claude --help`, exit/JSON classification, GitHub-state outcome, `blocked` fallback labelling, Opus review with truncation marker, cleanup, `run-record.sh` call (best-effort, path resolution per design.md), summary line, exit codes 0/1/2.
- [ ] 2.3 Support `MODE=direct` (no worktree, no review, success = issue closed).
- [ ] 2.4 Extend the `gh` stub so `issue list`, `issue view --json labels,state,body`, `pr list --head`, `pr diff`, `pr comment`, `issue edit`, `issue comment` are served from env/fixture files and logged.
- [ ] 2.5 Write the bats tests: happy path with two issues (2 worker calls, 2 review calls with `--model opus --tools ""`, 2 `gh pr comment`, 2 lines in `GRID_RUN_LOG`, worktrees gone, branches kept); `MAX_ISSUES` cap; zero issues; timeout then continue; exit-1 worker stops the run with exit 1; `error_max_turns` JSON continues; silent worker gets `blocked`; dirty tree exit 2; lock contention; stale lock; `--max-turns` probe both ways; direct mode; missing run-record tolerated.

## 3. Phase A (interactive): instantiate.sh, Linux profile, schedule renderers

Depends on: 1, 2.
Files: `scripts/instantiate.sh`, new `scripts/lib/render-schedule.sh`, new `tests/test_render_schedule.bats`, new `tests/test_instantiate.bats`.
Acceptance: both new test files pass and together cover every scenario in `specs/issue-loop-scheduling/spec.md` and the instantiate-related scenarios in `specs/issue-loop-pr-mode/spec.md` (base branch, modes, labels, escaping, idempotency). Tests instantiate into a temp git repo with a temp `HOME`, stubs for `gh`/`claude`, and `SYSTEMD_USER_DIR` / `LAUNCH_AGENTS_DIR` temp dirs.
Verify: `tests/lib/bats-core/bin/bats tests/test_render_schedule.bats tests/test_instantiate.bats` then `bash scripts/gate.sh`.

- [ ] 3.1 Create `scripts/lib/render-schedule.sh` with `render_systemd_service`, `render_systemd_timer`, `render_launchd_plist`, `render_crontab_line` (printf-based, pure, documented arguments), matching the unit text in design.md.
- [ ] 3.2 `instantiate.sh`: add options (`--base-branch --mode --max-issues --max-turns --issue-timeout --worker-model --review-model --setup-cmd --schedule-hour`, keep `--launchd-hour` alias), profile `linux`, profile-to-mode defaults, base-branch detection, update `usage()` and the header comment.
- [ ] 3.3 `instantiate.sh`: fill `{{BASE_BRANCH}}`; awk-select the MODE block; escape sed replacement values; copy `run-issues.sh`, shipped hooks (guard and worktree helper only in `pr` mode) instead of heredocs; render `loop/loop.conf` only if absent and print "left alone" when it differs; remove the now-dead heredoc workaround comments.
- [ ] 3.4 `instantiate.sh`: label creation for all four labels with `--limit 200` listing; create-if-absent only.
- [ ] 3.5 `instantiate.sh`: `linux` profile writes systemd units via the renderers to `${SYSTEMD_USER_DIR:-$XDG_CONFIG_HOME/systemd/user}` (default `~/.config/systemd/user`), computes `TimeoutStartSec`, warns if the env file is missing, prints enable and `loginctl enable-linger` commands, executes none; `mac-mini` plist switches to the renderer, the runner command and the `io.the-grid.issue-loop.<slug>` label, written to `${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}`.
- [ ] 3.6 `instantiate.sh`: update generated `CLAUDE.md` text (base branch, runner, PR flow) for the new profiles; still never overwrites an existing `CLAUDE.md`.
- [ ] 3.7 Write both bats files (renderer determinism and directives; instantiate base branch, modes, no `main` leakage, labels create/no-op, escaping `a && b`, idempotent second run with no `wrote:` lines, linux units and no activation commands run, mac-mini plist, `systemd-analyze verify` when available else `skip`).

## 4. Phase A (interactive): Docs and the-grid's own loop/ instance

Depends on: 1, 2, 3.
Files: `automation-factory/patterns/issue-loop/README.md`, `automation-factory/README.md` (patterns row and roadmap wording only), `loop/` (re-cut output: `loop-prompt.template.md`, `setup.sh`, `run-issues.sh`, `loop.conf`, `hooks/*`, `README.md`), `CLAUDE.md` (one line under Key files if `loop/` wording needs it).
Acceptance: re-running the same `instantiate.sh` command a second time prints no `wrote:` lines; `bash loop/setup.sh` exits 0 with a temp `HOME`-independent check (settings written to the gitignored `.claude/settings.json`); the pattern README no longer contains the "Known issues" section or any reference to a specific personal repo; `grep -rE '/Users/|/home/' automation-factory scripts/instantiate.sh scripts/lib/render-schedule.sh loop` finds nothing.
Verify: `bash scripts/gate.sh` plus the two commands above.

- [ ] 4.1 Rewrite the pattern README: PR mode, runner, `loop.conf` reference table, Linux setup (env file keys, `chmod 600`, `loginctl enable-linger`, enabling the timer, `systemctl --user start` for a manual fire), the fixed bugs recorded as history in two lines, no personal repo names; update the module table and roadmap (PR mode shipped).
- [ ] 4.2 Re-cut the-grid's own instance: `bash scripts/instantiate.sh issue-loop . --profile work --base-branch next --verify-cmd "bash scripts/gate.sh" (repo auto-detected from the git remote; do not pass --repo) --project-context "<existing one-liner from loop/README.md>" --review-focus "<existing>"` run from a clean tree; review the diff; keep the hand-written `loop/README.md` but update its parameters section (base `next`, PR mode, `gate.sh`, labels, runner usage).
- [ ] 4.3 Run `bash loop/setup.sh` locally and confirm `.claude/settings.json` gains PreToolUse guard and PostToolUse review entries without removing others (inspect with `jq`); do not commit `.claude/`.
- [ ] 4.4 Update `automation-factory/README.md` roadmap bullet for `instantiate.sh` to reflect shipped profiles (personal, work, mac-mini, linux).

## 5. Phase A, HUMAN: Prove the runner on a sandbox repo

Depends on: 4.
HUMAN: needs Gareth at the keyboard (creates a GitHub repo, supplies tokens, runs on the Linux machine).
Files: none in the-grid (sandbox repo is throwaway); append findings to `design.md` Decisions only if a Decided: item turns out wrong.
Acceptance: all of these observed and pasted into the PR/issue: a sandbox repo with `next` branch and two trivial issues labelled `ready-for-agent` becomes two PRs to `next`, each with an Opus review comment, issues relabelled `ready-for-human` and still open, two lines in the run log, no worktrees left, `systemctl --user start issue-loop-<slug>.service` repeats the cycle on a fresh pair of issues, a deliberately ambiguous third issue ends `needs-human`, a deliberately failing verify command ends `blocked` with a clean tree.
Verify: the observations above; then `bash scripts/gate.sh` unchanged.

- [ ] 5.1 Gareth creates the sandbox repo (private), a `next` branch, two issues ("Add a line `hello` to README.md", "Add a file `hello.txt` containing `hi`"), and runs `instantiate.sh issue-loop <clone> --profile linux --base-branch next --verify-cmd "test -f README.md"`.
- [ ] 5.2 Gareth runs, once, on the Linux machine: `claude setup-token`, `gh auth login` as the automation account, creates `~/.config/the-grid/issue-loop.env` (mode 600) with `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN`, `loginctl enable-linger "$USER"`.
- [ ] 5.3 Dry run by hand: `bash loop/run-issues.sh` inside the clone; inspect PRs, comments, labels, `runs.jsonl`.
- [ ] 5.4 Fire via systemd: enable the timer, `systemctl --user start` the service on two fresh issues; check `journalctl --user -u <service>`.
- [ ] 5.5 Verify the real `claude -p --output-format json` field names the runner parses (`is_error`, `subtype`, `total_cost_usd`) and whether `--max-turns` is accepted by the installed version; record the answers in the PR description and fix `run-issues.sh` if they differ.
- [ ] 5.6 Check whether `bash scripts/gate.sh` passes inside a bare worktree of the-grid (no submodules, no venv); if not, decide with Gareth on `SETUP_CMD` or a lighter `VERIFY_CMD` for the-grid's instance and apply it to `loop/loop.conf`.

## 6. Phase B: karpathy-loop pattern

Depends on: none (parallel to Phase A is fine, but schedule after it).
Files: new `automation-factory/patterns/karpathy-loop/{README.md,karpathy_loop.py,loop.example.ini,program.template.md,rubric.example.md}`, new `automation-factory/patterns/karpathy-loop/example/` (a `command`-metric demo: `artifact.txt`, `score.py`, `edit.sh` that makes a deterministic edit, `loop.ini`), new `tests/test_karpathy_loop.bats`, `automation-factory/README.md` (patterns table row only).
Acceptance: `tests/test_karpathy_loop.bats` passes and covers every scenario in `specs/karpathy-loop/spec.md` using only stub commands (no model calls, no network): scaffold, baseline, keep, discard, minimise, command and judge metrics, out-of-range, crash and three-crash stop, max-iter, plateau, fixture tamper exit 3, nothing-outside-dir, resume, command timeout. `python3 -I -m py_compile` succeeds on the engine; the engine imports only stdlib.
Verify: `tests/lib/bats-core/bin/bats tests/test_karpathy_loop.bats` then `bash scripts/gate.sh`.
Content rule: do NOT read or copy anything from any private prompt-factory repo; the shape (fixtures, one editable file, scalar, keep/discard, results.tsv, plateau, promote by hand) is fully specified in design.md. Names, brands, prompts and rubrics in examples are invented and generic.

- [ ] 6.1 Implement `karpathy_loop.py` with subcommands `init` and `run` (`--max-iter`, `--dir`), INI parsing, guard hashing, TSV logging, command templating with `shlex.quote`, per-command timeout, resume, exit codes (0 ok, 1 crashes, 2 config error, 3 guard).
- [ ] 6.2 Write `program.template.md` (what the editing agent may and may not do; ends with "print `CHANGED: <one line>`"), `rubric.example.md` (generic 3-dimension rubric ending with the `SCORE:` instruction), `loop.example.ini` as in design.md.
- [ ] 6.3 Write the `example/` demo so `python3 karpathy_loop.py run example` works offline and ends in a measurable improvement.
- [ ] 6.4 Write `README.md`: use cases, layout, loop diagram in text, ini reference, "bring your own CLI agent" examples (claude, codex; others tagged unverified), cost guidance (set `max_iter`, cap the commands), promotion step.
- [ ] 6.5 Write the bats tests.

## 7. Phase B: cli-cron pattern

Depends on: 3 (uses `scripts/lib/render-schedule.sh`).
Files: new `automation-factory/patterns/cli-cron/{README.md,run-agent.sh,install.sh,job.conf.example,prompt.example.md,agents.example.conf,.gitignore}`, new `tests/test_cli_cron.bats`, `automation-factory/README.md` (patterns table row only).
Acceptance: `tests/test_cli_cron.bats` passes and covers every scenario in `specs/cli-agent-cron/spec.md` using shell one-liners as the "agent" and the existing `timeout` shim; `agents.example.conf` tags are checked by a test (every agent line has `verified <date>` or `UNVERIFIED`; no uncommented bypass flag).
Verify: `tests/lib/bats-core/bin/bats tests/test_cli_cron.bats` then `bash scripts/gate.sh`.

- [ ] 7.1 Implement `run-agent.sh` per design.md (conf sourcing, preflight exit 2, lock, timeout, logs, pruning, run-record, exit codes).
- [ ] 7.2 Implement `install.sh` (`--at`, `--scheduler`, default by `uname`; env overrides for output dirs; prints activation commands; never executes them).
- [ ] 7.3 Write `job.conf.example`, `prompt.example.md`, `.gitignore` (ignores `logs/`).
- [ ] 7.4 Write `agents.example.conf`: re-run `claude --help` and `codex exec --help` and tag `verified <date>` only for flags actually seen; tag gemini and opencode `UNVERIFIED` unless those CLIs are installed on the implementing machine and their help was read.
- [ ] 7.5 Write `README.md`: the pattern in one screen, caps (wall clock via `timeout`, spend/turn caps via the agent's own flags), where to put credentials for unattended runs, how it differs from `issue-loop` (no worktree, no issues, no PR), and the explicit pointer that Paperclip/OpenClaw triggers are out of scope (issue #4 stays open).
- [ ] 7.6 Write the bats tests.

## 8. Phase B: Docs index and factory-chain runbook

Depends on: 6, 7.
Files: `automation-factory/README.md`, new `automation-factory/docs/factory-chain.md`.
Acceptance: `automation-factory/README.md` patterns table lists issue-loop, karpathy-loop and cli-cron with one-line use cases; `factory-chain.md` is a numbered runbook that goes from empty directory to a staffed, looping project using the three existing entry points (`project-factory/scripts/cut-project.sh`, `agent-factory/deploy.py`, `scripts/instantiate.sh`), with every command copied from the real READMEs and flags checked against each script's `--help`; contains no personal data. A bats check greps the runbook for each script path and asserts the path exists.
Verify: `bash scripts/gate.sh`.

- [ ] 8.1 Update the patterns table and roadmap list in `automation-factory/README.md`.
- [ ] 8.2 Write `factory-chain.md` as a runbook only (no new script); end with "Not yet scripted: see issue #21".
- [ ] 8.3 Add the path-exists bats check to `tests/test_instantiate.bats` or a new `tests/test_factory_chain_doc.bats`.
