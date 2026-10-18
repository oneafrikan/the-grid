## Context

Facts checked against the worktree (`spec/epistemics-and-loop`, cut from `origin/next`) and `git show main:...` on 2026-10-18:

- `main` pattern: `README.md`, `setup.sh`, `loop-prompt.template.md`, `hooks/post-commit-review.sh`, `.gitignore`. No guard, no worktree helper, no runner. `scripts/instantiate.sh` is 539 lines, embeds the guard and worktree helper as heredocs for `--profile work`, and for `mac-mini` writes a launchd plist running `claude --dangerously-skip-permissions -p "$(cat loop/loop-prompt.md)"`. Its default opt-in label is `agent-ready`, but gh-triage applies `ready-for-agent` (this repo has that label, verified with `gh label list`).
- `next` pattern: adds `run-issues.sh` (774 lines), `loop.conf.template`, `hooks/guard-main-push.sh` (211), `hooks/new-agent-worktree.sh` (39), a fixed `post-commit-review.sh` (136) and a merging `setup.sh` (106). `scripts/instantiate.sh` (671 lines), `loop/**` and four bats files live in `_retired/issue-loop/` (`RETIRED.md` lists 32 defects). `automation-factory/docs/gh-triage-to-issue-loop.md` was deleted by `depersonalise` (commit 4f30534: "runbook for one private server and work repos"); the `main` copy names a chat-channel id, a server path and another account's repos.
- `scripts/lib/render-schedule.sh` exists on `next`, used by `scripts/usage/install-schedule.sh`, `scripts/instincts.sh`, `scripts/grid`. It accepts only `daily:HH:MM` and `weekly:DOW:HH:MM`; a poll every N minutes cannot be rendered today.
- `claude` 2.1.302 lists `--agent`, `--max-budget-usd`, `--permission-mode`, `--session-id`, `-n/--name`, `--settings`, `--setting-sources`, `--output-format`; it does NOT list `--max-turns` (`claude --help | grep -c -- --max-turns` printed 0). `gh issue view --json` has no `authorAssociation` (gh 2.45.0); `gh api repos/R/issues/N` and `.../comments` do (checked read-only).
- Existing label scheme in the repo: `ready-for-agent`, `ready-for-human`, `needs-human`, `blocked`, `needs-triage`, `needs-info`, `wontfix`, `severity:*`. gh-triage writes the Agent Brief as an issue comment headed `## Agent Brief` (`agent-factory/roles/gh-triage/SKILL.md`, "Agent brief template").
- `hooks/lib/common.sh` documents `grid_git_segments`: "Call it directly (NOT inside $(...), the results are globals)" and returns via `GIT_SUB`, `GIT_FLAG`, `GIT_START`, `GIT_LEN`. It prints nothing.

### Defects reproduced on the worktree

Run against `automation-factory/patterns/issue-loop/hooks/guard-main-push.sh` with the payload `{"tool_input":{"command":...}}`:

| Command | Result | Meaning |
|---|---|---|
| `git push origin main` | exit 2 | blocked (built-in splitter) |
| same, with `GRID_DIR=<worktree>` | exit 0 | **R10.qa.F1**: `git_segments()` calls `grid_git_segments` inside `< <(...)`; the parser prints nothing, so the guard sees no segments and allows everything |
| `git push origin 'main'` | exit 0 | **R10.qa.F14**: quoted refspec |
| `/usr/bin/git push origin main` | exit 0 | F14: path-qualified git |
| `gh pr 'merge' 5`, `/usr/bin/gh pr merge 5` | exit 0 | same bypass on the `gh` side (not in `RETIRED.md`; found here) |
| `bash -c 'git push origin main'` | exit 0 | documented known gap, stays |

The shared parser handles the quoted and path-qualified forms correctly (`grid_git_segments "/usr/bin/git push origin 'main'"` yields `push` with flag words `origin main`). On a machine where `~/.the-grid/hooks/lib/common.sh` exists (every machine with next merged), F1 is the default behaviour, not an edge case. The retired test for "shared parser used" used a fixture whose `grid_git_segments` wrote a marker file, so it could never see the parser's real contract.

## Approach

### File layout after B1 (pattern, copied into `<target>/loop/` by `instantiate.sh`)

```
automation-factory/patterns/issue-loop/
  README.md                    rewritten, short
  loop-prompt.template.md      interactive /loop prompt; {{BASE_BRANCH}} + MODE:pr|direct blocks; copied VERBATIM
  worker-prompt.template.md    NEW headless prompt for one issue (placeholders filled by run-issue.sh)
  loop.conf.template           rendered once
  setup.sh                     renders loop/loop-prompt.md from template + loop.conf; self-tests the guard; `--interactive` also wires hooks into local settings, `--unwire` removes them
  run-issue.sh                 NEW B1
  wake.sh                      NEW B2
  hooks/guard-main-push.sh  hooks/new-agent-worktree.sh  hooks/post-commit-review.sh
  .gitignore                   loop-prompt.md
```

Runtime state (untracked, outside any worktree): `<git-common-dir>/issue-loop/` holding `lock/` (dir with `pid`, `worker`, `issue`, `started`), `runs.log` (`YYYY-MM-DD issue outcome`), and in B3 `backoff` (`until=<epoch> fails=<n> issue=<n> issue_fails=<n>`; `fails` counts consecutive infra failures across issues, `issue_fails` those on `issue`).

### run-issue.sh algorithm (bash 3.2 compatible, `set -euo pipefail`, never `set -x`)

Usage: `bash loop/run-issue.sh [issue-number]`. With no number it picks the lowest-numbered open issue carrying `ISSUE_LABEL`. With a number that issue must still carry `ISSUE_LABEL`.

1. **Load**: `loop/loop.conf`; append `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` to PATH (never prepend); `GIT_TERMINAL_PROMPT=0`; stdin from `/dev/null`; resolve `timeout`/`gtimeout`; `claude` via `${GRID_CLAUDE:-claude}`.
2. **Preflight** (any failure: one stderr line naming the fix, exit 2, nothing touched): `MODE=pr`; `VERIFY_CMD` non-empty; `git gh jq claude timeout` present; `claude auth status --json` has `.loggedIn == true`; `gh auth status` ok; `GH_REPO` set; `origin/BASE_BRANCH` exists (`git ls-remote`); guard script `loop/hooks/guard-main-push.sh` present and executable; `<worktree-root>` creatable. (The guard is NOT read from `.claude/settings.json`; see step 9.)
3. **Lock** (`mkdir` in the state dir; exit 0 "busy" with the pid when held). Cleanup `trap` on EXIT/INT/TERM/HUP removes the worktree and the lock.
4. **Daily cap**: count today's lines in `runs.log`; at `MAX_ISSUES_PER_DAY` exit 0 without touching anything.
5. **Select** the issue. Read it with `gh api repos/R/issues/N` (labels, author association) and `.../comments`.
6. **Gates** (each refusal swaps labels, comments, records `skipped`, exit 0): severity label present; existing open PR or remote branch `issue-N`; `TRUST_GATE=on` and author not OWNER/MEMBER/COLLABORATOR.
7. **Role**: zero `agent:*` labels = generic session; one = `--agent <name>` after checking `<name>.md` exists in `${AGENTS_DIR:-~/.claude/agents}` or `<repo>/.claude/agents` and its frontmatter `tools:` line (if any) names `Edit` or `Write`; otherwise `blocked`.
8. **Worktree**: `git fetch origin +refs/heads/BASE:refs/remotes/origin/BASE`; `git worktree add --no-track -B issue-N <root>/issue-N origin/BASE`. `SETUP_CMD` runs there under `timeout`.
9. **Worker**: prompt = `worker-prompt.template.md` with title, body (cut at 60000 bytes) and the Agent Brief (latest comment starting `## Agent Brief` whose author association is trusted; other comments are never shown). Command:
   `timeout -k 30 ISSUE_TIMEOUT claude -p [--agent R] --model WORKER_MODEL --max-budget-usd MAX_BUDGET_USD --output-format json --allowedTools "$WORKER_ALLOWED_TOOLS" --settings $TMP/worker-settings.json --session-id <uuid> -n issue-N "<prompt>"`. `$TMP/worker-settings.json` is written by the runner per run and holds only the guard's PreToolUse entry (absolute path of the repo's `loop/hooks/guard-main-push.sh`). With `WORKER_PERMISSIONS=bypass` (fallback) `--dangerously-skip-permissions` replaces `--allowedTools`. with cwd = the worktree, `LOOP_OUTCOME_FILE` and `GRID_LOOP_HEADLESS=1` in the environment, stdin `/dev/null`. The worker pid goes in `lock/worker`.
10. **Classify the worker**: exit 124/137 = timeout (issue-level); other non-zero or non-JSON output = infra; `is_error` with a budget subtype = issue-level; any other error result = infra. Outcome line (`done` | `needs-human <reason>` | `blocked <reason>`) read from `LOOP_OUTCOME_FILE`.
11. **Git-state check** (only for `done`): branch is `issue-N`, tree clean, at least one commit ahead of `origin/BASE`.
12. **Verify (the runner, not the model)**: `bash -c "$VERIFY_CMD"` in the worktree under `timeout VERIFY_TIMEOUT`. Fail: `blocked`, comment with the last 40 lines (cut to 3000 bytes), no push.
13. **Integrate**: `git push origin HEAD:refs/heads/issue-N` (explicit refspec; `--no-verify` is not used, hooks are left alone), `gh pr create --base BASE --head issue-N --title "<title> (#N)" --body-file ...`, swap labels, comment the PR URL. The issue stays open.
14. **Record**: remove the worktree (branch kept); append `runs.log`; one `scripts/run-record.sh` line (`--role <agent|RUN_ROLE> --action work-issue --target R#N --outcome ok|skipped|error --cost-usd ... --note ...`). Exit 0 for any issue-level outcome, 1 for infra.

### Label transitions (invariant: on exit 0 for an issue, `ISSUE_LABEL` is gone)

| Outcome | Remove | Add | Issue comment | run-record | exit |
|---|---|---|---|---|---|
| PR opened | ISSUE_LABEL | `ready-for-human` | PR URL | ok | 0 |
| worker says `needs-human` | ISSUE_LABEL | `needs-human` | reason | skipped | 0 |
| trust gate refused | ISSUE_LABEL | `needs-human` | which check failed | skipped | 0 |
| severity label / existing PR or branch | ISSUE_LABEL | `ready-for-human` | reason (+ PR link) | skipped | 0 |
| verify failed, no commit, wrong branch, dirty tree, timeout, budget, `blocked`, agent refused, worktree/setup failure | ISSUE_LABEL | `blocked` | reason | error | 0 |
| infra failure (claude/gh/git/network) | nothing | nothing | none | error | 1 |

Self-healing: if a `gh issue edit` fails after the PR exists, the next run hits "existing PR" and finishes the label swap.

### Hooks

- **Guard**: when `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` exists, source it, call `grid_check_cmd_cap` and `grid_git_segments "$COMMAND"` DIRECTLY (no subshell, no process substitution), then `grid_check_balanced`, and iterate `GIT_SUB/GIT_START/GIT_LEN/GIT_FLAG`. Otherwise use the built-in splitter, fixed to strip `"`, `'` and `\` from words and to match `git`/`gh` by basename. Both paths implement one decision function and one test table. The `gh` side always uses the built-in splitter (the shared parser covers git only), with the same normalisation.
- **Review hook**: as `next` (cwd from payload, anchored commit regex, per-worktree dedupe file, PR then issue then log, detached, `--tools ""`, model and budget caps, `GRID_REVIEW_RUNNING` recursion guard, stands down on `GRID_LOOP_HEADLESS=1`).
- **setup.sh**: default run renders the prompt placeholders from `loop.conf` into the gitignored `loop/loop-prompt.md` and self-tests the guard script directly; it writes nothing to `.claude/settings.json`. `--interactive` adds `next`'s jq merge by command basename (review hook under PostToolUse, guard under PreToolUse, byte-identical re-run) for a repo where the operator runs an interactive loop; `--unwire` removes our entries. The self-test also asserts a quoted refspec and a path-qualified `git` are blocked.

## Decisions

- Decided: one script, one issue per invocation; the queue drains one issue per waker tick or per hand start. Reason: a multi-issue runner needs per-issue state across a long process; one issue makes lock, cleanup, record and exit codes trivial to reason about and test. Alternative rejected: keep `next`'s `run-issues.sh` loop.
- Decided: same user, same machine, operator's own `gh` and `claude` logins. The runner never reads, mints, scrubs or passes a token. Alternative rejected: `next`'s App/JWT/`env -u` design (operator veto).
- Decided (D5): the worker runs under an explicit `--allowedTools` allowlist (`WORKER_ALLOWED_TOOLS`, default `Read,Edit,Write,Glob,Grep,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git add:*),Bash(git commit:*)`; the project appends its test commands). No `git push`, no `gh`, no `--dangerously-skip-permissions`. `WORKER_PERMISSIONS=bypass` is a fallback the operator selects only if proof task 8.5 shows the allowlist cannot work. UNVERIFIED: that a `-p` session denies unlisted tools instead of hanging, and which of `--permission-mode acceptEdits|dontAsk` is needed; task 8.5 decides. Alternative rejected: bypass by default (`next`, `main`'s plist).
- Decided: the worker only commits; the runner verifies, pushes, opens the PR and swaps labels. Reason: the only way "never commits a red build" is true is the runner running the gate (R10.qa.F6). Under the allowlist the worker has no push or `gh` tool; the guard and the runner's git-state check are the backstop.
- Decided: the runner's `VERIFY_CMD` result overrides the worker's `done`. A worker that claims success with a red gate gets `blocked`.
- Decided: headless prompt is a separate short template, not the interactive template with a preamble. Reason: the interactive template has seven steps for a self-pacing loop; the headless worker has one issue and no GitHub writes. Two prompts can drift, so both are small and both are tested for their key lines. The interactive template stays verbatim in the target repo; `setup.sh` renders `loop/loop-prompt.md` from it and `loop.conf` (closes R10.qa.F5, where re-cutting rewrote the tracked template).
- Decided (D4): the guard is scoped to the worker. The runner generates a settings file holding only the guard and passes it with `--settings`; `setup.sh` does not write the guard (or the review hook) into `.claude/settings.json` unless run with `--interactive`, which exists for a repo where the operator chose to run an interactive loop session. In the-grid, `--interactive` is never run: the operator's own merge-on-green sessions must not be blocked by `gh pr merge` rules. User-level settings and CLAUDE.md still load (no `--setting-sources`). See Risk 1.
- Decided (D6): the worker prompt states the session is unattended with no human, so check-in, confirm-scope and ask-first rules do not apply; ambiguity ends the run with `needs-human`. The runner does not read `role.yaml`; roles already marked `unattended: true` carry their own safe-target and run-record rules.
- Decided: no `--max-turns` (not in the CLI). The caps are `--max-budget-usd`, `ISSUE_TIMEOUT`, `MAX_ISSUES_PER_DAY`. Closes R10.qa.F12.
- Decided: `--session-id <uuid>` (from `/proc/sys/kernel/random/uuid`, else `uuidgen`, else omitted) and `-n issue-N`, so the transcript can be found and the session is listable. The session id goes in the run-record note.
- Decided: trust gate = author association only (see proposal 5). gh-triage runs under the operator's login, so "who applied the label" cannot distinguish human intent from the triage agent and is not used.
- Decided: role label is `agent:<name>` (`agent:grid-backend-dev`), not `role:`. No label = generic session (no `--agent`).
- Decided: `ISSUE_LABEL` default is `ready-for-agent` everywhere (the `main` default `agent-ready` is a bug).
- Decided: profiles are `personal` (direct, interactive only), `work` and `mac-mini` (pr). The `linux` profile of `next` is dropped (its content was the OS-user setup). `--mode` overrides.
- Decided: waker is `exec bash run-issue.sh`, not a detached child: the cron child IS the runner, so `ps`/`kill` work and the next tick sees the lock.
- Decided (D11): `instantiate.sh --waker-interval` defaults to 15; the printed text and the README say the floor is 60 minutes and the line must not be installed until B3 passes. Group 12 removes that wording only after the B3 proof. B2's own proof runs `wake.sh` by hand; it installs nothing.
- Decided: `render-schedule.sh` gains `every:N` (N = 1..59 minutes) for `render_crontab_line` only. `render_systemd_timer` and `render_launchd_plist` return 2 for it ("every: is cron-only"). Existing `daily`/`weekly` output must stay byte-identical (regression test). Reason: smallest change that lets the waker be rendered the way the operator asked.
- Decided (B3): infra failure keeps the opt-in label and exits 1; `backoff` is written with `fails+1` and `until = now + min(15min * 2^(fails-1), 6h)`; any run that reaches an issue-level outcome clears it. A rate-limit signal in the worker output or stderr (pattern list in `run-issue.sh`, UNVERIFIED against the real CLI) records outcome `stopped` with note `rate-limited` and sets the backoff directly. Three consecutive infra failures on the same issue (`issue_fails`) mark it `blocked` (poison-issue rule, R10.qa.F4).
- Decided (B3): stale lock = `lock/pid` names a dead process (`kill -0` fails with ESRCH; EPERM counts as alive), or names a live process whose command line does not contain `run-issue.sh` (pid reuse, `ps -p PID -o command=`), or `lock/` has no `pid` and is older than 10 minutes. Reclaim is `mv lock lock.stale.$$` (atomic) then `mkdir`. Tests control time through `GRID_LOOP_NOW` (epoch seconds, read only when set). B1 does none of this: a held lock exits 0 and prints the pid and the path.
- Decided: restoring `gh-triage-to-issue-loop.md` means a generic rewrite of the two ideas that matter (the join is the `ready-for-agent` label; the loop never classifies, it reads the Agent Brief), not a copy. A verbatim copy fails the personal-data gate and reverses `depersonalise`. The original stays in the private archive.

## Alternatives rejected

- **Keep `next`'s runner and strip the security code.** 774 lines, never run, 32 defects; stripping leaves the trust-gate plumbing and token helpers' shape everywhere. A 250-line single-issue runner is easier to prove.
- **Keep `main` as is and add only a guard.** Leaves the verify gap, no PR mode, no caps, `--dangerously-skip-permissions` in a plist with no timeout.
- **Runner posts an Opus review** (`next`). Adds a model call, cap and failure mode per PR; operator's standing independent-QA process covers it.
- **systemd/launchd waker.** `every:N` for cron is the smallest additive change; launchd `StartInterval` can follow after the Mac test.
- **Detached waker child with nohup.** Hides the PID behind a double fork for no benefit.

## Risks

1. **Operator's global `CLAUDE.md` rules reach the headless worker.** The operator's rules include "pause after every 3 tool calls and wait for a go-ahead", "ask before acting", "confirm scope". In `-p` mode nobody answers. The worker prompt states that no human is present and those rules do not apply, and a proof run (task 3.6) does more than three tool calls without stopping. UNVERIFIED whether a prompt instruction overrides them; if not, the fallback is `--bare` (skips hooks and memory; also skips the guard, so rejected) or a repo-level override, to be decided after the proof.
2. **cron has no desktop session.** `gh auth status` here reports the token comes from the keyring. A cron job may not reach the keyring. B2 task 9.5 proves or disproves this in a stripped environment before the cron line is installed.
3. **Worker runs as the operator.** Under the allowlist it has no `gh` or `git push` tool, but a Bash prefix rule is not a sandbox and `bash -c` can dodge the guard. Mitigations: the guard (mistake-catcher only); the only merge path is a human; branch protection on the base is the real boundary. With `WORKER_PERMISSIONS=bypass` the worker can run any `gh` call the guard does not block. Stated in the pattern README.
4. **Waker before backoff.** Installing the cron line before B3 means a persistent infra failure is retried every tick. B2 code may merge first; the cron line stays uninstalled until B3 passes (D11), and the floor is 60 minutes until then.
5. **Verify output in a public issue comment.** The last 40 lines of a failing gate go in a comment. A test that prints a secret would publish it. Mitigation: cut to 3000 bytes; the repo's commit-time secret scan does not see comments. Residual, documented.
6. **`runs.log` day counting uses local date.** A TZ change moves the boundary. Accepted.

## UNVERIFIED (to be proven by the tasks, not assumed)

- `claude -p --output-format json` field names (`is_error`, `subtype`, `total_cost_usd`) and the subtype for an exhausted `--max-budget-usd`.
- The real rate-limit signal from `claude -p` (text, exit code, JSON).
- That tracked `CLAUDE.md` is auto-loaded from the worktree cwd in a headless run.
- That `--settings <file>` adds the guard hook alongside user-level hooks.
- That `PURPOSE.md` and `MAP.md` are read before editing in a headless run (they exist only after A1; the proof uses a throwaway repo with canary files).
- `--agent` plus `--model`: which wins.
- `gh` and `claude` authentication under cron.
- Whether `.github/CODEOWNERS` or branch protection exists on this repo (not needed by the loop; relevant to the PR-only rule).
