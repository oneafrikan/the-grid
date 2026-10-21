# Pattern: issue-loop

An agent that works a repo's labelled GitHub issues and hands a verified pull request to a human (or, with `MODE=direct`, lands the verified commit on the base branch itself). It never merges and never classifies issues: [gh-triage](../../docs/gh-triage-to-issue-loop.md) classifies and writes the Agent Brief, the loop reads it. Same user, same machine: it uses the operator's own `gh` and `claude` logins, with no separate OS user, no GitHub App and no token handling.

It runs two ways from the same cut:

- **Headless, one issue per run:** `bash loop/run-issue.sh`. A small script with a real PID, started by hand.
- **Interactively:** a `/loop` session you watch, using `loop/loop-prompt.md`.

| Piece | File | Role |
|---|---|---|
| runner | `run-issue.sh` | Lock, caps, gates, role routing, worktree, headless `claude -p` worker, **runner-side verify**, push, PR, labels, run record. |
| worker prompt | `worker-prompt.template.md` | The headless prompt for one issue. The worker only commits. |
| interactive prompt | `loop-prompt.template.md` | The `/loop` prompt with a `pr` and a `direct` block. Copied verbatim into the target; `setup.sh` renders `loop/loop-prompt.md` from it. |
| config | `loop.conf.template` | Rendered once into `loop/loop.conf`, the single source of config. |
| guard | `hooks/guard-main-push.sh` | PreToolUse mistake-catcher for pushes and merges. Reaches the worker only through the runner's per-run `--settings` file. |
| cron wrapper | `cron-run.sh` | What the cron line runs: sources `loop/cron.env` (PATH, HOME), then `exec`s the runner. |
| watch and drain | `status.sh`, `drain.sh` | `status.sh`: read-only one-screen view of the queue, lock, backoff and recent runs. `drain.sh`: runs the runner repeatedly until the queue is empty. |
| fast verify | `verify.sh` | Optional `VERIFY_CMD`: shellcheck, Python syntax, related bats, Markdown and rules lint on what changed. |
| worktree helper | `hooks/new-agent-worktree.sh` | Cuts `issue-<N>` worktrees off `origin/<base>`. |
| review hook | `hooks/post-commit-review.sh` | PostToolUse: reviews each commit of an interactive session and comments on the PR or issue. Stands down in headless runs. |
| wiring | `setup.sh`, `.gitignore` | Renders the prompt, self-tests the guard. `--interactive` wires hooks into the repo's settings. |

## Instantiate it into a target repo

```bash
bash scripts/instantiate.sh issue-loop <target-repo> --profile <personal|work|mac-mini> [options]
```

| Profile | Default mode | Runner, guard, worktree helper |
|---|---|---|
| `personal` | `direct` (interactive `/loop` only) | no |
| `work` | `pr` | yes |
| `mac-mini` | `pr` | yes |

Options: `--repo`, `--issue-repo`, `--base-branch` (default: `origin/HEAD`'s branch, else `main`), `--mode pr|direct`, `--land pr|direct`, `--verify-cmd`, `--label` (default `ready-for-agent`), `--project-context`, `--review-focus`, `--setup-cmd`, `--worker-model`, `--agent-labels a,b`, `--fast-verify`, `--cron-every N`, `--cron-log <file>`. Run it with no arguments for the list. It needs an authenticated `gh` (to create labels).

`--mode direct` (and the `personal` profile) is the interactive `/loop` with no runner. `--land direct` is the headless one: the cut ships the same runner files as `pr` and renders `MODE='direct'` into `loop.conf`, so the runner lands the verified commit on the base branch with no PR (see "Direct mode"), and `--cron-every` is allowed. `--land` works with any profile and conflicts with a different `--mode`; `--cron-every` is refused for the interactive mode.

What it does, idempotently (a second identical run prints no `wrote:` line):

- copies the pattern into a tracked top-level `loop/` folder, files verbatim;
- renders `loop/loop.conf` **once**; a re-run says "left alone" and never overwrites your edits. An existing `loop/loop.conf`, or else `loop/loop.conf.seed` (the project factory's defaults), supplies any value you did not pass;
- runs `bash loop/setup.sh`;
- creates, if absent, the opt-in label, `ready-for-human`, `needs-human`, `blocked` and one `agent:<name>` label per `--agent-labels` entry, in the issue repo;
- appends `.claude/settings.json` to the target's `.gitignore` once;
- writes a `CLAUDE.md` only if there is none.

It writes no scheduler file and no hook entry into `.claude/settings.json`. With `--cron-every` it also writes the gitignored `loop/cron.env` and prints a crontab line (see "Unattended").

## `loop/loop.conf`

Tracked, plain assignments, **no secrets**. Every line is `KEY=${KEY:-'value'}`, so an exported variable of the same name overrides the file for one run.

| Key | Default | Meaning |
|---|---|---|
| `GH_REPO` | detected from `origin` | `owner/name`: code, branches, pushes, PRs |
| `ISSUE_REPO` | `GH_REPO` | `owner/name` the issues are read from. Set it to a private tracker when issue text must not be public |
| `BASE_BRANCH` | `origin/HEAD`'s branch, else `main` | PR target and worktree base |
| `ISSUE_LABEL` | `ready-for-agent` | opt-in label |
| `MODE` | by profile | `pr`: push `issue-<N>` and open a draft PR. `direct`: no PR, the runner pushes the verified commit to `BASE_BRANCH` (see "Direct mode") |
| `VERIFY_CMD` | empty | run by the **runner**; empty means the runner refuses to start |
| `VERIFY_TIMEOUT` | `900` | seconds |
| `SETUP_CMD` | empty | run in each worktree before the worker (for example `npm ci`) |
| `PROJECT_CONTEXT`, `REVIEW_FOCUS` | prompted | one-liners for the prompts and the review hook |
| `WORKER_MODEL` | `sonnet` | always passed as `--model` |
| `MAX_BUDGET_USD` | `5` | worker `--max-budget-usd`, always passed |
| `ISSUE_TIMEOUT` | `1800` | seconds, worker |
| `WORKER_EXIT_GRACE` | `30` | seconds a worker may keep running after writing a valid outcome; then the runner stops its process group and carries on as if it had exited |
| `WORKER_PERMISSIONS` | `allowlist` | `allowlist`, or `bypass` (a fallback, see below) |
| `WORKER_ALLOWED_TOOLS` | `Read`, `Edit`, `Write`, `Glob`, `Grep` and `Bash(git <sub>:*)` for status, diff, log, show, add, commit | passed as `--allowedTools`; the runner appends `Bash(<VERIFY_CMD>:*)` itself (the worker is told to run it), unless that entry is already listed or `VERIFY_CMD` contains `,` or `)` (skipped with a warning); add any other test commands. No `git push`, no `gh` |
| `MAX_ISSUES_PER_DAY` | `0` | daily cap on issues handled; `0` means unlimited |
| `TRUST_GATE` | `on` | `on`: only OWNER, MEMBER or COLLABORATOR issues and briefs are read |
| `RUN_ROLE` | `issue-loop` | run-record role when the issue has no `agent:` label |

There is no `--max-turns`: the CLI has no such flag. The caps are spend, wall clock and the daily count. `WORKER_PERMISSION_MODE` (optional, empty by default) is passed as `--permission-mode` when set.

Worktrees live in `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}/issue-<N>`, outside the repo.

## The runner

`bash loop/run-issue.sh [issue-number]` handles exactly one issue. **The first run is started by hand.** Exit codes: **0** for any issue-level outcome (PR opened or commit landed, refused by a gate, blocked, needs-human) and for "nothing to do", "busy", "backing off" and "daily cap reached"; **1** for an infrastructure failure (the issue keeps its label, and the next tick backs off); **2** for a preflight or usage problem (nothing touched, one stderr line names the fix).

Order of events:

1. Preflight: `MODE` is `pr` or `direct`, `VERIFY_CMD` set, `git gh jq claude timeout` present, the guard script present and executable. A tick inside the backoff window exits 0 here.
2. Lock (`<git-common-dir>/issue-loop/lock`; a stale one is taken over), then the daily cap (if `MAX_ISSUES_PER_DAY` is above 0), then both logins and `origin` (a failure here is infrastructure, exit 1), then pick the lowest-numbered open issue carrying the label.
3. Gates before any model call: `severity:critical|high` goes to `ready-for-human`; an existing PR or remote `issue-<N>` branch goes to `ready-for-human`; with `TRUST_GATE=on` a stranger's issue goes to `needs-human`.
4. Role routing from an `agent:<name>` label.
5. A worktree off `origin/<base>`, `SETUP_CMD`, then the worker: `claude -p` with `--model`, `--max-budget-usd`, `--output-format json`, `--allowedTools`, a per-run `--settings` file holding only the guard, `--session-id` and `-n issue-<N>`, under `timeout -k 30 ISSUE_TIMEOUT`.
6. Git-state check (on `issue-<N>`, clean, at least one commit ahead), then the **runner runs `VERIFY_CMD` itself**. The worker's own `done` never substitutes for it.
7. `MODE=pr`: push `HEAD:refs/heads/issue-<N>` (never the base), `gh pr create`, swap labels, comment the PR URL, one `run-record.sh` line. The issue stays open.
   The PR is opened as a draft: CI does not run until it is marked ready for review, and the operator marks it ready (`gh pr ready <n>`) when it is time to merge.

Outcomes:

| Result | Labels | Run record |
|---|---|---|
| PR opened | `ready-for-agent` out, `ready-for-human` in | ok |
| worker says `needs-human <reason>`, or a gate refuses a stranger | `needs-human` | skipped |
| severity label, or an existing PR or branch | `ready-for-human` | skipped |
| verify failed, no commit, wrong branch, dirty tree, timeout (uncommitted work is saved as a WIP commit on local `issue-<N>`), spend cap, worker `blocked`, refused agent, setup or worktree failure, direct-mode rebase conflict or rejected push | `blocked`, with the reason in a comment | error |
| commit landed (`MODE=direct`) | `ready-for-agent` out, `ready-for-human` in, issue closed | ok |
| infrastructure failure: claude or gh logged out, gh or origin unreachable, `gh pr list` failing, a worker cut off by a usage or rate limit | unchanged | error, exit 1, backoff |

With issues in a different repo (`ISSUE_REPO`), every issue call targets the tracker and every push and PR call targets the code repo. The PR body is only `refs <tracker>#<N>` and the PR title is a fixed `issue-loop: work for <tracker>#<N>` (with issues in the same repo the title is the worker's commit subject): the issue title and body never reach the PR text. The worker prompt also tells it not to quote the issue in commit messages and not to end them with `#<N>` in this mode (that number would cross-link an unrelated item on the code repo); the prompt is a request, and the commit messages themselves are pushed to the code repo as the worker wrote them.

State lives in `<git-common-dir>/issue-loop/`: `lock/` (with `pid`, `issue`, `started`, `worker`), `runs.log` and `backoff`.

### Direct mode

`MODE=direct` is for a repo where the operator wants no PRs. After the runner's own `VERIFY_CMD` passes it fetches the base, rebases `issue-<N>` onto `origin/<BASE_BRANCH>` if the base moved (and runs `VERIFY_CMD` again, because the rebased tree is not the one that was verified), then pushes `HEAD:refs/heads/<BASE_BRANCH>` without force. It comments the short sha on the issue, swaps `ready-for-agent` for `ready-for-human` and closes the issue. A rebase conflict or a rejected push (branch protection, a base that moved again) labels the issue `blocked`, comments, pushes nothing and keeps the work on the local branch `issue-<N>`. The worker still cannot push; only the runner does, and the guard still blocks the worker from pushing to the base. With issues in another repo the commit message carries `refs <tracker>#<N>` as in `pr` mode, and the comment is on the tracker.

There is no review step: **branch protection and the `VERIFY_CMD` gate are the only checks**, so use direct mode only where the base branch can take unreviewed commits. The runner writes `<state>/landed.<N>` (the commit sha) just before the push. If `gh` fails, or the runner is killed, between the push and the label swap, the issue keeps `ready-for-agent`; the next run that picks it finds the marker, sees the sha on `origin/<base>`, and finishes the label swap, comment and close **without working the issue again**. A marker whose sha is not on the base (the push never happened or was rejected) is dropped. Files that `VERIFY_CMD` rewrote in the worktree are discarded before a rebase, so a regenerated lockfile or snapshot does not turn a clean rebase into a "conflict".

### Failures that are not the issue's fault

A logged-out `claude` or `gh`, an unreachable `gh` or `origin`, a failing `gh pr list`, and a worker whose error result or stderr shows a login, key, network or usage/rate-limit failure are infrastructure: the runner exits 1, the issue keeps `ready-for-agent`, and `backoff` records `until=<epoch> fails=<n>`. Ticks inside the window exit 0 quietly. The window is 15 minutes after the first failure and doubles with each consecutive one, up to 6 hours. Any issue-level outcome or an empty queue clears it, and `run-issue.sh <N>` ignores it. Verify failures, worker `blocked`, timeouts and the like still mark the issue `blocked` or `needs-human`.

The service patterns (`SERVICE_RE` in `run-issue.sh`) read only the worker's stderr and its result text when that result is an error: a normal final answer is never probed, so an issue about rate limiting is not mistaken for an outage. Checked against claude 2.1.305 (real output, captured by pointing it at an empty config dir, a dummy API key, and a closed port):

| Case | Result text | Exit |
|---|---|---|
| not logged in | `Not logged in · Please run /login` | 1 |
| invalid key | `Invalid API key · Fix external API key` | 1 |
| unreachable API | `API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)` | 1, after about 3 minutes of internal retries |

Not captured, patterns are best guesses: a real usage or rate limit and an overloaded API (they cannot be provoked without spending money or exhausting the account). An unknown model name was not captured either (the CLI warns on stderr and proceeds). With `HTTPS_PROXY` on a closed port claude printed nothing for 150 s: such a worker ends at `ISSUE_TIMEOUT`. A timeout where the worker printed no result and left no edit and no commit is therefore treated as an outage (label kept, backoff, no poison count); a worker that timed out after producing work is saved as a WIP commit and the issue is marked `blocked`.

**Poison issue.** A worker failure the service patterns do not explain (a crash, or an error result with no login, key, network or limit text) is counted per issue in `backoff` (`issue=<n> issue_fails=<n>`). The third in a row on the same issue marks it `blocked` with one comment and the queue moves on. Outages and limits never count, and any issue-level outcome or an empty queue clears the counter. If the relabel itself fails, the normal backoff applies instead.

A lock whose recorded pid is gone, or now belongs to something that is not a `run-issue.sh`, or that has no pid file and is older than 5 minutes, is taken over with a log line (a crash, SIGKILL or reboot). The takeover first stops the dead runner's orphaned `claude` worker (the pid in `lock/worker`, only if its command line contains `claude`), and hands the lock back if its pid changed during the takeover. A live runner keeps the lock and the new tick exits 0 "busy".

## Unattended: one cron line per repo

```bash
bash scripts/instantiate.sh issue-loop <repo> --profile work [--land direct] --cron-every 15 [--cron-log <file>]
```

Prints one crontab line for that repo (poll every N minutes, 1-59) and the command that adds it. Run it once per repo; each repo has its own `loop/`, lock and log, so repos run concurrently and a repo never overlaps itself. The guard against overlap is the runner's lock: a tick that finds it held exits 0 "busy".

- The log defaults to `~/.grid/logs/issue-loop-<repo>.log` (`--cron-log` overrides), appended by the line.
- The line runs `bash loop/cron-run.sh`, which sources `loop/cron.env` and `exec`s `run-issue.sh`. `cron.env` holds `HOME` and a `PATH` that includes the directories of `gh`, `claude`, `jq`, `git`, `awk` and `timeout`, resolved when you ran the install. It is machine-local and gitignored. Re-run the install after moving a tool or the repo.
- Nothing is installed for you: `instantiate.sh` never runs `crontab`. The activation command it prints is idempotent (pasting it twice leaves one copy).
- Check the environment before trusting it: run the printed line's command under `env -i HOME=$HOME PATH=/usr/bin:/bin sh -c '...'` (everything after the five time fields) and read the log. It should show the runner's own messages, not "command not found".

Backoff, the poison-issue rule and stale-lock takeover are described under "Failures that are not the issue's fault".

## Watching and draining

Both ship in the runner cuts (`pr`, and `direct` via `--land`) next to `run-issue.sh`, verbatim and executable. Neither is scheduled or installed by anything.

- `bash loop/status.sh [path/to/loop.conf]` is read-only (no file, fetch, label or lock is written) and exits 0 unless `loop.conf` cannot be read (exit 2). With a path it reads that config and the state of the repo that owns it. It prints, on one screen:
  - open issues per label in `ISSUE_REPO` (the opt-in label, `ready-for-human`, `blocked`, `needs-human`) and the issue the runner would pick next;
  - the lock: pid, whether it is alive and is a `run-issue.sh`, and whether it is stale;
  - the backoff window (until when, failure counts, the poison-issue counter);
  - the last 10 `work-issue` records for this `ISSUE_REPO` from the run log (`GRID_RUN_LOG`, default `~/.the-grid-private/runs.jsonl`) and today's cost (UTC date, as the records are UTC);
  - open `blocked` and `needs-human` issues by title, and the last commit on `BASE_BRANCH` (from `gh`, else the local copy).
- `bash loop/drain.sh` runs `run-issue.sh` again and again, one at a time, with your environment, and prints one line per run (issue, outcome, elapsed). It stops when the queue is empty, when the runner exits non-zero (infrastructure failure: it reports it and exits 1; the backoff is already recorded), when the runner answers "busy", "backing off" or "daily cap reached", or when the same issue comes back twice in a row. Ctrl-C stops the runner cleanly and exits 130. It adds no cap of its own. "An issue was handled" is read from the runner's `runs.log`, not from its text; the text only names why it stopped.

## Fast verify

`VERIFY_CMD` is whatever your repo's gate is. When the full suite is too slow for a loop run, select the shipped `loop/verify.sh`: `--fast-verify` at install time, or `VERIFY_CMD='bash loop/verify.sh'` in `loop/loop.conf`. An explicit `--verify-cmd` wins over `--fast-verify`. It checks only what the branch changed against `origin/<BASE_BRANCH>` (override with `VERIFY_BASE`), and skips a step whose tool is absent, saying so:

- `shellcheck` on changed shell scripts;
- a syntax check on changed Python files;
- the changed `tests/*.bats`, plus every test that mentions a changed script by name (`tests/lib/bats-core`, else `bats` on `PATH`);
- changed Markdown: no leftover `<<<<<<<` / `>>>>>>>` conflict markers;
- `python3 scripts/rules.py lint` when files under `rules/` changed and that script exists.

It exits 1 when nothing has changed. It is a sanity pass, not a replacement for CI on the pull request, which stays the authoritative gate. Bash 3.2 compatible.

## Role routing

Label an issue `agent:<name>` (for example `agent:grid-backend-dev`) and the worker runs as `claude -p --agent <name>`. No label means a generic session. These end `blocked` with a comment, no worktree and no model call: a name with characters outside `[A-Za-z0-9._-]`, two `agent:` labels, no `<name>.md` in `~/.claude/agents` (or `$AGENTS_DIR`) or `.claude/agents`, or an agent whose frontmatter `tools:` line names neither `Edit` nor `Write` (read-only roles cannot build). The run record's role is the routed agent, else `RUN_ROLE`.

## Hooks

- **Guard** (`hooks/guard-main-push.sh`): blocks, with exit 2, a `git push` whose refspec names `main`, `master` or the base branch (quoted and path-qualified forms too); a bare push while on one of those; `--force`, `-f`, `--force-with-lease`, `--mirror`, `--all`; `gh pr merge`; and `gh api` calls with `/merge` or a PUT, PATCH or DELETE method. It uses the shared parser in `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` when present, else a built-in splitter; both give the same answers on the decision table.
- **Review hook** (`hooks/post-commit-review.sh`): reviews each commit of an interactive session once, from the payload's working directory, capped (`--model`, `--max-budget-usd`, `--tools ""`). It stands down when `GRID_LOOP_HEADLESS=1` (the runner sets it for the worker) or `GRID_REVIEW_RUNNING=1`.
- **setup.sh:** by default it renders `loop/loop-prompt.md` and self-tests the guard, and writes nothing to `.claude/settings.json`. `--interactive` wires the review hook and the guard into the repo's settings for a session you chose to run interactively; `--unwire` removes only those entries.

**The guard is not installed in the-grid's own `.claude/settings.json`, on purpose:** it blocks `gh pr merge`, and the operator's own sessions in the-grid merge reviewed PRs. In every repo the guard reaches the worker only through the runner's per-run settings file; `--interactive` is for a repo where you decided an interactive loop session should be guarded too.

### Known gaps

- The guard is a mistake-catcher, not a boundary. On the built-in parser `bash -c '...'` and `eval` are not inspected (the shared parser unwraps them once); shell aliases and scripts that call git internally are not inspected on either path.
- The built-in splitter (used when `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` is absent, as in a business repo with no the-grid checkout) only sees a command whose first word is `git` or `gh`. It lets through, checked by running it: a subshell `(git push origin main)`, a group `{ git push origin main; }`, a backgrounded `sleep 1 & git push origin main`, a wrapper such as `sudo`, `env`, `command`, `time` or `xargs` before `git push ...`, and a substitution `echo $(git push origin main)`. The shared parser blocks all of these.
- On BOTH parsers a merge made through `gh api graphql` (a `mergePullRequest` mutation) is not recognised; only `gh pr merge` and `gh api` calls with `/merge` or a PUT, PATCH or DELETE method are.
- With `WORKER_PERMISSIONS=bypass` the worker can run any `gh` call the guard does not block.
- The runner runs `VERIFY_CMD` on worker-authored files (for example a conftest) as the operator, outside the allowlist and guard.
- The failing-gate tail (3000 bytes) is posted to the tracker; if the tracker is public and the code repo is private, private output leaks.
- Issue text is in the worker argv, so it is visible via `ps` to local users.

## What the worker can and cannot do

The worker runs as you, with your `gh` and `claude` logins, in a throwaway worktree. Under the default `allowlist` it has file tools and `git add|commit|status|diff|log|show` plus your `VERIFY_CMD` (added by the runner) and whatever other test commands you add; it has no `git push` and no `gh`. An unlisted Bash command is denied without a prompt or a hang, which also denies any other command your tests run and any command your global Claude rules make a session run (a git identity check, for example): name them in `WORKER_ALLOWED_TOOLS`, or the worker cannot run its checks and ends `blocked`. That is a permission list, not a sandbox: a Bash prefix rule can be dodged, and the guard only catches the obvious mistakes. What bounds the damage is that the loop only opens pull requests and a human merges: **put branch protection on the base branch**. `WORKER_PERMISSIONS=bypass` (`--dangerously-skip-permissions`) is a fallback the operator chooses only if the allowlist cannot complete a normal task.

The issue text is the worker's whole task, so it must come from someone trusted: with `TRUST_GATE=on` the issue's author, and the author of any Agent Brief that is read, must be OWNER, MEMBER or COLLABORATOR. If the verify output of a failing gate contains a secret, its last 40 lines (at most 3000 bytes) go into an issue comment.

## Why each decision was made

- **Label-gated selection, lowest number first.** A human (or gh-triage) opts each issue in.
- **The runner verifies, pushes and opens the PR.** The only way "never commit a red build" is true is the runner running the gate itself.
- **One issue per invocation.** Lock, cleanup, record and exit codes are trivial to reason about and to test.
- **Guard scoped to the worker.** Per-run `--settings`, so the operator's own sessions are never blocked.
- **Tracked `loop/` folder, not `.claude/`.** The automation survives a clone or a move; only `.claude/settings.json` is machine-local.
