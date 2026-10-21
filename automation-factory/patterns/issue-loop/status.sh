#!/usr/bin/env bash
# loop/status.sh — one-screen, READ-ONLY view of the issue-loop: queue, lock, backoff, recent runs.
#
# Usage:  bash loop/status.sh [path/to/loop.conf]
#   no argument : the loop.conf next to this script (the repo's own loop/).
#   a path      : that config, and the repo that owns it (<conf dir>/..) supplies the lock,
#                 backoff and base-branch state. Lets a copy of this script read another checkout.
#
# Why it exists: run-issue.sh keeps its state in places an operator never looks (the git common
# dir, a private run log) and exits 0 for nearly everything, so "is it working?" had no answer.
#
# Read-only on purpose: it writes no file (no temp file, no fetch, no label change, no lock) so it
# is always safe to run, including while the runner or drain.sh is mid-run. Every number comes from
# something it reads this second; where a source is missing it says so instead of guessing.
#
# Exit 0 always, except 2 when loop.conf cannot be read. No caps, no flags.
# Bash 3.2 compatible (no mapfile, no associative arrays). Needs git, and gh + jq for the
# network and run-log sections (each degrades to a one-line note when absent).

set -u

src="${BASH_SOURCE[0]:-$0}"
LOOP_DIR="$(cd "$(dirname "$src")" && pwd -P)"
CONF="${1:-$LOOP_DIR/loop.conf}"
if [ ! -f "$CONF" ] || [ ! -r "$CONF" ]; then echo "status: cannot read loop.conf at $CONF" >&2; exit 2; fi
CONF="$(cd "$(dirname "$CONF")" && pwd -P)/$(basename "$CONF")"
REPO_ROOT="$(cd "$(dirname "$CONF")/.." && pwd -P)"

# The config is plain KEY=${KEY:-'value'} assignments (the runner sources it the same way).
# shellcheck disable=SC1090
. "$CONF"
: "${GH_REPO:=}"
: "${ISSUE_REPO:=$GH_REPO}"
: "${BASE_BRANCH:=main}"
: "${ISSUE_LABEL:=ready-for-agent}"

# clean <text> — drop control characters (issue titles and run notes are untrusted text; an escape
# sequence in one must not reach the operator's terminal).
clean() { printf '%s' "$1" | tr -d '[:cntrl:]'; }
# trunc <n> <text> — first n characters, with an ellipsis when cut.
trunc() {
  local t="$2"
  if [ "${#t}" -gt "$1" ]; then printf '%s...' "${t:0:$(($1 - 3))}"; else printf '%s' "$t"; fi
}
# epoch_fmt <epoch> — local time for an epoch (GNU date -d, else BSD date -r).
epoch_fmt() { date -d "@$1" '+%H:%M:%S' 2>/dev/null || date -r "$1" '+%H:%M:%S' 2>/dev/null || echo "epoch $1"; }

GIT_COMMON=""
if git -C "$REPO_ROOT" rev-parse --git-common-dir >/dev/null 2>&1; then
  GIT_COMMON="$(cd "$REPO_ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
fi
STATE="${GIT_COMMON:+$GIT_COMMON/issue-loop}"
LOCK="$STATE/lock"
BACKOFF="$STATE/backoff"
RUN_LOG="${GRID_RUN_LOG:-$HOME/.the-grid-private/runs.jsonl}"
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
HAVE_GH=0; command -v gh >/dev/null 2>&1 && HAVE_GH=1

echo "issue-loop status  $(date '+%Y-%m-%d %H:%M:%S')  repo=$GH_REPO  issues=$ISSUE_REPO  base=$BASE_BRANCH"

# ---- queue ------------------------------------------------------------------
# One gh call per label: the same JSON gives the count, the next pick and the titles below.
echo
echo "QUEUE ($ISSUE_REPO, open issues by label)"
BLOCKED_TXT=""
NEXT_TXT=""
if [ "$HAVE_GH" = 0 ] || [ "$HAVE_JQ" = 0 ]; then
  echo "  gh or jq not on PATH: queue unavailable"
else
  line=""
  for lbl in "$ISSUE_LABEL" ready-for-human blocked needs-human; do
    # a configured ISSUE_LABEL equal to one of the fixed names must not be counted twice
    case " $line " in *" $lbl="*) continue ;; esac
    if js="$(gh issue list --repo "$ISSUE_REPO" --state open --label "$lbl" --limit 200 --json number,title 2>/dev/null)" \
       && n="$(printf '%s' "$js" | jq 'length' 2>/dev/null)"; then
      line="$line $lbl=$n"
      case "$lbl" in
        "$ISSUE_LABEL")
          # the runner picks the lowest-numbered open issue carrying the label
          first="$(printf '%s' "$js" | jq -r 'sort_by(.number) | .[0] // empty | "#\(.number)  \(.title)"' 2>/dev/null)"
          if [ -n "$first" ]; then NEXT_TXT="$(trunc 90 "$(clean "$first")")"; fi ;;
        blocked|needs-human)
          rows="$(printf '%s' "$js" | jq -r 'sort_by(.number) | .[] | "    #\(.number)  \(.title)"' 2>/dev/null)"
          if [ -n "$rows" ]; then
            BLOCKED_TXT="$BLOCKED_TXT
  $lbl:"
            while IFS= read -r r; do BLOCKED_TXT="$BLOCKED_TXT
$(trunc 100 "$(clean "$r")")"; done <<EOF
$rows
EOF
          fi ;;
      esac
    else
      line="$line $lbl=?"
    fi
  done
  echo " $line"
fi
echo "  next pick: ${NEXT_TXT:-none (queue empty or unreadable)}"

# ---- lock -------------------------------------------------------------------
echo
echo "LOCK"
if [ -z "$STATE" ]; then
  echo "  $REPO_ROOT is not a git repository: no state dir"
elif [ ! -d "$LOCK" ]; then
  echo "  not held"
else
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  iss="$(cat "$LOCK/issue" 2>/dev/null || true)"
  since="$(cat "$LOCK/started" 2>/dev/null || true)"
  alive="no"; isrunner="n/a"; stale=0
  case "$pid" in
    ''|*[!0-9]*)
      # same rule as the runner: a pid-less lock older than 5 minutes is dead, a younger one is mid-start
      if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then stale=1; fi ;;
    *)
      if ps -p "$pid" >/dev/null 2>&1; then
        alive="yes"
        case "$(ps -p "$pid" -o command= 2>/dev/null || true)" in
          *run-issue.sh*) isrunner="yes" ;;
          *) isrunner="no"; stale=1 ;;   # pid reused by something else
        esac
      else
        stale=1
      fi ;;
  esac
  echo "  HELD  pid=${pid:-none} alive=$alive run-issue.sh=$isrunner${iss:+ issue=#$iss}${since:+ since=$since}"
  if [ "$stale" = 1 ]; then echo "  STALE: the next run takes it over (a crash, SIGKILL or reboot left it)"; fi
fi

# ---- backoff ----------------------------------------------------------------
echo
echo "BACKOFF"
if [ -z "$STATE" ] || [ ! -f "$BACKOFF" ]; then
  echo "  none"
else
  # `until=<epoch> fails=<n> issue=<n> issue_fails=<n>`: match whole keys so fails != issue_fails
  bo() { tr ' ' '\n' < "$BACKOFF" 2>/dev/null | sed -n "s/^$1=//p" | sed -n '1p'; }
  b_until="$(bo until)"; b_fails="$(bo fails)"; b_issue="$(bo issue)"; b_ifails="$(bo issue_fails)"
  now="$(date +%s)"
  case "$b_until" in
    ''|*[!0-9]*) echo "  backoff file present but unreadable: $(clean "$(head -c 200 "$BACKOFF")")" ;;
    *)
      if [ "$now" -lt "$b_until" ]; then
        echo "  ACTIVE until $(epoch_fmt "$b_until") ($(( (b_until - now + 59) / 60 )) min left); cron ticks and drain.sh stop quietly until then"
      else
        echo "  expired at $(epoch_fmt "$b_until") (the next run goes ahead and clears it on success)"
      fi
      echo "  consecutive infra failures=${b_fails:-0}${b_issue:+  poison counter: issue #$b_issue failed ${b_ifails:-0} in a row}" ;;
  esac
fi

# ---- recent runs ------------------------------------------------------------
echo
echo "RECENT RUNS (this repo's work-issue records; run log: $RUN_LOG)"
if [ "$HAVE_JQ" = 0 ]; then
  echo "  jq not on PATH: unavailable"
elif [ ! -f "$RUN_LOG" ]; then
  echo "  no run log yet"
else
  # -R + fromjson? so one malformed line cannot hide the rest of the log
  # shellcheck disable=SC2016  # $r is a jq variable (--arg r), not a shell one
  SEL='fromjson? | select(.action == "work-issue" and ((.target // "") | startswith($r + "#")))'
  rows="$(jq -Rr --arg r "$ISSUE_REPO" "$SEL"' | [.ts, .target, .outcome, (.cost_usd // "-" | tostring), (.note // "")] | @tsv' "$RUN_LOG" 2>/dev/null | tail -n 10)"
  if [ -z "$rows" ]; then
    echo "  none for $ISSUE_REPO"
  else
    printf '  %-20s %-8s %-8s %-7s %s\n' TIME TARGET OUTCOME COST NOTE
    while IFS="$(printf '\t')" read -r ts tgt out cost note; do
      # cost is a raw float in the record (0.2784278000000...); show cents
      case "$cost" in -|'') cost="-" ;; *) cost="$(printf '$%.2f' "$cost" 2>/dev/null || echo "$cost")" ;; esac
      printf '  %-20s %-8s %-8s %-7s %s\n' "$(clean "$ts")" "#${tgt#*#}" "$(clean "$out")" "$(clean "$cost")" "$(trunc 60 "$(clean "$note")")"
    done <<EOF
$rows
EOF
  fi
  # run-record timestamps are UTC, so "today" here is the UTC date
  utc_today="$(date -u '+%Y-%m-%d')"
  tot="$(jq -Rr --arg r "$ISSUE_REPO" --arg d "$utc_today" "$SEL"' | select((.ts // "") | startswith($d)) | "\(.cost_usd // 0)"' "$RUN_LOG" 2>/dev/null \
        | awk '{ s += $1; n++ } END { printf "%d runs, $%.2f", n, s }')"
  echo "  today (UTC $utc_today): ${tot:-0 runs, \$0.00}"
fi

# ---- attention --------------------------------------------------------------
if [ -n "$BLOCKED_TXT" ]; then
  echo
  echo "NEEDS A HUMAN$BLOCKED_TXT"
fi

# ---- base branch ------------------------------------------------------------
echo
echo "BASE BRANCH ($BASE_BRANCH)"
last=""
if [ "$HAVE_GH" = 1 ] && [ "$HAVE_JQ" = 1 ] && [ -n "$GH_REPO" ]; then
  last="$(gh api "repos/$GH_REPO/commits/$BASE_BRANCH" --jq '"\(.sha[0:7])  \(.commit.author.date)  \(.commit.message | split("\n")[0])"' 2>/dev/null || true)"
fi
if [ -z "$last" ] && [ -n "$GIT_COMMON" ]; then
  # no network answer: fall back to the local copy (as of the last fetch, so it may lag the remote)
  for ref in "origin/$BASE_BRANCH" "$BASE_BRANCH"; do
    last="$(git -C "$REPO_ROOT" log -1 --format='%h  %cI  %s' "$ref" 2>/dev/null || true)"
    if [ -n "$last" ]; then last="$last  [local $ref]"; break; fi
  done
fi
echo "  $(trunc 120 "$(clean "${last:-unavailable}")")"
exit 0
