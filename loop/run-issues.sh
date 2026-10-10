#!/usr/bin/env bash
# loop/run-issues.sh — headless, capped, auditable issue-loop runner.
#
# One fresh `claude -p` session per issue, in its own git worktree, run by a
# dedicated unprivileged OS user. The worker model NEVER holds a GitHub token:
# the runner (not the agent) pushes, opens the PR, relabels and comments, using a
# 1-hour GitHub App installation token it keeps in an UNEXPORTED shell variable
# and hands to each gh/git call as GH_TOKEN. A stronger model (REVIEW_MODEL)
# reviews each PR diff and the runner posts that as a PR comment. One run-record
# line is written per issue.
#
# Usage:   bash loop/run-issues.sh        (from cron, launchd, a systemd unit, or by hand)
# Config:  loop/loop.conf (tracked, no secrets)   +   the loop user's env file
#          ${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env}  (mode 600, PARSED not
#          sourced; keys GH_APP_ID, GH_APP_INSTALLATION_ID, GH_APP_KEY_FILE,
#          LOOP_TRUSTED_ACTORS, LOOP_OPERATOR_HOME)
#
# Exit codes: 0 run finished (issue-level failures are fine; also "nothing to do"
#               and "another run holds the lock")
#             1 infrastructure failure mid-run (stopped early; the issue keeps its label)
#             2 preflight failed (nothing was touched)
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, mapfile, ${x,,},
# |&, local -n, wait -n; command arrays start non-empty; no `producer | head`
# under pipefail; no sed -i / stat -c / date -d / readlink -f / xargs -r.
# Never runs under `set -x` (the token would be traced).

set -euo pipefail

# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
log()  { printf '%s run-issues: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s run-issues: warning: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
# die_pre <message> — preflight failure: one stderr line naming the fix, exit 2.
die_pre() { echo "run-issues: $*" >&2; exit 2; }

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# loose_perms <file> — true when group or other has ANY access. (`find -perm -077`
# needs all six bits set, so every bit is tested on its own; GNU and BSD alike.)
loose_perms() {
  [ -n "$(find "$1" \( -perm -040 -o -perm -020 -o -perm -010 -o -perm -004 -o -perm -002 -o -perm -001 \) -print 2>/dev/null)" ]
}

# subst_all <from> <to> — literal replace on stdin -> stdout (no sed escaping needed).
subst_all() {
  if [ -z "$1" ]; then cat; return 0; fi
  FROM="$1" TO="$2" awk 'BEGIN { from = ENVIRON["FROM"]; to = ENVIRON["TO"]; n = length(from) }
    { line = $0; out = ""
      while ((i = index(line, from)) > 0) { out = out substr(line, 1, i - 1) to; line = substr(line, i + n) }
      print out line }'
}

# cut_bytes <n> <text> — first n bytes of text (via a file: no pipe, no SIGPIPE).
cut_bytes() {
  printf '%s' "$2" > "$TMP/cut.txt"
  head -c "$1" "$TMP/cut.txt"
}

# --------------------------------------------------------------------------
# step 1 — locate the repo, load config, parse the env file, fix PATH
# --------------------------------------------------------------------------
src="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "$src")/.." && pwd -P)"
[ -f "$REPO_ROOT/loop/loop.conf" ] || die_pre "loop/loop.conf not found under $REPO_ROOT; run scripts/instantiate.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/loop/loop.conf"

# Keys an older loop.conf may lack.
: "${GH_REPO:=}" "${BASE_BRANCH:=main}" "${ISSUE_LABEL:=ready-for-agent}" "${MODE:=pr}"
: "${LABEL_BUDGETS:=}" "${VERIFY_CMD:=}" "${SETUP_CMD:=}"
: "${PROJECT_CONTEXT:=a software project}" "${REVIEW_FOCUS:=correctness, style, test coverage}"
: "${MAX_ISSUES:=3}" "${MAX_TURNS:=40}" "${MAX_BUDGET_USD:=5}" "${REVIEW_BUDGET_USD:=2}"
: "${ISSUE_TIMEOUT:=1800}" "${REVIEW_TIMEOUT:=600}" "${WORKER_MODEL:=sonnet}" "${REVIEW_MODEL:=opus}"
: "${REVIEW_DIFF_LINES:=1500}" "${RUN_ROLE:=issue-loop}"

# Headless runs are pr-only: the runner integrates through PRs and preflight
# requires a PR-only base, which a direct push would violate.
if [ "$MODE" != "pr" ]; then
  die_pre "headless runs are pr-only; use direct mode from an interactive /loop"
fi
[ -n "$GH_REPO" ] || die_pre "GH_REPO is empty in loop/loop.conf"

# launchd and cron start with PATH=/usr/bin:/bin, so claude, gh, jq and gtimeout are
# invisible there. APPEND (never prepend) so no system tool is ever shadowed.
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$PATH:$d" ;;
  esac
done
export PATH

# A credential prompt in a headless run would hang until the timeout; fail instead.
export GIT_TERMINAL_PROMPT=0
if [ -z "${GIT_SSH_COMMAND:-}" ]; then export GIT_SSH_COMMAND="ssh -o BatchMode=yes"; fi

# Env file: a fixed default (never XDG_CONFIG_HOME, which a unit does not set).
ENV_FILE="${GRID_LOOP_ENV:-$HOME/.config/the-grid/issue-loop.env}"
# Start empty: the caller's environment must not smuggle these in.
GH_APP_ID=""; GH_APP_INSTALLATION_ID=""; GH_APP_KEY_FILE=""
LOOP_TRUSTED_ACTORS=""; LOOP_OPERATOR_HOME=""
if [ -f "$ENV_FILE" ]; then
  if loose_perms "$ENV_FILE"; then die_pre "$ENV_FILE is group/world accessible; run: chmod 600 $ENV_FILE"; fi
  # PARSED, never sourced and never `set -a`: a line like $(rm -rf ~) is just ignored text.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    [ "$key" != "$line" ] || continue
    val="${line#*=}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    case "$key" in
      GH_APP_ID) GH_APP_ID="$val" ;;
      GH_APP_INSTALLATION_ID) GH_APP_INSTALLATION_ID="$val" ;;
      GH_APP_KEY_FILE) GH_APP_KEY_FILE="$val" ;;
      LOOP_TRUSTED_ACTORS) LOOP_TRUSTED_ACTORS="$val" ;;
      LOOP_OPERATOR_HOME) LOOP_OPERATOR_HOME="$val" ;;
      GH_TOKEN|GITHUB_TOKEN)
        # a leftover long-lived PAT on disk would defeat the whole point of the App
        die_pre "remove $key from $ENV_FILE; the loop mints a GitHub App token" ;;
    esac
  done < "$ENV_FILE"
fi
KEY="${GH_APP_KEY_FILE:-$HOME/.config/the-grid/app.pem}"

# The worker environment must never carry these; also unset in the runner itself.
unset GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN

CLAUDE_BIN="${GRID_CLAUDE:-claude}"

# timeout binary: macOS has none by default.
TIMEOUT_BIN="${GRID_TIMEOUT_BIN:-}"
if [ -z "$TIMEOUT_BIN" ]; then
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
  fi
fi
[ -n "$TIMEOUT_BIN" ] || die_pre "no timeout binary; install GNU coreutils (macOS: brew install coreutils)"

OWNER="${GH_REPO%%/*}"
REPO_NAME="${GH_REPO##*/}"

TMP="$(mktemp -d)"
HAVE_LOCK=0
LOCK=""
CURRENT_WT=""
CHILD_PID=""

# cleanup — runs on EVERY exit path (normal, die, INFRA stop, signal).
cleanup() {
  trap - EXIT
  if [ -n "$CHILD_PID" ]; then kill -TERM "$CHILD_PID" 2>/dev/null || true; fi
  if [ -n "$CURRENT_WT" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$CURRENT_WT" >/dev/null 2>&1 || rm -rf "$CURRENT_WT"
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
  if [ "$HAVE_LOCK" = 1 ] && [ -n "$LOCK" ]; then rm -rf "$LOCK"; fi
}
trap cleanup EXIT
# bash defers a trap until the foreground child exits, so children run via
# run_child (background + wait), which a trapped signal interrupts at once.
trap 'exit 143' INT TERM HUP
# An unexpected command failure is an infrastructure failure (exit 1), not a
# stray status from whichever tool died. (-E: the trap also applies in functions.)
set -E
trap 'echo "run-issues: unexpected failure near line $LINENO" >&2; exit 1' ERR

# --- GitHub App token (kept in UNEXPORTED shell variables) ---
LOOP_GH_TOKEN=""
LOOP_APP_PERMS=""
LOOP_TOKEN_AT=0
MINT_ERR=""
TOKEN_REMINT_SECS="${GRID_LOOP_TOKEN_REMINT_SECS:-2700}"

# mint_token — mint an installation token; sets LOOP_GH_TOKEN/LOOP_APP_PERMS/LOOP_TOKEN_AT.
# Returns non-zero with the script's one-line reason in MINT_ERR.
mint_token() {
  local bin out rc=0
  if [ -n "${GRID_APP_TOKEN_BIN:-}" ]; then bin="$GRID_APP_TOKEN_BIN"
  elif [ -f "$REPO_ROOT/loop/gh-app-token.sh" ]; then bin="$REPO_ROOT/loop/gh-app-token.sh"
  else bin="${GRID_DIR:-$HOME/.the-grid}/scripts/lib/gh-app-token.sh"
  fi
  if [ ! -f "$bin" ]; then MINT_ERR="gh-app-token.sh not found ($bin)"; return 1; fi
  out="$(GH_APP_ID="$GH_APP_ID" GH_APP_INSTALLATION_ID="$GH_APP_INSTALLATION_ID" GH_APP_KEY_FILE="$KEY" \
    bash "$bin" --json 2>"$TMP/mint.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    MINT_ERR="$(sed -n '1p' "$TMP/mint.err")"
    [ -n "$MINT_ERR" ] || MINT_ERR="gh-app-token.sh exited $rc"
    return 1
  fi
  LOOP_GH_TOKEN="$(printf '%s' "$out" | jq -r '.token // empty')"
  LOOP_APP_PERMS="$(printf '%s' "$out" | jq -c '.permissions // empty')"
  out=""
  if [ -z "$LOOP_GH_TOKEN" ]; then MINT_ERR="gh-app-token.sh returned no token"; return 1; fi
  LOOP_TOKEN_AT="$(date +%s)"
  return 0
}

# gh_t / git_t — a GitHub call with the token passed for THIS call only.
gh_t()  { GH_TOKEN="$LOOP_GH_TOKEN" "$TIMEOUT_BIN" 60 gh "$@"; }
git_t() { GH_TOKEN="$LOOP_GH_TOKEN" "$TIMEOUT_BIN" 300 git "$@"; }

# --------------------------------------------------------------------------
# step 2 — preflight (any failure: one stderr line naming the fix, exit 2)
# --------------------------------------------------------------------------
# 2a tools and git identity
for tool in git gh jq curl openssl; do
  command -v "$tool" >/dev/null 2>&1 || die_pre "$tool is required but not on PATH"
done
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die_pre "claude is required but not on PATH (native install: ~/.local/bin)"
[ -n "$(git -C "$REPO_ROOT" config user.name || true)" ] || die_pre "git user.name is not set in $REPO_ROOT; run: git config user.name <name>"
[ -n "$(git -C "$REPO_ROOT" config user.email || true)" ] || die_pre "git user.email is not set in $REPO_ROOT; run: git config user.email <email>"

# 2b trusted actors and isolation from the operator's home
[ -n "$LOOP_TRUSTED_ACTORS" ] || die_pre "set LOOP_TRUSTED_ACTORS in $ENV_FILE"
if [ -z "$LOOP_OPERATOR_HOME" ] || [ ! -e "$LOOP_OPERATOR_HOME" ] || ls "$LOOP_OPERATOR_HOME" >/dev/null 2>&1; then
  die_pre "run the loop as a dedicated user that cannot read the operator's home (LOOP_OPERATOR_HOME in $ENV_FILE must exist and be unlistable); see README"
fi
TRUSTED=",$(lc "$LOOP_TRUSTED_ACTORS" | tr -d ' '),"
# is_trusted <login> — logins compared lower-cased.
is_trusted() {
  [ -n "$1" ] || return 1
  case "$TRUSTED" in
    *",$(lc "$1"),"*) return 0 ;;
  esac
  return 1
}

# 2c the PreToolUse guard is wired for THIS checkout
GUARD_HOOK="$REPO_ROOT/loop/hooks/guard-main-push.sh"
SETTINGS="$REPO_ROOT/.claude/settings.json"
if [ ! -x "$GUARD_HOOK" ] || [ ! -f "$SETTINGS" ] \
   || ! jq -e --arg c "$GUARD_HOOK" '[.hooks.PreToolUse[]?.hooks[]?.command] | index($c) != null' "$SETTINGS" >/dev/null 2>&1; then
  die_pre "guard hook not wired for $REPO_ROOT; run bash loop/setup.sh"
fi

# 2d claude is logged in as this user (no model call)
auth_out="$(env -u CLAUDE_CODE_OAUTH_TOKEN "$TIMEOUT_BIN" 60 "$CLAUDE_BIN" auth status --json 2>/dev/null || true)"
if ! printf '%s' "$auth_out" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
  die_pre "claude not logged in for this user; run \`claude\` once interactively as the loop user"
fi

# 2e GitHub App identity
[ -n "$GH_APP_ID" ] || die_pre "set GH_APP_ID in $ENV_FILE"
[ -f "$KEY" ] || die_pre "put the App private key at $KEY, mode 600; see README"
if loose_perms "$KEY"; then die_pre "$KEY is group/world accessible; run: chmod 600 $KEY"; fi
if ! mint_token; then die_pre "$MINT_ERR"; fi
if env -u GH_TOKEN -u GITHUB_TOKEN "$TIMEOUT_BIN" 60 gh auth status >/dev/null 2>&1; then
  die_pre "this user has a stored gh login the worker could use; run gh auth logout"
fi
repos_json="$(gh_t api "/installation/repositories?per_page=100" 2>/dev/null || true)"
if ! printf '%s' "$repos_json" | jq -e --arg r "$(lc "$GH_REPO")" '[.repositories[]?.full_name | ascii_downcase] | index($r) != null' >/dev/null 2>&1 \
   || gh_t api user >/dev/null 2>&1; then
  die_pre "the token is not a GitHub App installation token for $GH_REPO; see README"
fi

# 2f origin must be https (an SSH key in this user's home would give the worker push access).
# The raw config value is read: `git remote get-url` would show an insteadOf rewrite.
origin_url="$(git -C "$REPO_ROOT" config --get remote.origin.url || true)"
case "$origin_url" in
  https://*) ;;
  *) die_pre "origin must be https (is: ${origin_url:-unset}); an SSH key in this user's home would give the worker push access" ;;
esac

# 2g the base branch exists on origin
if ! git_t -C "$REPO_ROOT" ls-remote --exit-code origin "refs/heads/$BASE_BRANCH" >/dev/null 2>&1; then
  die_pre "cannot reach origin or branch $BASE_BRANCH does not exist there (git ls-remote failed)"
fi

# 2h a ruleset requiring a pull request applies to the base branch
rules_json="$(gh_t api "repos/$GH_REPO/rules/branches/$BASE_BRANCH" 2>/dev/null || true)"
n_pr_rules="$(printf '%s' "$rules_json" | jq '[.[]? | select(.type == "pull_request")] | length' 2>/dev/null || true)"
case "$n_pr_rules" in
  ""|*[!0-9]*) n_pr_rules=0 ;;
esac
if [ "$n_pr_rules" -lt 1 ]; then
  die_pre "add a ruleset requiring a pull request on $BASE_BRANCH, empty bypass list; classic protection cannot be verified with a non-admin token"
fi

# 2i the App must not hold Administration or Workflows
if ! printf '%s' "$LOOP_APP_PERMS" | jq -e 'type == "object" and (has("administration") | not) and (has("workflows") | not)' >/dev/null 2>&1; then
  die_pre "the App has Administration or Workflows permission, or the token response lacked permissions; set the App permissions as in the README"
fi

# 2j clean tree, then the lock (absolute path: --git-common-dir is relative in a main checkout)
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || die_pre "$REPO_ROOT has uncommitted changes; commit or discard them"
LOCK="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/issue-loop.lock"
acquire_lock() {
  local pid=""
  if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; HAVE_LOCK=1; return 0; fi
  if [ -f "$LOCK/pid" ]; then pid="$(cat "$LOCK/pid" 2>/dev/null || true)"; fi
  # pid file missing or empty = held (the owner may be between mkdir and the write)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    # stale: rename is atomic, so two reclaimers cannot both win
    if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      rm -rf "$LOCK.stale.$$"
      if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; HAVE_LOCK=1; return 0; fi
    fi
  fi
  log "another run holds the lock ($LOCK${pid:+, pid $pid}); exiting"
  exit 0
}
acquire_lock

# --------------------------------------------------------------------------
# run bookkeeping
# --------------------------------------------------------------------------
N_OK=0; N_SKIPPED=0; N_ERROR=0
RUN_RECORD=""
if [ -n "${GRID_RUN_RECORD:-}" ] && [ -f "$GRID_RUN_RECORD" ]; then RUN_RECORD="$GRID_RUN_RECORD"
elif [ -f "${GRID_DIR:-$HOME/.the-grid}/scripts/run-record.sh" ]; then RUN_RECORD="${GRID_DIR:-$HOME/.the-grid}/scripts/run-record.sh"
elif [ -f "$REPO_ROOT/scripts/run-record.sh" ]; then RUN_RECORD="$REPO_ROOT/scripts/run-record.sh"
fi
[ -n "$RUN_RECORD" ] || warn "run-record.sh not found; run records are skipped"

# record_run <issue> <outcome> <cost> <note> — best effort, never fails the run.
record_run() {
  local n="$1" outcome="$2" cost="$3" note="$4"
  [ -n "$RUN_RECORD" ] || return 0
  local args
  args=(--role "${ROLE:-$RUN_ROLE}" --action work-issue --target "$GH_REPO#$n" --outcome "$outcome" --note "$(cut_bytes 500 "$note")")
  if [ -n "$cost" ]; then args+=(--cost-usd "$cost"); fi
  bash "$RUN_RECORD" "${args[@]}" >/dev/null 2>&1 || warn "run-record.sh failed for $GH_REPO#$n"
  return 0
}

# infra_fail <issue-or-""> <message> [stderr-file] — stop the run (exit 1). The
# issue keeps its opt-in label so the next run retries it.
infra_fail() {
  local n="$1" msg="$2" errf="${3:-}"
  echo "run-issues: INFRASTRUCTURE FAILURE${n:+ on #$n}: $msg" >&2
  if [ -n "$errf" ] && [ -s "$errf" ]; then
    echo "--- last 20 lines of $(basename "$errf") ---" >&2
    tail -n 20 "$errf" >&2
  fi
  if [ -n "$n" ]; then record_run "$n" error "" "infra: $msg"; fi
  exit 1
}

# ensure_token — re-mint when the token is older than TOKEN_REMINT_SECS (a run can
# outlast the 1-hour token). A failed re-mint is an INFRA failure.
ensure_token() {
  local now
  now="$(date +%s)"
  if [ $((now - LOOP_TOKEN_AT)) -ge "$TOKEN_REMINT_SECS" ]; then
    if ! mint_token; then infra_fail "${CUR_ISSUE:-}" "could not re-mint the GitHub App token: $MINT_ERR"; fi
  fi
}

# run_child <out> <err> <in> <dir> cmd... — run cmd in <dir> with the given
# redirects as a BACKGROUND job and wait for it, so a trapped signal interrupts
# the wait at once. Sets CHILD_RC. The subshell execs cmd, so CHILD_PID is the
# command itself (timeout forwards TERM to its child).
run_child() {
  local out="$1" err="$2" in="$3" dir="$4"
  shift 4
  ( cd "$dir" || exit 97; exec "$@" ) < "$in" > "$out" 2> "$err" &
  CHILD_PID=$!
  CHILD_RC=0
  wait "$CHILD_PID" || CHILD_RC=$?
  CHILD_PID=""
}

# post a comment on the issue from text (token scrubbed, via --body-file)
comment_issue() {
  local n="$1" text="$2"
  printf '%s\n' "$text" | subst_all "$LOOP_GH_TOKEN" "***" > "$TMP/comment.txt"
  gh_t issue comment "$n" --repo "$GH_REPO" --body-file "$TMP/comment.txt" >/dev/null \
    || infra_fail "$n" "gh issue comment failed"
}
# label_issue <n> <add-label> — add <label>, remove the opt-in label.
label_issue() {
  gh_t issue edit "$1" --repo "$GH_REPO" --add-label "$2" --remove-label "$ISSUE_LABEL" >/dev/null \
    || infra_fail "$1" "gh issue edit failed"
}

# --------------------------------------------------------------------------
# step 3 — sync, probe
# --------------------------------------------------------------------------
git -C "$REPO_ROOT" worktree prune
# (explicit refspec: origin/<base> must be updated whatever fetch refspec the clone has)
git_t -C "$REPO_ROOT" fetch origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" >/dev/null 2>"$TMP/fetch.err" \
  || infra_fail "" "git fetch origin $BASE_BRANCH failed" "$TMP/fetch.err"

# --max-turns is passed only when the CLI lists it (2.1.295 does not); probed once.
SUPPORTS_MAX_TURNS=0
help_out="$(env -u CLAUDE_CODE_OAUTH_TOKEN "$TIMEOUT_BIN" 60 "$CLAUDE_BIN" --help 2>&1 || true)"
case "$help_out" in
  *--max-turns*) SUPPORTS_MAX_TURNS=1 ;;
esac

WORKTREE_ROOT="${LOOP_WORKTREE_ROOT:-$(dirname "$REPO_ROOT")/$(basename "$REPO_ROOT")-loop}"
TEMPLATE="$REPO_ROOT/loop/loop-prompt.template.md"
[ -f "$TEMPLATE" ] || { echo "run-issues: $TEMPLATE not found; run scripts/instantiate.sh" >&2; exit 2; }

# --------------------------------------------------------------------------
# step 4 — which issues
# --------------------------------------------------------------------------
# `sed -n`, not `head`: head exits early and under pipefail the producer can die
# with SIGPIPE (141). --limit 100 because the gh default is 30.
list_out="$(gh_t issue list --repo "$GH_REPO" --state open --label "$ISSUE_LABEL" --limit 100 --json number -q '.[].number' \
  2>"$TMP/list.err")" || infra_fail "" "gh issue list failed" "$TMP/list.err"
ISSUES=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  ISSUES="$ISSUES $n"
done <<EOF
$(printf '%s\n' "$list_out" | sort -n | sed -n "1,${MAX_ISSUES}p")
EOF
if [ -z "$ISSUES" ]; then
  log "nothing to do: no open issue labelled $ISSUE_LABEL"
  exit 0
fi
log "issues this run:$ISSUES"

# --------------------------------------------------------------------------
# step 5 — per issue
# --------------------------------------------------------------------------
# Outcome of the current issue (set by the helpers below).
OUTCOME=""; NOTE=""; COST_W=""; COST_R=""; ROLE=""; CUR_ISSUE=""; WT=""

# issue_blocked <n> <reason> — label blocked, comment, outcome error.
issue_blocked() {
  label_issue "$1" blocked
  comment_issue "$1" "issue-loop could not land this: $2"
  OUTCOME="error"; NOTE="$2"
}

# sum_costs <a> <b> — decimal sum or empty.
sum_costs() {
  if [ -z "$1" ] && [ -z "$2" ]; then return 0; fi
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.4f", a + b }'
}

process_issue() {
  local n="$1" issue_json title author_assoc last_labeller editor_logins renamed_actors a
  local label_names role_count role_file fm_tools budget pair plabel pusd
  local prompt_file prompt
  local cmd line reason worker_json is_err subtype

  CUR_ISSUE="$n"; OUTCOME=""; NOTE=""; COST_W=""; COST_R=""; ROLE=""; WT=""
  ensure_token

  # 5a: an open PR or a pushed branch already exists for this issue: leave it alone
  local pr_open remote_branch
  pr_open="$(gh_t pr list --repo "$GH_REPO" --head "issue-$n" --state open --json number -q '.[].number' 2>"$TMP/e.err")" \
    || infra_fail "$n" "gh pr list failed" "$TMP/e.err"
  remote_branch="$(git_t -C "$REPO_ROOT" ls-remote --heads origin "issue-$n" 2>"$TMP/e.err")" \
    || infra_fail "$n" "git ls-remote failed" "$TMP/e.err"
  if [ -n "$pr_open" ] || [ -n "$remote_branch" ]; then
    OUTCOME="skipped"; NOTE="branch or PR exists"
    return 0
  fi

  # one read supplies the prompt text and the labels
  issue_json="$(gh_t issue view "$n" --repo "$GH_REPO" --json title,body,labels 2>"$TMP/e.err")" \
    || infra_fail "$n" "gh issue view failed" "$TMP/e.err"
  title="$(printf '%s' "$issue_json" | jq -r '.title // ""')"

  # 5a1: trust gate. The issue text is the worker's whole task, so it must come from
  # a trusted person who labelled it. Nothing below creates a worktree or calls a model
  # until every check passes.
  local gate_fail=""
  author_assoc="$(gh_t api "repos/$GH_REPO/issues/$n" 2>"$TMP/e.err" | jq -r '.author_association // ""')" \
    || infra_fail "$n" "gh api issue read failed" "$TMP/e.err"
  case "$author_assoc" in
    OWNER|MEMBER|COLLABORATOR) ;;
    *) gate_fail="author check: author_association is '${author_assoc:-unknown}', need OWNER, MEMBER or COLLABORATOR" ;;
  esac
  if [ -z "$gate_fail" ]; then
    gh_t api --paginate "repos/$GH_REPO/issues/$n/events" > "$TMP/$n.events.json" 2>"$TMP/e.err" \
      || infra_fail "$n" "gh api issue events failed" "$TMP/e.err"
    last_labeller="$(jq -s -r --arg l "$ISSUE_LABEL" \
      '[.[][] | select(.event == "labeled" and .label.name == $l)] | last | .actor.login // ""' "$TMP/$n.events.json")"
    if ! is_trusted "$last_labeller"; then
      gate_fail="label check: '$ISSUE_LABEL' was applied by '${last_labeller:-unknown}', who is not in LOOP_TRUSTED_ACTORS"
    fi
  fi
  if [ -z "$gate_fail" ]; then
    renamed_actors="$(jq -s -r '[.[][] | select(.event == "renamed") | .actor.login // "unknown"] | .[]' "$TMP/$n.events.json")"
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      if ! is_trusted "$a"; then gate_fail="rename check: the title was edited by '$a', who is not in LOOP_TRUSTED_ACTORS"; break; fi
    done <<EOF
$renamed_actors
EOF
  fi
  if [ -z "$gate_fail" ]; then
    gh_t api graphql \
      -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){userContentEdits(first:100){nodes{editor{login}}}}}}' \
      -F o="$OWNER" -F r="$REPO_NAME" -F n="$n" > "$TMP/$n.edits.json" 2>"$TMP/e.err" \
      || infra_fail "$n" "gh api graphql (body edits) failed" "$TMP/e.err"
    editor_logins="$(jq -r '.data.repository.issue.userContentEdits.nodes[]? | (.editor.login // "ghost")' "$TMP/$n.edits.json")"
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      if ! is_trusted "$a"; then gate_fail="edit check: the body was edited by '$a', who is not in LOOP_TRUSTED_ACTORS"; break; fi
    done <<EOF
$editor_logins
EOF
  fi
  if [ -n "$gate_fail" ]; then
    label_issue "$n" needs-human
    comment_issue "$n" "issue-loop trust gate: $gate_fail"
    OUTCOME="skipped"; NOTE="trust gate: $gate_fail"
    return 0
  fi

  # 5a2: role routing (label role:<agent>) and the per-label budget
  label_names="$(printf '%s' "$issue_json" | jq -r '.labels[]?.name')"
  role_count=0
  while IFS= read -r a; do
    case "$a" in
      role:*) role_count=$((role_count + 1)); ROLE="${a#role:}" ;;
    esac
  done <<EOF
$label_names
EOF
  if [ "$role_count" -gt 1 ]; then
    ROLE=""
    issue_blocked "$n" "more than one role: label on the issue; keep exactly one"
    return 0
  fi
  if [ "$role_count" -eq 1 ]; then
    case "$ROLE" in
      ""|*[!A-Za-z0-9._-]*)
        ROLE=""
        issue_blocked "$n" "the role: label is not a valid agent name"
        return 0 ;;
    esac
    role_file=""
    if [ -f "${AGENTS_DIR:-$HOME/.claude/agents}/$ROLE.md" ]; then role_file="${AGENTS_DIR:-$HOME/.claude/agents}/$ROLE.md"
    elif [ -f "$REPO_ROOT/.claude/agents/$ROLE.md" ]; then role_file="$REPO_ROOT/.claude/agents/$ROLE.md"
    fi
    if [ -z "$role_file" ]; then
      issue_blocked "$n" "role:$ROLE names no wired agent ($ROLE.md not found in the agents dirs)"
      return 0
    fi
    # frontmatter tools: line (first --- block); an agent that cannot Edit or Write cannot build
    fm_tools="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^tools:/ { print; exit }' "$role_file")"
    if [ -n "$fm_tools" ]; then
      case "$fm_tools" in
        *Edit*|*Write*) ;;
        *) issue_blocked "$n" "agent $ROLE is read-only (tools: has neither Edit nor Write) and cannot build"; return 0 ;;
      esac
    fi
  fi
  # the largest LABEL_BUDGETS value whose label the issue carries wins (membership by case, not grep -q)
  budget="$MAX_BUDGET_USD"
  local labels_padded="|"
  while IFS= read -r a; do
    if [ -n "$a" ]; then labels_padded="$labels_padded$a|"; fi
  done <<EOF
$label_names
EOF
  for pair in $LABEL_BUDGETS; do
    plabel="${pair%=*}"; pusd="${pair##*=}"
    case "$labels_padded" in
      *"|$plabel|"*)
        if awk -v a="$pusd" -v b="$budget" 'BEGIN { exit !(a + 0 > b + 0) }'; then budget="$pusd"; fi ;;
    esac
  done

  # 5b: worktree off origin/<base>
  WT="$WORKTREE_ROOT/issue-$n"
  if [ -e "$WT" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git -C "$REPO_ROOT" worktree prune
  fi
  mkdir -p "$WORKTREE_ROOT"
  if ! git -C "$REPO_ROOT" worktree add --no-track -B "issue-$n" "$WT" "origin/$BASE_BRANCH" >/dev/null 2>"$TMP/e.err"; then
    issue_blocked "$n" "could not create the worktree: $(cut_bytes 300 "$(cat "$TMP/e.err")")"
    WT=""
    return 0
  fi
  CURRENT_WT="$WT"

  # 5c: setup command (the one runner-side step with no model cap: it gets a timeout)
  if [ -n "$SETUP_CMD" ]; then
    run_child "$TMP/$n.setup.out" "$TMP/$n.setup.err" /dev/null "$WT" \
      env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN "$TIMEOUT_BIN" "$ISSUE_TIMEOUT" bash -c "$SETUP_CMD"
    if [ "$CHILD_RC" -ne 0 ]; then
      issue_blocked "$n" "SETUP_CMD failed (exit $CHILD_RC)"
      return 0
    fi
  fi

  # 5d: prompt = headless preamble + the instantiated template with {{WORKING_DIR}} -> the worktree
  printf '%s' "$issue_json" | jq -r '.body // ""' > "$TMP/$n.body"
  prompt_file="$TMP/$n.prompt"
  {
    printf 'HEADLESS RUN for issue #%s. You have no GitHub token.\n' "$n"
    printf 'Skip STEP 1 and STEP 6. In STEP 5 commit only: do NOT push, do NOT run gh, do\n'
    printf 'NOT open a PR; the runner does that. Wherever a step says to label, comment on\n'
    printf 'or close the issue, write the outcome line instead. Do not fetch the issue or\n'
    printf 'its comments; the issue text is below and is the whole task.\n'
    printf 'Finish by writing exactly one line to $LOOP_OUTCOME_FILE:\n'
    printf '  done | needs-human <reason> | blocked <reason>\n'
    printf -- '--- ISSUE #%s: %s\n' "$n" "$title"
    head -c 60000 "$TMP/$n.body"
    if [ "$(wc -c < "$TMP/$n.body" | tr -d ' ')" -gt 60000 ]; then printf '\n[TRUNCATED]\n'; fi
    printf '\n---\n\n'
    subst_all "{{WORKING_DIR}}" "$WT" < "$TEMPLATE"
  } > "$prompt_file"
  prompt="$(cat "$prompt_file")"

  # 5e: the worker. Optional flags are appended to a NON-EMPTY array (bash 3.2 + set -u).
  local outcome_file="$TMP/$n.outcome"
  cmd=("$TIMEOUT_BIN" -k 30 "$ISSUE_TIMEOUT" "$CLAUDE_BIN" -p)
  if [ -n "$ROLE" ]; then cmd+=(--agent "$ROLE"); fi
  cmd+=(--model "$WORKER_MODEL" --max-budget-usd "$budget")
  if [ "$SUPPORTS_MAX_TURNS" = 1 ]; then cmd+=(--max-turns "$MAX_TURNS"); fi
  cmd+=(--output-format json --dangerously-skip-permissions --settings "$SETTINGS"
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources 'project,local' "$prompt")
  log "issue #$n: worker starting${ROLE:+ (agent $ROLE)}, budget \$$budget"
  # stdin is /dev/null: `claude -p` waits for EOF on a pipe or an open ssh channel.
  run_child "$TMP/$n.worker.json" "$TMP/$n.worker.err" /dev/null "$WT" \
    env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    LOOP_OUTCOME_FILE="$outcome_file" GRID_LOOP_HEADLESS=1 "${cmd[@]}"

  # 5f: classify the worker exit
  case "$CHILD_RC" in
    124|137)
      issue_blocked "$n" "timeout: the worker ran past ISSUE_TIMEOUT (${ISSUE_TIMEOUT}s)"
      return 0 ;;
    0) ;;
    *) infra_fail "$n" "claude exited $CHILD_RC" "$TMP/$n.worker.err" ;;
  esac
  worker_json="$TMP/$n.worker.json"
  if ! jq -e . "$worker_json" >/dev/null 2>&1; then
    infra_fail "$n" "worker output was not JSON" "$TMP/$n.worker.err"
  fi
  is_err="$(jq -r '.is_error // false' "$worker_json")"
  subtype="$(jq -r '.subtype // ""' "$worker_json")"
  COST_W="$(jq -r '.total_cost_usd // empty' "$worker_json")"
  if [ "$subtype" = "error_max_turns" ]; then
    issue_blocked "$n" "max-turns: the worker hit the turn limit"
    return 0
  fi
  if [ "$is_err" = "true" ]; then
    infra_fail "$n" "claude returned an error result ($subtype)" "$TMP/$n.worker.err"
  fi

  # 5g: integrate. Only the runner pushes; the outcome line can confirm or downgrade, never
  # cause a push without commits.
  line=""
  if [ -f "$outcome_file" ]; then line="$(sed -n '1p' "$outcome_file" | tr -d '\r')"; fi
  case "$line" in
    done)
      local branch dirty ahead
      branch="$(git -C "$WT" branch --show-current)"
      dirty="$(git -C "$WT" status --porcelain)"
      ahead="$(git -C "$WT" rev-list --count "origin/$BASE_BRANCH..HEAD")"
      if [ "$branch" != "issue-$n" ]; then
        issue_blocked "$n" "the worker left the worktree on branch '${branch:-detached}', not issue-$n"; return 0
      fi
      if [ -n "$dirty" ]; then
        issue_blocked "$n" "the worker left uncommitted changes in the worktree"; return 0
      fi
      if [ "$ahead" -lt 1 ]; then
        issue_blocked "$n" "the loop ended without a commit"; return 0
      fi
      ensure_token
      # hooks off: a hook the worker planted in the worktree must never run while the
      # token is in the environment; explicit refspec.
      if ! git_t -C "$WT" -c core.hooksPath=/dev/null push --no-verify origin "HEAD:refs/heads/issue-$n" >/dev/null 2>"$TMP/$n.push.err"; then
        issue_blocked "$n" "push rejected: $(cut_bytes 300 "$(cat "$TMP/$n.push.err")")"
        return 0
      fi
      printf 'Closes #%s\n\nOpened by the issue-loop runner (worker model: %s).\n' "$n" "$WORKER_MODEL" > "$TMP/$n.prbody"
      local pr_url pr_num
      pr_url="$(gh_t pr create --repo "$GH_REPO" --base "$BASE_BRANCH" --head "issue-$n" --title "$title (#$n)" --body-file "$TMP/$n.prbody" 2>"$TMP/e.err" | tail -n 1)" || pr_url=""
      if [ -z "$pr_url" ]; then
        issue_blocked "$n" "the branch was pushed but gh pr create failed: $(cut_bytes 300 "$(cat "$TMP/e.err")")"
        return 0
      fi
      pr_num="${pr_url##*/}"
      label_issue "$n" ready-for-human
      comment_issue "$n" "PR opened: $pr_url. Needs human review and merge."
      OUTCOME="ok"; NOTE="PR $pr_url"
      ;;
    needs-human*)
      reason="$(cut_bytes 500 "${line#needs-human}")"
      label_issue "$n" needs-human
      comment_issue "$n" "issue-loop skipped this: needs a human.${reason:+ Reason:$reason}"
      OUTCOME="skipped"; NOTE="needs-human:$reason"
      return 0 ;;
    *)
      if [ -z "$line" ]; then reason="the worker wrote no outcome line"
      else reason="$(cut_bytes 500 "${line#blocked}")"; reason="${reason# }"; [ -n "$reason" ] || reason="the worker reported blocked"; fi
      issue_blocked "$n" "$reason"
      return 0 ;;
  esac

  # 5h: review (only for an opened PR). Text in, text out, no tools; the diff goes in on
  # stdin from a capped file because one argv string is limited to 128 KiB (E2BIG).
  local diff_lines review_in review_prompt rev_json rev_text
  gh_t pr diff "$pr_num" --repo "$GH_REPO" > "$TMP/$n.diff.full" 2>"$TMP/e.err" || : > "$TMP/$n.diff.full"
  diff_lines="$(wc -l < "$TMP/$n.diff.full" | tr -d ' ')"
  review_in="$TMP/$n.review.in"
  {
    if [ "$diff_lines" -gt "$REVIEW_DIFF_LINES" ]; then
      printf 'NOTE: the diff is TRUNCATED to its first %s of %s lines.\n\n' "$REVIEW_DIFF_LINES" "$diff_lines"
    fi
    printf '=== ISSUE #%s: %s\n' "$n" "$title"
    cat "$TMP/$n.body"
    printf '\n=== DIFF\n'
    sed -n "1,${REVIEW_DIFF_LINES}p" "$TMP/$n.diff.full"
  } > "$TMP/$n.review.full"
  head -c 100000 "$TMP/$n.review.full" > "$review_in"
  if [ "$(wc -c < "$TMP/$n.review.full" | tr -d ' ')" -gt 100000 ]; then printf '\n[TRUNCATED at 100000 bytes]\n' >> "$review_in"; fi
  review_prompt="You are a code reviewer for ${PROJECT_CONTEXT}. The issue and a pull-request diff are on stdin. Judge the diff against the issue's acceptance criteria. Focus on: ${REVIEW_FOCUS}. You have no tools; do not ask to run anything. Answer with 3 to 7 bullets, each tagged [blocker], [should-fix] or [nit], then one final line: VERDICT: approve | changes-requested"
  run_child "$TMP/$n.review.json" "$TMP/$n.review.err" "$review_in" "$TMP" \
    env -u GH_TOKEN -u GITHUB_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
    "$TIMEOUT_BIN" -k 30 "$REVIEW_TIMEOUT" "$CLAUDE_BIN" -p --model "$REVIEW_MODEL" \
    --max-budget-usd "$REVIEW_BUDGET_USD" --tools "" --output-format json "$review_prompt"
  case "$CHILD_RC" in
    0) ;;
    124|137) NOTE="$NOTE; review timeout"; return 0 ;;
    *) infra_fail "$n" "review claude exited $CHILD_RC" "$TMP/$n.review.err" ;;
  esac
  rev_json="$TMP/$n.review.json"
  if ! jq -e . "$rev_json" >/dev/null 2>&1; then infra_fail "$n" "review output was not JSON" "$TMP/$n.review.err"; fi
  if [ "$(jq -r '.is_error // false' "$rev_json")" = "true" ]; then
    infra_fail "$n" "review returned an error result ($(jq -r '.subtype // ""' "$rev_json"))" "$TMP/$n.review.err"
  fi
  COST_R="$(jq -r '.total_cost_usd // empty' "$rev_json")"
  rev_text="$(jq -r '.result // empty' "$rev_json")"
  if [ -z "$rev_text" ]; then NOTE="$NOTE; review empty"; return 0; fi
  ensure_token
  printf '**issue-loop review (%s)**\n\n%s\n\n_Advisory only: a human reviews and merges._\n' "$REVIEW_MODEL" "$rev_text" \
    | subst_all "$LOOP_GH_TOKEN" "***" > "$TMP/$n.review.comment"
  gh_t pr comment "$pr_num" --repo "$GH_REPO" --body-file "$TMP/$n.review.comment" >/dev/null \
    || infra_fail "$n" "gh pr comment failed"
  return 0
}

for ISSUE in $ISSUES; do
  process_issue "$ISSUE"
  # 5i: the worktree goes away on every path; the branch is kept
  if [ -n "$CURRENT_WT" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$CURRENT_WT" >/dev/null 2>&1 || rm -rf "$CURRENT_WT"
    git -C "$REPO_ROOT" worktree prune
    CURRENT_WT=""
  fi
  # 5j: one run-record line per issue
  [ -n "$OUTCOME" ] || OUTCOME="error"
  record_run "$ISSUE" "$OUTCOME" "$(sum_costs "$COST_W" "$COST_R")" "$NOTE"
  log "issue #$ISSUE: $OUTCOME${NOTE:+ ($NOTE)}"
  case "$OUTCOME" in
    ok) N_OK=$((N_OK + 1)) ;;
    skipped) N_SKIPPED=$((N_SKIPPED + 1)) ;;
    *) N_ERROR=$((N_ERROR + 1)) ;;
  esac
done

# --------------------------------------------------------------------------
# step 6 — summary (the EXIT trap releases the lock)
# --------------------------------------------------------------------------
log "done: $N_OK ok, $N_SKIPPED skipped, $N_ERROR error"
exit 0
