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
  for c in bash uname mkdir rm cat dirname; do ln -s "$(command -v "$c")" "$BIN/$c"; done
}

teardown() {
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
