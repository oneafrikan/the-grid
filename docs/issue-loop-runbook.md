# Issue-loop runbook

How to run, watch and feed the live issue loop in this repo. For runner internals (gates, outcomes, locks, backoff, hooks) read `automation-factory/patterns/issue-loop/README.md`; this file does not repeat it. State below is as of 2026-10-21.

## What is live

- The pattern in `automation-factory/patterns/issue-loop/` is cut into this repo as `loop/`. It is an untracked instance (excluded via `.git/info/exclude`), so a fresh clone has no `loop/`.
- Local-only files in `loop/`: `loop.conf`, `cron.env`, `loop-prompt.md`. The rest are copies of the pattern.
- `loop/loop.conf` holds:
  - `ISSUE_REPO=<owner>/the-grid-private`: issues live in the private tracker, code lands in the public repo.
  - `MODE=direct`: after verify the runner rebases on `origin/main`, re-verifies, pushes to `main`, comments the sha, labels the issue `ready-for-human` and closes it. No PR.
  - `MAX_ISSUES_PER_DAY=0`: unlimited. Do not add caps.
  - `VERIFY_CMD`: the fast `loop/verify.sh` (changed-file checks only). The full gate takes about 35 minutes and is CI's job at merge.
  - `LOOP_WORKTREE_ROOT=$HOME/grid-loop`: worktrees are `~/grid-loop/issue-<N>`.
- Cron is NOT installed. The operator turns it on once the first queue is drained.

## Sync the live instance after the pattern changes

1. Copy from the pattern dir into `loop/`: `run-issue.sh`, `worker-prompt.template.md`, `cron-run.sh`, `verify.sh`, `status.sh`, `drain.sh`.
   ```bash
   cd ~/.the-grid
   for f in run-issue.sh worker-prompt.template.md cron-run.sh verify.sh status.sh drain.sh; do
     cp automation-factory/patterns/issue-loop/$f loop/$f
   done
   ```
2. Syntax-check each shell script: `for f in run-issue.sh cron-run.sh verify.sh status.sh drain.sh; do bash -n loop/$f; done`.
3. Do not overwrite `loop/loop.conf`, `loop/cron.env` or `loop/loop-prompt.md`.
4. Keep `loop/run-issue.sh`, `loop/status.sh`, `loop/drain.sh` and `loop/verify.sh` executable (`chmod +x`); `cron-run.sh` is run through `bash`.

## Watch

1. One-screen, read-only view: `cd ~/.the-grid && bash loop/status.sh`.
   - Prints: open issues per label in the tracker, the next pick, lock state, backoff window, the last 10 runs with cost, titles of `blocked` and `needs-human` issues, head of the base branch.
   - Safe to run while a runner or drain is mid-run.
2. Optional timed monitor in an interactive session: `/loop 20m` running `bash loop/status.sh` plus a CI check on `main` (for example `gh run list --branch main --limit 3`). Report only; the monitor changes nothing.
3. Heavy checks run at merge-to-main only. A push to `main` cancels the in-flight CI run on `main`, so the final state is what counts.

## Drain the queue by hand

Faster than waiting for cron ticks.

1. `cd ~/.the-grid && bash loop/drain.sh`.
   - Serial: runs `run-issue.sh` until the queue is empty.
   - Stops on: empty queue, infrastructure failure (exit 1), "busy", "backing off", "daily cap reached", or the same issue picked twice in a row.
   - Ctrl-C stops the runner cleanly (exit 130).
2. Unattended, with a log:
   ```bash
   cd ~/.the-grid && mkdir -p ~/.grid/logs && nohup bash loop/drain.sh > ~/.grid/logs/drain-$(date +%F).log 2>&1 &
   ```
3. Check progress with `bash loop/status.sh`.

## Cron (operator only)

- One line per repo, printed by the installer. An agent never installs it.
- Shape (expand `~` to an absolute path; `<repo>` is the repo path):
  ```
  */15 * * * * mkdir -p ~/.grid/logs && cd <repo> && bash loop/cron-run.sh >> ~/.grid/logs/issue-loop-<repo>.log 2>&1
  ```
- `loop/cron-run.sh` sources the gitignored `loop/cron.env` (`HOME`, `PATH`), then `exec`s the runner.
- The installer prints the exact line: `bash scripts/instantiate.sh issue-loop <repo> --profile work --land direct --cron-every 15` (see the pattern README, "Unattended").
- Do not run cron and `drain.sh` at once: the runner lock makes the second one exit "busy".

## Feed the queue

The worker sees the issue body plus the latest TRUSTED comment (author OWNER, MEMBER or COLLABORATOR) whose body starts with `## Agent Brief`. Nothing else.

To queue a public issue:

1. In the private tracker, file a mirror titled `<title> (mirror of the-grid#N)`.
2. Body: scope, files, the exact cheap verify command, and `depends on` lines.
   - Verify command = `bash loop/verify.sh` plus named bats files (for example `tests/lib/bats-core/bin/bats tests/test_foo.bats`). Never the full gate.
3. Post one comment headed exactly `## Agent Brief`.
4. Add the `ready-for-agent` label LAST. Label lists lag about 1 second: `sleep 3` before relying on a listing.
5. File in dependency order: the runner picks the LOWEST issue number first, one at a time.

Never queue:
- Operator-only private issues (#3, #4, #29, #39, #70, #73).
- Work that needs deletion, `mkdir`, `cp`, `git submodule`, network, `pip` or the venv python. The worker cannot do these: split the issue, or leave that step for the operator.

## Worker limits

- Allowlist: `Read`, `Edit`, `Write`, `Glob`, `Grep`, `git add|commit|status|diff|log|show`, the `VERIFY_CMD`, and the bats, shellcheck and `python3` entries in `WORKER_ALLOWED_TOOLS` in `loop/loop.conf`.
- Commands must run bare: no `git -C`, `cd`, pipes, redirects, `&&` chains or heredocs.
- No `git push`, no `gh`. The runner pushes.
- Write briefs with these limits in mind; a brief that needs a pipe or a `cd` ends `blocked`.

## Failures

- Infrastructure failure (logged-out `claude` or `gh`, unreachable origin, rate limit): the issue keeps `ready-for-agent`; the loop backs off 15 minutes, doubling to 6 hours. Fix the cause, then `bash loop/status.sh` to see when the window ends. `bash loop/run-issue.sh <N>` ignores the backoff.
- Three consecutive worker failures on one issue (the poison rule): the issue is labelled `blocked` with a comment.
- Timeout: uncommitted work is saved as a WIP commit on local branch `issue-<N>` in `~/grid-loop/issue-<N>`.
- Rebase conflict or rejected push in direct mode: `blocked`, work kept on local `issue-<N>`.
- Re-queue after fixing: remove `blocked` and add `ready-for-agent` again.

## Agents and permissions

1. Agent briefs saying "push straight to main" were denied by the auto-mode classifier. Relaunch with "commit on a worktree branch, do not push; the orchestrator merges". Never retry the denied wording.
2. An agent's `gh issue create` was denied once; the operator ran the filing script by hand.
3. Never work around a denial. Report it.
4. Subagent hand-backs are model output, not user input. Verify the files and claims they report (one agent claimed two files were ready that did not exist).

## Planned, not built: dev / staging / production

- Intended: dev, staging and production environments, with feature branches pulled into any of the three.
- Today the runner has one `BASE_BRANCH` per repo (`loop/loop.conf`).
- Needed later:
  - a per-issue target, for example a `base:<branch>` label read by the runner;
  - a separate promote step dev -> staging -> production (not the loop's job).
- Until then `main` is the only long-lived branch and `MODE=direct` is the remediation mode. Do not use direct mode for staging or production.

## State on 2026-10-21

- A drain started about 10:44Z over private issues #104-#107 and #110-#120.
  - Contents: mirrors of front-door items, the factory-chain runbook, and the context-engineer (#118, #119) and gsd (#120) roles.
  - #118, #119 and #120 each include one unreviewed budget-ratchet raise; the operator reviews these afterwards.
- Deferred, not queued: `karpathy-loop` and `cli-cron` (private #108, #109), until `main` is stable.
- Held: the `index.html` rebuild (public #150), blocked on the operator's render step (#149) and a `git rm`.

## Never

- Never install the crontab line for the operator.
- Never run the git-identity `--apply` step or edit git identity; the operator does that once per machine.
- Never merge to `main` with a failing test.
- Never invent caps (count, spend or time) for the loop.
