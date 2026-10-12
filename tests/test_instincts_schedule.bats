#!/usr/bin/env bats
# Tests for `instincts.sh schedule` and `instincts.sh sync` (openspec change
# `instincts`, group 5: schedule and private-repo sync).
#
# Offline and temp-dir only. `crontab`, `launchctl`, `systemctl` and `loginctl` are
# the shared logging stubs (tests/helpers/stubs.bash): every call is logged to
# $STUB_LOG, and the tests assert the log stays EMPTY, i.e. `schedule` only prints.
# Sync runs against a temp bare remote plus temp clones; the real private repo,
# ~/.grid and the real home are never touched. Instinct lines are synthetic
# placeholders (sync moves bytes; it never parses them).

bats_require_minimum_version 1.5.0
load helpers/stubs

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SH="$REPO_ROOT/scripts/instincts.sh"

setup() {
  # A git hook (the commit gate) exports these; they must not leak into the fixtures.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GRID_LEARNING_DIR
  export PYTHONDONTWRITEBYTECODE=1
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export GRID_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GRID_RUN_LOG="$BATS_TEST_TMPDIR/runs.jsonl"
  export INSTINCTS_NOW="2026-10-08"            # ISO week 2026-W41
  # Commits need an identity; never read the real global git config.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  make_stubs
}

teardown() { clean_stubs; }

# --- helpers ------------------------------------------------------------------

# fake_uname KERNEL — a `uname` on PATH that prints KERNEL, so both platforms render
# on any machine. (A separate dir, not the logging stub dir, so it never pollutes $STUB_LOG.)
fake_uname() {
  mkdir -p "$BATS_TEST_TMPDIR/unamebin"
  printf '#!/bin/sh\necho %s\n' "$1" > "$BATS_TEST_TMPDIR/unamebin/uname"
  chmod +x "$BATS_TEST_TMPDIR/unamebin/uname"
  export PATH="$BATS_TEST_TMPDIR/unamebin:$PATH"
}

# no_scheduler_calls — no scheduler stub was invoked and nothing was written under HOME.
no_scheduler_calls() {
  [ ! -s "$STUB_LOG" ]
  [ -z "$(find "$HOME" -mindepth 1 -print -quit)" ]
}

# mk_remote_and_clones — a bare remote with one commit, and clones A and B of it.
mk_remote_and_clones() {
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  PA="$BATS_TEST_TMPDIR/priv-a"
  PB="$BATS_TEST_TMPDIR/priv-b"
  git init -q --bare -b main "$REMOTE"
  git clone -q "$REMOTE" "$PA" 2>/dev/null
  git -C "$PA" checkout -q -b main 2>/dev/null || true
  printf 'private\n' > "$PA/README"
  git -C "$PA" add README
  git -C "$PA" commit -q -m init
  git -C "$PA" push -q -u origin main
  git clone -q "$REMOTE" "$PB" 2>/dev/null
}

# write_instinct DIR HOST — a synthetic per-host instinct file under DIR/learning/instincts.
write_instinct() {
  mkdir -p "$1/learning/instincts/aaaaaaaaaaaa"
  printf '{"id":"synthetic-habit","host":"%s"}\n' "$2" > "$1/learning/instincts/aaaaaaaaaaaa/$2.jsonl"
}

# sync_as HOST DIR — run `instincts.sh sync` as HOST against the private repo DIR.
sync_as() {
  GRID_HOST="$1" GRID_PRIVATE_DIR="$2" run bash "$SH" sync
}

# --- schedule -----------------------------------------------------------------

@test "schedule (Linux): systemd service+timer, activation commands and crontab line; nothing run or written" {
  fake_uname Linux
  run bash "$SH" schedule
  [ "$status" -eq 0 ]
  # crontab line: minute 00, hour 6, day-of-week 1 (Monday), repo root from the script path
  echo "$output" | grep -qE "^00 06 \* \* 1 mkdir -p .*/logs && cd $REPO_ROOT && bash $REPO_ROOT/scripts/instincts.sh analyse --all >> .*/logs/instincts.log 2>&1$"
  # systemd pair
  echo "$output" | grep -q '^ExecStart=bash '"$REPO_ROOT"'/scripts/instincts.sh analyse --all$'
  echo "$output" | grep -q '^WorkingDirectory='"$REPO_ROOT"'$'
  echo "$output" | grep -q '^OnCalendar=Mon \*-\*-\* 06:00:00$'
  echo "$output" | grep -q '^Persistent=true$'
  echo "$output" | grep -q 'systemctl --user daemon-reload && systemctl --user enable --now grid-instincts.timer'
  # no launchd text on Linux
  ! echo "$output" | grep -q '<plist' || false
  no_scheduler_calls
}

@test "schedule (Darwin): launchd plist, activation command and crontab line; nothing run or written" {
  fake_uname Darwin
  run bash "$SH" schedule
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '<string>io.the-grid.instincts</string>'
  echo "$output" | grep -q '<string>'"$REPO_ROOT"'/scripts/instincts.sh</string>'
  echo "$output" | grep -q '<key>Weekday</key>'
  echo "$output" | grep -qE '<integer>6</integer>'
  echo "$output" | grep -q "launchctl bootstrap gui/\$(id -u) $HOME/Library/LaunchAgents/io.the-grid.instincts.plist"
  echo "$output" | grep -qE '^00 06 \* \* 1 '
  # no systemd text on macOS
  ! echo "$output" | grep -q 'OnCalendar' || false
  no_scheduler_calls
}

@test "schedule: logs go to GRID_STATE_DIR/logs/instincts.log" {
  fake_uname Linux
  run bash "$SH" schedule
  [ "$status" -eq 0 ]
  echo "$output" | grep -q ">> $GRID_STATE_DIR/logs/instincts.log 2>&1"
}

@test "schedule: a repo path the renderer rejects exits 2 and prints nothing to stdout" {
  fake_uname Linux
  # a copy of the two files the command needs, under a path containing a space
  local copy="$BATS_TEST_TMPDIR/odd dir"
  mkdir -p "$copy/scripts/lib"
  cp "$SH" "$copy/scripts/instincts.sh"
  cp "$REPO_ROOT/scripts/lib/render-schedule.sh" "$copy/scripts/lib/render-schedule.sh"
  run --separate-stderr bash "$copy/scripts/instincts.sh" schedule
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unsafe"* ]]
  no_scheduler_calls
}

@test "schedule: --install and any other argument exit 2" {
  run bash "$SH" schedule --install
  [ "$status" -eq 2 ]
  run bash "$SH" schedule now
  [ "$status" -eq 2 ]
  no_scheduler_calls
}

# --- sync ---------------------------------------------------------------------

@test "sync: each host's file pushes and pulls with no conflict" {
  mk_remote_and_clones
  write_instinct "$PA" host-a
  sync_as host-a "$PA"
  [ "$status" -eq 0 ]
  [ "$(git -C "$PA" log -1 --format=%s)" = "instincts: host-a 2026-W41" ]
  [ "$(git -C "$REMOTE" log -1 --format=%s)" = "instincts: host-a 2026-W41" ]

  # host B pulls A's file, adds its own, pushes
  write_instinct "$PB" host-b
  sync_as host-b "$PB"
  [ "$status" -eq 0 ]
  [ -f "$PB/learning/instincts/aaaaaaaaaaaa/host-a.jsonl" ]
  [ "$(git -C "$REMOTE" log -1 --format=%s)" = "instincts: host-b 2026-W41" ]

  # host A pulls B's file; it has nothing new of its own, so no extra commit
  local before; before="$(git -C "$PA" rev-list --count HEAD)"
  sync_as host-a "$PA"
  [ "$status" -eq 0 ]
  [ -f "$PA/learning/instincts/aaaaaaaaaaaa/host-b.jsonl" ]
  [ "$(git -C "$PA" rev-list --count HEAD)" -eq "$((before + 1))" ]   # only the pulled host-b commit
  [ "$(git -C "$PA" log -1 --format=%s)" = "instincts: host-b 2026-W41" ]
}

@test "sync: no changes creates no commit" {
  mk_remote_and_clones
  write_instinct "$PA" host-a
  sync_as host-a "$PA"
  [ "$status" -eq 0 ]
  local before; before="$(git -C "$PA" rev-parse HEAD)"
  sync_as host-a "$PA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes to commit"* ]]
  [ "$(git -C "$PA" rev-parse HEAD)" = "$before" ]
}

@test "sync: stages only learning/instincts, never other files in the private repo" {
  mk_remote_and_clones
  write_instinct "$PA" host-a
  printf 'x\n' > "$PA/unrelated.txt"                  # untracked, outside the instincts path
  printf 'changed\n' >> "$PA/README"                   # tracked, modified, outside the path
  sync_as host-a "$PA"
  [ "$status" -eq 0 ]
  [ "$(git -C "$PA" show --name-only --format= HEAD)" = "learning/instincts/aaaaaaaaaaaa/host-a.jsonl" ]
  [ -f "$PA/unrelated.txt" ]
  git -C "$PA" status --short | grep -q 'unrelated.txt'
  git -C "$PA" status --short | grep -q 'README'
}

@test "sync: a failing push still exits 0 with a warning, and the commit stays local" {
  mk_remote_and_clones
  # A remote that rejects every push (works even when tests run as root).
  printf '#!/bin/sh\necho rejected-by-test >&2\nexit 1\n' > "$REMOTE/hooks/pre-receive"
  chmod +x "$REMOTE/hooks/pre-receive"
  write_instinct "$PA" host-a
  sync_as host-a "$PA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync warning"*"push failed"* ]]
  [ "$(git -C "$PA" log -1 --format=%s)" = "instincts: host-a 2026-W41" ]
  [ "$(git -C "$REMOTE" rev-list --count main)" -eq 1 ]
}

@test "sync: a private dir that is not a git repo is skipped with a notice, exit 0" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  write_instinct "$BATS_TEST_TMPDIR/plain" host-a
  sync_as host-a "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git repo"* ]]
}

@test "sync: a private dir that is only a folder inside another repo is not committed to" {
  mk_remote_and_clones
  mkdir -p "$PA/nested"
  write_instinct "$PA/nested" host-a
  local before; before="$(git -C "$PA" rev-parse HEAD)"
  sync_as host-a "$PA/nested"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git repo"* ]]
  [ "$(git -C "$PA" rev-parse HEAD)" = "$before" ]
}

@test "sync: a missing private dir is skipped, exit 0" {
  sync_as host-a "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync skipped"* ]]
}

@test "sync: refuses a private dir inside the repo checkout (data never goes in this repo)" {
  sync_as host-a "$REPO_ROOT/some-private"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing"* ]]
  [ ! -e "$REPO_ROOT/some-private" ]
}

# --- analyse calls sync -------------------------------------------------------

@test "analyse --all ends with a sync; --no-sync and --dry-run skip it" {
  mk_remote_and_clones
  export GRID_PRIVATE_DIR="$PA" GRID_HOST=host-a
  mkdir -p "$GRID_STATE_DIR"           # no observations: nothing to analyse, no model call
  run bash "$SH" analyse --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync: no changes to commit"* ]]
  run bash "$SH" analyse --all --no-sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"sync"* ]]
  run bash "$SH" analyse --all --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"sync"* ]]
}
