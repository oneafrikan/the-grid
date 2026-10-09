## Context

The issue-loop pattern (`automation-factory/patterns/issue-loop/`) is cut into a
target repo by `scripts/instantiate.sh`. Today it assumes direct pushes to `main`,
macOS launchd and an interactive `/loop` session. The uplift plan needs it to run
unattended overnight on a Linux box: Sonnet implements, Opus reviews, PRs land on
the long-lived `next` branch, Gareth merges. Two lessons already learned
(`issue-loop/README.md` "Known issues"): the guard hook was wired only at
instantiate time, and the prompt template's push step contradicts the work profile.

Facts verified while drafting (local `claude` 2.1.295, 2026-10-09):
- `claude --help` lists `--model`, `--output-format`, `--settings`, `--tools`, `--max-budget-usd`, `--dangerously-skip-permissions`, `--permission-mode`.
- `claude --help` does NOT list `--max-turns`. The plan assumed it. The runner therefore probes for it (see Decisions) and relies on `timeout` as the hard cap.
- `codex exec [PROMPT]` exists. `gemini` and `opencode` are not installed on this machine, so their command lines stay unverified until first use.
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
MAX_BUDGET_USD=${MAX_BUDGET_USD:-}    # passed as --max-budget-usd when set; empty = no flag
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
1  resolve REPO_ROOT (script dir/..); source loop/loop.conf; resolve TIMEOUT_BIN
   (GRID_TIMEOUT_BIN, else timeout, else gtimeout; none -> exit 2)
2  preflight: git gh jq claude present; `gh auth status`; REPO_ROOT tree clean
   (git status --porcelain empty); acquire lock dir "$(git rev-parse --git-common-dir)/issue-loop.lock"
   (mkdir; pid file inside; stale lock = pid not alive -> reclaim; live lock -> log + exit 0)
3  git fetch origin BASE_BRANCH
4  issues = gh issue list --repo R --state open --label ISSUE_LABEL --json number -q '.[].number' | sort -n | head -MAX_ISSUES
   none -> log "nothing to do", exit 0
5  for each N (serial):
   a  skip (outcome skipped, note "branch or PR exists") if `gh pr list --head issue-N --state open` is non-empty
      or `git ls-remote --heads origin issue-N` is non-empty
   b  MODE=pr: WT=$WORKTREE_ROOT/issue-N, `git worktree remove --force` if stale, then
      `git worktree add -B issue-N "$WT" origin/BASE_BRANCH`; MODE=direct: WT=REPO_ROOT
   c  run SETUP_CMD in WT if set (failure = issue-level error)
   d  prompt = preamble + loop-prompt.template.md with {{WORKING_DIR}} -> WT (sed at runtime)
      preamble: "HEADLESS RUN. Work ONLY issue #N. Skip STEP 1. Do not loop. Stop after STEP 6/7."
   e  worker: (cd WT && GRID_LOOP_HEADLESS=1 "$TIMEOUT_BIN" -k 30 ISSUE_TIMEOUT
        claude -p --model WORKER_MODEL [--max-turns MAX_TURNS] --output-format json
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
        claude -p --model REVIEW_MODEL --tools "" --output-format json
        under "$TIMEOUT_BIN" REVIEW_TIMEOUT; result text -> `gh pr comment PR --body-file`
        review exit 124 -> post nothing, note "review timeout"; other non-zero -> INFRA
   i  cleanup: `git worktree remove --force WT` (pr mode); branch kept
   j  run-record: run-record.sh --role RUN_ROLE --action work-issue --target "R#N"
        --outcome <ok|error|skipped> [--cost-usd worker+review] --note "<short reason, PR url>"
   k  INFRA failure at any point: run-record outcome error, release lock, exit 1
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
5. `--model "${GRID_REVIEW_MODEL:-sonnet}"` and `--tools ""`.
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

New options: `--base-branch` (default: `git symbolic-ref --short refs/remotes/origin/HEAD` minus `origin/`, else `main`), `--mode pr|direct` (default by profile), `--max-issues`, `--max-turns`, `--issue-timeout`, `--worker-model`, `--review-model`, `--setup-cmd`, `--schedule-hour` (`--launchd-hour` kept as an alias). New profile `linux`.

| Profile | Default mode | Guard + worktree helper | Scheduler files |
|---|---|---|---|
| personal | direct | no | none |
| work | pr | yes | none |
| mac-mini | direct | no | launchd plist, now running the runner |
| linux | pr | yes | systemd user service + timer |

Other fixes in the same file: `sed` replacement values are escaped (`&`, `|`, `\`) so a `VERIFY_CMD` like `a && b` is filled correctly; `gh label list --limit 200` (default 30 hides existing labels); all four labels created if absent (`ISSUE_LABEL` green 0E8A16, `ready-for-human` D93F0B, `needs-human` D93F0B, `blocked` B60205); `com.gareth.` removed from the launchd label (now `io.the-grid.issue-loop.<slug>`); the guard and worktree heredocs replaced by copying the shipped pattern files (kills the bash-heredoc-in-`$(...)` workaround comments); the generated target `CLAUDE.md` text updated for the runner and base branch.

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
EnvironmentFile=%h/.config/the-grid/issue-loop.env
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

The env file `~/.config/the-grid/issue-loop.env` (mode 600, created by the human,
never by a script) holds `CLAUDE_CODE_OAUTH_TOKEN=...` and `GH_TOKEN=...`. Linger
(`loginctl enable-linger "$USER"`, once, needs the human) lets the user manager run
timers while logged out. `instantiate.sh` writes the units and prints
`systemctl --user daemon-reload && systemctl --user enable --now <timer>` and the
linger command; it never runs them.

### 10b: karpathy-loop

Instance directory layout (created by `karpathy_loop.py init <dir>`):

```
<dir>/
  loop.ini            # config (below)
  program.md          # instructions to the editing agent: what is fair game, what is not
  rubric.md           # judge rubric (judge metric only)
  artifact.md         # THE one editable file (any filename; set in loop.ini)
  fixtures/           # fixed inputs, read-only by contract
  best/               # snapshot of the best artifact so far
  runs/<iter>/        # per-iteration output.txt, judge.txt, edit.txt
  results.tsv         # log (untracked)
  .guard.json         # sha256 of fixtures/, rubric.md, program.md, loop.ini (untracked)
```

```ini
[loop]
artifact = artifact.md
fixtures = fixtures
direction = max            ; max | min
max_iter = 5
plateau_delta = 0.3        ; an iteration "counts" only if it improves best by at least this
plateau_patience = 2       ; stop after this many consecutive iterations that did not count
cmd_timeout = 600          ; seconds, applied to every command below

[agent]
; stdin = edit prompt; must edit [loop] artifact in place; last "CHANGED: <text>" stdout line = description
edit_cmd = claude -p --model sonnet --permission-mode acceptEdits

[metric]
kind = judge               ; judge | command
; kind = command
score_cmd = python3 score.py {artifact} {fixtures}   ; last stdout line is a number
; kind = judge
run_cmd =                  ; optional; stdout = the output to judge; empty = judge the artifact text itself
judge_cmd = claude -p --model haiku --tools ""        ; stdin = rubric + output; must end with "SCORE: <number>"
rubric = rubric.md
scale_min = 0
scale_max = 10
```

`{artifact}` and `{fixtures}` are replaced with shell-quoted absolute paths; commands
run with `shell=True`, cwd = `<dir>`, stdin as noted (empty for `run_cmd`/`score_cmd`).

`results.tsv` (tab-separated; tabs and newlines in descriptions replaced by spaces):

```
iteration	score	status	description	timestamp
0	6.50	keep	baseline	2026-10-09T09:12:03Z
1	8.00	keep	added explicit rule with worked example	2026-10-09T09:14:40Z
2	7.80	discard	tightened register, lost a section	2026-10-09T09:16:02Z
3		crash	score_cmd exit 1	2026-10-09T09:17:10Z
```

Loop: baseline (iter 0) scores the artifact as-is and snapshots it to `best/`. Each
iteration: verify `.guard.json` (mismatch = stop, exit 3, nothing restored beyond
the artifact) then build the edit prompt (program.md + artifact path + last 5
results rows + tail of the previous `judge.txt`), run `edit_cmd`, score, then keep
if strictly better in `direction` (best updated, artifact stays) else discard
(artifact restored from `best/`). Crash (command failure, timeout, unparsable or
out-of-range score) restores from `best/`; three consecutive crashes stop the run.
Stop conditions: `max_iter` reached, plateau (patience), guard mismatch, crashes.
At exit the working artifact equals `best/`. The engine only ever writes inside
`<dir>`; it prints the promotion command and never runs it. Re-running resumes:
iteration numbering and best score come from `results.tsv`, and `--max-iter`
counts iterations of this invocation only.

### 10b: cli-cron

```
patterns/cli-cron/
  README.md
  run-agent.sh           # runner, copied into the job dir
  install.sh             # <job-dir> --at HH:MM [--scheduler systemd|launchd|cron]: renders units via scripts/lib/render-schedule.sh
  job.conf.example
  prompt.example.md
  agents.example.conf    # one commented command line per agent with a "verified <date>" or "UNVERIFIED" tag
```

`job.conf` (`KEY=${KEY:-value}` style, sourced):

```
JOB_NAME=${JOB_NAME:-daily-report}
PROMPT_FILE=${PROMPT_FILE:-prompt.md}          # relative to the job dir
AGENT_CMD=${AGENT_CMD:-}                       # REQUIRED; run with bash -c; env PROMPT_FILE is exported
TIMEOUT_SECS=${TIMEOUT_SECS:-900}
LOG_DIR=${LOG_DIR:-logs}                       # relative to the job dir; gitignore it
KEEP_LOGS=${KEEP_LOGS:-14}
RUN_ROLE=${RUN_ROLE:-cli-cron}
```

`AGENT_CMD` is not a templating language: it is a shell command line that reads the
prompt from `$PROMPT_FILE`. Example for claude (verified flags only):
`claude -p --model sonnet --max-budget-usd 2 "$(cat "$PROMPT_FILE")"`. Codex:
`codex exec "$(cat "$PROMPT_FILE")"` (`exec` verified; sandbox flags left to the user).
Gemini `gemini -p "$(cat "$PROMPT_FILE")"` and opencode `opencode run "$(cat "$PROMPT_FILE")"` are tagged UNVERIFIED.
Caps: wall-clock via `timeout`, spend/turn caps via the agent's own flags.
`run-agent.sh`: lock (mkdir), preflight (prompt file readable, first word of
`AGENT_CMD` on PATH, timeout binary), run under `timeout -k 30`, stdout+stderr to
`$LOG_DIR/<JOB_NAME>-<UTC stamp>.log`, prune to `KEEP_LOGS`, then one
`run-record.sh` line (`--action run --target JOB_NAME`; 124 = error with note
`timeout`). Exit code mirrors the agent (124 on timeout).

### Tests

All bats, all offline, all inside temp dirs. Shared helper
`tests/helpers/stubs.bash` creates a stub dir prepended to PATH with fake `gh`,
`claude`, and `timeout` (a shim that drops `-k N SECS` and execs the rest), each
logging its argv to `$STUB_LOG` and reading canned behaviour from env vars
(`STUB_ISSUES`, `STUB_CLAUDE_EXIT`, `STUB_CLAUDE_JSON`). Real `git` is used against
a temp bare "origin". `GRID_RUN_LOG` points at a temp file; `HOME` is a temp dir so
nothing touches the real `~/.claude`, `~/.config` or `~/Library`.

## Decisions

- Decided: this change ships six capabilities and two phases; Phase A groups (1 to 5) must merge to `next` before the first overnight run; Phase B groups (6 to 8) are the only ones the overnight loop may take.
- Decided: base branch is a `{{BASE_BRANCH}}` placeholder filled by `instantiate.sh`, defaulting to the repo's `origin/HEAD` branch else `main`; the-grid's own instance sets `next`.
- Decided: integration modes are `pr` and `direct`; `pr` is the default for the `work` and `linux` profiles, `direct` for `personal` and `mac-mini` (unchanged behaviour for existing profiles).
- Decided: the prompt template holds both modes as `<!-- MODE:direct -->` / `<!-- MODE:pr -->` blocks and `instantiate.sh` keeps one with awk; reason: one source of truth, no per-profile template fork.
- Decided: the headless runner uses the same prompt template with a short override preamble rather than a second prompt file; reason: avoids two prompts drifting.
- Decided: the worktree is created by the runner (deterministic), the PR/push/relabel steps are done by the agent per the prompt; reason: the interactive `/loop` path needs the same instructions, and the runner verifies the outcome from GitHub state afterwards.
- Decided: worktrees live in `$WORKTREE_ROOT` = `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}/issue-<N>`; reason: outside the repo so no ignore rules are needed.
- Decided: outcome is read from GitHub state (open PR, labels, issue state), never parsed from model text.
- Decided: infra failure = preflight failure, `claude` exit non-zero other than 124, `is_error` JSON that is not `error_max_turns`, or a `gh` call failing in the runner itself; the run stops at once, exit 1. Issue-level failure = timeout (124), max-turns, verify failure, ambiguous issue; the runner labels `blocked` or `needs-human`, comments, and continues.
- Decided: `--max-turns` is passed only when `claude --help` output contains `--max-turns`; otherwise only `timeout` and optional `--max-budget-usd` (via `MAX_BUDGET_USD`, default unset) cap a run. The plan assumed `--max-turns` exists; the installed 2.1.295 does not list it. The probe runs once per run.
- Decided: `--output-format json` is used for both claude calls to read cost and error subtype; the parse is defensive (`jq -r '.total_cost_usd // empty'`) and the exact field names are re-checked during the sandbox proving step.
- Decided: workers run with `--dangerously-skip-permissions`; reason: unattended; containment is the worktree, the PreToolUse guard, a dedicated non-admin GitHub token, and branch protection on the base branch.
- Decided: the review call uses `--tools ""` (text in, text out, no tools) and the `opus` alias; reason: read-only by construction and cheapest correct form.
- Decided: reviews are posted as a PR comment, never as an approval or merge; the verdict line is advisory.
- Decided: in `direct` mode the runner skips the worktree and the Opus review step and leaves review to the post-commit hook; reason: no PR to review.
- Decided: the runner suppresses the in-session review hook with `GRID_LOOP_HEADLESS=1`; reason: one Opus review per PR, not a second Sonnet one per commit.
- Decided: `KillMode` stays at the systemd default (control-group) and the runner waits for every child before exiting; reason: with the hook suppressed no detached children exist, and control-group kills everything on a `systemctl stop` or timeout, which is what we want. `Type=oneshot` makes systemd wait for the runner.
- Decided: `EnvironmentFile` has no leading `-`; reason: a missing token file should fail loudly at start, not run unauthenticated.
- Decided: timer is `OnCalendar` daily at `--schedule-hour` (default 2), `Persistent=true`; no `RandomizedDelaySec`.
- Decided: `instantiate.sh` writes unit files and prints activation commands but never runs `systemctl`, `launchctl` or `loginctl`; reason: state changes need the human (rule 9).
- Decided: unit output dirs are overridable with `SYSTEMD_USER_DIR` and `LAUNCH_AGENTS_DIR` env vars so tests never write to the real home.
- Decided: `loop.conf` is created only if absent; re-running `instantiate.sh` with changed flags prints "loop.conf exists, left alone" for a differing value rather than overwriting tuned caps.
- Decided: the guard hook ships as a pattern file (resolves the old TODO); `setup.sh` wires it whenever the file exists, so a clone or move restores it.
- Decided: `setup.sh` merges by removing only its own entries (matched by command basename); reason: never clobber other tools' hooks.
- Decided: `gate.sh` shellcheck coverage is extended to `automation-factory/patterns/*/*.sh` and `automation-factory/patterns/*/hooks/*.sh`; scripts must pass at `-S warning`.
- Decided: the-grid's own `loop/` is re-cut with `--profile work --base-branch next --verify-cmd "bash scripts/gate.sh"`; the Linux box later re-runs `instantiate.sh` with `--profile linux` to get its units. The Mac must not get systemd files.
- Decided: `SETUP_CMD` is empty for the-grid's instance; whether `scripts/gate.sh` passes inside a bare worktree (no submodules, no venv) is checked during sandbox/dry-run and is an open question for Gareth.
- Decided: the sandbox proving step uses a throwaway GitHub repo with a `next` branch, two trivial issues ("add a line to README", "add a file `hello.txt`"), `VERIFY_CMD="test -f README.md"`; the-grid itself is not touched until it passes.
- Decided: `karpathy-loop` engine is Python 3 stdlib (`karpathy_loop.py`), config is INI parsed by `configparser`; reason: PyYAML is not stdlib, the numeric/TSV logic is awkward in bash.
- Decided: all model calls in `karpathy-loop` go through user-configured CLI command lines, never an SDK or API key; reason: harness-neutral (any CLI agent), reuses the user's existing auth.
- Decided: `karpathy-loop` guards fixtures, rubric, program.md and loop.ini by sha256 recorded at baseline; a mismatch stops the run. Enforces the "cannot touch the ground truth" rule mechanically.
- Decided: `keep` means strictly better than best in `direction`; plateau means `plateau_patience` consecutive iterations that did not improve best by at least `plateau_delta`. Defaults: max_iter 5, plateau_delta 0.3, patience 2.
- Decided: `karpathy-loop` ships a tiny worked example with a `command` metric (no model call) used by the bats test and as living documentation.
- Decided: `karpathy-loop` and `cli-cron` ship their own scaffold scripts (`init`, `install.sh`); `instantiate.sh` is not extended for them; scheduling code is shared through `scripts/lib/render-schedule.sh`.
- Decided: `cli-cron` has no default `AGENT_CMD` and the example does not use `--dangerously-skip-permissions`; a job that needs write tools opts in explicitly.
- Decided: agent command presets in `agents.example.conf` are tagged `verified <date>` only if `--help` was checked on the implementing machine; otherwise `UNVERIFIED`. Today: claude and codex verifiable here, gemini and opencode not.
- Decided: run records for runner jobs use `--role issue-loop` (override via `RUN_ROLE`) and `--action work-issue`; for cli-cron `--role cli-cron --action run`. Recording is best-effort: a missing `run-record.sh` logs a warning and never fails the run. Its path comes from `GRID_RUN_RECORD`, else `${GRID_DIR:-$HOME/.the-grid}/scripts/run-record.sh`, else `<repo>/scripts/run-record.sh` if it exists.
- Decided: issue #4 is partially served (scheduled headless Claude Code run, PR/run-record handoff) and stays open for the Paperclip/OpenClaw trigger; issue #21 is partially served by a documented runbook and stays open for the scripted chain.
- Decided: no machine names, usernames, emails or absolute home paths in any shipped file; units and plists get paths at render time from the target directory and `%h`/`$HOME`.
