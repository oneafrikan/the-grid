#!/usr/bin/env bash
# weekly.sh — the scheduled usage job (budget-and-usage design.md section 4).
#
# 1. Run the extractor into <private>/usage/<host>.json.
# 2. If <private> is a git repo: commit ONLY that file, pull, push.
# 3. Append one line to <state>/usage.log.
#
# Idempotent: a second run with nothing new extracts "unchanged", stages nothing
# and makes no commit. Git failures (offline, diverged, no upstream) are logged
# and NEVER fatal: the commit stays local and the next weekly run retries.
#
# The private repo may hold the operator's own work in progress, so the git phase
# is guarded by scripts/lib/private-git-guard.sh: it is skipped entirely while a
# rebase/merge/cherry-pick is in progress, HEAD is detached, entries are unmerged
# or there is no upstream; the pull is skipped (never autostashed) while tracked
# files outside usage/ are modified; and the push happens only when the push
# remote matches <private>/.grid-private-remote and every unpushed commit touches
# only usage/<host>.json. A foreign unpushed commit makes the run exit 4.
#
# Env (all optional):
#   GRID_PRIVATE_DIR  private repo / dir      (default ~/.the-grid-private)
#   GRID_STATE_DIR    machine-local state dir (default ~/.grid); holds usage.log
#   GRID_HOST         host name for the file and commit message (default hostname -s)
#   GRID_GIT_TIMEOUT  seconds before one git call is killed (default 120)
#
# Run by the per-OS scheduler written by install-schedule.sh; runs nothing else.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRIVATE="${GRID_PRIVATE_DIR:-$HOME/.the-grid-private}"
STATE="${GRID_STATE_DIR:-$HOME/.grid}"
LOG="$STATE/usage.log"

# Same sanitising as extract.py (every char outside [A-Za-z0-9._-] -> '_') so the
# file name staged below is exactly the file the extractor wrote.
HOST_RAW="${GRID_HOST:-$(hostname -s 2>/dev/null)}"
HOST="$(printf '%s' "$HOST_RAW" | tr -c 'A-Za-z0-9._-' '_')"

mkdir -p "$STATE" || { echo "usage-weekly: cannot create $STATE" >&2; exit 1; }

# log <text...> — one timestamped line appended to usage.log.
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# logcmd <label> <rc> <output> — record a step; its output is indented under it.
logcmd() {
  log "$1 rc=$2"
  if [ -n "$3" ]; then printf '%s\n' "$3" | sed 's/^/    /' >> "$LOG"; fi
}

# --- overlap guard ------------------------------------------------------------
# mkdir is atomic and works on stock macOS (no flock there). A lock older than two
# hours belongs to a run that died without running its trap, and is taken over.
LOCK="$STATE/weekly.lock"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "usage-weekly: already running (lock $LOCK held); exiting"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# --- git helpers ---------------------------------------------------------------
# A hook-exported GIT_DIR would redirect every call; a credential prompt must fail
# fast, because cron has no terminal to answer it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_TERMINAL_PROMPT=0
GIT_TIMEOUT="${GRID_GIT_TIMEOUT:-120}"
GUARD="$GRID_DIR/scripts/lib/private-git-guard.sh"

# pgit <git args...> — `git -C <private>` under a perl alarm (stock macOS has no
# `timeout`). A killed call returns 142 and is logged like any other failure.
pgit() {
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$GIT_TIMEOUT" git -C "$PRIVATE" "$@"
  else
    git -C "$PRIVATE" "$@"
  fi
}

# --- 1. extract -------------------------------------------------------------
# Exit 0 also covers "no adapter available". Exit 1/2 (corrupt host file, bad
# host name, --out inside the repo) is a real failure: log it and stop before git.
out="$(python3 "$GRID_DIR/scripts/usage/extract.py" --out "$PRIVATE/usage" --host "$HOST" 2>&1)"
rc=$?
logcmd "extract" "$rc" "$out"
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  exit "$rc"
fi

# --- 2. git (only when PRIVATE is itself a repo root) ------------------------
# A private dir that is not a git repo (thin client) is fine: file only.
# Compare the toplevel to PRIVATE so a dir that merely sits inside some other
# repo is never committed into that repo.
exit_code=0
top="$(git -C "$PRIVATE" rev-parse --show-toplevel 2>/dev/null || true)"
phys="$(cd "$PRIVATE" 2>/dev/null && pwd -P || true)"
if [ -n "$top" ] && [ "$top" = "$phys" ]; then
  file="usage/$HOST.json"

  # Operator work in progress => skip the whole git phase (the file is already
  # written) and touch nothing in the repo.
  if reason="$(bash "$GUARD" precheck "$PRIVATE")"; then
    # Stage and commit ONLY this host's file (the pathspec on commit keeps anything
    # else the operator has staged out of the automated commit). No attribution.
    # Committing BEFORE the pull leaves that file clean, so no autostash is needed.
    # Regular files only: a symlink here would stage whatever it points at.
    if [ -f "$PRIVATE/$file" ] && [ ! -L "$PRIVATE/$file" ]; then
      pgit add -- "$file" >/dev/null 2>&1
      if pgit diff --cached --quiet -- "$file"; then
        log "git commit: nothing to commit"
      else
        out="$(pgit commit -m "usage: $HOST $(date -u +%Y-%m-%d)" -- "$file" 2>&1)"; rc=$?
        logcmd "git commit" "$rc" "$out"
      fi
    fi

    # Pull only while no tracked file outside usage/ is modified: a rebase refuses
    # then, and --autostash would re-apply the operator's edit into conflict markers.
    # The job still commits and pushes its own file.
    if bash "$GUARD" outside-clean "$PRIVATE" "$file"; then
      out="$(pgit pull --rebase 2>&1)"; rc=$?
      logcmd "git pull" "$rc" "$out"
      if [ "$rc" -ne 0 ] && [ "$(bash "$GUARD" precheck "$PRIVATE")" = "rebase-in-progress" ]; then
        # The precheck above proved no rebase was running before the pull, so this
        # one is ours: abort it so it cannot block every later run.
        pgit rebase --abort >/dev/null 2>&1 || true
        log "git pull: conflict, rebase aborted; local commit kept"
      fi
    else
      log "private repo has other changes; pull skipped"
    fi

    # Push every run, not only after a new commit, so an earlier failed push retries.
    # Re-check first: a failed pull must never leave a conflicted state we push from.
    if reason="$(bash "$GUARD" precheck "$PRIVATE")"; then
      msg="$(bash "$GUARD" push-ok "$PRIVATE" "$file")"; grc=$?
      if [ "$grc" -eq 0 ]; then
        out="$(pgit push 2>&1)"; rc=$?
        logcmd "git push" "$rc" "$out"
      else
        log "git push skipped: $msg"
        printf 'usage-weekly: push skipped: %s\n' "$msg" >&2
        # 4 = a foreign unpushed commit; 3 (remote not confirmed) stays a warning.
        [ "$grc" -eq 4 ] && exit_code=4
      fi
    else
      log "git push skipped: private repo busy ($reason)"
    fi
  else
    log "git phase skipped: private repo busy ($reason)"
  fi
else
  log "private dir is not a git repo root; file only"
fi

# --- 3. summary line -----------------------------------------------------------
log "usage-weekly done host=$HOST private=$PRIVATE"
exit "$exit_code"
