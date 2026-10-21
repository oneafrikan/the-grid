#!/usr/bin/env bash
# run-issue.sh — work ONE labelled GitHub issue headlessly, then hand a verified PR to a human
# (MODE=pr) or land the verified commit straight on the base branch (MODE=direct).
#
# Usage:  bash loop/run-issue.sh [issue-number]
#   no number : pick the lowest-numbered open issue carrying ISSUE_LABEL (default ready-for-agent)
#   a number  : that issue, which must still carry ISSUE_LABEL (else exit 2)
#
# What one invocation does (details: openspec/changes/issue-loop-v2, design.md + specs/loop-runner):
#   preflight -> lock -> daily cap -> select -> gates (severity, existing PR/branch, trust)
#   -> role routing -> worktree -> headless `claude -p` worker -> git-state check
#   -> the RUNNER runs VERIFY_CMD -> pr: push issue-N, open the PR | direct: rebase onto the base,
#   re-verify if the base moved, push to the base -> swap labels -> run record.
#
# Rules this script lives by:
#   - Same user, same machine: it uses the operator's own `gh` and `claude` logins. It never
#     reads, mints or passes a token (GH_TOKEN etc. are simply inherited by children).
#   - The worker only COMMITS. This script verifies, pushes, opens the PR and swaps labels.
#     "Never commit a red build" is true because the runner runs the gate, not because the
#     prompt asks nicely (R10.qa.F6). The worker's own `done` never substitutes for it.
#   - It never merges and never classifies issues: gh-triage classifies, a human merges. MODE=direct
#     is the one exception to "a human merges": it pushes the verified commit to BASE_BRANCH itself.
#   - The guard hook reaches the worker only through the per-run --settings file written here;
#     this script never reads or writes <repo>/.claude/settings.json.
#   - Exit 0 for any issue-level outcome (PR opened, refused by a gate, blocked, needs-human),
#     1 for an infrastructure failure (claude/gh/git/network: the issue keeps its label),
#     2 for a preflight / usage problem (nothing touched).
#
# Bash 3.2 compatible (macOS). Never `set -x`: the environment must not be printed.
# Needs: git gh jq claude, GNU timeout (gtimeout on macOS), awk.

set -euo pipefail

# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
log()  { printf '%s run-issue: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s run-issue: warning: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
# die_pre <message> — preflight failure: one stderr line naming the fix, exit 2.
die_pre() { echo "run-issue: $*" >&2; exit 2; }

# cut_bytes <n> <text> — first n bytes of text (via a file: no pipe, no SIGPIPE).
cut_bytes() {
  printf '%s' "$2" > "$TMP/cut.txt"
  head -c "$1" "$TMP/cut.txt"
}

# tail_cut <file> <lines> <bytes> — the last <lines> lines of a file, then the LAST <bytes> bytes.
tail_cut() {
  tail -n "$2" "$1" > "$TMP/tail.txt" 2>/dev/null || true
  tail -c "$3" "$TMP/tail.txt"
}

# render_template <template> — fill {{KEY}} in ONE left-to-right pass (a value is never
# re-scanned, so an issue body containing "{{ISSUE_TITLE}}" is emitted literally).
#   V_<KEY>  (environment) : a short value.
#   F_<KEY>  (environment) : a file whose contents replace a line that is exactly {{KEY}}.
render_template() {
  awk '
    {
      line = $0
      if (match(line, /^\{\{[A-Z_]+\}\}$/)) {
        k = substr(line, 3, length(line) - 4)
        if (("F_" k) in ENVIRON) {
          f = ENVIRON["F_" k]
          while ((getline l < f) > 0) print l
          close(f)
          next
        }
      }
      out = ""
      while ((i = index(line, "{{")) > 0) {
        j = index(substr(line, i + 2), "}}")
        if (j == 0) break
        k = substr(line, i + 2, j - 1)
        out = out substr(line, 1, i - 1)
        if (("V_" k) in ENVIRON) { out = out ENVIRON["V_" k]; line = substr(line, i + j + 3) }
        else { out = out "{{"; line = substr(line, i + 2) }
      }
      print out line
    }' "$1"
}

# --------------------------------------------------------------------------
# step 1 — locate the repo, load config, fix PATH
# --------------------------------------------------------------------------
src="${BASH_SOURCE[0]:-$0}"
LOOP_DIR="$(cd "$(dirname "$src")" && pwd -P)"
REPO_ROOT="$(cd "$LOOP_DIR/.." && pwd -P)"
[ -f "$LOOP_DIR/loop.conf" ] || die_pre "loop/loop.conf not found under $REPO_ROOT; run scripts/instantiate.sh from the-grid"
# shellcheck disable=SC1091
. "$LOOP_DIR/loop.conf"

# Defaults for any key an older loop.conf lacks (the file itself already lets the environment win).
: "${GH_REPO:=}"
: "${ISSUE_REPO:=$GH_REPO}"
: "${BASE_BRANCH:=main}"
: "${ISSUE_LABEL:=ready-for-agent}"
: "${MODE:=pr}"
: "${VERIFY_CMD:=}"
: "${VERIFY_TIMEOUT:=900}"
: "${SETUP_CMD:=}"
: "${WORKER_MODEL:=sonnet}"
: "${MAX_BUDGET_USD:=5}"
: "${ISSUE_TIMEOUT:=1800}"
: "${WORKER_EXIT_GRACE:=30}"
: "${WORKER_PERMISSIONS:=allowlist}"
: "${WORKER_ALLOWED_TOOLS:=Read,Edit,Write,Glob,Grep,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git add:*),Bash(git commit:*)}"
# Optional (empty = not passed): a --permission-mode for the allowlist run. Which value, if any,
# lets a normal task finish with no prompt is decided by the real-claude proof (tasks 8.5).
: "${WORKER_PERMISSION_MODE:=}"
: "${MAX_ISSUES_PER_DAY:=0}"   # 0 = unlimited
: "${TRUST_GATE:=on}"
: "${RUN_ROLE:=issue-loop}"

# cron / launchd start with a bare PATH. APPEND (never prepend) the usual user bin dirs so a
# binary already on PATH always wins.
PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
export PATH
# Nothing may wait for a terminal: git must never prompt, every child gets stdin from /dev/null.
export GIT_TERMINAL_PROMPT=0
exec < /dev/null

CLAUDE_BIN="${GRID_CLAUDE:-claude}"

# --------------------------------------------------------------------------
# step 2 — arguments and preflight (any failure: one stderr line, exit 2, nothing touched)
# --------------------------------------------------------------------------
ARG_ISSUE=""
if [ "$#" -gt 1 ]; then die_pre "usage: bash loop/run-issue.sh [issue-number]"; fi
if [ "$#" -eq 1 ]; then
  case "$1" in
    ''|*[!0-9]*) die_pre "usage: bash loop/run-issue.sh [issue-number] (got '$1')" ;;
  esac
  ARG_ISSUE="$1"
fi

case "$MODE" in
  pr|direct) ;;
  *) die_pre "MODE must be 'pr' or 'direct' (got '$MODE') in loop/loop.conf" ;;
esac
[ -n "$VERIFY_CMD" ] || die_pre "VERIFY_CMD is empty in loop/loop.conf: the runner refuses to push anything it has not verified; set it (e.g. VERIFY_CMD='pytest')"
case "$WORKER_PERMISSIONS" in
  allowlist|bypass) ;;
  *) die_pre "WORKER_PERMISSIONS must be 'allowlist' or 'bypass' (got '$WORKER_PERMISSIONS') in loop/loop.conf" ;;
esac
[ -n "$GH_REPO" ] || die_pre "GH_REPO is empty in loop/loop.conf; set it to owner/name"
case "$MAX_ISSUES_PER_DAY" in ''|*[!0-9]*) die_pre "MAX_ISSUES_PER_DAY must be a number (got '$MAX_ISSUES_PER_DAY')" ;; esac
case "$VERIFY_TIMEOUT" in ''|*[!0-9]*) die_pre "VERIFY_TIMEOUT must be a number of seconds (got '$VERIFY_TIMEOUT')" ;; esac
case "$ISSUE_TIMEOUT" in ''|*[!0-9]*) die_pre "ISSUE_TIMEOUT must be a number of seconds (got '$ISSUE_TIMEOUT')" ;; esac
case "$WORKER_EXIT_GRACE" in ''|*[!0-9]*) die_pre "WORKER_EXIT_GRACE must be a number of seconds (got '$WORKER_EXIT_GRACE')" ;; esac

for _tool in git gh jq awk; do
  command -v "$_tool" >/dev/null 2>&1 || die_pre "'$_tool' not found on PATH; install it"
done
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || [ -x "$CLAUDE_BIN" ] || die_pre "'$CLAUDE_BIN' (claude) not found on PATH; install Claude Code and log in"
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
else die_pre "GNU timeout not found (macOS: brew install coreutils, which provides gtimeout)"
fi

GUARD="$LOOP_DIR/hooks/guard-main-push.sh"
[ -x "$GUARD" ] || die_pre "$GUARD is missing or not executable; re-run instantiate.sh"

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die_pre "$REPO_ROOT is not a git repository"

# Absolute git common dir (--git-common-dir is relative in a main checkout).
GIT_COMMON="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
MAIN_ROOT="${GIT_COMMON%/.git}"
WT_ROOT="${LOOP_WORKTREE_ROOT:-$(dirname "$MAIN_ROOT")/$(basename "$MAIN_ROOT")-loop}"
mkdir -p "$WT_ROOT" 2>/dev/null || die_pre "cannot create the worktree root $WT_ROOT (set LOOP_WORKTREE_ROOT)"

STATE="$GIT_COMMON/issue-loop"
LOCK="$STATE/lock"
RUNS_LOG="$STATE/runs.log"
# BACKOFF holds `until=<epoch> fails=<n>` after an infrastructure failure (see infra_fail).
BACKOFF="$STATE/backoff"
mkdir -p "$STATE"

# now_epoch prints the current epoch seconds for the backoff window only. GRID_LOOP_NOW is a TEST
# HOOK that pins the clock so a test can check the doubling table and the cap without waiting; it is
# unset in production, and anything but a plain integer is ignored.
now_epoch() {
  case "${GRID_LOOP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$GRID_LOOP_NOW" ;;
  esac
}

# Inside the backoff window a cron tick exits quietly: a persistent outage (logged-out claude, gh
# down, usage limit) must not be hammered every tick. A run for an explicit issue number is a human
# asking, so it ignores the window.
if [ -z "$ARG_ISSUE" ] && [ -f "$BACKOFF" ]; then
  _until="$(sed -n 's/^until=\([0-9]*\).*/\1/p' "$BACKOFF" 2>/dev/null || true)"
  if [ -n "$_until" ] && [ "$(now_epoch)" -lt "$_until" ]; then
    log "backing off after infrastructure failures until epoch $_until ($BACKOFF); exiting"
    exit 0
  fi
fi

# --------------------------------------------------------------------------
# step 3 — cleanup trap and lock
# --------------------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-issue.XXXXXX")"
CHILD_PID=""
CURRENT_WT=""
HAVE_LOCK=0
HAVE_TAKEOVER=0

# cleanup — runs on EVERY exit path (normal, die, infra stop, signal): stop the worker, remove
# the worktree (the BRANCH is kept), the temp dir (which holds the per-run settings file) and the lock.
cleanup() {
  trap - EXIT
  if [ -n "$CHILD_PID" ]; then
    # the worker's own children first (best effort), then the worker
    pkill -TERM -P "$CHILD_PID" 2>/dev/null || true
    kill -TERM "$CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_WT" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$CURRENT_WT" >/dev/null 2>&1 || rm -rf "$CURRENT_WT"
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
  if [ "$HAVE_LOCK" = 1 ]; then rm -rf "$LOCK"; fi
  if [ "$HAVE_TAKEOVER" = 1 ]; then rmdir "$LOCK.takeover" 2>/dev/null || true; fi
}
trap cleanup EXIT
# bash defers a trap until the foreground child exits, so children run via run_child
# (background + wait), which a trapped signal interrupts at once.
trap 'exit 143' INT TERM HUP
# An unexpected command failure is an infrastructure failure (exit 1), not a stray status.
set -E
trap 'echo "run-issue: unexpected failure near line $LINENO" >&2; exit 1' ERR

# lock_stale — sets `holder` and `stale` from what is on disk right now.
lock_stale() {
  holder=""
  if [ -f "$LOCK/pid" ]; then holder="$(cat "$LOCK/pid" 2>/dev/null || true)"; fi
  # Stale lock (a crash, SIGKILL or reboot left it): the recorded pid is gone, or was reused by a
  # process that is not a run-issue.sh. Take it over; a live runner keeps the lock (non-overlap guard).
  stale=0
  if [ -n "$holder" ]; then
    case "$holder" in *[!0-9]*) ;; *)
      if ! ps -p "$holder" >/dev/null 2>&1; then stale=1
      else case "$(ps -p "$holder" -o command= 2>/dev/null || true)" in *run-issue.sh*) ;; *) stale=1 ;; esac
      fi ;;
    esac
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    # No pid file: a crash between mkdir and the pid write. A live runner writes it within
    # milliseconds, so a pid-less lock older than 5 minutes is dead, not "busy forever".
    stale=1
  fi
}

if ! mkdir "$LOCK" 2>/dev/null; then
  lock_stale
  took=0
  # Takeover is serialised by a second mkdir mutex. Without it a runner that read the lock as stale
  # can rename a lock a faster runner has just re-created and is still filling in, and the put-back
  # below leaves that runner without its lock for a moment (its write to $LOCK/pid fails, exit 1).
  # The loser of the mutex is simply busy, like any runner that finds a live lock.
  if [ "$stale" = 1 ]; then
    # a mutex left by a runner SIGKILLed inside the few lines below would block takeovers for good
    if [ -n "$(find "$LOCK.takeover" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$LOCK.takeover" 2>/dev/null || true; fi
    if mkdir "$LOCK.takeover" 2>/dev/null; then
      HAVE_TAKEOVER=1
      lock_stale   # look again under the mutex: the lock may have been taken over since the read above
    else
      stale=0
    fi
  fi
  # mv is atomic: only one run can move the stale lock away.
  if [ "$stale" = 1 ] && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
    moved="$(cat "$LOCK.stale.$$/pid" 2>/dev/null || true)"
    if [ "$moved" != "$holder" ]; then
      # Another runner re-took the lock between our read and the rename: what we moved is LIVE. Put it back.
      [ -e "$LOCK" ] || mv "$LOCK.stale.$$" "$LOCK" 2>/dev/null || true
      rm -rf "$LOCK.stale.$$"
    else
      # A SIGKILLed runner leaves its claude worker running (until ISSUE_TIMEOUT). Stop that worker's
      # process group before a second one starts on the same issue; the command-line check keeps a
      # reused pid from hitting an unrelated process.
      oldw="$(cat "$LOCK.stale.$$/worker" 2>/dev/null || true)"
      case "$oldw" in ''|*[!0-9]*) ;; *)
        case "$(ps -p "$oldw" -o command= 2>/dev/null || true)" in
          *claude*) kill -TERM -- "-$oldw" 2>/dev/null || kill -TERM "$oldw" 2>/dev/null || true
                    log "stopped the orphaned worker (pid $oldw) of the stale lock" ;;
        esac ;;
      esac
      if mkdir "$LOCK" 2>/dev/null; then took=1; fi
      rm -rf "$LOCK.stale.$$"
    fi
  fi
  if [ "$HAVE_TAKEOVER" = 1 ]; then rmdir "$LOCK.takeover" 2>/dev/null || true; HAVE_TAKEOVER=0; fi
  if [ "$took" = 1 ]; then
    log "took over a stale lock (pid ${holder:-none} is not a running run-issue.sh)"
  else
    log "busy: another run holds the lock (${holder:+pid $holder, }$LOCK); exiting"
    exit 0
  fi
fi
HAVE_LOCK=1
printf '%s\n' "$$" > "$LOCK/pid"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$LOCK/started"

# --------------------------------------------------------------------------
# run bookkeeping
# --------------------------------------------------------------------------
RUN_RECORD=""
if [ -n "${GRID_RUN_RECORD:-}" ] && [ -f "$GRID_RUN_RECORD" ]; then RUN_RECORD="$GRID_RUN_RECORD"
elif [ -f "${GRID_DIR:-$HOME/.the-grid}/scripts/run-record.sh" ]; then RUN_RECORD="${GRID_DIR:-$HOME/.the-grid}/scripts/run-record.sh"
elif [ -f "$REPO_ROOT/scripts/run-record.sh" ]; then RUN_RECORD="$REPO_ROOT/scripts/run-record.sh"
fi
[ -n "$RUN_RECORD" ] || warn "run-record.sh not found; run records are skipped"

N=""            # the issue being handled
ROLE=""         # agent name when routed, else RUN_ROLE
SESSION_ID=""
COST=""

# record_run <outcome ok|skipped|error> <note> — one run-record line + one runs.log line.
# Best effort: a failing recorder never fails the run.
record_run() {
  local outcome="$1" note="$2" args
  printf '%s %s %s\n' "$(date '+%Y-%m-%d')" "$N" "$outcome" >> "$RUNS_LOG" 2>/dev/null || true
  [ -n "$RUN_RECORD" ] || return 0
  [ -z "$SESSION_ID" ] || note="$note (session $SESSION_ID)"
  args=(--role "${ROLE:-$RUN_ROLE}" --action work-issue --target "$ISSUE_REPO#$N" --outcome "$outcome" --note "$(cut_bytes 500 "$note")")
  if [ -n "$COST" ]; then args+=(--cost-usd "$COST"); fi
  bash "$RUN_RECORD" "${args[@]}" >/dev/null 2>&1 || warn "run-record.sh failed for $ISSUE_REPO#$N"
  return 0
}

# bo_get <key> — one field of the backoff file (`until=<epoch> fails=<n> issue=<n> issue_fails=<n>`).
# Split on spaces and match the whole key, so `fails` never reads `issue_fails`.
bo_get() { tr ' ' '\n' < "$BACKOFF" 2>/dev/null | sed -n "s/^$1=//p" | sed -n '1p' || true; }

# SERVICE_RE — text in a worker's result or stderr that means the claude SERVICE refused or dropped the
# run (login, limit, network), not that the issue is bad. Case-insensitive ERE.
#   Captured from claude 2.1.305 (the tests pin these strings):
#     'not logged in'    result "Not logged in · Please run /login" (is_error true, exit 1)
#     'invalid api key'  result "Invalid API key · Fix external API key" (is_error true, HTTP 401)
#     'econnrefused'     result "API Error: Connection refused — a firewall or proxy may be blocking it
#                        (ECONNREFUSED)" (is_error true, exit 1, after ~3 minutes of internal retries;
#                        ANTHROPIC_BASE_URL pointed at a closed port)
#   NOT captured (no safe way to trigger them without spending money or exhausting a real account);
#   best guesses from the service's wording, kept so a real one is not blamed on the issue:
#     'usage limit', 'rate limit', 'limit reached', 'overloaded_error', 'credit balance is too low',
#     'oauth token', 'econnreset', 'etimedout', 'could not resolve host'.
SERVICE_RE='not logged in|please run /login|invalid api key|usage limit|rate.?limit|limit reached|overloaded_error|credit balance is too low|oauth token|econnrefused|connection refused|econnreset|etimedout|could not resolve host'

# infra_fail <message> [poison] — stop the run with exit 1. The issue KEEPS its opt-in label (so a
# later run retries it) and gets no comment; one run-record line says error.
#
# Poison rule: a failure caused by THIS issue's run (the worker crashed or returned an error the
# service patterns do not explain; the caller passes "poison") is counted in the backoff file's
# `issue=` / `issue_fails=`. The third in a row on the same issue marks it `blocked` (one comment) and
# exits 0, so one bad issue cannot hold the queue (the lowest number is always tried first). Outages
# (logins, gh, origin, usage limits) never pass "poison": they are not the issue's fault, and counting
# them would block innocent issues in bulk. The counter dies with the backoff file (any issue-level
# outcome, via conclude, or an empty queue).
infra_fail() {
  echo "run-issue: INFRASTRUCTURE FAILURE${N:+ on #$N}: $1" >&2
  local fails=0 prev win=900 pissue pfails
  prev="$(bo_get fails)"
  case "$prev" in ''|*[!0-9]*) ;; *) fails="$prev" ;; esac
  pissue="$(bo_get issue)"; pfails="$(bo_get issue_fails)"
  case "$pfails" in ''|*[!0-9]*) pfails=0 ;; esac
  if [ "${2:-}" = poison ] && [ -n "$N" ]; then
    if [ "$pissue" = "$N" ]; then pfails=$((pfails + 1)); else pfails=1; fi
    pissue="$N"
    if [ "$pfails" -ge 3 ]; then
      # A direct gh call, not conclude(): a failing relabel must fall through to the normal backoff.
      if gh_t issue edit "$N" --repo "$ISSUE_REPO" --remove-label "$ISSUE_LABEL" --add-label blocked >/dev/null 2>&1; then
        rm -f "$BACKOFF"
        post_comment "issue-loop blocked this: the worker failed with an infrastructure error on 3 consecutive runs for this issue, so the issue itself probably breaks it. Last error: $(cut_bytes 300 "$1")"
        record_run error "poison: 3 consecutive infra failures: $(cut_bytes 300 "$1")"
        log "#$N -> blocked (error): 3 consecutive infra failures on this issue"
        exit 0
      fi
    fi
  fi
  if [ -n "$N" ]; then record_run error "infra: $(cut_bytes 300 "$1")"; fi
  # Back off: the window starts at 15 minutes and doubles with each consecutive failure, up to 6 hours.
  # Any issue-level outcome (conclude) or an empty queue clears it.
  fails=$((fails + 1))
  local i=1
  while [ "$i" -lt "$fails" ] && [ "$win" -lt 21600 ]; do win=$((win * 2)); i=$((i + 1)); done
  [ "$win" -le 21600 ] || win=21600
  printf 'until=%s fails=%s issue=%s issue_fails=%s\n' "$(( $(now_epoch) + win ))" "$fails" "$pissue" "$pfails" > "$BACKOFF" 2>/dev/null || true
  exit 1
}

# gh_t / git_t — bounded calls, so a hung network never wedges the lock.
gh_t()  { "$TIMEOUT_BIN" 60 gh "$@"; }
git_t() { "$TIMEOUT_BIN" 300 git "$@"; }

# run_child <out> <err> <dir> cmd... — run cmd in <dir> as a BACKGROUND job and wait, so a trapped
# signal interrupts the wait at once. stdin is /dev/null. Sets CHILD_RC. The subshell execs cmd, so
# CHILD_PID is the command itself. The pid goes to $CHILD_PID_FILE when set (lock/worker).
# With GRACE_WATCH=1 a grace_watch runs beside the child (the worker only).
CHILD_RC=0
GRACE_WATCH=0

# outcome_valid — the outcome file's first line starts with a recognised outcome word.
outcome_valid() {
  local line=""
  if [ -f "$OUTCOME_FILE" ]; then line="$(sed -n '1p' "$OUTCOME_FILE" 2>/dev/null || true)"; fi
  case "$line" in done|needs-human*|blocked*) return 0 ;; esac
  return 1
}

# grace_watch <pid> — a worker can write its outcome and then never exit (a background watcher keeps
# the session alive). Once the outcome is valid, give the worker WORKER_EXIT_GRACE seconds to exit by
# itself, then stop its whole process group (timeout leads one) and leave $TMP/worker-reaped so the
# classifier knows the missing result and the signal exit are ours, not a failure. It ends by itself
# when the worker is gone.
grace_watch() {
  local pid="$1" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if outcome_valid; then
      while [ "$waited" -lt "$WORKER_EXIT_GRACE" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1; waited=$((waited + 1))
      done
      kill -0 "$pid" 2>/dev/null || return 0
      : > "$TMP/worker-reaped"
      log "#$N: the worker wrote its outcome but did not exit within ${WORKER_EXIT_GRACE}s; stopping it"
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || rm -f "$TMP/worker-reaped"
      waited=0
      while [ "$waited" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
      if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; fi
      return 0
    fi
    sleep 1
  done
  return 0
}

run_child() {
  local out="$1" err="$2" dir="$3"
  shift 3
  ( cd "$dir" || exit 97; exec "$@" ) < /dev/null > "$out" 2> "$err" &
  CHILD_PID=$!
  if [ -n "${CHILD_PID_FILE:-}" ]; then printf '%s\n' "$CHILD_PID" > "$CHILD_PID_FILE"; fi
  CHILD_RC=0
  if [ "$GRACE_WATCH" = 1 ]; then grace_watch "$CHILD_PID" > /dev/null 2>&1 < /dev/null & fi
  wait "$CHILD_PID" || CHILD_RC=$?
  CHILD_PID=""
}

# post_comment <text> — comment on the issue (in ISSUE_REPO) from a file. Best effort.
post_comment() {
  printf '%s\n' "$1" > "$TMP/comment.txt"
  gh_t issue comment "$N" --repo "$ISSUE_REPO" --body-file "$TMP/comment.txt" >/dev/null 2>&1 \
    || warn "could not comment on $ISSUE_REPO#$N"
}

# conclude <label-to-add> <run-record outcome> <comment> <note> — end an ISSUE-LEVEL outcome:
# swap labels (ISSUE_LABEL out, exactly one of ready-for-human|needs-human|blocked in), comment,
# record, exit 0. The label swap is what keeps a refused issue from starving the queue (R10.qa.F3):
# if it fails the run is an infrastructure failure and the label stays for a retry.
CLOSE_ISSUE=0   # set to 1 by the direct-mode landing: conclude also closes the issue
conclude() {
  local add="$1" outcome="$2" text="$3" note="$4"
  if ! gh_t issue edit "$N" --repo "$ISSUE_REPO" --remove-label "$ISSUE_LABEL" --add-label "$add" >/dev/null 2>"$TMP/edit.err"; then
    infra_fail "could not relabel $ISSUE_REPO#$N: $(cut_bytes 200 "$(cat "$TMP/edit.err")")"
  fi
  rm -f "$BACKOFF"   # gh and the issue answered: the infrastructure is fine again
  if [ -n "$N" ]; then rm -f "$STATE/landed.$N"; fi   # the issue now carries its outcome (see the direct-mode landing)
  post_comment "$text"
  if [ "$CLOSE_ISSUE" = 1 ]; then
    gh_t issue close "$N" --repo "$ISSUE_REPO" >/dev/null 2>&1 || warn "could not close $ISSUE_REPO#$N"
  fi
  record_run "$outcome" "$note"
  log "#$N -> $add ($outcome): $(cut_bytes 160 "$note")"
  exit 0
}
# blocked <reason> — the common issue-level failure.
DENIALS=""
blocked() {
  local text="issue-loop could not land this: $1"
  if [ -n "$DENIALS" ]; then
    text="$text
The worker was denied: $DENIALS. If those are commands the project needs, add them to WORKER_ALLOWED_TOOLS in loop/loop.conf."
  fi
  conclude blocked error "$text" "blocked: $1"
}

# --------------------------------------------------------------------------
# step 4 — daily cap (counted from runs.log, local date)
# --------------------------------------------------------------------------
today="$(date '+%Y-%m-%d')"
handled_today=0
if [ -f "$RUNS_LOG" ]; then
  handled_today="$(grep -c "^$today " "$RUNS_LOG" 2>/dev/null || true)"
  [ -n "$handled_today" ] || handled_today=0
fi
# 0 means no cap (the default); a positive number stops new issues once that many were handled today.
if [ "$MAX_ISSUES_PER_DAY" -gt 0 ] && [ "$handled_today" -ge "$MAX_ISSUES_PER_DAY" ]; then
  log "daily cap reached ($handled_today of $MAX_ISSUES_PER_DAY issues today); nothing to do"
  exit 0
fi

# --------------------------------------------------------------------------
# step 4b — logins and the remote. These are infrastructure, not a bad issue or a bad config: a
# logged-out claude or gh, or a network blip, keeps every issue labelled and backs off (infra_fail),
# so the next cron tick retries. Only a base branch the remote really lacks is a config error.
# --------------------------------------------------------------------------
# claude must be logged in: `auth status --json` carries .loggedIn (exits non-zero when logged out).
_auth="$("$CLAUDE_BIN" auth status --json 2>/dev/null || true)"
printf '%s' "$_auth" | jq -e '.loggedIn == true' >/dev/null 2>&1 || infra_fail "claude is not logged in; run 'claude auth login' as this user"
gh auth status >/dev/null 2>&1 || infra_fail "gh is not logged in (or gh is unreachable); run 'gh auth login' as this user"
# ls-remote --exit-code: 2 = the ref is absent (config error), any other failure = remote unreachable
_rc=0
git_t -C "$REPO_ROOT" ls-remote --exit-code --heads origin "refs/heads/$BASE_BRANCH" >/dev/null 2>&1 || _rc=$?
case "$_rc" in
  0) ;;
  2) die_pre "origin/$BASE_BRANCH does not exist on the remote; fix BASE_BRANCH in loop/loop.conf" ;;
  *) infra_fail "could not reach origin (git ls-remote exit $_rc)" ;;
esac

# --------------------------------------------------------------------------
# step 5 — select the issue and read it
# --------------------------------------------------------------------------
if [ -n "$ARG_ISSUE" ]; then
  N="$ARG_ISSUE"
else
  if ! gh_t issue list --repo "$ISSUE_REPO" --state open --label "$ISSUE_LABEL" --limit 200 \
        --json number --jq '.[].number' > "$TMP/list.txt" 2> "$TMP/list.err"; then
    infra_fail "gh issue list failed: $(cut_bytes 200 "$(cat "$TMP/list.err")")"
  fi
  N="$(sort -n "$TMP/list.txt" | sed -n '1p')"
  if [ -z "$N" ]; then
    rm -f "$BACKOFF"
    log "nothing to do: no open issue labelled $ISSUE_LABEL in $ISSUE_REPO"
    exit 0
  fi
fi
CUR_ISSUE="$N"
echo "$N" > "$LOCK/issue"

# gh issue view --json has no author association, so use the REST endpoints (gh api).
if ! gh_t api "repos/$ISSUE_REPO/issues/$N" > "$TMP/issue.json" 2> "$TMP/issue.err"; then
  infra_fail "could not read $ISSUE_REPO#$N: $(cut_bytes 200 "$(cat "$TMP/issue.err")")"
fi
jq -e 'type == "object"' "$TMP/issue.json" >/dev/null 2>&1 || infra_fail "the answer for $ISSUE_REPO#$N was not a JSON object"

jq -r '[.labels[]? | (if type == "object" then .name else . end)] | .[]' "$TMP/issue.json" > "$TMP/labels.txt"
has_label() { grep -qxF -- "$1" "$TMP/labels.txt"; }

# The issues endpoint also answers for pull requests (they carry a pull_request key). A PR is never
# work for the worker, so refuse it by number as well as by label (nothing touched, exit 2).
if jq -e 'has("pull_request")' "$TMP/issue.json" >/dev/null 2>&1; then
  N=""   # not handled: no record, no label change
  die_pre "$ISSUE_REPO#$CUR_ISSUE is a pull request, not an issue"
fi
if ! has_label "$ISSUE_LABEL"; then
  N=""   # not handled: no record, no label change
  die_pre "$ISSUE_REPO#$CUR_ISSUE does not carry the label '$ISSUE_LABEL'; add it or pick another issue"
fi
if [ "$(jq -r '.state // "open"' "$TMP/issue.json")" != "open" ]; then
  N=""
  die_pre "$ISSUE_REPO#$CUR_ISSUE is not open"
fi

# Already landed (MODE=direct): an earlier run pushed this issue's commit to the base but could not
# update the issue (gh failed in between), so the marker it wrote before the push is still here. If the
# commit is on origin/<base> now, finish the label swap, comment and close WITHOUT working it again.
# If it is not (the push never happened or was rejected), the marker is stale: drop it and work the
# issue as normal.
if [ "$MODE" = "direct" ] && [ -f "$STATE/landed.$N" ]; then
  landed_sha="$(cat "$STATE/landed.$N" 2>/dev/null || true)"
  if ! git_t -C "$REPO_ROOT" fetch origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" >/dev/null 2>"$TMP/e.err"; then
    infra_fail "git fetch origin $BASE_BRANCH failed: $(cut_bytes 200 "$(cat "$TMP/e.err")")"
  fi
  if [ -n "$landed_sha" ] && git -C "$REPO_ROOT" cat-file -e "$landed_sha^{commit}" 2>/dev/null \
     && git -C "$REPO_ROOT" merge-base --is-ancestor "$landed_sha" "origin/$BASE_BRANCH" 2>/dev/null; then
    CLOSE_ISSUE=1
    SHA="$(git -C "$REPO_ROOT" rev-parse --short "$landed_sha")"
    conclude ready-for-human ok "issue-loop landed commit $SHA on $BASE_BRANCH ($GH_REPO). A run that pushed it could not update this issue, so a later run finished the label swap without working it again. The issue is closed; review the commit when convenient." "recovered: $SHA already on $BASE_BRANCH"
  fi
  rm -f "$STATE/landed.$N"
fi

TITLE="$(jq -r '.title // ""' "$TMP/issue.json")"
ASSOC="$(jq -r '.author_association // ""' "$TMP/issue.json")"
is_trusted_assoc() { case "$1" in OWNER|MEMBER|COLLABORATOR) return 0 ;; esac; return 1; }

# --------------------------------------------------------------------------
# step 6 — gates, before any worktree or model call (each: relabel, comment, record skipped, exit 0)
# --------------------------------------------------------------------------
# severity defence in depth: gh-triage owns classification; this only READS labels.
for _sev in severity:critical severity:high; do
  if has_label "$_sev"; then
    conclude ready-for-human skipped "issue-loop skipped this: it also carries \`$_sev\`, so a human should take it." "gate: $_sev"
  fi
done

# an open PR or a remote branch for this issue already exists
pr_line=""
# A failing `gh pr list` is an outage, not "no PR": carrying on could open a second PR.
if gh_t pr list --repo "$GH_REPO" --head "issue-$N" --state open --json number,url \
     --jq '.[0] | "\(.number) \(.url)"' > "$TMP/pr.txt" 2> "$TMP/prlist.err"; then
  pr_line="$(sed -n '1p' "$TMP/pr.txt")"
else
  infra_fail "gh pr list failed: $(cut_bytes 200 "$(cat "$TMP/prlist.err")")"
fi
case "$pr_line" in null*|"") pr_line="" ;; esac
if [ -n "$pr_line" ]; then
  pr_num="${pr_line%% *}"
  pr_url="${pr_line#* }"
  [ "$pr_url" != "$pr_line" ] || pr_url=""
  conclude ready-for-human skipped "issue-loop skipped this: an open pull request already exists for it (#$pr_num${pr_url:+, $pr_url}). A human should review it." "gate: existing PR $pr_num"
fi
# ls-remote --exit-code: 0 = the branch exists, 2 = absent, anything else = the remote is unreachable
_rc=0
git_t -C "$REPO_ROOT" ls-remote --exit-code --heads origin "refs/heads/issue-$N" >/dev/null 2>&1 || _rc=$?
case "$_rc" in
  0) conclude ready-for-human skipped "issue-loop skipped this: the branch \`issue-$N\` already exists on the remote. A human should look at it." "gate: branch issue-$N exists" ;;
  2) ;;
  *) infra_fail "could not check origin for the branch issue-$N (git ls-remote exit $_rc)" ;;
esac

# trust gate: only OWNER / MEMBER / COLLABORATOR issues are worked. A null/empty association is untrusted.
if [ "$TRUST_GATE" = "on" ] && ! is_trusted_assoc "$ASSOC"; then
  conclude needs-human skipped "issue-loop skipped this: the issue author's association (\`${ASSOC:-unknown}\`) is not OWNER, MEMBER or COLLABORATOR (TRUST_GATE=on)." "gate: untrusted author"
fi

# --------------------------------------------------------------------------
# step 7 — role routing from an agent:<name> label
# --------------------------------------------------------------------------
agent_labels="$(grep '^agent:' "$TMP/labels.txt" || true)"
AGENT=""
if [ -n "$agent_labels" ]; then
  if [ "$(printf '%s\n' "$agent_labels" | wc -l | tr -d ' ')" -gt 1 ]; then
    blocked "more than one agent: label is set; keep exactly one"
  fi
  AGENT="${agent_labels#agent:}"
  case "$AGENT" in
    ''|*[!A-Za-z0-9._-]*) blocked "the agent: label holds characters outside [A-Za-z0-9._-]" ;;
  esac
  AGENT_FILE=""
  for _d in "${AGENTS_DIR:-$HOME/.claude/agents}" "$REPO_ROOT/.claude/agents"; do
    if [ -f "$_d/$AGENT.md" ]; then AGENT_FILE="$_d/$AGENT.md"; break; fi
  done
  [ -n "$AGENT_FILE" ] || blocked "agent \`$AGENT\` was not found in ~/.claude/agents or .claude/agents"
  # the frontmatter `tools:` line, if any, must allow editing: a read-only role cannot build
  tools_line="$(awk 'NR==1 && $0 != "---" { exit } NR>1 && $0 == "---" { exit } /^tools:/ { print; exit }' "$AGENT_FILE")"
  if [ -n "$tools_line" ]; then
    case "$tools_line" in
      *Edit*|*Write*) ;;
      *) blocked "agent \`$AGENT\` is read-only (its tools: line names neither Edit nor Write)" ;;
    esac
  fi
  ROLE="$AGENT"
fi

# --------------------------------------------------------------------------
# step 8 — worktree
# --------------------------------------------------------------------------
WT="$WT_ROOT/issue-$N"
# a leftover from a crashed run is removed and recreated
if [ -e "$WT" ]; then
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
fi
if ! git_t -C "$REPO_ROOT" fetch origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" >/dev/null 2>"$TMP/e.err"; then
  infra_fail "git fetch origin $BASE_BRANCH failed: $(cut_bytes 200 "$(cat "$TMP/e.err")")"
fi
# A local issue-N that is ahead of the base holds earlier work (for example a timed-out run's WIP
# commit). `worktree add -B` would reset it to the base, so move it aside first.
if git -C "$REPO_ROOT" rev-parse -q --verify "refs/heads/issue-$N" >/dev/null 2>&1 \
   && [ "$(git -C "$REPO_ROOT" rev-list --count "origin/$BASE_BRANCH..refs/heads/issue-$N" 2>/dev/null || echo 0)" -gt 0 ]; then
  _prev="issue-$N-prev-$(date +%s)"
  git -C "$REPO_ROOT" branch -m "issue-$N" "$_prev" >/dev/null 2>&1 \
    && log "#$N: kept the earlier local branch issue-$N as $_prev"
fi
CURRENT_WT="$WT"   # from here the trap removes it
if ! git -C "$REPO_ROOT" worktree add --no-track -B "issue-$N" "$WT" "origin/$BASE_BRANCH" >/dev/null 2>"$TMP/e.err"; then
  blocked "could not create the worktree: $(cut_bytes 300 "$(cat "$TMP/e.err")")"
fi
if [ -n "$SETUP_CMD" ]; then
  run_child "$TMP/setup.out" "$TMP/setup.err" "$WT" "$TIMEOUT_BIN" "$ISSUE_TIMEOUT" bash -c "$SETUP_CMD"
  if [ "$CHILD_RC" -ne 0 ]; then
    blocked "SETUP_CMD failed (exit $CHILD_RC): $(tail_cut "$TMP/setup.err" 20 600)"
  fi
fi

# --------------------------------------------------------------------------
# step 9 — the worker prompt (issue + the latest TRUSTED Agent Brief; no other comment) and the run
# --------------------------------------------------------------------------
if gh_t api --paginate "repos/$ISSUE_REPO/issues/$N/comments" 2>/dev/null | jq -s 'add // []' > "$TMP/comments.json" 2>/dev/null; then :; else echo '[]' > "$TMP/comments.json"; fi
jq -e 'type == "array"' "$TMP/comments.json" >/dev/null 2>&1 || echo '[]' > "$TMP/comments.json"
# a failed or null answer means "no trusted brief", never "trust everyone"
jq -r '[ .[] | select((.body // "") | startswith("## Agent Brief"))
         | select(.author_association as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) ]
       | last | (.body // "")' "$TMP/comments.json" > "$TMP/brief.full" 2>/dev/null || : > "$TMP/brief.full"
head -c 20000 "$TMP/brief.full" > "$TMP/brief.txt"
if [ -z "$(tr -d '[:space:]' < "$TMP/brief.txt")" ]; then echo "(none)" > "$TMP/brief.txt"; fi

jq -r '.body // ""' "$TMP/issue.json" > "$TMP/body.full"
head -c 60000 "$TMP/body.full" > "$TMP/body.txt"
if [ "$(wc -c < "$TMP/body.full" | tr -d ' ')" -gt 60000 ]; then
  printf '\n[... issue body cut at 60000 bytes ...]\n' >> "$TMP/body.txt"
fi

# The worker may write ONLY here: this directory (and nothing else of $TMP, which also holds the
# per-run settings file with the guard) is what --add-dir exposes.
OUTCOME_DIR="$TMP/outcome.d"
mkdir -p "$OUTCOME_DIR"
OUTCOME_FILE="$OUTCOME_DIR/outcome"
# Commit-message rule. Same repo: the commit ends with "#N" (it links the issue, and the review hook
# reads it). Issues in ANOTHER repo: "#N" would cross-link an unrelated item on the code repo and the
# code repo may be public, so the worker must not carry issue text or a bare number into its commits.
if [ "$ISSUE_REPO" = "$GH_REPO" ]; then
  COMMIT_RULE="Commit your work on branch issue-$N with a short message that ends with \"#$N\"."
else
  COMMIT_RULE="Commit your work on branch issue-$N. The issue lives in another repo ($ISSUE_REPO) and this repo may be public: do NOT quote or paraphrase the issue title or body in commit messages, and do not end a commit message with \"#$N\" (that number belongs to the other repo). Use a short neutral subject; you may end the message with \"refs $ISSUE_REPO#$N\"."
fi
PROMPT="$(V_ISSUE_NUMBER="$N" V_ISSUE_TITLE="$TITLE" V_WORKING_DIR="$WT" V_VERIFY_CMD="$VERIFY_CMD" \
          V_COMMIT_RULE="$COMMIT_RULE" V_OUTCOME_FILE="$OUTCOME_FILE" F_ISSUE_BODY="$TMP/body.txt" F_AGENT_BRIEF="$TMP/brief.txt" \
          render_template "$LOOP_DIR/worker-prompt.template.md")"

# Per-run settings holding ONLY the guard's PreToolUse entry (D4). The repo's own
# .claude/settings.json is never read or written; this file is deleted with $TMP.
SETTINGS_FILE="$TMP/worker-settings.json"
jq -n --arg g "$GUARD" \
  '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$g}]}]}}' > "$SETTINGS_FILE"

if [ -r /proc/sys/kernel/random/uuid ]; then SESSION_ID="$(cat /proc/sys/kernel/random/uuid)"
elif command -v uuidgen >/dev/null 2>&1; then SESSION_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
fi

# argv as one non-empty array. The prompt comes straight after -p: --allowedTools takes a
# variable number of values and would swallow a trailing prompt as a tool name. No --max-turns
# (the CLI has none: R10.qa.F12).
args=(-p "$PROMPT")
if [ -n "$AGENT" ]; then args+=(--agent "$AGENT"); fi
args+=(--model "$WORKER_MODEL" --max-budget-usd "$MAX_BUDGET_USD" --output-format json)
if [ -n "$SESSION_ID" ]; then args+=(--session-id "$SESSION_ID"); fi
args+=(-n "issue-$N" --settings "$SETTINGS_FILE" --add-dir "$OUTCOME_DIR")
if [ -n "$WORKER_PERMISSION_MODE" ]; then args+=(--permission-mode "$WORKER_PERMISSION_MODE"); fi
if [ "$WORKER_PERMISSIONS" = "bypass" ]; then
  args+=(--dangerously-skip-permissions)
else
  # The worker prompt tells it to run VERIFY_CMD itself first, so the allowlist must let it, or a fresh
  # cut's first run ends `blocked` on a denied command. Add exactly that one entry (nothing else) unless
  # the operator already listed it. A comma would split the entry and a ")" would end it early, so such a
  # value is skipped with a warning (the operator names the commands in WORKER_ALLOWED_TOOLS instead).
  ALLOWED_TOOLS="$WORKER_ALLOWED_TOOLS"
  _verify_entry="Bash($VERIFY_CMD:*)"
  case "$VERIFY_CMD" in
    *,*|*\)*) warn "VERIFY_CMD contains ',' or ')', so it was not added to the worker allowlist; list the commands it runs in WORKER_ALLOWED_TOOLS" ;;
    *) case ",$ALLOWED_TOOLS," in
         *",$_verify_entry,"*) ;;
         *) ALLOWED_TOOLS="$ALLOWED_TOOLS,$_verify_entry" ;;
       esac ;;
  esac
  args+=(--allowedTools "$ALLOWED_TOOLS")
fi

log "#$N: starting the worker${AGENT:+ (agent $AGENT)} in $WT"
CHILD_PID_FILE="$LOCK/worker"
GRACE_WATCH=1
run_child "$TMP/worker.json" "$TMP/worker.err" "$WT" \
  env LOOP_OUTCOME_FILE="$OUTCOME_FILE" GRID_LOOP_HEADLESS=1 \
  "$TIMEOUT_BIN" -k 30 "$ISSUE_TIMEOUT" "$CLAUDE_BIN" "${args[@]}"
GRACE_WATCH=0
CHILD_PID_FILE=""
WORKER_RC="$CHILD_RC"
# Stopped by grace_watch after it wrote a valid outcome: carry on as if it had exited by itself.
WORKER_REAPED=0
if [ -e "$TMP/worker-reaped" ]; then WORKER_REAPED=1; WORKER_RC=0; fi

# --------------------------------------------------------------------------
# step 10 — classify the worker
# --------------------------------------------------------------------------
# The result object (some CLI versions wrap events in an array: take the last result).
RESULT_OK=0
if jq -e 'type == "object" or type == "array"' "$TMP/worker.json" >/dev/null 2>&1; then
  jq -c 'if type == "array" then (map(select(.type == "result")) | last // {}) else . end' "$TMP/worker.json" > "$TMP/result.json" 2>/dev/null && RESULT_OK=1
fi
if [ "$RESULT_OK" = 1 ]; then
  _c="$(jq -r '.total_cost_usd // empty' "$TMP/result.json" 2>/dev/null || true)"
  case "$_c" in ''|*[!0-9.]*) COST="" ;; *) COST="$_c" ;; esac
fi

# Names of what the worker was denied (tool and command only, each cut short, never any output). It is
# appended to every blocked comment: the usual cause is a command missing from WORKER_ALLOWED_TOOLS.
if [ "$RESULT_OK" = 1 ]; then
  DENIALS="$(jq -r '[ .permission_denials[]? | ((.tool_name // "tool") + (if (.tool_input.command // "") != "" then ": " + (.tool_input.command | tostring | .[0:80]) else "" end)) ] | .[0:6] | join("; ")' "$TMP/result.json" 2>/dev/null || true)"
  DENIALS="$(cut_bytes 400 "$DENIALS")"
fi

if [ "$WORKER_RC" -eq 124 ] || [ "$WORKER_RC" -eq 137 ]; then
  # A claude that hangs silently (an unreachable API retries without printing, see README) looks like a
  # timeout, but a worker that printed no result AND left no edit and no commit did nothing: that is
  # an outage, not a bad issue. Keep the label and back off; no poison count (it is not the issue's
  # fault). A worker that timed out after producing work takes the WIP/blocked path below.
  if [ "$RESULT_OK" != 1 ] && [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] \
     && [ "$(git -C "$WT" rev-list --count "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)" -eq 0 ]; then
    infra_fail "the worker hit ISSUE_TIMEOUT (${ISSUE_TIMEOUT}s) having printed nothing and changed nothing; treating it as a claude/network outage"
  fi
  # The cleanup trap removes the worktree, so uncommitted work would be lost: commit it as WIP on the
  # local branch issue-N (never pushed) first. A worker that switched branches is left alone.
  wip_note="Any commits it made are on the local branch issue-$N."
  if [ "$(git -C "$WT" symbolic-ref --short -q HEAD 2>/dev/null || true)" = "issue-$N" ] \
     && [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    # same wording rule as the worker: no issue text in a commit on a possibly public repo
    if [ "$ISSUE_REPO" = "$GH_REPO" ]; then wip_ref="#$N"; else wip_ref="refs $ISSUE_REPO#$N"; fi
    if git -C "$WT" add -A >/dev/null 2>&1 \
       && git -C "$WT" commit -q --no-verify -m "WIP: worker timed out, unfinished ($wip_ref)" >/dev/null 2>&1; then
      wip_note="Its uncommitted work was saved as a WIP commit on the local branch issue-$N (not pushed)."
    else
      wip_note="Its uncommitted work could not be saved and was lost."
    fi
  fi
  blocked "the worker exceeded ISSUE_TIMEOUT (${ISSUE_TIMEOUT}s) and was stopped. $wip_note"
fi
# What the service said: is this run's failure the SERVICE's (login, limit, network: SERVICE_RE) or
# possibly the issue's? The first never counts toward the poison rule. The probe is stderr plus the
# result text ONLY when the result is an error: a normal result is the worker's own final answer, and
# an issue ABOUT rate limiting whose worker forgot the outcome line must end `blocked`, not be
# retried as an outage.
{ if [ "$RESULT_OK" = 1 ] && [ "$(jq -r '.is_error // false' "$TMP/result.json" 2>/dev/null)" = "true" ]; then
    jq -r '.result // ""' "$TMP/result.json" 2>/dev/null || true
  fi
  head -c 2000 "$TMP/worker.err" 2>/dev/null || true; } | head -c 4000 > "$TMP/infra-probe.txt" || true
POISON=poison
if grep -qiE "$SERVICE_RE" "$TMP/infra-probe.txt"; then POISON=""; fi
if [ "$RESULT_OK" = 1 ] && [ "$(jq -r '.is_error // false' "$TMP/result.json")" = "true" ]; then
  subtype="$(jq -r '.subtype // ""' "$TMP/result.json")"
  case "$subtype" in
    *budget*) blocked "the worker stopped at its spend cap (MAX_BUDGET_USD=$MAX_BUDGET_USD, $subtype)" ;;
    *) infra_fail "the worker returned an error result ($subtype): $(cut_bytes 200 "$(jq -r '.result // ""' "$TMP/result.json")")" "$POISON" ;;
  esac
fi
if [ "$WORKER_REAPED" != 1 ] && { [ "$WORKER_RC" -ne 0 ] || [ "$RESULT_OK" != 1 ]; }; then
  infra_fail "the worker failed (exit $WORKER_RC): $(cut_bytes 300 "$(cat "$TMP/worker.err")")" "$POISON"
fi

OUTCOME_LINE=""
if [ -f "$OUTCOME_FILE" ]; then OUTCOME_LINE="$(sed -n '1p' "$OUTCOME_FILE")"; fi
case "$OUTCOME_LINE" in
  needs-human*)
    reason="$(cut_bytes 500 "${OUTCOME_LINE#needs-human}")"; reason="${reason# }"
    [ -n "$reason" ] || reason="the worker asked for a human decision"
    conclude needs-human skipped "issue-loop stopped: the worker needs a human decision: $reason" "worker needs-human: $reason" ;;
  blocked*)
    reason="$(cut_bytes 500 "${OUTCOME_LINE#blocked}")"; reason="${reason# }"
    [ -n "$reason" ] || reason="the worker reported blocked"
    blocked "$reason" ;;
  done) ;;
  *)
    # No outcome line can also mean claude itself was cut off (usage or rate limit, login, network).
    # That is the infrastructure's fault, not the issue's: keep the label and back off.
    if [ -z "$POISON" ]; then
      infra_fail "the worker was cut off by the claude service: $(cut_bytes 200 "$(head -n 3 "$TMP/infra-probe.txt")")"
    fi
    blocked "the worker wrote no recognised outcome line (expected done, needs-human or blocked)" ;;
esac

# --------------------------------------------------------------------------
# step 11 — git-state check (only for `done`): on issue-N, clean, at least one commit ahead
# --------------------------------------------------------------------------
if [ "$(git -C "$WT" symbolic-ref --short -q HEAD 2>/dev/null || true)" != "issue-$N" ]; then
  blocked "the worktree is not on branch issue-$N after the run"
fi
if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  blocked "the worktree has uncommitted changes after the run"
fi
ahead="$(git -C "$WT" rev-list --count "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo 0)"
if [ "$ahead" -lt 1 ]; then
  blocked "the loop ended without a commit"
fi

# --------------------------------------------------------------------------
# step 12 — verify: the RUNNER runs the gate. Only exit 0 allows a push.
# --------------------------------------------------------------------------
run_verify() {
  run_child "$TMP/verify.out" "$TMP/verify.err" "$WT" "$TIMEOUT_BIN" -k 10 "$VERIFY_TIMEOUT" bash -c "$VERIFY_CMD"
  if [ "$CHILD_RC" -ne 0 ]; then
    cat "$TMP/verify.out" "$TMP/verify.err" > "$TMP/verify.all" 2>/dev/null || true
    vtail="$(tail_cut "$TMP/verify.all" 40 3000)"
    if [ "$CHILD_RC" -eq 124 ] || [ "$CHILD_RC" -eq 137 ]; then
      blocked "verify timed out after ${VERIFY_TIMEOUT}s. Last output:
$vtail"
    fi
    blocked "the verify command failed (exit $CHILD_RC), so nothing was pushed. Last output:
$vtail"
  fi
}
run_verify

# --------------------------------------------------------------------------
# step 12b — MODE=direct: land the verified commit on the base branch (no PR)
# --------------------------------------------------------------------------
if [ "$MODE" = "direct" ]; then
  # A refusal from here on keeps the local branch issue-N, so the work is never lost.
  if ! git_t -C "$WT" fetch origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" >/dev/null 2>"$TMP/e.err"; then
    infra_fail "git fetch origin $BASE_BRANCH failed: $(cut_bytes 200 "$(cat "$TMP/e.err")")"
  fi
  # If the base moved while the worker ran, put the work on top of it. The rebased tree is not the
  # one that was verified, so verify again before anything is pushed.
  if ! git -C "$WT" merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD; then
    # VERIFY_CMD may have rewritten tracked files (a snapshot, a lockfile, a regenerated catalogue); git
    # refuses to rebase a dirty tree. Only the commit is landed, so drop those edits first; a refusal
    # below is then a real conflict.
    git -C "$WT" reset -q --hard HEAD >/dev/null 2>&1 || true
    if ! git -C "$WT" rebase "origin/$BASE_BRANCH" >/dev/null 2>"$TMP/rebase.err"; then
      git -C "$WT" rebase --abort >/dev/null 2>&1 || true
      blocked "the rebase onto origin/$BASE_BRANCH conflicted, so nothing was pushed; the work is on the local branch issue-$N. $(cut_bytes 300 "$(cat "$TMP/rebase.err")")"
    fi
    run_verify
  fi
  # Landing marker, written BEFORE the push: if gh fails between the push and the label swap, the issue
  # keeps ISSUE_LABEL and the next tick would work it again and land a duplicate. A later run reads
  # this file (see "already landed" after step 5) and finishes the label swap instead. The sha is the
  # signal rather than a commit-message trailer or a search of the base's history because it is exact
  # (the push keeps the sha), needs no change to the worker's commit, and cannot match an older commit
  # when a human later re-labels the issue for new work: conclude() deletes the file on any outcome.
  git -C "$WT" rev-parse HEAD > "$STATE/landed.$N"
  # Explicit refspec, never forced: a base that moved again since the fetch is a rejection, not a clobber.
  if ! git_t -C "$WT" push origin "HEAD:refs/heads/$BASE_BRANCH" >/dev/null 2>"$TMP/push.err"; then
    rm -f "$STATE/landed.$N"   # nothing landed
    blocked "push to $BASE_BRANCH rejected, so nothing landed; the work is on the local branch issue-$N: $(cut_bytes 300 "$(cat "$TMP/push.err")")"
  fi
  SHA="$(git -C "$WT" rev-parse --short HEAD)"
  CLOSE_ISSUE=1
  conclude ready-for-human ok "issue-loop landed commit $SHA on $BASE_BRANCH ($GH_REPO). Its verify command passed in the runner. The issue is closed; review the commit when convenient." "landed $SHA on $BASE_BRANCH"
fi

# --------------------------------------------------------------------------
# step 13 — integrate: push issue-N (explicit refspec, never the base), open the PR, swap labels
# --------------------------------------------------------------------------
if ! git_t -C "$WT" push origin "HEAD:refs/heads/issue-$N" >/dev/null 2>"$TMP/push.err"; then
  blocked "push rejected: $(cut_bytes 300 "$(cat "$TMP/push.err")")"
fi
# The PR carries only a reference to the issue: never the issue title or body, because the code
# repo may be public while the tracker is private. Same repo: the title is the worker's own commit
# subject. Issues in another repo: a fixed title, because a commit subject is worker-written text and
# can carry issue text (the prompt asks it not to; this is the enforcement).
pr_title="issue-loop: work for $ISSUE_REPO#$N"
if [ "$ISSUE_REPO" = "$GH_REPO" ]; then
  subject="$(git -C "$WT" log -1 --format=%s)"
  [ -z "$subject" ] || pr_title="$subject"
fi
printf 'refs %s#%s\n\nOpened by the issue-loop runner after its own run of the verify command passed. Needs human review and merge.\n' \
  "$ISSUE_REPO" "$N" > "$TMP/pr-body.txt"
# --draft: CI skips draft PRs, so heavy checks wait until the operator marks it ready.
if ! gh_t pr create --draft --repo "$GH_REPO" --base "$BASE_BRANCH" --head "issue-$N" \
      --title "$pr_title" --body-file "$TMP/pr-body.txt" > "$TMP/pr.out" 2> "$TMP/pr.err"; then
  blocked "the branch was pushed but gh pr create failed: $(cut_bytes 300 "$(cat "$TMP/pr.err")")"
fi
PR_URL="$(tail -n 1 "$TMP/pr.out")"

# conclude() does the label swap + comment + record + exit 0
conclude ready-for-human ok "issue-loop opened a pull request: $PR_URL
Its verify command passed in the runner. Needs human review and merge; the issue stays open." "PR opened: $PR_URL"
