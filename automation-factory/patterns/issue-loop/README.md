# Pattern: issue-loop

An autonomous agent that works a repo's GitHub issue backlog, with an automatic
code review on everything it produces. It runs two ways from the same cut:

- **Interactively**: a `/loop` session you start in Claude Code, using your own credentials.
- **Headless**: `loop/run-issues.sh`, a capped, auditable runner for a server. One fresh
  session per issue, a dedicated unprivileged OS user, no GitHub token in the model's
  environment, PRs to a long-lived integration branch, a stronger-model review on each PR.

| Module | File | Role |
|--------|------|------|
| **1 — review hook** | `hooks/post-commit-review.sh` | PostToolUse(Bash) hook: on every `git commit`, runs a backgrounded, capped `claude -p` review of that commit and posts it on the branch's open PR (else on issue `#N` from the commit subject). |
| **2 — loop prompt** | `loop-prompt.template.md` | The `/loop` prompt. Two mutually exclusive `MODE` blocks: `pr` (worktree, PR to the base branch, relabel, never close) or `direct` (push the base branch, close the issue). |
| **3 — headless runner** | `run-issues.sh` + `loop.conf.template` | Unattended runner (pr mode only): preflight, trust gate, tokenless worker per issue, the runner pushes/opens the PR/relabels, Opus review, run record. Config in `loop/loop.conf`. |
| **4 — guard + worktree** | `hooks/guard-main-push.sh`, `hooks/new-agent-worktree.sh` | PreToolUse mistake-catcher for pushes/merges; cuts `issue-<N>` worktrees off `origin/<base>`. |
| **5 — token minter** | `scripts/lib/gh-app-token.sh` (copied to `loop/gh-app-token.sh`) | Mints a 1-hour GitHub App installation token with `openssl` + `curl` + `jq`. |
| **wiring** | `setup.sh` + `.gitignore` | Regenerates the prompt instance, merges the review and guard hooks into `.claude/settings.json` (only its own entries), self-tests the guard. Idempotent. |

Scheduling is not part of the pattern: `scripts/instantiate.sh` renders a systemd user
timer (linux profile) or a launchd plist (mac-mini profile) through the shared
`scripts/lib/render-schedule.sh`, writes the files and **prints** the activation
commands. It never runs `systemctl`, `launchctl` or `crontab`.

## Instantiate it into a target repo

```bash
bash scripts/instantiate.sh issue-loop <target-repo> --profile <personal|work|mac-mini|linux> [options]
```

| Profile | Default mode | Guard + worktree helper + runner | Scheduler files |
|---|---|---|---|
| `personal` | direct | no | none |
| `work` | pr | yes | none |
| `mac-mini` | pr | yes | launchd plist |
| `linux` | pr | yes | systemd user service + timer |

Options: `--repo` (auto-detected from the git remote), `--base-branch` (default: the
repo's `origin/HEAD` branch, else `main`), `--mode pr|direct`, `--verify-cmd`, `--label`
(default `ready-for-agent`), `--project-context`, `--review-focus`, `--max-issues`,
`--max-turns`, `--issue-timeout`, `--worker-model`, `--review-model`, `--setup-cmd`,
`--role-labels a,b,c`, `--schedule-hour` (alias `--launchd-hour`). Run it with no
arguments for the full list.

What it does, idempotently (a second identical run prints no `wrote:` line):

- copies the pattern into a **tracked** top-level `loop/` folder (not `.claude/`, which is
  commonly gitignored in target repos, so the automation survives a clone or move);
- fills the prompt (`{{BASE_BRANCH}}`, repo, context, verify command, label) and keeps exactly one `MODE` block;
- renders `loop/loop.conf` **once**: re-running with different flags says "left alone" instead of overwriting your tuned caps;
- creates, if absent, the opt-in label, `ready-for-human`, `needs-human`, `blocked` and one `role:<name>` label per `--role-labels` entry;
- runs `bash loop/setup.sh`, which writes the machine-local, gitignored `.claude/settings.json` wiring.

`instantiate.sh` needs an authenticated `gh` (to create labels). A headless loop user has
none by design, so run it as `GH_TOKEN="$(bash scripts/lib/gh-app-token.sh)" bash scripts/instantiate.sh ...`
(with the `GH_APP_*` variables set as in "Linux setup" below).

After a clone or a move, only `bash loop/setup.sh` is needed.

## `loop/loop.conf`

Tracked, plain assignments, **no secrets**. Every line is `KEY=${KEY:-value}`, so an
environment variable of the same name overrides the file for one run.

| Key | Default | Meaning |
|---|---|---|
| `GH_REPO` | detected | `owner/name` |
| `BASE_BRANCH` | `main` / detected | Branch PRs target (pr) or that direct mode pushes |
| `ISSUE_LABEL` | `ready-for-agent` | Opt-in label: only labelled issues are worked |
| `MODE` | `pr` | `pr` or `direct`. The runner refuses `direct` (interactive `/loop` only) |
| `LABEL_BUDGETS` | empty | Space-separated `label=usd` pairs that raise the worker spend cap, e.g. `ws:rule-packs=15` |
| `VERIFY_CMD` | empty | Gate the agent must pass before committing |
| `SETUP_CMD` | empty | Run in each issue worktree before the agent (e.g. `npm ci`), under `ISSUE_TIMEOUT` |
| `PROJECT_CONTEXT`, `REVIEW_FOCUS` | | One-liners fed to the review prompts |
| `MAX_ISSUES` | 3 | Issues per run, lowest number first |
| `MAX_TURNS` | 40 | Passed as `--max-turns` only if `claude --help` lists that flag |
| `MAX_BUDGET_USD` | 5 | Worker `--max-budget-usd` (always passed) |
| `REVIEW_BUDGET_USD` | 2 | Review `--max-budget-usd` (always passed) |
| `ISSUE_TIMEOUT` / `REVIEW_TIMEOUT` | 1800 / 600 | Wall-clock cap per worker / review run, in seconds |
| `WORKER_MODEL` / `REVIEW_MODEL` | sonnet / opus | Always passed explicitly |
| `REVIEW_DIFF_LINES` | 1500 | Diff lines given to the review (the review input is also capped at 100000 bytes) |
| `RUN_ROLE` | `issue-loop` | Role name in run records when no `role:` label routed the issue |

Worktrees live in `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}/issue-<N>`,
outside the repo, so no ignore rules are needed.

## The headless runner

`bash loop/run-issues.sh` exits **0** when the run finished (issue-level failures are fine,
and so is "nothing to do" or "another run holds the lock"), **1** on an infrastructure
failure mid-run (stopped at once; the issue keeps its label), **2** when preflight failed
(nothing was touched; one stderr line names the fix).

Per issue, serially: skip it if a PR or `issue-<N>` branch already exists → **trust gate**
(see below) → optional role routing → a worktree off `origin/<base>` → the worker
(`claude -p`, explicit `--model`, `--max-budget-usd`, wall-clock `timeout`, stdin from
`/dev/null`, no MCP servers, `--setting-sources project,local`) → the **runner** decides
the outcome from git state plus the worker's one-line outcome file:

| Worker wrote | Git state | Result |
|---|---|---|
| `done` | on `issue-<N>`, clean, at least one commit ahead of the base | push, PR to the base (`Closes #N`), `ready-for-human`, issue left **open**, Opus review comment |
| `needs-human <reason>` | any | label `needs-human`, reason in a comment |
| anything else, timeout, max turns, no commit, rejected push | any | label `blocked`, reason in a comment |

A PR to a non-default base does not auto-close its issue on merge, which is why the issue
stays open and is relabelled. The review (`--model opus --tools ""`) is advisory text on
the PR, never an approval. One `run-record.sh` line is written per issue (best effort).

## Running unattended safely

The worker runs with `--dangerously-skip-permissions`. Containment is layered, and the
**guard hook is only a mistake-catcher: branch protection and token scope are the boundary**.

1. **A dedicated unprivileged OS user** with its own `HOME`, its own clone and its own
   `claude` login, that cannot read the operator's home. Preflight checks this mechanically:
   `LOOP_OPERATOR_HOME` (in the env file) must exist and must not be listable by the running user.
2. **A GitHub App, not a personal token.** Create an App under the operator's account
   (no webhook; repository permissions Contents, Pull requests and Issues read/write,
   Metadata read; **no Administration, no Workflows**), install it on the **one** repo, and
   download its private key to `~/.config/the-grid/app.pem` (mode 600). Each run mints a
   1-hour installation token with `gh-app-token.sh` (an RS256 JWT with `exp` at most 10
   minutes ahead, signed with the key) and re-mints after 45 minutes. Commits and PRs show
   as `<app-slug>[bot]`. Preflight refuses a token that is not an installation token for
   this repo (`gh api user` must fail) or whose App holds Administration or Workflows.
   To revoke: delete the key in the App settings (a stolen key mints new tokens until it is deleted).
3. **A ruleset requiring a pull request on the base branch, with an EMPTY bypass list.**
   Preflight checks `gh api repos/<owner>/<name>/rules/branches/<base>` for a `pull_request` rule.
4. **The runner holds the token, the worker never does.** The token lives in an unexported
   shell variable and is passed per `gh`/`git` call as `GH_TOKEN`. The worker, `SETUP_CMD` and
   the review run under `env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN`. The runner
   pushes with `-c core.hooksPath=/dev/null push --no-verify`, so a hook the worker planted
   never runs while the token is in the environment. The loop user must have no stored `gh`
   login (preflight fails if it does) and an `https://` origin (an SSH key in its home would
   give the worker push access).
5. **A trust gate before any worktree or model call.** The issue text is the worker's whole task, so
   it must come from someone trusted: `author_association` is OWNER, MEMBER or COLLABORATOR; the
   last person to apply the opt-in label is in `LOOP_TRUSTED_ACTORS`; every body editor and every
   title-rename actor is in `LOOP_TRUSTED_ACTORS`. Otherwise the issue gets `needs-human` and a
   comment, and the run moves on. Issue comments are never given to the worker. `LOOP_TRUSTED_ACTORS`
   lives in the env file, not in the tracked `loop.conf`, so no username lands in the repo.
6. **Caps on everything.** Spend (`--max-budget-usd`), wall clock (`timeout -k 30`), issues per run,
   and a lock so two runs never overlap.

**What the worker can do:** edit files in its worktree, run the verify command and shell
commands as the loop user, commit on `issue-<N>`. **What it cannot do:** push, open PRs, touch
labels, read the operator's home, reach any repo but the one installed, merge anything (the
ruleset), or change App permissions.

**Residual risk:** the worker runs as the same OS user as the runner, so a deliberately
hostile worker could read the env file, the App key and the token. `env -u` stops the token
reaching tool output, logs and child processes by accident. What bounds a deliberate read is
the App's permissions (one repo, no Workflows or Administration), the 1-hour token lifetime,
the ability to delete the key, and the ruleset with an empty bypass list. Delete the key first
if you suspect a leak.

## Linux setup (systemd user timer)

As the dedicated loop user (all UNVERIFIED on a real box until the proving run in the uplift runbook):

1. Put the App key at `~/.config/the-grid/app.pem` (`chmod 600`) and create
   `~/.config/the-grid/issue-loop.env` (`chmod 600`). The runner **parses** it (never sources it) and reads only these keys:
   ```
   GH_APP_ID=...                  # required
   GH_APP_INSTALLATION_ID=...     # optional when the App has exactly one installation
   GH_APP_KEY_FILE=...            # optional, default ~/.config/the-grid/app.pem
   LOOP_TRUSTED_ACTORS=login,...  # required: logins whose labelling and edits are trusted
   LOOP_OPERATOR_HOME=/path/to/operator-home   # required: a path this user must NOT be able to list
   ```
   A `GH_TOKEN=` or `GITHUB_TOKEN=` line is refused. The env file and the key must both be mode 600. Scripts never create these files.
2. Let git use the per-call token over https, once: `GH_TOKEN="$(bash loop/gh-app-token.sh)" gh auth setup-git`.
3. Cut the loop into the clone: `GH_TOKEN="$(bash scripts/lib/gh-app-token.sh)" bash scripts/instantiate.sh issue-loop . --profile linux --base-branch next ...`, then `bash loop/setup.sh` (instantiate runs it too).
4. Linger, once, with sudo, so the user timer fires while nobody is logged in: `sudo loginctl enable-linger <loop-user>`. Without it the user manager does not exist at 02:00 and `Persistent=true` runs the missed job at the next login. `instantiate.sh` warns when linger is not `yes` and prints a crontab line as the alternative that fires while logged out without linger (it never installs it).
5. Enable the timer as that user (the command `instantiate.sh` printed): `systemctl --user daemon-reload && systemctl --user enable --now issue-loop-<owner>-<repo>.timer`.
6. Fire one run by hand to look at the result first: `systemctl --user start issue-loop-<owner>-<repo>.service` (journal: `journalctl --user -u issue-loop-<owner>-<repo>.service`).

The unit sets `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin`, runs the runner as
`Type=oneshot` with `TimeoutStartSec = MAX_ISSUES x (ISSUE_TIMEOUT + REVIEW_TIMEOUT) + 600`, and has no
`EnvironmentFile` and no `network-online.target` line (a user manager has no such unit; a network that
is not up yet is caught by the runner's `git ls-remote` preflight, and the next timer fire retries).

## macOS (launchd) note — UNTESTED

The `mac-mini` profile writes a LaunchAgent plist that runs `/bin/bash <repo>/loop/run-issues.sh`
directly (no login shell; the runner fixes its own PATH), with `HOME`, `PATH`, `WorkingDirectory`
and logs under `~/.grid/logs/`. The plist must belong to the dedicated loop user. A LaunchAgent only
runs while that user has a GUI session, and the Keychain-held `claude` login is not readable over a
bare SSH session, so a headless Mac needs auto-login of the dedicated user. Nothing in the test suite
activates a scheduler; this path is written and unit-tested as text only.

## Role routing

Label an issue `role:<agent-name>` (for example `role:grid-backend-dev`) and the worker runs as
`claude -p --agent <name>` with the same model, spend cap and timeout as any worker. No label means the
default session. An agent is "wired" when `<name>.md` exists in `~/.claude/agents/` (or `$AGENTS_DIR`) or in
the repo's `.claude/agents/`. These end `blocked` with a comment, no worktree and no model call:
an unwired name, two `role:` labels, or an agent whose frontmatter `tools:` line contains neither
`Edit` nor `Write` (read-only roles such as a QA or security reviewer cannot build). The Opus review is
never routed to an agent. `instantiate.sh --role-labels a,b,c` creates the labels; create them only for builder roles.
The run record's role is the routed agent, else `RUN_ROLE`.

## Hooks

- **Guard** (`hooks/guard-main-push.sh`, PreToolUse): blocks, with exit 2, a `git push` whose refspec
  target is `main`, `master` or the base branch; a bare `git push` while on one of those; `--force`, `-f`,
  `--force-with-lease`, `--mirror`, `--all`; `gh pr merge`; and `gh api` calls with `/merge` or a
  PUT/PATCH/DELETE method. Words are matched exactly, so `git push -u origin issue-main-fix` is fine.
  It uses `hooks/lib/common.sh`'s `grid_git_segments` from `${GRID_DIR:-$HOME/.the-grid}` when present,
  else its own split. **Known gaps:** `bash -c '...'`, `eval`, shell aliases and scripts that call git are not inspected.
- **Review hook** (`hooks/post-commit-review.sh`, PostToolUse): reviews each commit once (deduped per
  checkout), from the payload's working directory, with `--model ${GRID_REVIEW_MODEL:-sonnet}`,
  `--max-budget-usd ${GRID_REVIEW_BUDGET_USD:-1}` and `--tools ""`. It stands down when
  `GRID_LOOP_HEADLESS=1` (the runner does one Opus review per PR instead) or `GRID_REVIEW_RUNNING=1`
  (its own reviewer).

## History

Fixed in this version: `setup.sh` now wires the `PreToolUse` guard as well as the review hook (a clone or
move used to silently lose the guard), and the prompt's push step is mode-aware instead of a hard-coded
`git push origin main` that contradicted the `work` profile.
The verify-failure revert is now `reset --hard && clean -fd` (the old `checkout -- .` leaked untracked files).

## Why each decision was made

- **Label-gated selection, not "lowest open issue."** A human opts each issue into autonomous work.
  Without this gate the loop would attack design/judgment issues it cannot resolve. Lowest-numbered
  *within the label* keeps picking deterministic.
- **Verify gate before commit.** The loop runs `VERIFY_CMD` and never commits a red build. On failure
  it tries to fix what it changed, else reverts and labels the issue `blocked`.
- **Failure and ambiguity handling.** Under-specified issues get a comment and `needs-human` and are
  skipped: the loop never spins or guesses on judgment calls.
- **"Only the changes the issue requires."** Autonomous agents over-implement; this keeps diffs minimal and reviewable.
- **Commit message carries `#N`.** It tells the review hook which issue a commit belongs to and leaves a clean issue-to-commit trail.
- **Review runs backgrounded and capped.** Claude Code is never blocked, and every model call carries an
  explicit model, a spend cap and a time cap.
- **Honest diff truncation.** Large diffs are capped for cost, but the review says so instead of silently under-reviewing.
- **The runner integrates, the agent does not.** The agent only commits and writes one outcome line, so
  no model ever holds a token, and the outcome can only downgrade, never cause a push without commits.
- **Portable content lives in a tracked `loop/` folder, not `.claude/`.** The automation must survive a
  clone or a move; only machine-specific wiring (absolute paths) is regenerated by `setup.sh`. Check
  `git check-ignore -v <path>` before dropping any generated file into a target repo.
- **One schedule renderer.** `scripts/lib/render-schedule.sh` is the only place systemd, launchd and
  cron text is produced, so every scheduled the-grid job renders and tests the same way.

## Roadmap

- **Shipped:** PR mode, the headless runner, the GitHub App token, the linux profile.
- **Actionable review**: the next iteration reads the prior auto-review and fixes critical findings before moving on.
- **Compose with `agent-factory`**: partly done via `role:<agent>` routing; the implement step can delegate to composed specialists.
- **Paperclip / OpenClaw triggers**: the runner is the scheduled Claude Code path only; other triggers stay out of scope here.
