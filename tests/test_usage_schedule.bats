#!/usr/bin/env bats
# scripts/usage/weekly.sh + scripts/usage/install-schedule.sh.
#
# No scheduler stubs: installer runs use a PATH of symlinked essentials that holds
# no launchctl, systemctl, crontab or loginctl, so any call to one would print
# "command not found" (asserted absent). Everything runs under temp dirs; nothing
# is installed, enabled or read from the real home, ~/.claude or private repo.

bats_require_minimum_version 1.5.0
load helpers/setup

FIX="$BATS_TEST_DIRNAME/fixtures/usage"
WEEKLY="$BATS_TEST_DIRNAME/../scripts/usage/weekly.sh"
INSTALL="$BATS_TEST_DIRNAME/../scripts/usage/install-schedule.sh"

setup() {
  common_setup
  T="$(mktemp -d)"
  # Same synthetic transcript tree the extractor tests use.
  cp -R "$FIX/claude-projects" "$T/projects"
  mkdir -p "$T/skills" "$T/agents" "$T/state" "$T/home"
  printf '{"cleanupPeriodDays": 60}\n' > "$T/settings.json"
  export CLAUDE_PROJECTS_DIR="$T/projects"
  export SKILLS_DIR="$T/skills" AGENTS_DIR="$T/agents"
  export CLAUDE_SETTINGS="$T/settings.json"
  export GRID_STATE_DIR="$T/state"
  export GRID_PRIVATE_DIR="$T/private"
  export GRID_HOST=testhost
  # Commits need an identity; never read the real global git config.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  # HOME inside the sandbox: the plist bakes HOME in, and nothing may touch the real one.
  export HOME="$T/home"
  export LAUNCH_AGENTS_DIR="$T/la" SYSTEMD_USER_DIR="$T/sd"

  # PATH of symlinked essentials: no scheduler binary can be found.
  BIN="$T/bin"; mkdir -p "$BIN"
  local c
  # mktemp + mv: the installer writes unit files via a temp file and an atomic rename.
  for c in bash uname mkdir rm cat dirname mktemp mv; do ln -s "$(command -v "$c")" "$BIN/$c"; done
}

teardown() {
  # A test may leave a read-only dir behind; make everything removable first.
  chmod -R u+w "$T" 2>/dev/null || true
  rm -rf "$T"
  common_teardown
}

# private_repo — a git repo at $GRID_PRIVATE_DIR with a local bare remote and upstream set.
private_repo() {
  git init -q --bare "$T/remote.git"
  git init -q -b main "$GRID_PRIVATE_DIR"
  git -C "$GRID_PRIVATE_DIR" remote add origin "$T/remote.git"
  git -C "$GRID_PRIVATE_DIR" commit -q --allow-empty -m init
  git -C "$GRID_PRIVATE_DIR" push -q -u origin main
}

# mark_remote — create the push-remote marker (.grid-private-remote) the push guard needs.
# Call it after any `remote set-url`: the marker must equal the current push URL.
mark_remote() {
  git -C "$GRID_PRIVATE_DIR" remote get-url --push origin > "$GRID_PRIVATE_DIR/.grid-private-remote"
}

# private_repo_with_file — private_repo plus a tracked README.md pushed to the remote.
private_repo_with_file() {
  private_repo
  printf 'line one\n' > "$GRID_PRIVATE_DIR/README.md"
  git -C "$GRID_PRIVATE_DIR" add README.md
  git -C "$GRID_PRIVATE_DIR" commit -q -m readme
  git -C "$GRID_PRIVATE_DIR" push -q origin main
}

# remote_commit_readme <text> — a second clone edits README.md and pushes (remote moves ahead).
remote_commit_readme() {
  git clone -q -b main "$T/remote.git" "$T/other" 2>/dev/null
  printf '%s\n' "$1" > "$T/other/README.md"
  git -C "$T/other" commit -q -am "remote edit"
  git -C "$T/other" push -q origin main
}

# install <scheduler> [args...] — run the installer with the scheduler-free PATH.
# `env` sets PATH only for the installer (bats' own `run` still needs mktemp etc.).
# DISPLAY/WAYLAND_DISPLAY are blanked (headless) unless TEST_DISPLAY is set.
install() {
  local s="$1"; shift
  run --separate-stderr env PATH="$BIN" GRID_SCHEDULER="$s" DISPLAY="${TEST_DISPLAY:-}" WAYLAND_DISPLAY= \
    "$(command -v bash)" "$INSTALL" "$@"
}

# --- weekly.sh ----------------------------------------------------------------

@test "(a) weekly.sh makes one commit holding only usage/<host>.json and pushes it" {
  private_repo
  mark_remote
  # An unrelated untracked file and a staged one must stay out of the commit.
  echo x > "$GRID_PRIVATE_DIR/other.txt"
  git -C "$GRID_PRIVATE_DIR" add other.txt
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-list --count HEAD)" = 2 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" show --name-only --format= HEAD)" = "usage/testhost.json" ]
  [[ "$(git -C "$GRID_PRIVATE_DIR" log -1 --format=%s)" =~ ^usage:\ testhost\ [0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
  # Pushed: the bare remote has the same tip.
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" ]
  # No AI attribution in the commit message.
  ! git -C "$GRID_PRIVATE_DIR" log -1 --format=%B | grep -qi 'claude\|co-authored' || false
  grep -q 'git push rc=0' "$T/state/usage.log"
}

@test "(b) a second run makes no new commit" {
  private_repo
  run bash "$WEEKLY"; [ "$status" -eq 0 ]
  before="$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)"
  run bash "$WEEKLY"; [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" = "$before" ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-list --count HEAD)" = 2 ]
}

@test "(c) an unreachable remote exits 0, keeps the commit and logs the push failure" {
  private_repo
  git -C "$GRID_PRIVATE_DIR" remote set-url origin "$T/no-such-remote.git"
  mark_remote
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-list --count HEAD)" = 2 ]
  grep -q 'git push rc=[1-9]' "$T/state/usage.log"
  grep -q 'git pull rc=[1-9]' "$T/state/usage.log"
  # No rebase left half-finished.
  [ ! -d "$GRID_PRIVATE_DIR/.git/rebase-merge" ] && [ ! -d "$GRID_PRIVATE_DIR/.git/rebase-apply" ]
}

@test "(d) a private dir that is not a git repo gets the file and exits 0" {
  mkdir -p "$GRID_PRIVATE_DIR"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ -f "$GRID_PRIVATE_DIR/usage/testhost.json" ]
  [ ! -d "$GRID_PRIVATE_DIR/.git" ]
  grep -q 'file only' "$T/state/usage.log"
}

# --- weekly.sh: private-repo git handling (WP-024) ------------------------------

@test "mid-rebase repo with a resolved index: weekly.sh leaves rebase state, files and index untouched, no commit, no push" {
  private_repo
  mark_remote
  printf 'base\n' > "$GRID_PRIVATE_DIR/f.txt"
  git -C "$GRID_PRIVATE_DIR" add f.txt
  git -C "$GRID_PRIVATE_DIR" commit -q -m base
  git -C "$GRID_PRIVATE_DIR" push -q origin main
  git -C "$GRID_PRIVATE_DIR" checkout -q -b topic
  printf 'topic\n' > "$GRID_PRIVATE_DIR/f.txt"
  git -C "$GRID_PRIVATE_DIR" commit -q -am topic
  git -C "$GRID_PRIVATE_DIR" checkout -q main
  printf 'main\n' > "$GRID_PRIVATE_DIR/f.txt"
  git -C "$GRID_PRIVATE_DIR" commit -q -am main
  git -C "$GRID_PRIVATE_DIR" checkout -q topic
  git -C "$GRID_PRIVATE_DIR" rebase main >/dev/null 2>&1 || true     # stops on the conflict
  printf 'resolved\n' > "$GRID_PRIVATE_DIR/f.txt"
  git -C "$GRID_PRIVATE_DIR" add f.txt                                 # resolved index, rebase pending
  [ -d "$GRID_PRIVATE_DIR/.git/rebase-merge" ]
  before_index="$(git -C "$GRID_PRIVATE_DIR" diff --cached)"
  before_head="$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)"
  before_remote="$(git -C "$T/remote.git" rev-parse main)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ -d "$GRID_PRIVATE_DIR/.git/rebase-merge" ]
  [ "$(cat "$GRID_PRIVATE_DIR/f.txt")" = resolved ]
  [ "$(git -C "$GRID_PRIVATE_DIR" diff --cached)" = "$before_index" ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" = "$before_head" ]
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$before_remote" ]
  grep -q 'rebase-in-progress' "$T/state/usage.log"
}

@test "remote ahead plus operator edit to a tracked file: no conflict markers anywhere, log has a pull skip" {
  private_repo_with_file
  mark_remote
  remote_commit_readme "line one remote"
  printf 'line one local\n' > "$GRID_PRIVATE_DIR/README.md"          # operator's uncommitted edit
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  ! grep -rq '^<<<<<<<' "$GRID_PRIVATE_DIR" --exclude-dir=.git || false
  [ "$(cat "$GRID_PRIVATE_DIR/README.md")" = "line one local" ]       # operator edit preserved
  ! git -C "$GRID_PRIVATE_DIR" log -p --all | grep -q '^+<<<<<<<' || false
  grep -q 'pull skipped' "$T/state/usage.log"
  [ ! -e "$GRID_PRIVATE_DIR/.git/rebase-merge" ]
}

@test "an unpushed foreign commit: the remote head does not move, exit 4, log line" {
  private_repo
  mark_remote
  printf 'mine\n' > "$GRID_PRIVATE_DIR/notes.txt"
  git -C "$GRID_PRIVATE_DIR" add notes.txt
  git -C "$GRID_PRIVATE_DIR" commit -q -m "operator work"
  before_remote="$(git -C "$T/remote.git" rev-parse main)"
  run bash "$WEEKLY"
  [ "$status" -eq 4 ]
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$before_remote" ]
  grep -q 'push skipped' "$T/state/usage.log"
  grep -q 'foreign-commits' "$T/state/usage.log"
  # The job's own commit is still made locally, on top of the operator's.
  [ "$(git -C "$GRID_PRIVATE_DIR" log -1 --format=%s)" != "operator work" ]
}

@test "detached HEAD: no commit is created, the file is still extracted" {
  private_repo
  mark_remote
  git -C "$GRID_PRIVATE_DIR" checkout -q --detach
  before="$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" = "$before" ]
  [ -f "$GRID_PRIVATE_DIR/usage/testhost.json" ]
  grep -q 'detached-head' "$T/state/usage.log"
}

@test "no upstream: no commit is created" {
  private_repo
  mark_remote
  git -C "$GRID_PRIVATE_DIR" branch -q --unset-upstream
  before="$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" = "$before" ]
  grep -q 'no-upstream' "$T/state/usage.log"
}

@test "no marker file: nothing is pushed and a warning is logged" {
  private_repo
  before_remote="$(git -C "$T/remote.git" rev-parse main)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-list --count HEAD)" = 2 ]       # committed locally
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$before_remote" ]
  grep -q 'push skipped' "$T/state/usage.log"
}

@test "a marker that does not match the push remote: nothing is pushed" {
  private_repo
  echo "git@example.invalid:someone/else.git" > "$GRID_PRIVATE_DIR/.grid-private-remote"
  before_remote="$(git -C "$T/remote.git" rev-parse main)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$before_remote" ]
  grep -q 'push skipped' "$T/state/usage.log"
}

@test "a git that hangs is killed by the alarm and weekly.sh still finishes" {
  private_repo
  mark_remote
  # A stub git that sleeps on pull and defers to the real git otherwise.
  mkdir -p "$T/stubbin"
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = pull ] && exec sleep 60; done\nexec %s "$@"\n' "$(command -v git)" > "$T/stubbin/git"
  chmod +x "$T/stubbin/git"
  start=$SECONDS
  PATH="$T/stubbin:$PATH" GRID_GIT_TIMEOUT=2 run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 30 ]
  grep -q 'git pull rc=14[0-9]' "$T/state/usage.log"
}

@test "a second concurrent run exits as already running; a stale lock is taken over" {
  private_repo
  mark_remote
  mkdir "$T/state/weekly.lock"
  before="$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  grep -q 'already running' "$T/state/usage.log"
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" = "$before" ]
  # Older than two hours: stale, so the run proceeds and releases the lock.
  python3 -c 'import os,sys,time; t=time.time()-3*3600; os.utime(sys.argv[1],(t,t))' "$T/state/weekly.lock"   # portable (BSD touch has no -d)
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-list --count HEAD)" = 2 ]
  [ ! -e "$T/state/weekly.lock" ]
}

# --- weekly.sh write hygiene (WP-026) --------------------------------------------

@test "two simultaneous weekly.sh runs: one logs already running, no traceback" {
  private_repo
  mark_remote
  # A python3 shim that stalls the first run inside the extractor so the second overlaps it.
  mkdir -p "$T/slowbin"
  printf '#!/bin/bash\nsleep 3\nexec %s "$@"\n' "$(command -v python3)" > "$T/slowbin/python3"
  chmod +x "$T/slowbin/python3"
  PATH="$T/slowbin:$PATH" bash "$WEEKLY" &
  first=$!
  sleep 1
  PATH="$T/slowbin:$PATH" run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  wait "$first"
  [ "$(grep -c 'already running' "$T/state/usage.log")" = 1 ]
  ! grep -q Traceback "$T/state/usage.log" || false
}

@test "usage/<host>.json as a symlink is not staged" {
  private_repo
  mark_remote
  mkdir -p "$GRID_PRIVATE_DIR/usage"
  printf 'victim\n' > "$T/victim.txt"
  ln -s "$T/victim.txt" "$GRID_PRIVATE_DIR/usage/testhost.json"
  # An extractor that "succeeds" without writing, so weekly.sh reaches the staging step.
  mkdir -p "$T/okbin"
  printf '#!/bin/bash\nexit 0\n' > "$T/okbin/python3"
  chmod +x "$T/okbin/python3"
  before="$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)"
  PATH="$T/okbin:$PATH" run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$GRID_PRIVATE_DIR" rev-parse HEAD)" = "$before" ]
  [ -z "$(git -C "$GRID_PRIVATE_DIR" ls-files usage)" ]
  grep -q 'not a regular file' "$T/state/usage.log"
}

# --- weekly.sh: the push is explicit (push-guard hardening) ------------------------

@test "push.default=matching with an unpushed commit on another branch: that branch is not pushed" {
  private_repo
  mark_remote
  git -C "$GRID_PRIVATE_DIR" config push.default matching
  git -C "$GRID_PRIVATE_DIR" branch side
  git -C "$GRID_PRIVATE_DIR" push -q origin side
  git -C "$GRID_PRIVATE_DIR" checkout -q side
  printf 'unreviewed\n' > "$GRID_PRIVATE_DIR/side.txt"
  git -C "$GRID_PRIVATE_DIR" add side.txt
  git -C "$GRID_PRIVATE_DIR" commit -q -m "side work"
  git -C "$GRID_PRIVATE_DIR" checkout -q main
  side_before="$(git -C "$T/remote.git" rev-parse side)"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/remote.git" rev-parse side)" = "$side_before" ]
  # The job's own commit still went out on its own branch.
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$(git -C "$GRID_PRIVATE_DIR" rev-parse main)" ]
}

@test "a second push URL on the remote is refused, in either order: nothing reaches it" {
  private_repo
  mark_remote
  git init -q --bare "$T/elsewhere.git"
  # marker URL first, extra URL second: `get-url --push` alone would show only the first
  git -C "$GRID_PRIVATE_DIR" remote set-url --add --push origin "$T/remote.git"
  git -C "$GRID_PRIVATE_DIR" remote set-url --add --push origin "$T/elsewhere.git"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  grep -q 'push skipped' "$T/state/usage.log"
  [ -z "$(git -C "$T/elsewhere.git" for-each-ref refs/heads)" ]
  # reverse order
  git -C "$GRID_PRIVATE_DIR" config --unset-all remote.origin.pushurl
  git -C "$GRID_PRIVATE_DIR" remote set-url --add --push origin "$T/elsewhere.git"
  git -C "$GRID_PRIVATE_DIR" remote set-url --add --push origin "$T/remote.git"
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$T/elsewhere.git" for-each-ref refs/heads)" ]
}

@test "a branch pushRemote pointing at another remote is not used: only the verified remote is pushed to" {
  private_repo
  mark_remote
  git init -q --bare "$T/elsewhere.git"
  git -C "$GRID_PRIVATE_DIR" remote add elsewhere "$T/elsewhere.git"
  git -C "$GRID_PRIVATE_DIR" config branch.main.pushRemote elsewhere
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$T/elsewhere.git" for-each-ref refs/heads)" ]
  [ "$(git -C "$T/remote.git" rev-parse main)" = "$(git -C "$GRID_PRIVATE_DIR" rev-parse main)" ]
}

# --- install-schedule.sh -------------------------------------------------------

# paths_ok <file...> — every absolute path in the files is under $T, the repo, or a
# standard system dir. The PATH-variable lines are dropped first (they list system dirs).
paths_ok() {
  local repo bad
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Leading class excludes "<" so closing tags like </key> are not read as paths.
  bad="$(grep -hv 'DOCTYPE\|\.local/bin' "$@" | grep -oE '(^|[ =">])/[A-Za-z0-9_./@+-]+' | sed -E 's/^[ =">]//' \
    | grep -v -e "^$T" -e "^$repo" -e '^/bin/bash$' -e '^/dev/null$' || true)"
  [ -z "$bad" ] || { echo "unexpected absolute paths: $bad" >&2; return 1; }
}

@test "(e) launchd: writes the plist with Monday 09:00 and prints activation" {
  install launchd
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"command not found"* ]]
  p="$LAUNCH_AGENTS_DIR/io.the-grid.usage.plist"
  [ -f "$p" ]
  grep -q '<key>Weekday</key>' "$p"
  grep -A1 '<key>Weekday</key>' "$p" | grep -q '<integer>1</integer>'
  grep -A1 '<key>Hour</key>' "$p" | grep -q '<integer>9</integer>'
  grep -A1 '<key>Minute</key>' "$p" | grep -q '<integer>0</integer>'
  grep -q "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/usage/weekly.sh" "$p"
  grep -q "$T/state/io.the-grid.usage.log" "$p"
  paths_ok "$p"
  [[ "$output" == *'launchctl bootout gui/$(id -u)/io.the-grid.usage 2>/dev/null; launchctl bootstrap gui/$(id -u) '"$p"* ]]
}

@test "(e) systemd: writes service and timer with Monday 09:00 and prints activation" {
  install systemd
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"command not found"* ]]
  s="$SYSTEMD_USER_DIR/grid-usage.service" t="$SYSTEMD_USER_DIR/grid-usage.timer"
  [ -f "$s" ]
  [ -f "$t" ]
  grep -q '^Type=oneshot$' "$s"
  grep -q "^ExecStart=/bin/bash $(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/usage/weekly.sh$" "$s"
  grep -q '^OnCalendar=Mon \*-\*-\* 09:00:00$' "$t"
  grep -q '^Persistent=true$' "$t"
  grep -q '^RandomizedDelaySec=1h$' "$t"
  paths_ok "$s" "$t"
  [[ "$output" == *"systemctl --user daemon-reload && systemctl --user enable --now grid-usage.timer"* ]]
  # Headless (no DISPLAY / WAYLAND_DISPLAY): the linger line is printed.
  [[ "$output" == *"loginctl enable-linger"* ]]
}

@test "(e) systemd with a display set does not print the linger line" {
  TEST_DISPLAY=:0 install systemd
  [ "$status" -eq 0 ]
  [[ "$output" != *"enable-linger"* ]]
}

@test "(e) cron: prints the weekly line and writes nothing" {
  install cron
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"command not found"* ]]
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # The shared renderer zero-pads the fields ("00 09"), which cron reads as 0 9.
  [[ "$output" == *"00 09 * * 1 mkdir -p $T/state && cd $repo && /bin/bash $repo/scripts/usage/weekly.sh >> $T/state/usage.log 2>&1"* ]]
  [[ "$output" == *"crontab -"* ]]
  [ ! -e "$LAUNCH_AGENTS_DIR" ]
  [ ! -e "$SYSTEMD_USER_DIR" ]
  printf '%s\n' "$output" > "$T/out.txt"
  paths_ok "$T/out.txt"
}

@test "(f) installing twice gives identical files and prints unchanged; --uninstall removes them" {
  for s in launchd systemd; do
    install "$s"; [ "$status" -eq 0 ]
    [[ "$output" == *"wrote "* ]]
    sum1="$(cat "$LAUNCH_AGENTS_DIR"/* "$SYSTEMD_USER_DIR"/* 2>/dev/null | cksum)"
    install "$s"; [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged "* ]]
    [[ "$output" != *"wrote "* ]]
    [ "$sum1" = "$(cat "$LAUNCH_AGENTS_DIR"/* "$SYSTEMD_USER_DIR"/* 2>/dev/null | cksum)" ]
    install "$s" --uninstall; [ "$status" -eq 0 ]
    [[ "$output" == *"removed "* ]]
    [[ "$output" == *"Deactivate"* ]]
    # Uninstall twice is a clean no-op too.
    install "$s" --uninstall; [ "$status" -eq 0 ]
    [[ "$output" == *"absent "* ]]
  done
  [ -z "$(find "$LAUNCH_AGENTS_DIR" "$SYSTEMD_USER_DIR" -type f)" ]
}

@test "(f) --uninstall prints the matching deactivation command per scheduler" {
  install launchd --uninstall
  [[ "$output" == *'launchctl bootout gui/$(id -u)/io.the-grid.usage'* ]]
  install systemd --uninstall
  [[ "$output" == *"systemctl --user disable --now grid-usage.timer"* ]]
  install cron --uninstall
  [[ "$output" == *"crontab -e"* ]]
}

@test "(g) a GRID_DIR path the renderer rejects exits 2 and writes nothing" {
  # A copy of the scripts under a directory name with a space: the installer
  # derives GRID_DIR from its own location, so the renderer sees an unsafe path.
  mkdir -p "$T/un safe/scripts"
  cp -R "$BATS_TEST_DIRNAME/../scripts/usage" "$BATS_TEST_DIRNAME/../scripts/lib" "$T/un safe/scripts/"
  for s in launchd systemd cron; do
    run --separate-stderr env PATH="$BIN" GRID_SCHEDULER="$s" "$(command -v bash)" "$T/un safe/scripts/usage/install-schedule.sh"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"cannot escape"* ]]
  done
  [ ! -e "$LAUNCH_AGENTS_DIR" ] && [ ! -e "$SYSTEMD_USER_DIR" ]
}

@test "(g) an unsafe state dir also exits 2 and writes nothing" {
  # launchd bakes the state dir into the plist, so it is validated there.
  GRID_STATE_DIR="$T/bad state" install launchd
  [ "$status" -eq 2 ]
  [ ! -e "$LAUNCH_AGENTS_DIR" ]
}

# --- install-schedule.sh: uninstall, symlinks, environment (WP-027) --------------

# mode_of <path> — octal permission bits (portable: no stat flags).
mode_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }

@test "install with the probe passing, --uninstall with the probe failing (cron fallback) removes both unit files" {
  # A fake `uname` (Linux) and a `systemctl` whose probe succeeds: the installer picks systemd.
  mkdir -p "$T/probe"
  printf '#!/bin/sh\necho Linux\n' > "$T/probe/uname"
  printf '#!/bin/sh\nexit 0\n' > "$T/probe/systemctl"
  chmod +x "$T/probe/uname" "$T/probe/systemctl"
  run --separate-stderr env -u GRID_SCHEDULER PATH="$T/probe:$BIN" DISPLAY=:0 "$(command -v bash)" "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$SYSTEMD_USER_DIR/grid-usage.service" ]
  [ -f "$SYSTEMD_USER_DIR/grid-usage.timer" ]
  # Now the probe fails (no systemctl on PATH): detection falls back to cron.
  run --separate-stderr env -u GRID_SCHEDULER PATH="$T/probe-less:$BIN" DISPLAY=:0 "$(command -v bash)" "$INSTALL" --uninstall
  [ "$status" -eq 0 ]
  [ -z "$(find "$SYSTEMD_USER_DIR" -type f)" ]
  [[ "$output" == *"removed "* ]]
  [[ "$output" == *"systemctl --user disable --now grid-usage.timer"* ]]
}

@test "--uninstall from a copy of the scripts under a path with a space exits 0 and removes files" {
  install systemd; [ "$status" -eq 0 ]
  install launchd; [ "$status" -eq 0 ]
  mkdir -p "$T/un safe/scripts"
  cp -R "$BATS_TEST_DIRNAME/../scripts/usage" "$BATS_TEST_DIRNAME/../scripts/lib" "$T/un safe/scripts/"
  # One uninstall removes the files of every scheduler, whichever one is named.
  run --separate-stderr env PATH="$BIN" GRID_SCHEDULER=systemd "$(command -v bash)" "$T/un safe/scripts/usage/install-schedule.sh" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed "* ]]
  [ -z "$(find "$LAUNCH_AGENTS_DIR" "$SYSTEMD_USER_DIR" -type f)" ]
  # And a second run is a clean no-op.
  run --separate-stderr env PATH="$BIN" GRID_SCHEDULER=launchd "$(command -v bash)" "$T/un safe/scripts/usage/install-schedule.sh" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"absent "* ]]
}

@test "a symlinked grid-usage.service is replaced, its target untouched, mode 0600" {
  mkdir -p "$SYSTEMD_USER_DIR"
  printf 'victim-original\n' > "$T/victim.txt"
  ln -s "$T/victim.txt" "$SYSTEMD_USER_DIR/grid-usage.service"
  install systemd
  [ "$status" -eq 0 ]
  [ "$(cat "$T/victim.txt")" = "victim-original" ]
  [ ! -L "$SYSTEMD_USER_DIR/grid-usage.service" ]
  [ "$(mode_of "$SYSTEMD_USER_DIR/grid-usage.service")" = 600 ]
  [ "$(mode_of "$SYSTEMD_USER_DIR/grid-usage.timer")" = 600 ]
  [[ "$output" == *"replaced symlink"* ]]
  # No temp file left behind.
  [ -z "$(find "$SYSTEMD_USER_DIR" -name '.*' -type f)" ]
}

@test "a relative GRID_STATE_DIR or GRID_PRIVATE_DIR exits 2 and writes nothing" {
  GRID_STATE_DIR=rel install launchd
  [ "$status" -eq 2 ]
  [ ! -e "$LAUNCH_AGENTS_DIR" ]
  GRID_PRIVATE_DIR=rel install systemd
  [ "$status" -eq 2 ]
  [ ! -e "$SYSTEMD_USER_DIR" ]
}

@test "the state dir exists after a launchd install" {
  GRID_STATE_DIR="$T/fresh-state" install launchd
  [ "$status" -eq 0 ]
  [ -d "$T/fresh-state" ]
}

@test "a custom GRID_STATE_DIR / GRID_PRIVATE_DIR / GRID_HOST prints the not-carried note" {
  GRID_STATE_DIR="$T/state" install systemd
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not carried into the scheduled job"* ]]
  # Nothing set: no note.
  run --separate-stderr env -i PATH="$BIN" HOME="$T/home" GRID_SCHEDULER=systemd SYSTEMD_USER_DIR="$T/sd2" "$(command -v bash)" "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"not carried"* ]]
}

@test "a read-only state dir: weekly.sh exits 1 with a message" {
  chmod 555 "$T/state"
  # Root ignores modes; fail loudly instead of passing without testing anything.
  [ ! -w "$T/state" ]
  run bash "$WEEKLY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not writable"* ]]
}

@test "weekly.sh: a pull that conflicts on the job's own file aborts its rebase, exits 0, logs it" {
  private_repo
  mark_remote
  # Another clone commits a DIFFERENT usage/testhost.json first, so the job's commit conflicts.
  git clone -q -b main "$T/remote.git" "$T/other" 2>/dev/null
  mkdir -p "$T/other/usage"
  printf '{"schema": 1, "other": true}\n' > "$T/other/usage/testhost.json"
  git -C "$T/other" add usage
  git -C "$T/other" commit -q -m "other host copy"
  git -C "$T/other" push -q origin main
  run bash "$WEEKLY"
  [ "$status" -eq 0 ]
  [ ! -d "$GRID_PRIVATE_DIR/.git/rebase-merge" ]
  [ ! -d "$GRID_PRIVATE_DIR/.git/rebase-apply" ]
  grep -q 'rebase aborted' "$T/state/usage.log"
  grep -q 'git pull rc=[1-9]' "$T/state/usage.log"
  # The local commit survived the abort.
  [ "$(git -C "$GRID_PRIVATE_DIR" log -1 --format=%s | cut -c1-6)" = "usage:" ]
}

@test "(h) the plist passes plutil -lint when plutil exists" {
  command -v plutil >/dev/null || skip "plutil not available"
  install launchd
  plutil -lint "$LAUNCH_AGENTS_DIR/io.the-grid.usage.plist"
}

@test "(h) the units pass systemd-analyze verify --user when available" {
  command -v systemd-analyze >/dev/null || skip "systemd-analyze not available"
  install systemd
  # Private runtime dir + probe-skip (see systemd_verify_private): never the live manager.
  systemd_verify_private "$SYSTEMD_USER_DIR/grid-usage.service" "$SYSTEMD_USER_DIR/grid-usage.timer"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "(h) systemd-analyze runs in a private XDG_RUNTIME_DIR" {
  # A stub records the runtime dir it was given; the inherited (real) one must not reach it.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\necho "$XDG_RUNTIME_DIR" >> "%s/rt.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/systemd-analyze"
  chmod +x "$BATS_TEST_TMPDIR/bin/systemd-analyze"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" XDG_RUNTIME_DIR=/run/user/4242 systemd_verify_private /nonexistent.service
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/rt.log" ]
  while IFS= read -r rt; do
    [[ "$rt" == "$BATS_TEST_TMPDIR"/* ]] || { echo "runtime dir leaked: $rt"; false; }
  done < "$BATS_TEST_TMPDIR/rt.log"
}
