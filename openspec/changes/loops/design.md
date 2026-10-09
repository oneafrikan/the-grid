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
- Claude credentials are file-based (`~/.claude/.credentials.json`, subscription login). Headless `claude -p` reads the same file, so no `setup-token` is needed. Under the isolation decision (below) the loop runs as a dedicated OS user with its own login file; `CLAUDE_CODE_OAUTH_TOKEN` is unset for every model call and is not a supported fallback.
- `gh` stores its token in the desktop keyring, which a headless service cannot unlock. Headless runs read `GH_TOKEN` from an env file; the runner keeps it out of the worker's environment and passes it per `gh`/`git` call.

Isolation (operator decision Q1, applied here): the unattended loop runs as a
dedicated unprivileged OS user with its own HOME, its own clone, its own `claude`
login and no read access to the operator's HOME. The runner, not the agent,
pushes, opens the PR and relabels. The worker model never has a GitHub token in
its environment. The guard hook is a mistake-catcher; branch protection (a
ruleset requiring PRs on the base) and token scope (a fine-grained PAT without
Administration or Workflows) are the boundary, and the runner refuses to start
without them.
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

The MODE blocks above serve the interactive `/loop` session (operator's own
credentials). A headless run uses the same template behind this exact preamble
(filled by the runner; `<title>`/`<body>` capped at 60000 bytes with a
`[TRUNCATED]` line):

```
HEADLESS RUN for issue #<N>. You have no GitHub token.
Skip STEP 1 and STEP 6. In STEP 5 commit only: do NOT push, do NOT run gh, do
NOT open a PR; the runner does that. Wherever a step says to label, comment on
or close the issue, write the outcome line instead. Do not fetch the issue or
its comments; the issue text is below and is the whole task.
Finish by writing exactly one line to $LOOP_OUTCOME_FILE:
  done | needs-human <reason> | blocked <reason>
--- ISSUE #<N>: <title>
<body>
---
```

### loop.conf (written once by instantiate.sh to `<target>/loop/loop.conf`)

Tracked, no secrets, sourced by `run-issues.sh`. Every line is
`KEY=${KEY:-value}` so a pre-set environment variable wins.

```
# loop/loop.conf — sourced by loop/run-issues.sh. Edit to tune; env vars override.
GH_REPO=${GH_REPO:-owner/name}
BASE_BRANCH=${BASE_BRANCH:-next}
ISSUE_LABEL=${ISSUE_LABEL:-ready-for-agent}
MODE=${MODE:-pr}                      # pr | direct (direct = interactive /loop only; the runner refuses it)
LABEL_BUDGETS=${LABEL_BUDGETS:-}      # space-separated label=usd pairs raising the worker cap, e.g. "ws:rule-packs=15"
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
   MODE != pr -> exit 2 "headless runs are pr-only; use direct mode from an interactive /loop";
   ENV_FILE=${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env} (fixed default, never
   XDG_CONFIG_HOME, which a unit does not set). If it exists and `find "$ENV_FILE" -perm -077`
   prints it -> exit 2 "chmod 600 $ENV_FILE". PARSE it, never source it, never `set -a`:
   `while IFS= read -r line` loop; accept only `GH_TOKEN=`, `LOOP_TRUSTED_ACTORS=`,
   `LOOP_OPERATOR_HOME=` lines (one pair of surrounding '…' or "…" stripped), ignore all
   else. GH_TOKEN goes into the UNEXPORTED shell variable LOOP_GH_TOKEN. Then
   `unset GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN` in the runner's own environment.
   Every runner gh call and every runner git network call is prefixed per call:
   `GH_TOKEN="$LOOP_GH_TOKEN" gh ...` / `GH_TOKEN="$LOOP_GH_TOKEN" git ...` (HTTPS
   credentials come from `gh auth setup-git`'s helper, which reads GH_TOKEN);
   APPEND each of "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin to PATH when
   it is not already a PATH entry (`case ":$PATH:" in *":$d:"*)`; append, never
   prepend, so nothing is shadowed). launchd and cron start with
   /usr/bin:/bin, so this one rule finds claude, gh, jq and gtimeout everywhere;
   export GIT_TERMINAL_PROMPT=0 (an HTTPS push needing a password fails instead of
   hanging) and, only if GIT_SSH_COMMAND is unset, GIT_SSH_COMMAND="ssh -o BatchMode=yes";
   resolve TIMEOUT_BIN (GRID_TIMEOUT_BIN, else timeout, else gtimeout; none -> exit 2,
   message "install GNU coreutils (macOS: brew install coreutils)")
2  preflight (any failure -> one stderr line naming the fix, exit 2), in this order;
   every network- or keyring-touching probe runs under `"$TIMEOUT_BIN" 60`:
   a  git gh jq claude present; `git config user.name` and `user.email` non-empty in REPO_ROOT
   b  LOOP_TRUSTED_ACTORS non-empty ("set LOOP_TRUSTED_ACTORS in $ENV_FILE");
      LOOP_OPERATOR_HOME non-empty, `[ -e ]`, and `ls "$LOOP_OPERATOR_HOME" >/dev/null 2>&1`
      FAILS ("run the loop as a dedicated user that cannot read the operator's home; see README")
   c  REPO_ROOT/.claude/settings.json (gitignored, per machine) contains a PreToolUse hook whose
      command equals "$REPO_ROOT/loop/hooks/guard-main-push.sh" and is executable, else
      "run bash loop/setup.sh"
   d  `env -u CLAUDE_CODE_OAUTH_TOKEN claude auth status --json | jq -e '.loggedIn == true'`
      ("claude not logged in for this user; run `claude` once interactively as the loop user")
   e  LOOP_GH_TOKEN non-empty ("set GH_TOKEN in $ENV_FILE"); `GH_TOKEN="$LOOP_GH_TOKEN" gh auth
      status` passes; `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status` FAILS ("this user has a
      stored gh login the worker could use; run gh auth logout"); token identity:
      `GH_TOKEN="$LOOP_GH_TOKEN" gh api user --jq .login` must NOT be in LOOP_TRUSTED_ACTORS
      ("the PAT must belong to a separate machine-account collaborator, not a trusted actor;
      see README") — otherwise a token-holder could label/edit issues that pass the trust gate
   f  `git remote get-url origin` starts with https:// ("origin must be https; an SSH key in
      this user's home would give the worker push access")
   g  `git ls-remote --exit-code origin BASE_BRANCH` (with the token)
   h  ruleset: `gh api repos/R/rules/branches/BASE_BRANCH` piped to
      `jq '[.[] | select(.type=="pull_request")] | length'` >= 1 ("add a ruleset requiring a pull
      request on BASE_BRANCH, empty bypass list; classic protection cannot be verified with a
      non-admin token")
   i  non-admin token: `gh api repos/R/branches/BASE_BRANCH/protection` must FAIL with stderr
      containing `HTTP 403`; success or any other failure -> "token has Administration access or
      the check is inconclusive; use the fine-grained PAT described in the README"
   j  REPO_ROOT tree clean (git status --porcelain empty); acquire the lock:
      LOCK=$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/issue-loop.lock
      (absolute: `--git-common-dir` prints a relative `.git` in a main checkout, RAN git 2.39;
      mkdir; write pid file inside; pid file missing or empty = held; stale lock = pid not
      alive -> reclaim by `mv "$LOCK" "$LOCK.stale.$$"` then `rm -rf` it, because rename is
      atomic and two reclaimers cannot both win; live lock -> log + exit 0);
      install `trap cleanup EXIT` and `trap 'exit 143' INT TERM HUP`; `cleanup` removes the
      current worktree (if any), $TMP and the lock
3  `git worktree prune`; git fetch origin BASE_BRANCH (with the token)
4  issues = gh issue list --repo R --state open --label ISSUE_LABEL --limit 100 --json number -q '.[].number' | sort -n | sed -n "1,${MAX_ISSUES}p"
   (`sed -n`, not `head`: `head` exits early and under pipefail the producer can die
   with SIGPIPE, status 141; `--limit 100` because the gh default is 30)
   none -> log "nothing to do", exit 0
5  for each N (serial):
   a  skip (outcome skipped, note "branch or PR exists") if `gh pr list --head issue-N --state open` is non-empty
      or `git ls-remote --heads origin issue-N` is non-empty
   a1 trust gate (all reads with the token; logins compared lower-cased via `tr`):
        author  = gh api repos/R/issues/N --jq .author_association  in {OWNER, MEMBER, COLLABORATOR}
        events  = gh api --paginate repos/R/issues/N/events > $TMP/N.events.json, then
                  jq -s --arg l "$ISSUE_LABEL" '[.[][] | select(.event=="labeled" and .label.name==$l)] | last | .actor.login // ""'
                  must be in LOOP_TRUSTED_ACTORS;
                  every `.event=="renamed"` actor must be in LOOP_TRUSTED_ACTORS
        editors = gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){userContentEdits(first:100){nodes{editor{login}}}}}}' -F o=… -F r=… -F n=N
                  every editor login must be in LOOP_TRUSTED_ACTORS
      any failure -> label needs-human, remove ISSUE_LABEL, comment "issue-loop trust gate: <check>",
      outcome skipped, continue (no worktree, no model call). The same `gh issue view N --json
      title,body,labels` read supplies the prompt text and the labels for a2.
   a2 role routing: ROLE = the name after `role:` on a `role:<name>` label (none -> empty).
      Issue-level failure (blocked + comment, continue; no worktree, no model call) when: more than
      one `role:` label; no agent file at "${AGENTS_DIR:-$HOME/.claude/agents}/ROLE.md" or
      "$REPO_ROOT/.claude/agents/ROLE.md"; or that file's frontmatter has a `tools:` line containing
      neither `Edit` nor `Write`.
      budget: BUDGET=MAX_BUDGET_USD; for each `label=usd` pair in LABEL_BUDGETS whose label the issue
      carries, BUDGET = the larger (compared with `awk`, values are decimals)
   b  WT=$WORKTREE_ROOT/issue-N, `git worktree remove --force` if stale, then
      `git worktree add --no-track -B issue-N "$WT" origin/BASE_BRANCH` (a failing add is an
      issue-level error)
   c  run SETUP_CMD in WT if set: `(cd WT && env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN
      "$TIMEOUT_BIN" ISSUE_TIMEOUT bash -c "$SETUP_CMD")`; failure or 124 = issue-level error
   d  prompt = headless preamble (see "Prompt template") + loop-prompt.template.md with
      {{WORKING_DIR}} -> WT (sed at runtime); LOOP_OUTCOME_FILE=$TMP/N.outcome (outside WT)
   e  worker: (cd WT && env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN
        LOOP_OUTCOME_FILE="$TMP/N.outcome" GRID_LOOP_HEADLESS=1
        "$TIMEOUT_BIN" -k 30 ISSUE_TIMEOUT
        claude -p [--agent ROLE] --model WORKER_MODEL --max-budget-usd BUDGET
        [--max-turns MAX_TURNS] --output-format json
        --dangerously-skip-permissions --settings REPO_ROOT/.claude/settings.json
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources project,local
        "$PROMPT" </dev/null)
      stdout -> $TMP/N.worker.json, stderr -> $TMP/N.worker.err
      (`</dev/null`: `claude -p` waits for EOF on a stdin that is a pipe or an open ssh
      channel; systemd gives /dev/null but cron, ssh and bats do not)
   f  classify the worker exit:
        124 or 137     -> issue-level failure "timeout" (137 = SIGKILL after the -k 30 grace)
        other non-zero -> INFRA failure: record, cleanup, stop (exit 1)
        0              -> parse json: is_error true and subtype != error_max_turns -> INFRA;
                          subtype error_max_turns -> issue-level failure "max-turns";
                          cost = .total_cost_usd // empty
   g  integrate (runner only; the worker never pushes). LINE = first line of $TMP/N.outcome
      (missing -> empty):
        LINE == done AND `git -C WT branch --show-current` == issue-N AND `git -C WT status
        --porcelain` empty AND `git -C WT rev-list --count origin/BASE_BRANCH..HEAD` >= 1
          -> `GH_TOKEN=… git -C WT -c core.hooksPath=/dev/null push --no-verify origin
             HEAD:refs/heads/issue-N` (hooks off: a hook the worker planted in the worktree
             must never run while the token is in the environment; explicit refspec; a
             rejected push, e.g. a workflow file the token cannot write, is issue-level
             "push rejected")
          -> `gh pr create --repo R --base BASE_BRANCH --head issue-N --title "<issue title> (#N)"
             --body-file` (body: "Closes #N" + the run note)
          -> `gh issue edit N --add-label ready-for-human --remove-label ISSUE_LABEL`; comment the
             PR url; issue stays open                                           -> ok
        LINE starts `needs-human` -> label needs-human, remove ISSUE_LABEL, comment the reason
                                                                                -> skipped
        anything else (blocked, missing/unknown line, no commit, dirty tree, wrong branch, f's
        issue-level failures) -> label blocked, remove ISSUE_LABEL, comment the reason -> error
      reasons from the outcome file are cut to 500 bytes and posted with --body-file
   h  review (outcome ok only): diff = gh pr diff PR | sed -n "1,${REVIEW_DIFF_LINES}p"
        (header line says "TRUNCATED" if cut); body = issue body + diff;
        env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN "$TIMEOUT_BIN" REVIEW_TIMEOUT
        claude -p --model REVIEW_MODEL --max-budget-usd REVIEW_BUDGET_USD --tools "" --output-format json
        the instruction text is the -p argument; issue body + diff go in on STDIN from a
        temp file (`< $TMP/N.review.in`), capped at 100000 bytes (`head -c` on a file, not a pipe)
        because one argv string is limited to 128 KiB on Linux (E2BIG);
        result text -> `gh pr comment PR --body-file`
        review exit 124 or 137 -> post nothing, note "review timeout"; other non-zero -> INFRA
   i  cleanup: `git worktree remove --force WT`; branch kept. Runs on every path including
      INFRA stop, via the EXIT trap from step 2
   j  run-record: run-record.sh --role "${ROLE:-RUN_ROLE}" --action work-issue --target "R#N"
        --outcome <ok|error|skipped> [--cost-usd worker+review] --note "<short reason, PR url>"
   k  INFRA failure at any point: print the last 20 lines of $TMP/N.worker.err (or
      the review's) to stderr so they land in the journal/launchd log; run-record
      outcome error; release lock; exit 1
6  release lock (trap EXIT); print one summary line "done: X ok, Y skipped, Z error"; exit 0
```

Bash 3.2 rules (apply to `run-issues.sh` and `run-agent.sh`; both traps were RAN on
macOS /bin/bash 3.2.57 while drafting this review):
- Under `set -u`, expanding an EMPTY array is an error (`a=(); echo "${a[@]}"` prints
  `a[@]: unbound variable`). Build every command as an array that starts non-empty,
  `cmd=(claude -p)`, then append optional flags (`--agent`, `--max-turns`), so
  `"${cmd[@]}"` is never empty. For any other possibly-empty array use `${a[@]+"${a[@]}"}`.
- Never `producer | grep -q` or `| head` under `pipefail`: the early-exiting consumer
  makes the producer die with SIGPIPE (`yes | grep -q y` returns 141, RAN). Capture
  first, then match: `help_out="$(claude --help 2>&1 || true)"; case "$help_out" in
  *--max-turns*) ...`. Same rule for the issue list (step 4 uses `sed -n`).
- Also banned (design.md Context): `mapfile`/`readarray`, `declare -A`, `${x,,}`,
  `${x^^}`, `|&`, `local -n`, `wait -n`. Use `read -r` loops, `case`, and `tr`.
- No `sed -i`, `stat -c/-f`, `date -d/-v`, `readlink -f`, `xargs -r`. File permissions
  are tested with `find "$f" -perm -077` (same on GNU and BSD); absolute paths with
  `(cd "$d" && pwd -P)`.
- Optional-variable reads use `${VAR:-}` (the file runs under `set -u`, and a systemd
  or cron environment lacks `USER`, `XDG_*` and `TERM`; use `${USER:-$(id -un)}`).

Worker settings: `--settings` points at the main checkout's generated
`.claude/settings.json` because a worktree does not contain gitignored
`.claude/`. That is how the guard hook applies inside every worktree.

Review prompt (fixed text in the script, with `{{PROJECT_CONTEXT}}`/`{{REVIEW_FOCUS}}`
filled from conf): reviewer is read-only text only; must answer with 3 to 7
bullets, each tagged `[blocker]`, `[should-fix]` or `[nit]`, then one line
`VERDICT: approve | changes-requested`. It judges the diff against the issue's
acceptance criteria.

### Hooks

`hooks/guard-main-push.sh` (PreToolUse, Bash). A mistake-catcher, not the boundary
(branch protection and token scope are; the headless worker has no token at all).
Reads `BASE_BRANCH` from `loop/loop.conf` (default `main`).

Segmenting: if `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` exists (shipped by
`hook-profiles#1`), the guard sources it and uses `grid_git_segments <command>` (quote-aware;
emits the git subcommand and its remaining words per segment). Otherwise it uses its own
fallback: split the command on `;`, `&&`, `||`, `|` and newline, word-split each segment with
`read -r -a`, drop leading `VAR=value` words. `gh` segments are always found by the fallback
split (the shared parser covers only git). Exit 2 with a stderr message when a segment:
- is `git push` with any word that, after stripping a leading `+`, a `refs/heads/` prefix and everything up to the last `:`, equals `main`, `master` or BASE_BRANCH;
- is a bare `git push` (no refspec word) while the current branch is one of those;
- is `git push` with `--force`, `-f` (or a short cluster containing `f`), `--force-with-lease[=…]`, `--mirror` or `--all`;
- is `gh pr merge`;
- is `gh api` with a word containing `/merge`, or `-X`/`--method` (also `-XPUT`, `--method=PUT`) with value `PUT`, `PATCH` or `DELETE` (case-insensitive).
Word matching (not `\bmain\b`) so `git push -u origin issue-main-fix` is allowed.
Known gaps (README): `bash -c`, `eval`, aliases and scripts that call git are not inspected.

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
| mac-mini | pr | yes | launchd plist, running the runner (pr-only) |
| linux | pr | yes | systemd user service + timer |

Other fixes in the same file: `sed` replacement values are escaped (`&`, `|`, `\`) so a `VERIFY_CMD` like `a && b` is filled correctly; `gh label list --limit 200` (default 30 hides existing labels); all four labels created if absent (`ISSUE_LABEL` green 0E8A16, `ready-for-human` D93F0B, `needs-human` D93F0B, `blocked` B60205); the personal-name prefix removed from the launchd label (now `io.the-grid.issue-loop.<slug>`); the guard and worktree heredocs replaced by copying the shipped pattern files (kills the bash-heredoc-in-`$(...)` workaround comments); the generated target `CLAUDE.md` text updated for the runner and base branch.

### Scheduling

`scripts/lib/render-schedule.sh` is the ONE schedule renderer for the-grid (G2): the
issue-loop (`instantiate.sh`), `cli-cron/install.sh`, `budget-and-usage#6`, `instincts#5`
and `manifest-lock-install#5` all render through it and only PRINT activation commands.
Built with `printf`, not heredocs inside `$(...)`; bash 3.2; no side effects.

Calling: `source scripts/lib/render-schedule.sh; render_x ARGS…`, or from any language
`bash scripts/lib/render-schedule.sh render_x ARGS…` (when executed rather than sourced it
dispatches `$1` if it is one of the functions below, else exits 2). Every function prints
to stdout and returns 0, or prints nothing to stdout, one line to stderr and returns 2.

Shared input rules:
- PATH-like args (WORKDIR, HOME_DIR, LOG_DIR, LOG_FILE, every CMD/ARG word) must match
  `^[A-Za-z0-9_./@+-]+$`; anything else (space, `%`, `$`, `&`, quotes, newline) -> 2.
  No escaping is attempted, so systemd, plist and cron text never needs quoting.
- DESC must match `^[A-Za-z0-9_./@+ -]+$` (spaces allowed, nothing else) -> else 2.
- SCHEDULE is `daily:HH:MM` or `weekly:DOW:HH:MM` (DOW one of Mon Tue Wed Thu Fri Sat Sun,
  HH 00-23, MM 00-59) -> else 2.
- RANDOM_DELAY (optional) must match `^[0-9]+(s|min|h)?$` -> else 2.

Signatures (stable interface; other changes call exactly these):

| Function | Arguments | Output |
|---|---|---|
| `render_unit_slug` | TEXT | TEXT with every char outside `[A-Za-z0-9_.-]` replaced by `-` |
| `render_systemd_service` | DESC WORKDIR TIMEOUT_SECS CMD [ARG…] | `[Unit]` Description; `[Service]` `Type=oneshot`, `WorkingDirectory=`, `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin`, `ExecStart=CMD ARG…`, `TimeoutStartSec=` (TIMEOUT_SECS integer, `0` -> line omitted) |
| `render_systemd_timer` | DESC SERVICE_UNIT SCHEDULE [RANDOM_DELAY] | `[Timer]` `OnCalendar=*-*-* HH:MM:00` (daily) or `OnCalendar=DOW *-*-* HH:MM:00` (weekly), `Persistent=true` (always), `RandomizedDelaySec=RANDOM_DELAY` only when given, `Unit=SERVICE_UNIT`; `[Install]` `WantedBy=timers.target` |
| `render_launchd_plist` | LABEL HOME_DIR WORKDIR LOG_DIR SCHEDULE CMD [ARG…] | plist with `Label`, `ProgramArguments` (CMD ARG…), `WorkingDirectory`, `EnvironmentVariables` `HOME`=HOME_DIR and `PATH`=HOME_DIR/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin, `StartCalendarInterval` `Hour`/`Minute` (+ `Weekday` 0=Sun…6=Sat for weekly), `StandardOutPath`/`StandardErrorPath` = LOG_DIR/LABEL.log |
| `render_crontab_line` | SCHEDULE LOG_FILE WORKDIR CMD [ARG…] | one line `MM HH * * DOW-or-* mkdir -p <dirname LOG_FILE> && cd WORKDIR && CMD ARG… >> LOG_FILE 2>&1` (DOW 0-6 for weekly) |
| `render_activation_commands` | SCHEDULER NAME | `systemd`: `systemctl --user daemon-reload && systemctl --user enable --now NAME` (NAME = timer unit); `launchd`: `launchctl bootstrap gui/$(id -u) NAME` (NAME = plist path); `cron`: `(crontab -l 2>/dev/null; echo 'LINE') \| crontab -` with LINE = NAME. Printed text only. |

The issue-loop timer passes no RANDOM_DELAY (one fire time, Decided below);
`budget-and-usage` passes one. A caller that receives 2 exits 2 itself ("install path
contains unsafe characters; move the repo or job dir").

Rendered systemd service (names/paths are examples):

```
[Unit]
Description=issue-loop runner for owner/name

[Service]
Type=oneshot
WorkingDirectory=/abs/path/to/target
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash /abs/path/to/target/loop/run-issues.sh
TimeoutStartSec=<MAX_ISSUES*(ISSUE_TIMEOUT+REVIEW_TIMEOUT)+600>
```

No `Wants=`/`After=network-online.target`: that is a system-manager target and a
`systemd --user` manager has no such unit, so the lines would be silent no-ops that
only look like protection (READ: systemd.special(7) / user-manager scope; not
verifiable on this macOS drafting machine). A network that is not up yet is caught by
the runner's `git ls-remote` preflight (exit 2); the failed unit is visible in
`systemctl --user status`, and the next timer fire retries.

The issue-loop unit name is `issue-loop-<render_unit_slug owner-name>`.

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

Credentials: the runner itself parses the env file
`${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env}` of the loop user (mode 600,
created by the human, never by a script), so systemd, launchd, cron and a manual run
behave the same and the unit carries no `EnvironmentFile`. Keys (no others are read):
- `GH_TOKEN=...` required: a fine-grained PAT created from a separate GitHub machine account (not the operator) that is a collaborator with write on the repo, for the one repo (Contents, Pull requests, Issues: read/write; Metadata: read; no Workflows, no Administration). `gh auth setup-git`, run once by the human as the loop user, makes HTTPS pushes use it.
- `LOOP_TRUSTED_ACTORS=login1,login2` required: GitHub logins whose labelling and edits the loop trusts. Kept here, not in the tracked `loop.conf`, so no username lands in the repo.
- `LOOP_OPERATOR_HOME=/home/<operator>` required: a path the loop user must NOT be able to list (isolation check).
Claude auth is the loop user's own credentials-file login; `CLAUDE_CODE_OAUTH_TOKEN` is unset for every model call.

Residual risk, stated in the README: the worker runs as the same OS user as the runner,
so a deliberately hostile worker could read the env file and use the token. `env -u`
stops the token reaching tool output, logs and child processes by accident; what bounds
a deliberate read is the token's scope (one repo, no Workflows/Administration) and the
ruleset requiring PRs on the base with an empty bypass list, both checked at preflight.

Linger (`sudo loginctl enable-linger <loop-user>`, once, needs the human) lets the user
manager run timers while logged out. Without it the user manager does not exist at
02:00, so nothing fires; `Persistent=true` then runs the missed job at the operator's
next login, which is mid-day, not overnight. `instantiate.sh` reads
`loginctl show-user "${USER:-$(id -un)}" --property=Linger --value 2>/dev/null || true`
(a failing probe must not abort the script under `set -e`; empty = unknown, treated
like `no`) when `loginctl` exists and warns when it is not `yes`. It writes the units
and prints `systemctl --user daemon-reload && systemctl --user enable --now <timer>`
and the linger command; it never runs them. When linger is not `yes` it also prints,
as an alternative that fires while logged out without linger, the one line from
`render_crontab_line` (`00 HH * * * mkdir -p <log dir> && cd <target> && /bin/bash
<target>/loop/run-issues.sh >> <log dir>/issue-loop-<slug>.log 2>&1`, log dir
`$HOME/.grid/logs`); it never edits a crontab. Re-running with changed flags prints
"unit changed: run systemctl --user daemon-reload" when a unit file's content differs
from what is on disk, and nothing when identical.

launchd (mac-mini profile): the plist runs `/bin/bash <target>/loop/run-issues.sh`
directly, not `bash -l -c` as today (the runner fixes its own PATH, step 1), and sets
`EnvironmentVariables` `HOME` and `PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
`WorkingDirectory`, and `StandardOutPath`/`StandardErrorPath` under `$HOME/.grid/logs/`
(launchd does not create that directory; `instantiate.sh` runs `mkdir -p` on it, as
it does for the unit dirs). A LaunchAgent only runs while the user has a GUI session,
and the Keychain-held Claude login is not readable over a bare SSH session, so a
headless Mac needs auto-login of the dedicated loop user; the README says so (UNTESTED
here, no scheduler is activated in tests).

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
`run-agent.sh` handles its environment like `run-issues.sh` step 1 except for the env
file: the optional `${GRID_CRON_ENV:-$HOME/.config/the-grid/cli-cron.env}` (same
`find -perm -077` refusal) is PARSED, never sourced, and every `KEY=value` line whose KEY
matches `^[A-Za-z_][A-Za-z0-9_]*$` is exported to the agent (a cli-cron job is the
operator's own trusted job, unlike issue text, so it may need tokens; it is a separate
file from the loop's so the loop token never reaches a cron job). Same PATH append, the
"Bash 3.2 rules" above, and `export GRID_CRON=1` for the agent (hooks such as the
instincts capture stand down on it). Then: lock (mkdir, absolute path, `trap` cleanup as in step 2), preflight
(prompt file readable, first word of `AGENT_CMD` on PATH, timeout binary; exit 2),
run under `timeout -k 30 TIMEOUT_SECS`, stdout+stderr to
`$LOG_DIR/<JOB_NAME>-<UTC stamp>.log`, prune to `KEEP_LOGS`, then one
`run-record.sh` line (`--action run --target JOB_NAME`; non-zero = error, 124 note
`timeout`; 137 after the `-k` grace is also reported as `timeout`). Exit code mirrors the agent (124 on timeout, 124 reported for 137 too).

### Tests

All bats, all offline, all inside temp dirs. Shared helper
`tests/helpers/stubs.bash` creates a stub dir prepended to PATH with fake `gh`,
`claude`, and `timeout` (a shim that drops `-k N SECS` and execs the rest), each
logging its argv to `$STUB_LOG` and reading canned behaviour from env vars
(`STUB_ISSUES`, `STUB_CLAUDE_EXIT`, `STUB_CLAUDE_JSON`, `STUB_CLAUDE_LOGGED_IN`); the `claude` stub answers `auth status --json` and `--help` without logging them as model calls, and `git ls-remote` runs against the temp bare origin. Real `git` is used against
a temp bare "origin". `GRID_RUN_LOG` points at a temp file; `HOME` is a temp dir so
nothing touches the real `~/.claude`, `~/.config` or `~/Library`.

Stub additions for Q1 (group 2): the `claude` stub appends `GH_TOKEN=${GH_TOKEN-<unset>}`,
`GITHUB_TOKEN=…` and `CLAUDE_CODE_OAUTH_TOKEN=…` to `$STUB_ENV_LOG` for every `-p` call;
when `STUB_WORKER_COMMIT=1` it creates and commits a file in its cwd; it writes
`$STUB_OUTCOME` (default `done`) to `$LOOP_OUTCOME_FILE` when that is set. The `gh` stub
logs `GH_TOKEN` per call, serves `api repos/*/issues/N` (`STUB_AUTHOR_ASSOC`, default
`OWNER`), `api --paginate repos/*/issues/N/events` (`STUB_EVENTS_JSON`, default one
`labeled` event by `trusted`), `api graphql` (`STUB_EDITORS_JSON`, default none),
`api repos/*/rules/branches/*` (`STUB_RULES_JSON`, default one `pull_request` rule),
`api repos/*/branches/*/protection` (exit 1 with `HTTP 403` unless `STUB_PROTECTION=admin`),
and `auth status` (passes only when `GH_TOKEN` is set, unless `STUB_GH_STORED_LOGIN=1`).
The test env file sets `LOOP_TRUSTED_ACTORS=trusted` and `LOOP_OPERATOR_HOME` to a temp
dir made `chmod 000` (the runner tests `skip` when `id -u` is 0); `origin` is a temp bare
repo reached through a `https://` URL rewritten with `git config url.<file-url>.insteadOf`.
The stub `claude` is also exported as `GRID_CLAUDE` (G5).

## Decisions

- Decided: this change ships six capabilities and two phases; Phase A groups (1 to 5) are built interactively, after `foundations`, and merge to `next` before the first overnight run; Phase B groups (6 to 8) are the only ones the overnight loop may take, and they merge after `instincts` per the cross-change merge order.
- Decided: every PR the loop builds targets `next` (the-grid's `loop/loop.conf` sets `BASE_BRANCH=next`); CI on `next` pushes is provided by `foundations#2`, not by this change.
- Decided: every model call on an unattended path passes an explicit `--model` plus a spend cap and a wall-clock cap: worker `--model WORKER_MODEL --max-budget-usd MAX_BUDGET_USD` (default 5) under `ISSUE_TIMEOUT`; review `--model REVIEW_MODEL --max-budget-usd REVIEW_BUDGET_USD` (default 2) under `REVIEW_TIMEOUT`; post-commit hook `--max-budget-usd GRID_REVIEW_BUDGET_USD` (default 1); cli-cron under `TIMEOUT_SECS` with the examples carrying `--model`; karpathy-loop under `cmd_timeout` and `max_iter` with README examples carrying `--model` and `--max-budget-usd`.
- Decided: base branch is a `{{BASE_BRANCH}}` placeholder filled by `instantiate.sh`, defaulting to the repo's `origin/HEAD` branch else `main`; the-grid's own instance sets `next`.
- Decided: integration modes are `pr` and `direct`; `pr` is the default for the `work`, `linux` and `mac-mini` profiles, `direct` for `personal` (interactive only). The headless runner is pr-only and exits 2 on `MODE=direct`; reason: under Q1 the runner, not the agent, integrates, and preflight requires a PR-only base, which a direct push would violate. Changes the old `mac-mini` default (direct) to pr.
- Decided: the prompt template holds both modes as `<!-- MODE:direct -->` / `<!-- MODE:pr -->` blocks and `instantiate.sh` keeps one with awk; reason: one source of truth, no per-profile template fork.
- Decided: the headless runner uses the same prompt template with a short override preamble rather than a second prompt file; reason: avoids two prompts drifting.
- Decided: in headless runs the runner creates the worktree AND does every GitHub write (push, PR, labels, comments); the agent only commits on `issue-<N>` and writes one outcome line to `$LOOP_OUTCOME_FILE`. The interactive `/loop` keeps the template's pr block (agent pushes with the operator's credentials). Reason: Q1 — the worker never holds a token.
- Decided: worktrees live in `$WORKTREE_ROOT` = `${LOOP_WORKTREE_ROOT:-<parent of repo>/<repo-name>-loop}/issue-<N>`; reason: outside the repo so no ignore rules are needed.
- Decided: the runner decides the outcome from git state plus the outcome line: a PR is opened only for `done` with a clean `issue-<N>` worktree at least one commit ahead of `origin/<base>`; `needs-human` maps to that label; everything else is `blocked`. The line can only confirm or downgrade, never cause a push without commits. The runner does not re-run `VERIFY_CMD`: the Opus review, CI on the PR and the human merge are the gate.
- Decided: infra failure = preflight failure, `claude` exit non-zero other than 124, `is_error` JSON that is not `error_max_turns`, or a `gh` call failing in the runner itself; the run stops at once, exit 1. Issue-level failure = timeout (124), max-turns, verify failure, ambiguous issue; the runner labels `blocked` or `needs-human`, comments, and continues.
- Decided: `--max-turns` is passed only when `claude --help` output contains `--max-turns`; `timeout` and `--max-budget-usd` are always passed. The plan assumed `--max-turns` exists; 2.1.295 does not list it. The probe runs once per run.
- Decided: `--output-format json` is used for both claude calls to read cost and error subtype; the parse is defensive (`jq -r '.total_cost_usd // empty'`) and the exact field names are re-checked during the sandbox proving step.
- Decided: workers run with `--dangerously-skip-permissions`; reason: unattended; containment is the dedicated loop user, the tokenless worker environment, the worktree, the PreToolUse guard (mistake-catcher), a fine-grained non-admin token and a ruleset requiring PRs on the base branch.
- Decided: the review call uses `--tools ""` (text in, text out, no tools) and the `opus` alias; reason: read-only by construction and cheapest correct form.
- Decided: reviews are posted as a PR comment, never as an approval or merge; the verdict line is advisory.
- Decided: `direct` mode is interactive-only (`personal` profile); the post-commit review hook covers it. The runner refuses it (exit 2).
- Decided: role routing is by issue label `role:<agent-name>` (e.g. `role:grid-backend-dev`); the worker runs `claude -p --agent <name>` with the same `--model`, budget and timeout as any worker (explicit `--model` is always passed; which of `--model` and the agent's `model:` frontmatter wins is checked in group 5). No label = default session, no `--agent`.
- Decided: an agent is "wired" when `<name>.md` exists in `${AGENTS_DIR:-$HOME/.claude/agents}` or the repo's `.claude/agents/`; an unwired name, or two `role:` labels, is an issue-level failure (`blocked` + comment, continue), checked before any worktree or model call.
- Decided: an agent whose frontmatter `tools:` line lists neither `Edit` nor `Write` (today `grid-qa-engineer`, `grid-security-reviewer`) is refused as a builder (issue-level failure); detection is by frontmatter, not a hard-coded list, so newly composed read-only roles are covered.
- Decided: the Opus review does NOT run as `--agent grid-qa-engineer`; it stays `claude -p --model opus --tools ""` with the fixed review prompt; reason: the review is text-in/text-out on a supplied diff, the QA role's procedure assumes tool use, its persona adds context tokens to every review, and the review must work on machines where that agent is not wired.
- Decided: the run record's `--role` is the routed agent name when present, else `RUN_ROLE` (default `issue-loop`).
- Decided: `instantiate.sh --role-labels a,b,c` creates `role:<name>` labels (colour 5319E7, create-if-absent, description "issue-loop: build as agent <name>"); default none. The-grid's re-cut passes `grid-backend-dev,grid-devops,grid-technical-writer,grid-sdet,grid-prompt-engineer,core-platform-engineer` (builders only; no label is created for read-only roles).
- Decided: the runner suppresses the in-session review hook with `GRID_LOOP_HEADLESS=1`; reason: one Opus review per PR, not a second Sonnet one per commit.
- Decided: `KillMode` stays at the systemd default (control-group) and the runner waits for every child before exiting; reason: with the hook suppressed no detached children exist, and control-group kills everything on a `systemctl stop` or timeout, which is what we want. `Type=oneshot` makes systemd wait for the runner.
- Decided: the runner (not the unit) parses the env file `${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env}` (keys `GH_TOKEN`, `LOOP_TRUSTED_ACTORS`, `LOOP_OPERATOR_HOME` only; never sourced, never `set -a`); `GH_TOKEN` lives in an unexported variable and is passed per call. Reason: one mechanism for systemd, launchd, cron and manual runs, and no code execution from a config file.
- Decided: Claude auth is checked with `claude auth status --json` (`.loggedIn == true`), no model call; the loop user's own credentials-file login is the only supported auth; `CLAUDE_CODE_OAUTH_TOKEN` is unset for every model call.
- Decided: the systemd unit sets `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin` (runner PATH handling: see the append Decided line below).
- Decided: the runner exports `GIT_TERMINAL_PROMPT=0` and preflights `git ls-remote --exit-code origin BASE_BRANCH`; reason: a credential prompt in a headless run hangs until the timeout instead of failing. HTTPS push auth is `gh auth setup-git` (human, as the loop user) plus the per-call `GH_TOKEN`.
- Decided: timer is `OnCalendar` daily at `--schedule-hour` (default 2), `Persistent=true`; no `RandomizedDelaySec`.
- Decided: `instantiate.sh` writes unit files and prints activation commands but never runs `systemctl`, `launchctl` or a state-changing `loginctl`; reason: state changes need the human. It may read `loginctl show-user` to warn that linger is off.
- Decided: unit output dirs are overridable with `SYSTEMD_USER_DIR` and `LAUNCH_AGENTS_DIR` env vars so tests never write to the real home.
- Decided: `loop.conf` is created only if absent; re-running `instantiate.sh` with changed flags prints "loop.conf exists, left alone" for a differing value rather than overwriting tuned caps.
- Decided: the guard hook ships as a pattern file (resolves the old TODO); `setup.sh` wires it whenever the file exists, so a clone or move restores it.
- Decided: `setup.sh` merges by removing only its own entries (matched by command basename); reason: never clobber other tools' hooks.
- Decided: `gate.sh` shellcheck coverage is extended to `automation-factory/patterns/*/*.sh` and `automation-factory/patterns/*/hooks/*.sh`; scripts must pass at `-S warning`.
- Decided: the-grid's own `loop/` is re-cut with `--profile work --base-branch next --verify-cmd "GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh"`; the loop user on the Linux box later re-runs `instantiate.sh` with `--profile linux` in its own clone to get its units. The Mac must not get systemd files.
- Decided: `SETUP_CMD` is empty for the-grid's instance; whether `scripts/gate.sh` passes inside a bare worktree (no submodules, no venv) is checked in group 5 (5.7); if it fails, the default fallback is `VERIFY_CMD="GRID_REQUIRE_DENYLIST=1 tests/lib/bats-core/bin/bats tests/"` with `SETUP_CMD="git submodule update --init tests/lib/bats-core"`.
- Decided: the sandbox proving step uses a throwaway PUBLIC GitHub repo (rulesets on private repos need a paid plan) with a `next` branch protected by a PR-requiring ruleset, two trivial issues ("add a line to README", "add a file `hello.txt`"), `VERIFY_CMD="test -f README.md"`; the-grid itself is not touched until it passes.
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
- Decided: the runner appends `$HOME/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` to PATH when absent (replaces "prepend `~/.local/bin` only when `claude` is missing"); reason: launchd and cron start with `/usr/bin:/bin`, so `gh`, `jq` and `gtimeout` are as invisible as `claude`; append (not prepend) so a system tool is never shadowed.
- Decided: timeout statuses 124 and 137 are both issue-level "timeout" (worker and review); reason: GNU `timeout -k` returns 137 when the child ignored TERM and was KILLed, which would otherwise be misread as an infrastructure failure and stop the whole night.
- Decided: command arrays start non-empty and no `producer | grep -q` / `| head` runs under `pipefail` (see "Bash 3.2 rules"); reason: both are real failures on macOS bash 3.2 (RAN) and silently pass on Linux bash 5.
- Decided: the worker runs with `</dev/null`; the review prompt's variable part (issue body + diff) goes in on stdin from a temp file, capped at 100000 bytes as well as `REVIEW_DIFF_LINES`; reason: `claude -p` waits on an open stdin, and a single argv string over 128 KiB fails with E2BIG on Linux.
- Decided: preflight additionally requires `git config user.name`/`user.email`, a `PreToolUse` guard entry in `.claude/settings.json`, and an env file that is not group/world accessible (`find -perm -077`); network and keyring probes run under `"$TIMEOUT_BIN" 60`; an SSH `origin` is now an exit 2, not a warning (Q1: an SSH key in the loop user's home would give the worker push access).
- Decided: the lock path is absolute, a stale lock is reclaimed by atomic `mv` then `rm -rf`, an empty pid file counts as held, and `trap cleanup EXIT` plus `trap 'exit 143' INT TERM HUP` remove the current worktree and the lock on every exit path; `git worktree prune` runs at start and worktrees are added with `--no-track`. Reason: `git rev-parse --git-common-dir` is relative in a main checkout (RAN), and a `systemctl stop` or TimeoutStartSec kill must not strand a worktree whose branch name blocks the next `worktree add -B`.
- Decided: the env file default is the fixed `$HOME/.config/the-grid/issue-loop.env` in runner, renderers, messages and docs; only the unit directory honours `XDG_CONFIG_HOME`; reason: a unit or cron job does not inherit the interactive `XDG_CONFIG_HOME`, so one path must serve all four launch routes.
- Decided: `SETUP_CMD` runs under `"$TIMEOUT_BIN" ISSUE_TIMEOUT`; reason: it is the one runner-side step with no model cap, and launchd and cron have no `TimeoutStartSec` backstop.
- Decided: the user unit has no `network-online.target` lines (a user manager does not know that target); renderers do NOT escape: any path/command word outside `[A-Za-z0-9_./@+-]` is refused with exit 2 (G2); the unit slug is sanitised to `[A-Za-z0-9_.-]`.
- Decided: when linger is off the linux profile prints the equivalent crontab line as the fires-while-logged-out alternative and never installs it; reason: with linger off the timer fires at next login, not overnight, and cron is the one scheduler that needs no linger.
- Decided: the launchd plist runs the runner directly (no `bash -l -c`), sets PATH explicitly, and logs under `$HOME/.grid/logs/` (machine-local state, D8).
- Decided (Q1): the unattended loop runs as a dedicated unprivileged OS user with its own HOME, clone, `claude` login and env file, and no read access to the operator's HOME; preflight enforces it mechanically (`LOOP_OPERATOR_HOME` must exist and not be listable). Operator confirmed 2026-10-09 (Q1: default accepted) — dedicated loop user + runner-does-push + trust gate + PR-ruleset/non-admin-token preflight (default YES).
- Decided (Q1): the worker, `SETUP_CMD` and the review call run under `env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN`; the worker argv adds `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources project,local`; group 5.6 confirms on the real CLI that `--settings` (guard hook) still applies and `--agent` still resolves user agents under `--setting-sources project,local`; if user agents do not resolve, the fallback is to look up agents only in `$REPO_ROOT/.claude/agents/` (written by `agent-factory/deploy.py`). Operator confirmed 2026-10-09 (Q1: default accepted) — same line.
- Decided (Q1): input trust gate before any worktree or model call: `author_association` in OWNER/MEMBER/COLLABORATOR; last `labeled` actor for `ISSUE_LABEL` in `LOOP_TRUSTED_ACTORS`; every body editor (GraphQL `userContentEdits`) and `renamed` actor in `LOOP_TRUSTED_ACTORS`; else `needs-human` + comment, continue. Issue comments are never given to the worker (the runner puts only title + body in the prompt and tells it not to fetch the issue). Operator confirmed 2026-10-09 (Q1: default accepted) — same line.
- Decided (Q1): preflight requires a repository ruleset with a `pull_request` rule on the base branch (`gh api repos/R/rules/branches/<base>`), and a token without Administration access (reading classic protection must fail with HTTP 403); exit 2 otherwise. The README documents the fine-grained PAT (single repo; Contents/Pull requests/Issues read-write, Metadata read; no Workflows, no Administration) and a ruleset with an EMPTY bypass list. Both API behaviours are UNVERIFIED on the drafting machine and are checked in group 5.6. Operator confirmed 2026-10-09 (Q1: default accepted) — same line.
- Decided (Q13, F6): the runner's PAT belongs to a separate GitHub machine-account collaborator (write access), never the operator; preflight 2e checks `gh api user --jq .login` with the PAT is NOT in `LOOP_TRUSTED_ACTORS` (exit 2); the runner pushes with `git -c core.hooksPath=/dev/null push --no-verify` so worker-planted hooks never run with the token. Reason: PRs opened by the machine account can be reviewed/approved by the operator, and a token-holder must not be able to satisfy the trust gate. Operator confirmed 2026-10-09 (Q13: default accepted).
- Decided (Q13 fallback): if HUMAN 5.1a shows a fine-grained PAT from the collaborator machine account cannot target a repo owned by another personal account, use a classic PAT with `public_repo` scope from a machine account whose ONLY collaborator access is this repo; preflight checks 2e (incl. token identity), 2h (PR ruleset) and 2i (classic protection read fails with HTTP 403) still apply unchanged. Operator confirmed 2026-10-09 (Q13: default accepted) — same line.
- Decided (Q1): proposal Non-goal reads "Isolation: dedicated unprivileged OS user; no container." Residual risk (same-uid worker can read the env file) is stated in the README and bounded by token scope plus the ruleset. Operator confirmed 2026-10-09 (Q1: default accepted) — same line.
- Decided (Q2): web tools (WebFetch, WebSearch) are NOT disabled in the worker, because the Q1 isolation preflight is mandatory for every headless run; rule-pack content issues may use WebFetch. If Q1 is answered NO, the worker argv gains `--disallowedTools WebFetch WebSearch`. Operator confirmed 2026-10-09 (Q2: default accepted) — WebFetch allowed in the loop worker only with Q1 isolation (default YES).
- Decided (Q8): `LABEL_BUDGETS` in `loop.conf` (space-separated `label=usd`) raises the worker's `--max-budget-usd` to the largest matching value; the-grid's `loop/loop.conf` sets `LABEL_BUDGETS=${LABEL_BUDGETS:-ws:rule-packs=15}`. Workers may use Opus subagents/reviewers inside that cap (rule-pack content PRs); the cap covers the whole `claude -p` call. Operator confirmed 2026-10-09 (Q8: default accepted) — `ws:rule-packs` issues get MAX_BUDGET_USD=15 and may use Opus reviewers (default YES).
- Decided (SEC2): the guard sources `${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh` and uses `grid_git_segments` when present (`hook-profiles#1`), else its own split; it also blocks `--mirror`, `--all`, `gh api` with `/merge` or `-X`/`--method` PUT/PATCH/DELETE. Spec text states "guard is a mistake-catcher; branch protection and token scope are the boundary". No hard dependency on hook-profiles: loops#1 (Phase A) is built before it merges; the shared-parser path is tested with a fixture `common.sh`.
- Decided (G2): `scripts/lib/render-schedule.sh` (loops#3) is the single schedule renderer with the signatures in "Scheduling"; daily and weekly schedules; `Persistent=true` on every timer; optional `RandomizedDelaySec` (4th arg of `render_systemd_timer`, requested by budget-and-usage); command-form dispatch for Python callers; print-only activation via `render_activation_commands`; unsafe path characters exit 2 (replaces the earlier escaping design).
- Decided (G5): `tests/helpers/stubs.bash` `make_stubs` (loops#1) is THE stub helper for every change; its `claude` stub is also exported as `GRID_CLAUDE` so code that honours that variable (agent-factory/run_evals.py convention) reaches it. No `GRID_CLAUDE_BIN`, no second stub helper.
- Decided (SEC14a): the-grid's loop `VERIFY_CMD` is `GRID_REQUIRE_DENYLIST=1 bash scripts/gate.sh`; HUMAN step 5.8 copies only `denylist.txt` (not the private repo) into the loop user's `~/.the-grid-private/denylist.txt`.
- Decided: `cli-cron` parses its own env file `${GRID_CRON_ENV:-$HOME/.config/the-grid/cli-cron.env}` (never sourced) and exports its pairs to the agent, plus `GRID_CRON=1` (SEC11a: capture hooks stand down); reason: cron jobs are the operator's trusted jobs and may need tokens, but must never receive the loop's token.
- Decided: run-record log stays at its existing default (G8); the loop user writes to its own home's default path.
