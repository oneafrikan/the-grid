#!/usr/bin/env bash
# hooks/scripts/auto-handoff.sh — SessionEnd hook, launched by hooks/run.sh.
#
# Writes a handoff for a finished session that did not run /handoff itself. This
# script only validates the payload and starts hooks/lib/auto-handoff-worker.sh fully
# detached; everything slow (parsing the transcript, the model call, git) happens in the
# worker. SessionEnd hooks share a short budget, so this returns in well under a second.
#
#   - GRID_AUTOHANDOFF_CHILD set  -> exit 0: this is the worker's own `claude -p` child
#                                    ending (the recursion guard, checked first)
#   - jq missing                  -> exit 0 with a stderr note (fail open: a background
#                                    hook must never get in the way)
#   - payload invalid             -> log action=skip reason=bad-payload, exit 0
#   - otherwise                   -> detach the worker, exit 0
#
# Payload (SessionEnd stdin): {session_id, transcript_path, cwd, reason}. No transcript
# parsing here.

LC_ALL=C; export LC_ALL
# The log names sessions and paths: a file this script creates is owner-only.
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"

# Recursion guard first: it must work even when jq is missing and whatever the payload.
[ -n "${GRID_AUTOHANDOFF_CHILD:-}" ] && exit 0

grid_require_jq open

LOG="${GRID_HOOK_LOG_DIR:-$HOME/.grid/hook-logs}/auto-handoff.log"
payload="$(cat)"

# skip_bad <session>: one log line, then leave (never an error exit).
skip_bad() {
  grid_log "$LOG" "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) session=$1 action=skip reason=bad-payload"
  exit 0
}

if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then skip_bad unknown; fi
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty | strings')"
transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty | strings')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty | strings')"
end_reason="$(printf '%s' "$payload" | jq -r '.reason // empty | strings')"

# The session id becomes a file name under the state dir: letters, digits, _ and -, 1 to 64
# characters (a long id would break the marker, lock and quarantine names).
if ! [[ "$sid" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then skip_bad unknown; fi
if [ -z "$transcript" ] || [ -z "$cwd" ] || [ ! -d "$cwd" ]; then skip_bad "$sid"; fi

# Detach: perl setsid() gives the worker its own session (it survives this process and
# the session's process group), alarm bounds a hung worker, and the redirects leave it no
# handle on this process's stdio. The alarm is the child timeout plus everything the worker
# may legitimately do around it: 60 s of git, 120 s for the digest and the cwd-lock wait. perl ships on macOS, Ubuntu and
# Arch; setsid(1) does not on macOS.
timeout="${GRID_AUTOHANDOFF_TIMEOUT:-900}"
[[ "$timeout" =~ ^[0-9]+$ ]] || timeout=900
wait_s="${GRID_AUTOHANDOFF_WAIT:-120}"
[[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=120
mkdir -p "$(dirname "$LOG")" 2>/dev/null
# No perl means no detach and no timeout: say so in the log instead of silently doing nothing.
if ! command -v perl >/dev/null 2>&1; then
  grid_log "$LOG" "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) session=$sid action=skip reason=no-perl"
  exit 0
fi
perl -MPOSIX -e 'POSIX::setsid(); alarm shift; exec @ARGV' "$((timeout + 60 + 120 + wait_s))" \
  bash "$HERE/lib/auto-handoff-worker.sh" "$sid" "$transcript" "$cwd" "$end_reason" \
  < /dev/null >> "$LOG" 2>&1 &
exit 0
