## Context

The issue-loop pattern (`automation-factory/patterns/issue-loop/`) is cut into a
target repo by `scripts/instantiate.sh`. Today it assumes direct pushes to `main`,
macOS launchd and an interactive `/loop` session. The uplift plan needs it to run
unattended overnight on a Linux box: Sonnet implements, Opus reviews, PRs land on
the long-lived `next` branch, the operator merges. Two lessons already learned
(`issue-loop/README.md` "Known issues"): the guard hook was wired only at
instantiate time, and the prompt template's push step contradicts the work profile.

Facts verified while drafting (drafting machine `claude` 2.1.295, 2026-10-09):
- `claude --help` lists `--model`, `--output-format`, `--settings`, `--tools`, `--max-budget-usd` ("only works with --print"), `--dangerously-skip-permissions`, `--permission-mode`.
- `claude --help` does NOT list `--max-turns`. The plan assumed it. The runner therefore probes for it (see Decisions); the hard caps are `timeout` and `--max-budget-usd`.
- `claude auth status --json` exists and prints `{"loggedIn": true, "authMethod": ...}`. It reads whichever credential source the CLI uses (credentials file, keychain, `CLAUDE_CODE_OAUTH_TOKEN`) without a model call, so it is the auth preflight.
- `codex exec [PROMPT]` exists and takes `-m, --model`.

The target box for the first unattended runs (Ubuntu 24.04) differs from a
desktop in ways the runner must absorb, not the operator:
- `claude` (2.1.289, native install) lives in `~/.local/bin`, which is not on the PATH of a non-login shell, a systemd user service or cron.
- Claude credentials are file-based (`~/.claude/.credentials.json`, subscription login). Headless `claude -p` reads the same file, so no `setup-token` is needed; `CLAUDE_CODE_OAUTH_TOKEN` stays an optional fallback.
- `gh` stores its token in the desktop keyring, which a headless service cannot unlock. Headless runs need `GH_TOKEN` in an env file.
- Linger is off, so user timers do not fire while the operator is logged out.
- Node is v18. Nothing in the runner needs Node (the CLI is the native binary); the OpenSpec CLI (Node >= 20.19) is not used by the runner.
- macOS has no `timeout`/`gtimeout` by default and ships bash 3.2. All new bash must run on bash 3.2 (no associative arrays, no `mapfile`, no `${var,,}`) and must locate the timeout binary at runtime.
- `scripts/gate.sh` shellchecks only `scripts/*.sh`, `scripts/lib/*.sh` and `.githooks/pre-commit`; pattern scripts are not covered today.

Phase A (10a) is built interactively and merged before any overnight run. Phase B
(10b) is a normal loop-buildable set of groups.

## Approach

### File layout after the change

```
automation-factory/patterns/issue-loop/
  README.md                    # updated: PR mode, runner, Linux, known-issues section replaced by "fixed" note
  loop-prompt.template.md      # {{BASE_BRANCH}} + MODE blocks
  setup.sh                     # fixed wiring
  run-issues.sh                # NEW headless runner, copied verbatim to <target>/loop/
  loop.conf.template           # NEW, rendered once by instantiate.sh to <target>/loop/loop.conf
  hooks/post-commit-review.sh  # fixed
  hooks/guard-main-push.sh     # NEW (was a heredoc inside instantiate.sh)
  hooks/new-agent-worktree.sh  # NEW (was a heredoc inside instantiate.sh), base-aware
  .gitignore
scripts/lib/render-schedule.sh # NEW pure renderers: systemd service/timer, launchd plist, crontab line
automation-factory/patterns/karpathy-loop/   # Phase B
automation-factory/patterns/cli-cron/        # Phase B
```

### Prompt template: MODE blocks

`loop-prompt.template.md` carries two mutually exclusive blocks for the
integration steps. `instantiate.sh` keeps one and drops the other with awk, so the
instance contains no markers.

```
<!-- MODE:direct -->
STEP 5 — Commit and push
git add <changed files>
git commit -m "<short description> #<N>"
git push origin {{BASE_BRANCH}}
STEP 6 — Close the issue
gh issue close <N> --repo {{GH_REPO}} --comment "Implemented in $(git log -1 --format='%h'). <summary>."
<!-- /MODE -->
<!-- MODE:pr -->
STEP 3a — Worktree
If `git branch --show-current` is already `issue-<N>`, you are in the issue worktree: stay in it.
Otherwise run `bash loop/hooks/new-agent-worktree.sh issue-<N>` and do ALL further work in the path it prints.
STEP 5 — Commit, push, open PR
git add <changed files>
git commit -m "<short description> #<N>"
git push -u origin issue-<N>
gh pr create --repo {{GH_REPO}} --base {{BASE_BRANCH}} --head issue-<N> --title "<short description> (#<N>)" --body "Closes #<N>"
STEP 6 — Hand over
gh issue edit <N> --repo {{GH_REPO}} --add-label ready-for-human --remove-label {{ISSUE_LABEL}}
gh issue comment <N> --repo {{GH_REPO}} --body "PR opened: <url>. Needs human review and merge."
Do NOT close the issue.
<!-- /MODE -->
```

Common text changes: the verify-failure revert becomes
`git -C {{WORKING_DIR}} reset --hard HEAD && git -C {{WORKING_DIR}} clean -fd`
(fixes the untracked-file leak of `git checkout -- .`); the guardrail "never
delete branches" stays; "Never push to {{BASE_BRANCH}}" is added.
In PR mode a PR to a non-default base does not auto-close the issue on merge,
which is why the issue is left open and relabelled instead.

### loop.conf (written once by instantiate.sh to `<target>/loop/loop.conf`)

Tracked, no secrets, sourced by `run-issues.sh`. Every line is
`KEY=${KEY:-value}` so a pre-set environment variable wins.

```
# loop/loop.conf — sourced by loop/run-issues.sh. Edit to tune; env vars override.
GH_REPO=${GH_REPO:-owner/name}
BASE_BRANCH=${BASE_BRANCH:-next}
ISSUE_LABEL=${ISSUE_LABEL:-ready-for-agent}
MODE=${MODE:-pr}                      # pr | direct
VERIFY_CMD=${VERIFY_CMD:-bash scripts/gate.sh}
SETUP_CMD=${SETUP_CMD:-}              # run in the worktree before the agent (e.g. npm ci); empty = none
PROJECT_CONTEXT=${PROJECT_CONTEXT:-a software project}
REVIEW_FOCUS=${REVIEW_FOCUS:-correctness, style, test coverage}
MAX_ISSUES=${MAX_ISSUES:-3}           # K issues per run
MAX_TURNS=${MAX_TURNS:-40}            # passed as --max-turns only if the claude CLI supports it
MAX_BUDGET_USD=${MAX_BUDGET_USD:-5}   # worker --max-budget-usd, always passed
REVIEW_BUDGET_USD=${REVIEW_BUDGET_USD:-2} # review --max-budget-usd, always passed
ISSUE_TIMEOUT=${ISSUE_TIMEOUT:-1800}  # seconds, per worker run
REVIEW_TIMEOUT=${REVIEW_TIMEOUT:-600} # seconds, per review run
WORKER_MODEL=${WORKER_MODEL:-sonnet}
REVIEW_MODEL=${REVIEW_MODEL:-opus}
REVIEW_DIFF_LINES=${REVIEW_DIFF_LINES:-1500}
RUN_ROLE=${RUN_ROLE:-issue-loop}
```

Values are written with `printf '%q'` so spaces and `&&` in `VERIFY_CMD` survive
sourcing.

### Runner algorithm (`loop/run-issues.sh`, bash 3.2 compatible)

Exit codes: 0 = run finished (issue-level failures are fine), 1 = infrastructure
failure mid-run (stopped early), 2 = preflight failed (nothing touched).

```
1  resolve REPO_ROOT (script dir/..); source loop/loop.conf;
   ENV_FILE=${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env}: if readable,
   `set -a; . "$ENV_FILE"; set +a` (optional; holds GH_TOKEN and, if needed,
   CLAUDE_CODE_OAUTH_TOKEN); if `claude` is not on PATH, prepend "$HOME/.local/bin";
   export GIT_TERMINAL_PROMPT=0 (a push needing a password fails instead of hanging);
   resolve TIMEOUT_BIN (GRID_TIMEOUT_BIN, else timeout, else gtimeout; none -> exit 2)
2  preflight (any failure -> one stderr line naming the fix, exit 2):
   git gh jq claude present;
   `claude auth status --json | jq -e '.loggedIn == true'` (message: "claude not
   logged in for this user; run `claude` once interactively, or set
   CLAUDE_CODE_OAUTH_TOKEN in $ENV_FILE");
   `gh auth status` (message: "gh has no usable token headless; set GH_TOKEN in $ENV_FILE");
   `git ls-remote --exit-code origin BASE_BRANCH` (remote reachable with these credentials);
   REPO_ROOT tree clean (git status --porcelain empty); acquire lock dir "$(git rev-parse --git-common-dir)/issue-loop.lock"
   (mkdir; pid file inside; stale lock = pid not alive -> reclaim; live lock -> log + exit 0)
3  git fetch origin BASE_BRANCH
4  issues = gh issue list --repo R --state open --label ISSUE_LABEL --json number -q '.[].number' | sort -n | head -MAX_ISSUES
   none -> log "nothing to do", exit 0
5  for each N (serial):
   a  skip (outcome skipped, note "branch or PR exists") if `gh pr list --head issue-N --state open` is non-empty
      or `git ls-remote --heads origin issue-N` is non-empty
   a2 role routing: labels = gh issue view N --json labels; ROLE = the name after
      `role:` on a `role:<name>` label (none -> ROLE empty). Issue-level failure
      (blocked + comment, continue; no worktree, no model call) when: more than one
      `role:` label; no agent file at "${AGENTS_DIR:-$HOME/.claude/agents}/ROLE.md"
      or "$REPO_ROOT/.claude/agents/ROLE.md" ("agent ROLE is not wired on this
      machine"); or the file's frontmatter has a `tools:` line containing neither
      `Edit` nor `Write` ("ROLE is read-only; use it as a reviewer, not a builder")
   b  MODE=pr: WT=$WORKTREE_ROOT/issue-N, `git worktree remove --force` if stale, then
      `git worktree add -B issue-N "$WT" origin/BASE_BRANCH`; MODE=direct: WT=REPO_ROOT
   c  run SETUP_CMD in WT if set (failure = issue-level error)
   d  prompt = preamble + loop-prompt.template.md with {{WORKING_DIR}} -> WT (sed at runtime)
      preamble: "HEADLESS RUN. Work ONLY issue #N. Skip STEP 1. Do not loop. Stop after STEP 6/7."
   e  worker: (cd WT && GRID_LOOP_HEADLESS=1 "$TIMEOUT_BIN" -k 30 ISSUE_TIMEOUT
        claude -p [--agent ROLE] --model WORKER_MODEL --max-budget-usd MAX_BUDGET_USD
        [--max-turns MAX_TURNS] --output-format json
        --dangerously-skip-permissions --settings REPO_ROOT/.claude/settings.json "$PROMPT")
      stdout -> $TMP/N.worker.json, stderr -> $TMP/N.worker.err
   f  classify the worker exit:
        124            -> issue-level failure "timeout"
        other non-zero -> INFRA failure: record, cleanup, stop (exit 1)
        0              -> parse json: is_error true and subtype != error_max_turns -> INFRA;
                          subtype error_max_turns -> issue-level failure "max-turns";
                          cost = .total_cost_usd // empty
   g  outcome from GitHub state, not from the model's text:
        pr mode:     open PR from issue-N exists                  -> ok
        direct mode: issue state is CLOSED                        -> ok
        issue now has label needs-human                           -> skipped
        issue now has label blocked                               -> error ("could not land")
        none of the above (incl. f's issue-level failures)        -> error; runner adds label
                                                                     blocked, removes ISSUE_LABEL,
                                                                     comments the reason
   h  review (pr mode and outcome ok only): diff = gh pr diff PR | head -REVIEW_DIFF_LINES
        (header line says "TRUNCATED" if cut); body = issue body + diff;
        claude -p --model REVIEW_MODEL --max-budget-usd REVIEW_BUDGET_USD --tools "" --output-format json
        under "$TIMEOUT_BIN" REVIEW_TIMEOUT; result text -> `gh pr comment PR --body-file`
        review exit 124 -> post nothing, note "review timeout"; other non-zero -> INFRA
   i  cleanup: `git worktree remove --force WT` (pr mode); branch kept
   j  run-record: run-record.sh --role "${ROLE:-RUN_ROLE}" --action work-issue --target "R#N"
        --outcome <ok|error|skipped> [--cost-usd worker+review] --note "<short reason, PR url>"
   k  INFRA failure at any point: print the last 20 lines of $TMP/N.worker.err (or
      the review's) to stderr so they land in the journal/launchd log; run-record
      outcome error; release lock; exit 1
6  release lock (trap EXIT); print one summary line "done: X ok, Y skipped, Z error"; exit 0
```

Worker settings: `--settings` points at the main checkout's generated
`.claude/settings.json` because a worktree does not contain gitignored
`.claude/`. That is how the guard hook applies inside every worktree.

Review prompt (fixed text in the script, with `{{PROJECT_CONTEXT}}`/`{{REVIEW_FOCUS}}`
filled from conf): reviewer is read-only text only; must answer with 3 to 7
bullets, each tagged `[blocker]`, `[should-fix]` or `[nit]`, then one line
`VERDICT: approve | changes-requested`. It judges the diff against the issue's
acceptance criteria.

### Hooks

`hooks/guard-main-push.sh` (PreToolUse, Bash). Reads `BASE_BRANCH` from
`loop/loop.conf` (default `main`). Exit 2 with a stderr message when the command:
- contains `git push` with any token that, after stripping a leading `+`, a `refs/heads/` prefix and everything up to the last `:`, equals `main`, `master` or BASE_BRANCH;
- is a bare `git push` while the current branch is one of those;
- contains `git push` with `--force`, `-f` or `--force-with-lease`;
- contains `gh pr merge`.
Token matching (not `\bmain\b`) so `git push -u origin issue-main-fix` is allowed.

`hooks/post-commit-review.sh` (PostToolUse, Bash) fixes:
1. Repo dir comes from payload `.cwd` (fallback `pwd`), used with `git -C`.
2. Commit detection by regex for a `git` word followed by optional `-C <dir>`/`-c k=v`/`--opt` args then `commit`, anchored after start, `;`, `&&`, `||`, `|` or `(`. Matches `git -C x commit` and `cd x && git commit`; does not match `git commit-tree` or `echo "git committed"`.
3. Dedupe: last reviewed hash stored in `$(git rev-parse --git-dir)/post-commit-review.last`; same hash = exit 0.
4. Posts to the open PR of the current branch (`gh pr view --json number`), else to issue `#N` from the commit subject, else log only.
5. `--model "${GRID_REVIEW_MODEL:-sonnet}"`, `--max-budget-usd "${GRID_REVIEW_BUDGET_USD:-1}"` and `--tools ""`.
6. Exits 0 immediately when `GRID_LOOP_HEADLESS=1` (the runner does the Opus review) or `GRID_REVIEW_RUNNING=1` (recursion guard; the hook sets it for its own `claude -p`).

`setup.sh` fixes: for each of `PostToolUse` (review hook) and `PreToolUse` (guard,
only if the file exists) it applies one jq function: remove any hook entry whose
command ends with our script's basename (so a moved repo replaces the stale
absolute path), drop matcher entries left empty, append our entry. Foreign hooks
are never touched. If the guard file is absent its stale entry is removed. It then
smoke-tests the guard (`git push origin <base>` must exit 2; `git push -u origin
issue-1` must exit 0) and exits non-zero if not. It also chmods
`loop/hooks/*.sh` and `loop/run-issues.sh`.

### instantiate.sh changes

New options: `--role-labels <a,b,...>` (see Decisions), `--base-branch` (default: `git symbolic-ref --short refs/remotes/origin/HEAD` minus `origin/`, else `main`), `--mode pr|direct` (default by profile), `--max-issues`, `--max-turns`, `--issue-timeout`, `--worker-model`, `--review-model`, `--setup-cmd`, `--schedule-hour` (`--launchd-hour` kept as an alias). New profile `linux`.

| Profile | Default mode | Guard + worktree helper | Scheduler files |
|---|---|---|---|
| personal | direct | no | none |
| work | pr | yes | none |
| mac-mini | direct | no | launchd plist, now running the runner |
| linux | pr | yes | systemd user service + timer |

Other fixes in the same file: `sed` replacement values are escaped (`&`, `|`, `\`) so a `VERIFY_CMD` like `a && b` is filled correctly; `gh label list --limit 200` (default 30 hides existing labels); all four labels created if absent (`ISSUE_LABEL` green 0E8A16, `ready-for-human` D93F0B, `needs-human` D93F0B, `blocked` B60205); the personal-name prefix removed from the launchd label (now `io.the-grid.issue-loop.<slug>`); the guard and worktree heredocs replaced by copying the shipped pattern files (kills the bash-heredoc-in-`$(...)` workaround comments); the generated target `CLAUDE.md` text updated for the runner and base branch.

### Scheduling

`scripts/lib/render-schedule.sh` exposes pure functions that print to stdout:
`render_systemd_service`, `render_systemd_timer`, `render_launchd_plist`,
`render_crontab_line`. Built with `printf`, not heredocs inside `$(...)`.

Rendered systemd service (names/paths are examples):

```
[Unit]
Description=issue-loop runner for owner/name
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/abs/path/to/target
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash /abs/path/to/target/loop/run-issues.sh
TimeoutStartSec=<MAX_ISSUES*(ISSUE_TIMEOUT+REVIEW_TIMEOUT)+600>
```

Rendered timer:

```
[Unit]
Description=Nightly issue-loop for owner/name

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=issue-loop-owner-name.service

[Install]
WantedBy=timers.target
```

Credentials: the runner itself loads the optional env file
`${GRID_LOOP_ENV:-~/.config/the-grid/issue-loop.env}` (mode 600, created by the
human, never by a script), so systemd, launchd, cron and a manual run behave the
same and the unit carries no `EnvironmentFile`. Keys:
- `GH_TOKEN=...` needed wherever `gh` keeps its token in a keyring (headless Linux). `gh auth setup-git`, run once by the human, makes HTTPS pushes use the same token.
- `CLAUDE_CODE_OAUTH_TOKEN=...` optional fallback only. With a file-based subscription login (`~/.claude/.credentials.json`) headless `claude -p` needs nothing extra.

Linger (`loginctl enable-linger "$USER"`, once, needs the human) lets the user
manager run timers while logged out. `instantiate.sh` reads
`loginctl show-user "$USER" --property=Linger --value` when `loginctl` exists and
warns when it is not `yes`. It writes the units and prints
`systemctl --user daemon-reload && systemctl --user enable --now <timer>` and the
linger command; it never runs them.

### 10b: karpathy-loop (lean)

One stdlib Python file plus a worked example. No scaffold command: the operator
copies `example/` and edits it. No built-in judge: an LLM judge is just a
`score_cmd` that prints a number (the README shows one).

```
automation-factory/patterns/karpathy-loop/
  README.md
  karpathy_loop.py         # `run <dir> [--max-iter N]`
  example/                 # offline demo, also the template to copy
    loop.ini
    program.md             # instructions to the editing agent
    artifact.txt           # THE one editable file
    fixtures/input.txt     # fixed input, read-only by contract
    edit.sh                # deterministic stand-in for an agent edit
    score.py               # prints a number as its last stdout line
```

Instance layout at run time (`<dir>` = a copy of `example/`):

```
<dir>/best/            # snapshot of the best artifact so far
<dir>/runs/<iter>/     # edit.txt and score.txt (raw stdout+stderr of each command)
<dir>/results.tsv      # log
<dir>/.guard.json      # sha256 of fixtures/, program.md, loop.ini
```

```ini
[loop]
artifact = artifact.txt
fixtures = fixtures
direction = max            ; max | min
max_iter = 5
plateau_delta = 0.3        ; an iteration "counts" only if it improves best by at least this
plateau_patience = 2       ; stop after this many consecutive iterations that did not count
cmd_timeout = 600          ; seconds, applied to both commands

[commands]
; stdin = edit prompt; must edit the artifact in place; last "CHANGED: <text>" stdout line = description
edit_cmd = bash edit.sh
; last stdout line parsed as a float
score_cmd = python3 score.py {artifact} {fixtures}
```

Model-backed commands are the operator's choice and are shown in the README with
an explicit model and spend cap on every call, for example
`edit_cmd = claude -p --model sonnet --max-budget-usd 1 --permission-mode acceptEdits`
and a judge `score_cmd = bash judge.sh {artifact}` where `judge.sh` runs
`claude -p --model haiku --max-budget-usd 0.2 --tools ""` on a rubric plus the
artifact and prints the number after its last `SCORE:` line.

`{artifact}` and `{fixtures}` are replaced with `shlex.quote`d absolute paths;
commands run with `shell=True`, cwd = `<dir>`, `timeout=cmd_timeout`; `edit_cmd`
gets the prompt on stdin, `score_cmd` gets empty stdin.

`results.tsv` (tab-separated; tabs and newlines in descriptions replaced by spaces):

```
iteration	score	status	description	timestamp
0	6.50	keep	baseline	2026-10-09T09:12:03Z
1	8.00	keep	added explicit rule	2026-10-09T09:14:40Z
2	7.80	discard	tightened wording	2026-10-09T09:16:02Z
3		crash	score_cmd exit 1	2026-10-09T09:17:10Z
```

Loop: `run` refuses (exit 2) if `results.tsv` already exists. Baseline (iter 0)
scores the artifact as-is, snapshots it to `best/` and writes `.guard.json`. Each
iteration: verify `.guard.json` (mismatch = exit 3 naming the file), build the edit
prompt (program.md + artifact path + last 5 results rows), run `edit_cmd`, run
`score_cmd`, keep if strictly better in `direction` (best updated) else discard
(artifact restored from `best/`). Crash (non-zero exit, timeout, unparsable score)
restores from `best/`; three consecutive crashes stop with exit 1. Stop also on
`max_iter` or plateau. At exit the artifact equals `best/`; the engine writes only
inside `<dir>` and prints `cp <dir>/best/<artifact> <DEST>` without running it.
Exit codes: 0 ok, 1 crashes, 2 config error, 3 guard.

### 10b: cli-cron (lean)

```
automation-factory/patterns/cli-cron/
  README.md
  run-agent.sh           # runner, copied into the job dir by the operator
  install.sh             # <job-dir> --at HH:MM [--scheduler systemd|launchd|cron]
  job.conf.example       # includes commented claude and codex AGENT_CMD examples
  prompt.example.md
  .gitignore             # logs/
```

`job.conf` (`KEY=${KEY:-value}` style, sourced):

```
JOB_NAME=${JOB_NAME:-daily-report}
PROMPT_FILE=${PROMPT_FILE:-prompt.md}          # relative to the job dir
AGENT_CMD=${AGENT_CMD:-}                       # REQUIRED; run with bash -c; env PROMPT_FILE is exported
TIMEOUT_SECS=${TIMEOUT_SECS:-900}
LOG_DIR=${LOG_DIR:-logs}                       # relative to the job dir; gitignored
KEEP_LOGS=${KEEP_LOGS:-14}
RUN_ROLE=${RUN_ROLE:-cli-cron}
```

`AGENT_CMD` is a shell command line that reads the prompt from `$PROMPT_FILE`.
The two shipped examples, both with an explicit model and a cap:
`claude -p --model sonnet --max-budget-usd 2 "$(cat "$PROMPT_FILE")"` and
`codex exec -m <model> "$(cat "$PROMPT_FILE")"` (codex has no spend flag; its cap
is `TIMEOUT_SECS`). Other CLIs are the operator's own line.
`run-agent.sh` does what `run-issues.sh` step 1 does for the environment (optional
`GRID_LOOP_ENV` file, `~/.local/bin` on PATH), then: lock (mkdir), preflight
(prompt file readable, first word of `AGENT_CMD` on PATH, timeout binary; exit 2),
run under `timeout -k 30 TIMEOUT_SECS`, stdout+stderr to
`$LOG_DIR/<JOB_NAME>-<UTC stamp>.log`, prune to `KEEP_LOGS`, then one
`run-record.sh` line (`--action run --target JOB_NAME`; non-zero = error, 124 note
`timeout`). Exit code mirrors the agent (124 on timeout).

### Tests

All bats, all offline, all inside temp dirs. Shared helper
`tests/helpers/stubs.bash` creates a stub dir prepended to PATH with fake `gh`,
`claude`, and `timeout` (a shim that drops `-k N SECS` and execs the rest), each
logging its argv to `$STUB_LOG` and reading canned behaviour from env vars
(`STUB_ISSUES`, `STUB_CLAUDE_EXIT`, `STUB_CLAUDE_JSON`, `STUB_CLAUDE_LOGGED_IN`); the `claude` stub answers `auth status --json` and `--help` without logging them as model calls, and `git ls-remote` runs against the temp bare origin. Real `git` is used against
a temp bare "origin". `GRID_RUN_LOG` points at a temp file; `HOME` is a temp dir so
nothing touches the real `~/.claude`, `~/.config` or `~/Library`.

## Decisions

- Decided: this change ships six capabilities and two phases; Phase A groups (1 to 5) are built interactively, after `foundations`, and merge to `next` before the first overnight run; Phase B groups (6 to 8) are the only ones the overnight loop may take, and they merge after `instincts` per the cross-change merge order.
- Decided: every PR the loop builds targets `next` (the-grid's `loop/loop.conf` sets `BASE_BRANCH=next`); CI on `next` pushes is provided by `foundations#2`, not by this change.
- Decided: every model call on an unattended path passes an explicit `--model` plus a spend cap and a wall-clock cap: worker `--model WORKER_MODEL --max-budget-usd MAX_BUDGET_USD` (default 5) under `ISSUE_TIMEOUT`; review `--model REVIEW_MODEL --max-budget-usd REVIEW_BUDGET_USD` (default 2) under `REVIEW_TIMEOUT`; post-commit hook `--max-budget-usd GRID_REVIEW_BUDGET_USD` (default 1); cli-cron under `TIMEOUT_SECS` with the examples carrying `--model`; karpathy-loop under `cmd_timeout` and `max_iter` with README examples carrying `--model` and `--max-budget-usd`.
- Decided: base branch is a `{{BASE_BRANCH}}` placeholder filled by `instantiate.sh`, defaulting to the repo's `origin/HEAD` branch else `main`; the-grid's own instance sets `next`.
- Decided: integration modes are `pr` and `direct`; `pr` is the default for the `work` and `linux` profiles, `direct` for `personal` and `mac-mini` (unchanged behaviour for existing profiles).
- Decided: the prompt template holds both modes as `<!-- MODE:direct -->` / `<!-- MODE:pr -->` blocks and `instantiate.sh` keeps one with awk; reason: one source of truth, no per-profile template fork.
- Decided: the headless runner uses the same prompt template with a short override preamble rather than a second prompt file; reason: avoids two prompts drifting.
- Decided: the worktree is created by the runner (deterministic), the PR/push/relabel steps are done by the agent per the prompt; reason: the interactive `/loop` path needs the same instructions, and the runner verifies the outcome from GitHub state afterwards.
- Decided: worktrees live in `$WORKTREE_ROOT` = `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}/issue-<N>`; reason: outside the repo so no ignore rules are needed.
- Decided: outcome is read from GitHub state (open PR, labels, issue state), never parsed from model text.
- Decided: infra failure = preflight failure, `claude` exit non-zero other than 124, `is_error` JSON that is not `error_max_turns`, or a `gh` call failing in the runner itself; the run stops at once, exit 1. Issue-level failure = timeout (124), max-turns, verify failure, ambiguous issue; the runner labels `blocked` or `needs-human`, comments, and continues.
- Decided: `--max-turns` is passed only when `claude --help` output contains `--max-turns`; `timeout` and `--max-budget-usd` are always passed. The plan assumed `--max-turns` exists; 2.1.295 does not list it. The probe runs once per run.
- Decided: `--output-format json` is used for both claude calls to read cost and error subtype; the parse is defensive (`jq -r '.total_cost_usd // empty'`) and the exact field names are re-checked during the sandbox proving step.
- Decided: workers run with `--dangerously-skip-permissions`; reason: unattended; containment is the worktree, the PreToolUse guard, a dedicated non-admin GitHub token, and branch protection on the base branch.
- Decided: the review call uses `--tools ""` (text in, text out, no tools) and the `opus` alias; reason: read-only by construction and cheapest correct form.
- Decided: reviews are posted as a PR comment, never as an approval or merge; the verdict line is advisory.
- Decided: in `direct` mode the runner skips the worktree and the Opus review step and leaves review to the post-commit hook; reason: no PR to review.
- Decided: role routing is by issue label `role:<agent-name>` (e.g. `role:grid-backend-dev`); the worker runs `claude -p --agent <name>` with the same `--model`, budget and timeout as any worker (explicit `--model` is always passed; which of `--model` and the agent's `model:` frontmatter wins is checked in group 5). No label = default session, no `--agent`.
- Decided: an agent is "wired" when `<name>.md` exists in `${AGENTS_DIR:-$HOME/.claude/agents}` or the repo's `.claude/agents/`; an unwired name, or two `role:` labels, is an issue-level failure (`blocked` + comment, continue), checked before any worktree or model call.
- Decided: an agent whose frontmatter `tools:` line lists neither `Edit` nor `Write` (today `grid-qa-engineer`, `grid-security-reviewer`) is refused as a builder (issue-level failure); detection is by frontmatter, not a hard-coded list, so newly composed read-only roles are covered.
- Decided: the Opus review does NOT run as `--agent grid-qa-engineer`; it stays `claude -p --model opus --tools ""` with the fixed review prompt; reason: the review is text-in/text-out on a supplied diff, the QA role's procedure assumes tool use, its persona adds context tokens to every review, and the review must work on machines where that agent is not wired.
- Decided: the run record's `--role` is the routed agent name when present, else `RUN_ROLE` (default `issue-loop`).
- Decided: `instantiate.sh --role-labels a,b,c` creates `role:<name>` labels (colour 5319E7, create-if-absent, description "issue-loop: build as agent <name>"); default none. The-grid's re-cut passes `grid-backend-dev,grid-devops,grid-technical-writer,grid-sdet,grid-prompt-engineer,core-platform-engineer` (builders only; no label is created for read-only roles).
- Decided: the runner suppresses the in-session review hook with `GRID_LOOP_HEADLESS=1`; reason: one Opus review per PR, not a second Sonnet one per commit.
- Decided: `KillMode` stays at the systemd default (control-group) and the runner waits for every child before exiting; reason: with the hook suppressed no detached children exist, and control-group kills everything on a `systemctl stop` or timeout, which is what we want. `Type=oneshot` makes systemd wait for the runner.
- Decided: the runner (not the unit) loads the optional env file `${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env}`; reason: one mechanism for systemd, launchd, cron and manual runs. A missing file is fine; missing auth fails loudly in preflight (exit 2) with a message naming the key to set.
- Decided: Claude auth is checked with `claude auth status --json` (`.loggedIn == true`), no model call; a file-based subscription login is the default and `CLAUDE_CODE_OAUTH_TOKEN` is only a fallback the operator adds if the file login fails under systemd.
- Decided: the runner prepends `$HOME/.local/bin` to PATH when `claude` is not found, and the systemd unit sets `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin`; reason: native installs live there and non-login shells do not see it.
- Decided: the runner exports `GIT_TERMINAL_PROMPT=0` and preflights `git ls-remote --exit-code origin BASE_BRANCH`; reason: a credential prompt in a headless run hangs until the timeout instead of failing. HTTPS push auth comes from `gh auth setup-git` + `GH_TOKEN` (human step).
- Decided: timer is `OnCalendar` daily at `--schedule-hour` (default 2), `Persistent=true`; no `RandomizedDelaySec`.
- Decided: `instantiate.sh` writes unit files and prints activation commands but never runs `systemctl`, `launchctl` or a state-changing `loginctl`; reason: state changes need the human. It may read `loginctl show-user` to warn that linger is off.
- Decided: unit output dirs are overridable with `SYSTEMD_USER_DIR` and `LAUNCH_AGENTS_DIR` env vars so tests never write to the real home.
- Decided: `loop.conf` is created only if absent; re-running `instantiate.sh` with changed flags prints "loop.conf exists, left alone" for a differing value rather than overwriting tuned caps.
- Decided: the guard hook ships as a pattern file (resolves the old TODO); `setup.sh` wires it whenever the file exists, so a clone or move restores it.
- Decided: `setup.sh` merges by removing only its own entries (matched by command basename); reason: never clobber other tools' hooks.
- Decided: `gate.sh` shellcheck coverage is extended to `automation-factory/patterns/*/*.sh` and `automation-factory/patterns/*/hooks/*.sh`; scripts must pass at `-S warning`.
- Decided: the-grid's own `loop/` is re-cut with `--profile work --base-branch next --verify-cmd "bash scripts/gate.sh"`; the Linux box later re-runs `instantiate.sh` with `--profile linux` to get its units. The Mac must not get systemd files.
- Decided: `SETUP_CMD` is empty for the-grid's instance; whether `scripts/gate.sh` passes inside a bare worktree (no submodules, no venv) is checked in group 5 (5.6); if it fails, the default fallback is `VERIFY_CMD="tests/lib/bats-core/bin/bats tests/"` with `SETUP_CMD="git submodule update --init tests/lib/bats-core"`.
- Decided: the sandbox proving step uses a throwaway GitHub repo with a `next` branch, two trivial issues ("add a line to README", "add a file `hello.txt`"), `VERIFY_CMD="test -f README.md"`; the-grid itself is not touched until it passes.
- Decided: `karpathy-loop` engine is Python 3 stdlib (`karpathy_loop.py`), config is INI parsed by `configparser`; reason: PyYAML is not stdlib, the numeric/TSV logic is awkward in bash.
- Decided: all model calls in `karpathy-loop` go through user-configured CLI command lines, never an SDK or API key; reason: harness-neutral (any CLI agent), reuses the user's existing auth.
- Decided: `karpathy-loop` guards fixtures, program.md and loop.ini by sha256 recorded at baseline; a mismatch stops the run. Enforces the "cannot touch the ground truth" rule mechanically.
- Decided: `keep` means strictly better than best in `direction`; plateau means `plateau_patience` consecutive iterations that did not improve best by at least `plateau_delta`. Defaults: max_iter 5, plateau_delta 0.3, patience 2.
- Decided: `karpathy-loop` has one metric kind, a `score_cmd` whose last stdout line is a number; an LLM judge is a `score_cmd` the operator writes (README example). No `init` subcommand (copy `example/`), no resume (`run` refuses an existing `results.tsv`); reason: smallest engine that serves both use cases.
- Decided: `karpathy-loop` ships a tiny worked example (no model call) used by the bats test, as living documentation and as the template to copy.
- Decided: `cli-cron` ships its own `install.sh`; `instantiate.sh` is not extended for either Phase B pattern; scheduling code is shared through `scripts/lib/render-schedule.sh`.
- Decided: `cli-cron` has no default `AGENT_CMD` and the example does not use `--dangerously-skip-permissions`; a job that needs write tools opts in explicitly.
- Decided: `cli-cron` ships exactly two commented `AGENT_CMD` examples (claude, codex) in `job.conf.example`, both flag-checked against `--help`; no preset file and no presets for CLIs not installed where it is built.
- Decided: run records for runner jobs use `--role issue-loop` (override via `RUN_ROLE`) and `--action work-issue`; for cli-cron `--role cli-cron --action run`. Recording is best-effort: a missing `run-record.sh` logs a warning and never fails the run. Its path comes from `GRID_RUN_RECORD`, else `${GRID_DIR:-$HOME/.the-grid}/scripts/run-record.sh`, else `<repo>/scripts/run-record.sh` if it exists.
- Decided: issue #4 is partially served (scheduled headless Claude Code run, PR/run-record handoff) and stays open for the Paperclip/OpenClaw trigger; issue #21 is partially served by a documented runbook and stays open for the scripted chain.
- Decided: no machine names, usernames, emails or absolute home paths in any shipped file; units and plists get paths at render time from the target directory and `%h`/`$HOME`.
