#!/usr/bin/env bats
# Tests for `grid drift` and `grid schedule`, group 5 of change
# `manifest-lock-install`.
#
# Every fixture is a throwaway git repo built inside the test (see
# helpers/grid_fixture.bash). Nothing touches the network, the real ~/.grid or
# the real ~/.claude, and no scheduler is ever invoked: launchctl, systemctl,
# crontab and loginctl are marker-writing stubs and the tests assert no marker
# appears. These tests verify my own implementation (a self-check); independent
# verification is for qa-engineer / sdet.

load helpers/setup
load helpers/stubs
load helpers/grid_fixture

setup() {
  common_setup
  T=$(mktemp -d)
  grid_env_isolate "$T/env"
  U="$T/upstream"
  G="$T/grid"
  make_upstream "$U"
  # A third skill that no test touches, so "counts the rest" has something to count.
  mkdir -p "$U/skills/gamma"
  printf -- '---\nname: gamma\ndescription: Fixture skill gamma\n---\nGamma body.\n' > "$U/skills/gamma/SKILL.md"
  upstream_commit "add gamma"
  make_grid_fixture "$G" "$U"
  GRID_BIN="$G/scripts/grid"
  # Lock the fixture the way a maintainer would (this is group 2's command).
  python3 -B "$GRID_BIN" --grid-dir "$G" lock >/dev/null
  # A stand-in ledger (group 3's file) so "the ledger is untouched" is checkable.
  printf 'kind\tname\tsource\n' > "$GRID_STATE_DIR/installed.manifest"
  REPORTS="$GRID_STATE_DIR/reports"
}

teardown() {
  rm -rf "$T"
  clean_stubs
  common_teardown
}

# drift [ARGS...]: run `grid drift` against the fixture grid.
# python3 -B: never write bytecode, so the fixture tree stays free of __pycache__.
drift() { python3 -B "$GRID_BIN" --grid-dir "$G" drift "$@"; }

# schedule ARGS...: run `grid schedule` against the fixture grid.
schedule() { python3 -B "$GRID_BIN" --grid-dir "$G" schedule "$@"; }

# upstream_commit MSG: commit everything pending in the upstream repo.
upstream_commit() {
  git -C "$U" add -A
  git -C "$U" commit -q -m "$1"
}

# lock_field NAME FIELD: print one field of the named entry in grid.lock.
lock_field() {
  python3 -B -c '
import json, sys
doc = json.load(open(sys.argv[1]))
print([e for e in doc["entries"] if e["name"] == sys.argv[2]][0][sys.argv[3]])
' "$G/grid.lock" "$1" "$2"
}

# upstream_change_alpha: second upstream commit, changes alpha only.
upstream_change_alpha() {
  printf 'changed\n' >> "$U/skills/alpha/SKILL.md"
  upstream_commit "change alpha"
}

# upstream_delete_beta: third upstream commit, deletes beta.
upstream_delete_beta() {
  git -C "$U" rm -rq nested/cat/beta
  upstream_commit "delete beta"
}

# empty_dir DIR: succeeds when DIR has no entries at all.
empty_dir() { [ -z "$(ls -A "$1")" ]; }

# --- drift -----------------------------------------------------------------------

@test "changed upstream: lists alpha changed with both short shas and counts the rest" {
  upstream_change_alpha
  locked=$(lock_field alpha sha)
  head=$(git -C "$U" rev-parse HEAD)
  run drift
  [ "$status" -eq 0 ]
  report=$(cat "$REPORTS/drift-latest.md")
  contains "$report" "- changed: 1"
  contains "$report" "- unchanged: 2"
  contains "$report" "- removed: 0"
  contains "$report" '`alpha`'
  contains "$report" "locked ${locked:0:12}"
  contains "$report" "upstream ${head:0:12}"
  lacks "$report" '`gamma`'
  lacks "$report" '`beta`'
}

@test "deleted upstream path is listed as removed" {
  upstream_change_alpha
  upstream_delete_beta
  run drift
  [ "$status" -eq 0 ]
  report=$(cat "$REPORTS/drift-latest.md")
  contains "$report" "- changed: 1"
  contains "$report" "- removed: 1"
  contains "$report" "## Removed"
  contains "$report" '`beta` (`nested/cat/beta`)'
}

@test "unchanged upstream says all current and fetches nothing" {
  export GRID_TRACE_FETCH="$T/trace"
  run drift
  [ "$status" -eq 0 ]
  contains "$output" "All 3 locked skills are current."
  # No fetch happened, so the trace file was never even created.
  [ ! -s "$T/trace" ]
  # The staging dir is created lazily: nothing for a run with nothing to fetch.
  [ ! -e "$G/.grid-tmp" ]
}

@test "a changed upstream fetches once and traces it; the staging dir is cleaned up" {
  export GRID_TRACE_FETCH="$T/trace"
  upstream_change_alpha
  run drift
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$T/trace" | tr -d ' ')" = "1" ]
  contains "$(cat "$T/trace")" "up $(git -C "$U" rev-parse HEAD)"
  [ ! -e "$G/.grid-tmp" ]
}

@test "report goes to reports/drift-<date>.md and drift-latest.md, identical, and --quiet prints nothing" {
  run drift --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$REPORTS/drift-latest.md" ]
  dated=$(ls "$REPORTS" | grep -c '^drift-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\.md$')
  [ "$dated" = "1" ]
  cmp "$REPORTS/drift-latest.md" "$REPORTS"/drift-[0-9]*.md
}

@test "report body has no absolute path" {
  upstream_change_alpha
  run drift --quiet
  [ "$status" -eq 0 ]
  report=$(cat "$REPORTS/drift-latest.md")
  lacks "$report" "$T"
  # No token that starts like an absolute path.
  refute grep -Eq '(^|[ `(])/[A-Za-z0-9_.~-]' "$REPORTS/drift-latest.md"
}

@test "unreachable file:// upstream is listed unreachable and exits 0" {
  printf 'version: 1\nsources:\n  up:\n    url: file://%s/does-not-exist\nwired:\n  baseline: baseline-submodules.example.txt\n' \
    "$T" > "$G/grid.yaml"
  run drift --quiet
  [ "$status" -eq 0 ]
  report=$(cat "$REPORTS/drift-latest.md")
  contains "$report" "## Unreachable"
  contains "$report" '`up`: cannot reach upstream'
  contains "$report" "- unreachable: 3 (in 1 source)"
  # The unreachable path itself must not leak into the report.
  lacks "$report" "does-not-exist"
}

@test "a ref that does not exist upstream is unreachable with 'ref not found'" {
  printf 'version: 1\nsources:\n  up:\n    url: file://%s\n    ref: no-such-branch\nwired:\n  baseline: baseline-submodules.example.txt\n' \
    "$U" > "$G/grid.yaml"
  run drift --quiet
  [ "$status" -eq 0 ]
  report=$(cat "$REPORTS/drift-latest.md")
  contains "$report" '`up`: ref not found'
}

@test "a ref named like a tail of another ref only matches the exact name" {
  # `ls-remote` pattern-matches names by tail: `feature/main` would match `main`.
  git -C "$U" branch "feature/side"
  printf 'version: 1\nsources:\n  up:\n    url: file://%s\n    ref: side\nwired:\n  baseline: baseline-submodules.example.txt\n' \
    "$U" > "$G/grid.yaml"
  run drift --quiet
  [ "$status" -eq 0 ]
  contains "$(cat "$REPORTS/drift-latest.md")" '`up`: ref not found'
}

@test "grid.lock, the ledger and repos/ are byte-identical before and after" {
  upstream_change_alpha
  upstream_delete_beta
  before_repos=$(tree_digest "$G/repos")
  before_lock=$(cat "$G/grid.lock")
  before_ledger=$(cat "$GRID_STATE_DIR/installed.manifest")
  lock_id=$(file_id "$G/grid.lock")
  ledger_id=$(file_id "$GRID_STATE_DIR/installed.manifest")
  run drift --quiet
  [ "$status" -eq 0 ]
  [ "$before_repos" = "$(tree_digest "$G/repos")" ]
  [ "$before_lock" = "$(cat "$G/grid.lock")" ]
  [ "$before_ledger" = "$(cat "$GRID_STATE_DIR/installed.manifest")" ]
  [ "$lock_id" = "$(file_id "$G/grid.lock")" ]
  [ "$ledger_id" = "$(file_id "$GRID_STATE_DIR/installed.manifest")" ]
}

@test "a second drift run on the same day leaves the reports byte-identical" {
  upstream_change_alpha
  run drift --quiet
  [ "$status" -eq 0 ]
  first=$(file_id "$REPORTS/drift-latest.md")
  run drift --quiet
  [ "$status" -eq 0 ]
  [ "$first" = "$(file_id "$REPORTS/drift-latest.md")" ]
}

# --- schedule --------------------------------------------------------------------

@test "schedule install on Darwin writes the plist: Weekday 1, Hour 9, parses as a plist" {
  GRID_OS=Darwin run schedule install
  [ "$status" -eq 0 ]
  plist="$LAUNCH_AGENTS_DIR/io.the-grid.drift.plist"
  [ -f "$plist" ]
  python3 -B -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$plist"
  python3 -B -c '
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
cal = d["StartCalendarInterval"]
assert cal["Weekday"] == 1, cal
assert cal["Hour"] == 9, cal
assert d["ProgramArguments"][-2:] == ["drift", "--quiet"], d["ProgramArguments"]
' "$plist"
  # launchd does not create the log dir, so grid does.
  [ -d "$GRID_STATE_DIR/logs" ]
  # Nothing is written for the other schedulers; activation is printed, not run.
  empty_dir "$SYSTEMD_USER_DIR"
  contains "$output" 'launchctl bootstrap gui/$(id -u)'
  contains "$output" "nothing is activated"
}

@test "schedule install on Linux writes both units: OnCalendar and Persistent" {
  GRID_OS=Linux run schedule install
  [ "$status" -eq 0 ]
  svc="$SYSTEMD_USER_DIR/grid-drift.service"
  tmr="$SYSTEMD_USER_DIR/grid-drift.timer"
  [ -f "$svc" ]
  [ -f "$tmr" ]
  contains "$(cat "$tmr")" "OnCalendar=Mon *-*-* 09:00:00"
  contains "$(cat "$tmr")" "Persistent=true"
  contains "$(cat "$tmr")" "Unit=grid-drift.service"
  contains "$(cat "$svc")" "scripts/grid drift --quiet"
  contains "$(cat "$svc")" "ExecStart=/usr/bin/env python3"
  empty_dir "$LAUNCH_AGENTS_DIR"
  contains "$output" "systemctl --user daemon-reload && systemctl --user enable --now grid-drift.timer"
  contains "$output" 'loginctl enable-linger "$USER"'
}

@test "schedule install on another OS writes nothing and prints a crontab line" {
  GRID_OS=Other run schedule install
  [ "$status" -eq 0 ]
  empty_dir "$LAUNCH_AGENTS_DIR"
  empty_dir "$SYSTEMD_USER_DIR"
  [ ! -e "$GRID_STATE_DIR/logs" ]
  contains "$output" "scripts/grid drift"
  contains "$output" "00 09 * * 1"
  # The cron line is identified by its text, not by a tag comment.
  lacks "$output" "# the-grid drift"
  contains "$output" "(crontab -l 2>/dev/null; echo '"
}

@test "a grid path containing a space makes schedule install exit 2 and write nothing" {
  make_grid_fixture "$T/my grid" "$U"
  for os in Darwin Linux Other; do
    GRID_OS=$os run python3 -B "$T/my grid/scripts/grid" --grid-dir "$T/my grid" schedule install
    [ "$status" -eq 2 ]
    contains "$output" "schedule not written"
  done
  empty_dir "$LAUNCH_AGENTS_DIR"
  empty_dir "$SYSTEMD_USER_DIR"
  [ ! -e "$GRID_STATE_DIR/logs" ]
}

@test "a second install leaves the files byte-identical" {
  GRID_OS=Linux run schedule install
  [ "$status" -eq 0 ]
  before=$(tree_digest "$SYSTEMD_USER_DIR")
  svc_id=$(file_id "$SYSTEMD_USER_DIR/grid-drift.service")
  GRID_OS=Linux run schedule install
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_digest "$SYSTEMD_USER_DIR")" ]
  [ "$svc_id" = "$(file_id "$SYSTEMD_USER_DIR/grid-drift.service")" ]
  contains "$output" "unchanged"

  GRID_OS=Darwin run schedule install
  [ "$status" -eq 0 ]
  before=$(tree_digest "$LAUNCH_AGENTS_DIR")
  GRID_OS=Darwin run schedule install
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_digest "$LAUNCH_AGENTS_DIR")" ]
}

@test "schedule remove deletes the files and prints the deactivation command" {
  GRID_OS=Linux run schedule install
  [ "$status" -eq 0 ]
  GRID_OS=Linux run schedule remove
  [ "$status" -eq 0 ]
  empty_dir "$SYSTEMD_USER_DIR"
  contains "$output" "systemctl --user disable --now grid-drift.timer"

  GRID_OS=Darwin run schedule install
  [ "$status" -eq 0 ]
  GRID_OS=Darwin run schedule remove
  [ "$status" -eq 0 ]
  empty_dir "$LAUNCH_AGENTS_DIR"
  contains "$output" 'launchctl bootout gui/$(id -u)/io.the-grid.drift'

  GRID_OS=Other run schedule remove
  [ "$status" -eq 0 ]
  contains "$output" 'crontab line containing `scripts/grid drift`'
}

@test "schedule remove with nothing installed exits 0" {
  GRID_OS=Linux run schedule remove
  [ "$status" -eq 0 ]
  contains "$output" "not present"
}

@test "install and remove never call launchctl, systemctl, crontab or loginctl" {
  make_stubs
  # Replace the logging stubs with marker writers: any call leaves a file.
  for s in launchctl systemctl crontab loginctl; do
    printf '#!/bin/sh\ntouch "%s/called.%s"\nexit 0\n' "$STUB_DIR" "$s" > "$STUB_DIR/$s"
    chmod +x "$STUB_DIR/$s"
  done
  for os in Darwin Linux Other; do
    GRID_OS=$os run schedule install
    [ "$status" -eq 0 ]
    GRID_OS=$os run schedule remove
    [ "$status" -eq 0 ]
  done
  # GRID_OS skips even the read-only probe, so there is no marker at all.
  [ ! -e "$STUB_DIR/called.launchctl" ]
  [ ! -e "$STUB_DIR/called.systemctl" ]
  [ ! -e "$STUB_DIR/called.crontab" ]
  [ ! -e "$STUB_DIR/called.loginctl" ]
}

@test "grid --help lists drift and schedule" {
  run python3 -B "$GRID_BIN" --help
  [ "$status" -eq 0 ]
  contains "$output" "drift"
  contains "$output" "schedule"
}
