#!/usr/bin/env bats
# issue-loop: loop/status.sh (read-only view) and loop/drain.sh (run the runner until the queue is
# empty). gh is a fake on PATH and run-issue.sh is a fake in a temp repo: no GitHub, no model call,
# nothing under the real ~/.claude, ~/.grid or ~/.the-grid-private (common_setup sandboxes them).

bats_require_minimum_version 1.5.0
load helpers/setup
load helpers/stubs

PAT_DIR="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"
INST="$BATS_TEST_DIRNAME/../scripts/instantiate.sh"

setup() {
  common_setup
  export DRAIN_PAUSE=0   # tests use a fake runner; no label lag to wait out
  T="$(mktemp -d)"
  T="$(cd "$T" && pwd -P)"
  export HOME="$T/home"
  mkdir -p "$HOME" "$T/bin"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  # common_setup pointed GRID_RUN_LOG at a temp dir; keep it, but start from an empty log
  : > "$GRID_RUN_LOG"

  # a repo with a loop/ holding the two scripts under test and a minimal config
  REPO="$T/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" commit -q --allow-empty -m "seed commit"
  mkdir -p "$REPO/loop"
  cp "$PAT_DIR/status.sh" "$PAT_DIR/drain.sh" "$REPO/loop/"
  cat > "$REPO/loop/loop.conf" <<'EOF'
GH_REPO=${GH_REPO:-'o/code'}
ISSUE_REPO=${ISSUE_REPO:-'o/tracker'}
BASE_BRANCH=${BASE_BRANCH:-'main'}
ISSUE_LABEL=${ISSUE_LABEL:-'ready-for-agent'}
EOF
  STATE="$REPO/.git/issue-loop"
  mkdir -p "$STATE"

  # fake gh: `issue list --label L` prints $FAKE_GH/label-L.json (default []), `api` prints commit.txt
  export FAKE_GH="$T/fakegh"
  mkdir -p "$FAKE_GH"
  cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "issue list" ]; then
  while [ $# -gt 0 ]; do [ "$1" = --label ] && label="$2"; shift; done
  if [ -f "$FAKE_GH/label-$label.json" ]; then cat "$FAKE_GH/label-$label.json"; else echo '[]'; fi
  exit 0
fi
if [ "$1" = api ]; then cat "$FAKE_GH/commit.txt"; exit 0; fi
exit 1
EOF
  chmod +x "$T/bin/gh"
  PATH="$T/bin:$PATH"
}

teardown() {
  clean_stubs
  rm -rf "$T"
  common_teardown
}

# ------------------------------------------------------------------ status ---

@test "status: queue counts, the next pick, blocked titles and the base commit" {
  echo '[{"number":9,"title":"later"},{"number":4,"title":"first in line"}]' > "$FAKE_GH/label-ready-for-agent.json"
  echo '[{"number":7,"title":"stuck on verify"}]' > "$FAKE_GH/label-blocked.json"
  echo 'abc1234  2026-01-01T00:00:00Z  Land the thing' > "$FAKE_GH/commit.txt"
  run bash "$REPO/loop/status.sh"
  [ "$status" -eq 0 ]
  contains "$output" "ready-for-agent=2 ready-for-human=0 blocked=1 needs-human=0"
  contains "$output" "next pick: #4  first in line"
  contains "$output" "#7  stuck on verify"
  contains "$output" "abc1234  2026-01-01T00:00:00Z  Land the thing"
}

@test "status: a lock whose pid is gone is reported held and STALE" {
  mkdir "$STATE/lock"
  sleep 0 & dead=$!; wait "$dead"
  echo "$dead" > "$STATE/lock/pid"
  echo 12 > "$STATE/lock/issue"
  run bash "$REPO/loop/status.sh"
  contains "$output" "HELD  pid=$dead alive=no"
  contains "$output" "STALE"
}

@test "status: a lock held by a live run-issue.sh is alive and not stale" {
  mkdir "$STATE/lock"
  # exec -a gives the process the command name run-issue.sh, as the real runner has
  ( exec -a run-issue.sh sleep 30 ) &
  live=$!
  echo "$live" > "$STATE/lock/pid"
  run bash "$REPO/loop/status.sh"
  kill "$live" 2>/dev/null || true
  contains "$output" "alive=yes run-issue.sh=yes"
  refute contains "$output" "STALE"
}

@test "status: an active backoff shows the fail counts and the poison issue" {
  echo "until=$(( $(date +%s) + 3600 )) fails=2 issue=15 issue_fails=1" > "$STATE/backoff"
  run bash "$REPO/loop/status.sh"
  contains "$output" "ACTIVE until"
  contains "$output" "consecutive infra failures=2"
  contains "$output" "issue #15 failed 1 in a row"
}

@test "status: recent runs and today's cost count only this tracker; a malformed log line is skipped" {
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  {
    printf '{"ts":"%s","action":"work-issue","target":"o/tracker#7","outcome":"ok","cost_usd":0.5,"note":"landed abc"}\n' "$now"
    echo 'not json at all'
    printf '{"ts":"%s","action":"work-issue","target":"other/repo#1","outcome":"ok","cost_usd":9,"note":"elsewhere"}\n' "$now"
  } > "$GRID_RUN_LOG"
  run bash "$REPO/loop/status.sh"
  contains "$output" "#7"
  contains "$output" "landed abc"
  refute contains "$output" "elsewhere"
  contains "$output" '1 runs, $0.50'
}

@test "status: writes nothing, and exits 2 when loop.conf cannot be read" {
  mkdir "$STATE/lock"; echo 1 > "$STATE/lock/pid"
  echo "until=1 fails=1 issue= issue_fails=0" > "$STATE/backoff"
  snap() { find "$T" -type f -exec cksum {} + | sort; find "$T" | sort; }
  before="$(snap)"
  run bash "$REPO/loop/status.sh"
  [ "$status" -eq 0 ]
  [ "$(snap)" = "$before" ]
  run -2 bash "$REPO/loop/status.sh" "$T/nope/loop.conf"
}

# ------------------------------------------------------------------- drain ---

# A fake runner. Each call takes the first line of $FAKE_QUEUE: a number is "handled" (a runs.log line
# plus the runner's own "#N -> ..." log line, as the real conclude() writes), empty is "nothing to
# do", and FAIL / BUSY / HANG model an infrastructure failure, a held lock and a long-running worker.
make_fake_runner() {
  cat > "$REPO/loop/run-issue.sh" <<'EOF'
#!/usr/bin/env bash
state="$(git -C "$(dirname "$0")/.." rev-parse --absolute-git-dir)/issue-loop"
n="$(head -n 1 "$FAKE_QUEUE")"
tail -n +2 "$FAKE_QUEUE" > "$FAKE_QUEUE.t"; mv "$FAKE_QUEUE.t" "$FAKE_QUEUE"
case "$n" in
  FAIL) echo "run-issue: INFRASTRUCTURE FAILURE: boom" >&2; exit 1 ;;
  BUSY) echo "2026-01-01T00:00:00Z run-issue: busy: another run holds the lock (pid 1, x); exiting"; exit 0 ;;
  HANG) trap 'touch "$FAKE_QUEUE.got-term"; exit 143' TERM
        touch "$FAKE_QUEUE.started"; sleep 30 & wait ;;
  '')   echo "2026-01-01T00:00:00Z run-issue: nothing to do: no open issue labelled ready-for-agent in o/tracker"; exit 0 ;;
  *)    echo "2026-01-01 $n ok" >> "$state/runs.log"
        echo "2026-01-01T00:00:00Z run-issue: #$n -> ready-for-human (ok): landed abc" ;;
esac
EOF
}

@test "drain: works the queue in order, one line per issue, and stops cleanly when it is empty" {
  make_fake_runner
  export FAKE_QUEUE="$T/queue"; printf '5\n6\n' > "$FAKE_QUEUE"
  run bash "$REPO/loop/drain.sh"
  [ "$status" -eq 0 ]
  contains "$output" "drain: #5 ok "
  contains "$output" "drain: #6 ok "
  contains "$output" "queue empty after 2 issue(s)"
}

@test "drain: a runner that exits non-zero stops the drain with exit 1 and shows why" {
  make_fake_runner
  export FAKE_QUEUE="$T/queue"; printf '5\nFAIL\n7\n' > "$FAKE_QUEUE"
  run bash "$REPO/loop/drain.sh"
  [ "$status" -eq 1 ]
  contains "$output" "drain: #5 ok"
  contains "$output" "runner exited 1"
  contains "$output" "INFRASTRUCTURE FAILURE: boom"
  # issue 7 was never asked for
  [ "$(cat "$FAKE_QUEUE")" = "7" ]
}

@test "drain: a held lock (exit 0, no record) stops it, saying busy" {
  make_fake_runner
  export FAKE_QUEUE="$T/queue"; printf 'BUSY\n' > "$FAKE_QUEUE"
  run bash "$REPO/loop/drain.sh"
  [ "$status" -eq 0 ]
  contains "$output" "busy after 0 issue(s)"
}

@test "drain: the same issue coming back twice in a row stops it instead of spinning" {
  make_fake_runner
  export FAKE_QUEUE="$T/queue"; printf '5\n5\n6\n' > "$FAKE_QUEUE"
  run bash "$REPO/loop/drain.sh"
  [ "$status" -eq 1 ]
  contains "$output" "#5 was picked twice in a row"
}

@test "drain: SIGINT stops the runner (it gets SIGTERM) and exits 130" {
  make_fake_runner
  export FAKE_QUEUE="$T/queue"; printf 'HANG\n' > "$FAKE_QUEUE"
  # A background job of a non-interactive shell starts with SIGINT ignored, which a script cannot
  # undo; a real Ctrl-C reaches a foreground drain. Restore the default disposition, then exec.
  python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("bash", ["bash", sys.argv[1]])' \
    "$REPO/loop/drain.sh" > "$T/drain.out" 2>&1 &
  dpid=$!
  for _ in $(seq 1 100); do [ -f "$FAKE_QUEUE.started" ] && break; sleep 0.1; done
  [ -f "$FAKE_QUEUE.started" ]
  kill -INT "$dpid"
  rc=0; wait "$dpid" || rc=$?
  [ "$rc" -eq 130 ]
  [ -f "$FAKE_QUEUE.got-term" ]
  contains "$(cat "$T/drain.out")" "interrupted"
}

# ----------------------------------------------------------------- shipping ---

@test "instantiate ships status.sh and drain.sh verbatim and executable in a runner cut" {
  make_stubs
  export STUB_GH_STORED_LOGIN=1
  tgt="$T/target"
  git init -q -b main "$tgt"
  echo seed > "$tgt/README.md"; git -C "$tgt" add -A; git -C "$tgt" commit -q -m seed
  run bash "$INST" issue-loop "$tgt" --profile work --repo owner/name --project-context x --review-focus y
  [ "$status" -eq 0 ]
  for f in status.sh drain.sh; do
    [ -x "$tgt/loop/$f" ]
    cmp "$PAT_DIR/$f" "$tgt/loop/$f"
  done
}
