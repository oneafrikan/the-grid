# Pattern: issue-loop

An agent that works a repo's labelled GitHub issues and hands a verified pull request to a human. It never merges and never classifies issues: [gh-triage](../../docs/gh-triage-to-issue-loop.md) classifies and writes the Agent Brief, the loop reads it. Same user, same machine: it uses the operator's own `gh` and `claude` logins, with no separate OS user, no GitHub App and no token handling.

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

Options: `--repo`, `--issue-repo`, `--base-branch` (default: `origin/HEAD`'s branch, else `main`), `--mode pr|direct`, `--verify-cmd`, `--label` (default `ready-for-agent`), `--project-context`, `--review-focus`, `--setup-cmd`, `--worker-model`, `--agent-labels a,b`. Run it with no arguments for the list. It needs an authenticated `gh` (to create labels).

What it does, idempotently (a second identical run prints no `wrote:` line):

- copies the pattern into a tracked top-level `loop/` folder, files verbatim;
- renders `loop/loop.conf` **once**; a re-run says "left alone" and never overwrites your edits. An existing `loop/loop.conf`, or else `loop/loop.conf.seed` (the project factory's defaults), supplies any value you did not pass;
- runs `bash loop/setup.sh`;
- creates, if absent, the opt-in label, `ready-for-human`, `needs-human`, `blocked` and one `agent:<name>` label per `--agent-labels` entry, in the issue repo;
- appends `.claude/settings.json` to the target's `.gitignore` once;
- writes a `CLAUDE.md` only if there is none.

It writes no scheduler file and no hook entry into `.claude/settings.json`.

## `loop/loop.conf`

Tracked, plain assignments, **no secrets**. Every line is `KEY=${KEY:-'value'}`, so an exported variable of the same name overrides the file for one run.

| Key | Default | Meaning |
|---|---|---|
| `GH_REPO` | detected from `origin` | `owner/name`: code, branches, pushes, PRs |
| `ISSUE_REPO` | `GH_REPO` | `owner/name` the issues are read from. Set it to a private tracker when issue text must not be public |
| `BASE_BRANCH` | `origin/HEAD`'s branch, else `main` | PR target and worktree base |
| `ISSUE_LABEL` | `ready-for-agent` | opt-in label |
| `MODE` | by profile | `pr` or `direct`. The runner refuses `direct` |
| `VERIFY_CMD` | empty | run by the **runner**; empty means the runner refuses to start |
| `VERIFY_TIMEOUT` | `900` | seconds |
| `SETUP_CMD` | empty | run in each worktree before the worker (for example `npm ci`) |
| `PROJECT_CONTEXT`, `REVIEW_FOCUS` | prompted | one-liners for the prompts and the review hook |
| `WORKER_MODEL` | `sonnet` | always passed as `--model` |
| `MAX_BUDGET_USD` | `5` | worker `--max-budget-usd`, always passed |
| `ISSUE_TIMEOUT` | `1800` | seconds, worker |
| `WORKER_PERMISSIONS` | `allowlist` | `allowlist`, or `bypass` (a fallback, see below) |
| `WORKER_ALLOWED_TOOLS` | `Read`, `Edit`, `Write`, `Glob`, `Grep` and `Bash(git <sub>:*)` for status, diff, log, show, add, commit | passed as `--allowedTools`; add your test commands. No `git push`, no `gh` |
| `MAX_ISSUES_PER_DAY` | `5` | daily cap |
| `TRUST_GATE` | `on` | `on`: only OWNER, MEMBER or COLLABORATOR issues and briefs are read |
| `RUN_ROLE` | `issue-loop` | run-record role when the issue has no `agent:` label |

There is no `--max-turns`: the CLI has no such flag. The caps are spend, wall clock and the daily count. `WORKER_PERMISSION_MODE` (optional, empty by default) is passed as `--permission-mode` when set.

Worktrees live in `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}/issue-<N>`, outside the repo.

## The runner

`bash loop/run-issue.sh [issue-number]` handles exactly one issue. **The first run is started by hand.** Exit codes: **0** for any issue-level outcome (PR opened, refused by a gate, blocked, needs-human) and for "nothing to do", "busy" and "daily cap reached"; **1** for an infrastructure failure (the issue keeps its label); **2** for a preflight or usage problem (nothing touched, one stderr line names the fix).

Order of events:

1. Preflight: `MODE=pr`, `VERIFY_CMD` set, `git gh jq claude timeout` present, both logins good, `origin/<base>` exists, the guard script present and executable.
2. Lock (`<git-common-dir>/issue-loop/lock`), then the daily cap, then pick the lowest-numbered open issue carrying the label.
3. Gates before any model call: `severity:critical|high` goes to `ready-for-human`; an existing PR or remote `issue-<N>` branch goes to `ready-for-human`; with `TRUST_GATE=on` a stranger's issue goes to `needs-human`.
4. Role routing from an `agent:<name>` label.
5. A worktree off `origin/<base>`, `SETUP_CMD`, then the worker: `claude -p` with `--model`, `--max-budget-usd`, `--output-format json`, `--allowedTools`, a per-run `--settings` file holding only the guard, `--session-id` and `-n issue-<N>`, under `timeout -k 30 ISSUE_TIMEOUT`.
6. Git-state check (on `issue-<N>`, clean, at least one commit ahead), then the **runner runs `VERIFY_CMD` itself**. The worker's own `done` never substitutes for it.
7. Push `HEAD:refs/heads/issue-<N>` (never the base), `gh pr create`, swap labels, comment the PR URL, one `run-record.sh` line. The issue stays open.

Outcomes:

| Result | Labels | Run record |
|---|---|---|
| PR opened | `ready-for-agent` out, `ready-for-human` in | ok |
| worker says `needs-human <reason>`, or a gate refuses a stranger | `needs-human` | skipped |
| severity label, or an existing PR or branch | `ready-for-human` | skipped |
| verify failed, no commit, wrong branch, dirty tree, timeout, spend cap, worker `blocked`, refused agent, setup or worktree failure | `blocked`, with the reason in a comment | error |
| infrastructure failure (claude, gh, git, network) | unchanged | error, exit 1 |

With issues in a different repo (`ISSUE_REPO`), every issue call targets the tracker and every push and PR call targets the code repo. The PR title is the worker's commit subject and its body is only `refs <tracker>#<N>`: the issue title and body never appear in the PR.

State lives in `<git-common-dir>/issue-loop/`: `lock/` (with `pid`, `issue`, `started`, `worker`) and `runs.log`.

## The waker, backoff and stale locks

Planned, not built yet:

- **Waker** (`wake.sh`): a cron poll the operator installs. The cron line stays uninstalled until backoff and stale-lock handling are proven.
- **Backoff** on rate limits and repeated infrastructure failures, and a **poison-issue rule** (three infra failures on one issue block it).
- **Stale-lock reclaim.**

Until those land, a run that finds the lock held exits 0 "busy" and names the pid; if a run was killed by SIGKILL, remove the lock directory by hand after checking the pid is gone.

## Role routing

Label an issue `agent:<name>` (for example `agent:grid-backend-dev`) and the worker runs as `claude -p --agent <name>`. No label means a generic session. These end `blocked` with a comment, no worktree and no model call: a name with characters outside `[A-Za-z0-9._-]`, two `agent:` labels, no `<name>.md` in `~/.claude/agents` (or `$AGENTS_DIR`) or `.claude/agents`, or an agent whose frontmatter `tools:` line names neither `Edit` nor `Write` (read-only roles cannot build). The run record's role is the routed agent, else `RUN_ROLE`.

## Hooks

- **Guard** (`hooks/guard-main-push.sh`): blocks, with exit 2, a `git push` whose refspec names `main`, `master` or the base branch (quoted and path-qualified forms too); a bare push while on one of those; `--force`, `-f`, `--force-with-lease`, `--mirror`, `--all`; `gh pr merge`; and `gh api` calls with `/merge` or a PUT, PATCH or DELETE method. It uses the shared parser in `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` when present, else a built-in splitter; both give the same answers on the decision table.
- **Review hook** (`hooks/post-commit-review.sh`): reviews each commit of an interactive session once, from the payload's working directory, capped (`--model`, `--max-budget-usd`, `--tools ""`). It stands down when `GRID_LOOP_HEADLESS=1` (the runner sets it for the worker) or `GRID_REVIEW_RUNNING=1`.
- **setup.sh:** by default it renders `loop/loop-prompt.md` and self-tests the guard, and writes nothing to `.claude/settings.json`. `--interactive` wires the review hook and the guard into the repo's settings for a session you chose to run interactively; `--unwire` removes only those entries.

**The guard is not installed in the-grid's own `.claude/settings.json`, on purpose:** it blocks `gh pr merge`, and the operator's own sessions in the-grid merge reviewed PRs. In every repo the guard reaches the worker only through the runner's per-run settings file; `--interactive` is for a repo where you decided an interactive loop session should be guarded too.

### Known gaps

- The guard is a mistake-catcher, not a boundary. On the built-in parser `bash -c '...'` and `eval` are not inspected (the shared parser unwraps them once); shell aliases and scripts that call git internally are not inspected on either path.
- A SIGKILL of the runner orphans the worker process; remove the stale lock by hand until stale-lock handling lands.
- With `WORKER_PERMISSIONS=bypass` the worker can run any `gh` call the guard does not block.

## What the worker can and cannot do

The worker runs as you, with your `gh` and `claude` logins, in a throwaway worktree. Under the default `allowlist` it has file tools and `git add|commit|status|diff|log|show` plus whatever test commands you add; it has no `git push` and no `gh`. An unlisted Bash command is denied without a prompt or a hang, which also denies your own verify command and any command your global Claude rules make a session run (a git identity check, for example): name them in `WORKER_ALLOWED_TOOLS`, or the worker cannot run its checks and ends `blocked`. That is a permission list, not a sandbox: a Bash prefix rule can be dodged, and the guard only catches the obvious mistakes. What bounds the damage is that the loop only opens pull requests and a human merges: **put branch protection on the base branch**. `WORKER_PERMISSIONS=bypass` (`--dangerously-skip-permissions`) is a fallback the operator chooses only if the allowlist cannot complete a normal task.

The issue text is the worker's whole task, so it must come from someone trusted: with `TRUST_GATE=on` the issue's author, and the author of any Agent Brief that is read, must be OWNER, MEMBER or COLLABORATOR. If the verify output of a failing gate contains a secret, its last 40 lines (at most 3000 bytes) go into an issue comment.

## Why each decision was made

- **Label-gated selection, lowest number first.** A human (or gh-triage) opts each issue in.
- **The runner verifies, pushes and opens the PR.** The only way "never commit a red build" is true is the runner running the gate itself.
- **One issue per invocation.** Lock, cleanup, record and exit codes are trivial to reason about and to test.
- **Guard scoped to the worker.** Per-run `--settings`, so the operator's own sessions are never blocked.
- **Tracked `loop/` folder, not `.claude/`.** The automation survives a clone or a move; only `.claude/settings.json` is machine-local.
