#!/usr/bin/env bash
# weekly.sh — the scheduled usage job (budget-and-usage design.md section 4).
#
# 1. Run the extractor into <private>/usage/<host>.json.
# 2. If <private> is a git repo: pull, commit ONLY that file, push.
# 3. Append one line to <state>/usage.log.
#
# Idempotent: a second run with nothing new extracts "unchanged", stages nothing
# and makes no commit. Git failures (offline, diverged, no upstream) are logged
# and NEVER fatal: the commit stays local and the next weekly run retries.
#
# Env (all optional):
#   GRID_PRIVATE_DIR  private repo / dir      (default ~/.the-grid-private)
#   GRID_STATE_DIR    machine-local state dir (default ~/.grid); holds usage.log
#   GRID_HOST         host name for the file and commit message (default hostname -s)
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
top="$(git -C "$PRIVATE" rev-parse --show-toplevel 2>/dev/null || true)"
phys="$(cd "$PRIVATE" 2>/dev/null && pwd -P || true)"
if [ -n "$top" ] && [ "$top" = "$phys" ]; then
  file="usage/$HOST.json"

  out="$(git -C "$PRIVATE" pull --rebase --autostash 2>&1)"; rc=$?
  logcmd "git pull" "$rc" "$out"
  if [ "$rc" -ne 0 ]; then
    # A half-finished rebase would block every later run; errors here are ignored.
    git -C "$PRIVATE" rebase --abort >/dev/null 2>&1 || true
  fi

  # Stage and commit ONLY this host's file (the pathspec on commit keeps anything
  # else the operator has staged out of the automated commit). No attribution.
  if [ -f "$PRIVATE/$file" ]; then
    git -C "$PRIVATE" add -- "$file" >/dev/null 2>&1
    if git -C "$PRIVATE" diff --cached --quiet -- "$file"; then
      log "git commit: nothing to commit"
    else
      out="$(git -C "$PRIVATE" commit -m "usage: $HOST $(date -u +%Y-%m-%d)" -- "$file" 2>&1)"; rc=$?
      logcmd "git commit" "$rc" "$out"
    fi
  fi

  # Push every run, not only after a new commit, so an earlier failed push retries.
  out="$(git -C "$PRIVATE" push 2>&1)"; rc=$?
  logcmd "git push" "$rc" "$out"
else
  log "private dir is not a git repo root; file only"
fi

# --- 3. summary line -----------------------------------------------------------
log "usage-weekly done host=$HOST private=$PRIVATE"
exit 0
