#!/usr/bin/env bash
# loop/drain.sh — work the whole queue by hand: run the runner again and again, serially, until
# there is nothing left to do or something needs a human.
#
# Usage:  bash loop/drain.sh
#   Nothing to configure: it passes its environment straight through to run-issue.sh, so
#   MAX_BUDGET_USD=2 bash loop/drain.sh behaves as the same override does for one run.
#
# Why it exists: a cron tick works one issue per interval. After a burst of triage the operator
# wants the queue emptied now, without waiting for ticks. This is only a loop around the runner:
# the lock, gates, backoff and verification all stay in run-issue.sh. It installs nothing, writes
# no state of its own and adds no caps (not on count, spend or time).
#
# Stops (with a message) when:
#   - the queue is empty        (runner exit 0, "nothing to do")
#   - the runner exits non-zero (infrastructure failure: backoff is now recorded; exit 1 here)
#   - the runner says "busy", "backing off" or "daily cap reached" (exit 0, but there is no
#     point asking again)
#   - the same issue comes back twice in a row (its label was not cleared; looping would spin)
#   - SIGINT / SIGTERM: the runner is stopped (its own trap cleans the worktree and lock) and
#     this exits 130.
#
# How "an issue was handled" is detected: the runner appends "<date> <issue> <outcome>" to
# <git-common-dir>/issue-loop/runs.log for every issue-level outcome, and nowhere else. A grown
# runs.log is the reliable signal; the runner's stdout text is only used to name WHY it stopped,
# because "nothing to do", "busy" and "backing off" are all exit 0 and write no record.
#
# Exit: 0 queue drained or stopped by busy/backoff/cap, 1 the runner failed, 2 cannot start,
# 130 interrupted. Bash 3.2 compatible.

set -u

src="${BASH_SOURCE[0]:-$0}"
LOOP_DIR="$(cd "$(dirname "$src")" && pwd -P)"
REPO_ROOT="$(cd "$LOOP_DIR/.." && pwd -P)"
RUNNER="$LOOP_DIR/run-issue.sh"
[ -f "$RUNNER" ] || { echo "drain: $RUNNER not found (this cut has no runner: it is the interactive mode)" >&2; exit 2; }
GIT_COMMON="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" \
  || { echo "drain: $REPO_ROOT is not a git repository" >&2; exit 2; }
RUNS_LOG="$GIT_COMMON/issue-loop/runs.log"

OUT="$(mktemp "${TMPDIR:-/tmp}/drain.XXXXXX")" || { echo "drain: cannot create a temp file" >&2; exit 2; }
CHILD=""
INTERRUPTED=0
cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

# The runner runs in the background so a signal reaches this shell at once (bash defers a trap
# until a foreground child exits). A background child of a non-interactive shell ignores SIGINT,
# so the handler forwards SIGTERM, which the runner traps (exit 143 after its own cleanup).
on_signal() {
  INTERRUPTED=1
  if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || true; fi
}
trap on_signal INT TERM HUP

runs_lines() { if [ -f "$RUNS_LOG" ]; then wc -l < "$RUNS_LOG" | tr -d ' '; else echo 0; fi; }

handled=0
prev_issue=""
echo "drain: starting ($RUNNER)"
while :; do
  # a signal that landed between runs must not start another one
  if [ "$INTERRUPTED" = 1 ]; then echo "drain: interrupted after $handled issue(s)"; exit 130; fi
  before="$(runs_lines)"
  start=$SECONDS
  bash "$RUNNER" > "$OUT" 2>&1 &
  CHILD=$!
  # wait returns early (status > 128) when a signal arrives; the second wait reaps the runner
  # after its cleanup has finished, so no worktree or lock is left behind.
  wait "$CHILD"; rc=$?
  if [ "$INTERRUPTED" = 1 ]; then wait "$CHILD" 2>/dev/null; rc=$?; fi
  CHILD=""
  elapsed=$((SECONDS - start))

  if [ "$INTERRUPTED" = 1 ]; then
    echo "drain: interrupted after $handled issue(s); the runner was stopped"
    exit 130
  fi

  if [ "$rc" -ne 0 ]; then
    echo "drain: runner exited $rc after ${elapsed}s; stopping (an infrastructure failure puts the loop in backoff)"
    tail -n 3 "$OUT" | sed 's/^/drain:   /'
    echo "drain: $handled issue(s) handled. Check: bash loop/status.sh"
    exit 1
  fi

  after="$(runs_lines)"
  if [ "$after" -gt "$before" ]; then
    # runs.log line: "<date> <issue> <outcome>"; the runner's last "#N -> ..." log line has the detail
    last_rec="$(tail -n 1 "$RUNS_LOG")"
    read -r _date issue outcome _ <<EOF2
$last_rec
EOF2
    issue="${issue:-?}"; outcome="${outcome:-?}"
    detail="$(grep -F 'run-issue: #' "$OUT" | tail -n 1 | sed 's/^[^ ]* run-issue: //' | tr -d '[:cntrl:]')"
    handled=$((handled + 1))
    printf 'drain: #%s %s %ss%s\n' "$issue" "$outcome" "$elapsed" "${detail:+  $detail}"
    if [ "$issue" = "$prev_issue" ]; then
      echo "drain: #$issue was picked twice in a row (its label was not cleared); stopping. Check: bash loop/status.sh"
      exit 1
    fi
    prev_issue="$issue"
    # Pause so GitHub's label list has caught up with the label swap just made; without it the next run
    # can pick the issue it just finished and exit 2. Backgrounded so a signal still ends the wait at once.
    sleep "${DRAIN_PAUSE:-10}" & wait $! || true
    continue
  fi

  # Exit 0 and no record: the runner did no issue work. Name why from its output.
  if grep -q 'nothing to do: no open issue' "$OUT"; then
    echo "drain: queue empty after $handled issue(s) (${elapsed}s last check)"
    exit 0
  fi
  if grep -q 'daily cap reached' "$OUT"; then
    echo "drain: daily cap reached after $handled issue(s); raise MAX_ISSUES_PER_DAY in loop/loop.conf to continue"
    exit 0
  fi
  if grep -q 'backing off' "$OUT"; then
    echo "drain: backing off after $handled issue(s) ($(grep 'backing off' "$OUT" | tail -n 1 | sed 's/^[^ ]* run-issue: //')); see bash loop/status.sh"
    exit 0
  fi
  if grep -q 'busy: another run holds the lock' "$OUT"; then
    echo "drain: busy after $handled issue(s): another runner (cron?) holds the lock; run again when it finishes"
    exit 0
  fi
  # Unrecognised: stop rather than spin on a runner that does nothing.
  echo "drain: the runner exited 0 but handled nothing and said why in a way drain does not know; stopping after $handled issue(s). Last output:"
  tail -n 3 "$OUT" | sed 's/^/drain:   /'
  exit 1
done
