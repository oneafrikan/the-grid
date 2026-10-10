#!/usr/bin/env bats
# scripts/lib/render-schedule.sh — the shared, pure, print-only schedule renderer.
# Covers specs/issue-loop-scheduling/spec.md (renderer scenarios).

bats_require_minimum_version 1.5.0
load helpers/stubs

LIB="$BATS_TEST_DIRNAME/../scripts/lib/render-schedule.sh"

setup() {
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$HOME"
}

teardown() {
  rm -rf "$T"
}

# rs <function> <args...> — the command form, stdout and stderr kept apart.
rs() { run --separate-stderr bash "$LIB" "$@"; }

# in_proc <function> <args...> — the sourced form (a fresh bash 3.2 process).
in_proc() {
  run --separate-stderr bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"
}

@test "render_unit_slug replaces everything outside [A-Za-z0-9_.-]" {
  rs render_unit_slug 'o/r name!'
  [ "$status" -eq 0 ]
  [ "$output" = "o-r-name-" ]
  rs render_unit_slug 'owner/the-grid.v2_x'
  [ "$output" = "owner-the-grid.v2_x" ]
}

@test "service: Type=oneshot, WorkingDirectory, PATH with %h/.local/bin, ExecStart, TimeoutStartSec" {
  rs render_systemd_service "issue-loop runner for owner/name" /srv/repo 7800 /bin/bash /srv/repo/loop/run-issues.sh
  [ "$status" -eq 0 ]
  contains "$output" "Description=issue-loop runner for owner/name"
  contains "$output" "Type=oneshot"
  contains "$output" "WorkingDirectory=/srv/repo"
  contains "$output" "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin"
  contains "$output" "ExecStart=/bin/bash /srv/repo/loop/run-issues.sh"
  contains "$output" "TimeoutStartSec=7800"
  lacks "$output" "EnvironmentFile"
  lacks "$output" "network-online.target"
  lacks "$output" "Wants="
  lacks "$output" "After="
}

@test "service: TIMEOUT_SECS 0 omits TimeoutStartSec" {
  rs render_systemd_service "d" /srv/repo 0 /bin/true
  [ "$status" -eq 0 ]
  lacks "$output" "TimeoutStartSec"
}

@test "timer: daily OnCalendar, Persistent=true, Unit, no RandomizedDelaySec by default" {
  rs render_systemd_timer "Nightly issue-loop for owner/name" issue-loop-owner-name.service daily:03:00
  [ "$status" -eq 0 ]
  contains "$output" "OnCalendar=*-*-* 03:00:00"
  contains "$output" "Persistent=true"
  contains "$output" "Unit=issue-loop-owner-name.service"
  contains "$output" "WantedBy=timers.target"
  lacks "$output" "RandomizedDelaySec"
  lacks "$output" "network-online.target"
}

@test "timer: weekly with a randomized delay; the same call without it has none" {
  rs render_systemd_timer "desc" x.service weekly:Sun:04:30 1h
  [ "$status" -eq 0 ]
  contains "$output" "OnCalendar=Sun *-*-* 04:30:00"
  contains "$output" "Persistent=true"
  contains "$output" "RandomizedDelaySec=1h"
  rs render_systemd_timer "desc" x.service weekly:Sun:04:30
  lacks "$output" "RandomizedDelaySec"
  contains "$output" "Persistent=true"
}

@test "timer: RANDOM_DELAY forms 30, 90s, 10min, 2h accepted; others refused" {
  for d in 30 90s 10min 2h; do
    rs render_systemd_timer "desc" x.service daily:01:00 "$d"
    [ "$status" -eq 0 ]
    contains "$output" "RandomizedDelaySec=$d"
  done
  for d in 1d "1 h" "-5" "h" "1h;rm"; do
    rs render_systemd_timer "desc" x.service daily:01:00 "$d"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "launchd plist: label, program args without a login shell, HOME/PATH, calendar, one log file" {
  rs render_launchd_plist io.the-grid.issue-loop.owner-name /Users/x /srv/repo /Users/x/.grid/logs daily:02:00 /bin/bash /srv/repo/loop/run-issues.sh
  [ "$status" -eq 0 ]
  contains "$output" "<string>io.the-grid.issue-loop.owner-name</string>"
  contains "$output" "<string>/bin/bash</string>"
  contains "$output" "<string>/srv/repo/loop/run-issues.sh</string>"
  lacks "$output" "<string>-l</string>"
  lacks "$output" "-lc"
  contains "$output" "<string>/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"
  contains "$output" "<key>HOME</key>"
  contains "$output" "<string>/srv/repo</string>"
  contains "$output" "<integer>2</integer>"
  contains "$output" "<integer>0</integer>"
  lacks "$output" "Weekday"
  contains "$output" "<key>StandardOutPath</key>"
  contains "$output" "<string>/Users/x/.grid/logs/io.the-grid.issue-loop.owner-name.log</string>"
  # well-formed XML
  printf '%s\n' "$output" > "$T/p.plist"
  if command -v plutil >/dev/null 2>&1; then plutil -lint "$T/p.plist"; fi
}

@test "launchd plist: weekly carries Weekday 0=Sun..6=Sat" {
  rs render_launchd_plist l /h /w /h/logs weekly:Sun:04:30 /bin/true
  contains "$output" "<key>Weekday</key>"
  rs render_launchd_plist l /h /w /h/logs weekly:Sat:04:30 /bin/true
  printf '%s\n' "$output" | grep -A1 'Weekday' | grep -q '<integer>6</integer>'
  rs render_launchd_plist l /h /w /h/logs weekly:Mon:04:30 /bin/true
  printf '%s\n' "$output" | grep -A1 'Weekday' | grep -q '<integer>1</integer>'
}

@test "crontab line: daily and weekly" {
  rs render_crontab_line daily:02:00 /home/u/.grid/logs/issue-loop-owner-name.log /srv/repo /bin/bash /srv/repo/loop/run-issues.sh
  [ "$status" -eq 0 ]
  [ "$output" = "00 02 * * * mkdir -p /home/u/.grid/logs && cd /srv/repo && /bin/bash /srv/repo/loop/run-issues.sh >> /home/u/.grid/logs/issue-loop-owner-name.log 2>&1" ]
  rs render_crontab_line weekly:Sun:04:30 /l/x.log /srv/repo /bin/true
  [ "$output" = "30 04 * * 0 mkdir -p /l && cd /srv/repo && /bin/true >> /l/x.log 2>&1" ]
}

@test "activation commands: printed text for the three schedulers" {
  rs render_activation_commands systemd issue-loop-owner-name.timer
  [ "$output" = "systemctl --user daemon-reload && systemctl --user enable --now issue-loop-owner-name.timer" ]
  rs render_activation_commands launchd /Users/x/Library/LaunchAgents/io.the-grid.issue-loop.owner-name.plist
  [ "$output" = 'launchctl bootstrap gui/$(id -u) /Users/x/Library/LaunchAgents/io.the-grid.issue-loop.owner-name.plist' ]
  rs render_activation_commands cron '00 02 * * * cd /srv && /bin/true >> /l 2>&1'
  [ "$output" = "(crontab -l 2>/dev/null; echo '00 02 * * * cd /srv && /bin/true >> /l 2>&1') | crontab -" ]
  rs render_activation_commands upstart foo
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "unsafe path characters are refused: exit 2, empty stdout, the value named on stderr" {
  local bad
  for bad in "/srv/my repo" '/srv/50%' '/srv/$HOME' '/srv/a&b' "/srv/it's" '/srv/"q"' '/srv/a;b' $'/srv/a\nb'; do
    rs render_systemd_service "d" "$bad" 100 /bin/true
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ -n "$stderr" ]
    rs render_systemd_service "d" /srv 100 /bin/bash "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    rs render_launchd_plist l /h "$bad" /h/logs daily:01:00 /bin/true
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    rs render_launchd_plist l "$bad" /w /h/logs daily:01:00 /bin/true
    [ "$status" -eq 2 ]
    rs render_launchd_plist l /h /w "$bad" daily:01:00 /bin/true
    [ "$status" -eq 2 ]
    rs render_crontab_line daily:01:00 "$bad/x.log" /w /bin/true
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    rs render_crontab_line daily:01:00 /l/x.log "$bad" /bin/true
    [ "$status" -eq 2 ]
  done
  rs render_systemd_service "d" "/srv/my repo" 100 /bin/true
  contains "$stderr" "/srv/my repo"
}

@test "an unsafe DESC is refused, a DESC with spaces and a slash is fine" {
  rs render_systemd_timer 'bad $(desc)' x.service daily:01:00
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  rs render_systemd_timer 'issue-loop runner for owner/name' x.service daily:01:00
  [ "$status" -eq 0 ]
}

@test "malformed schedules are refused" {
  local s
  for s in daily:25:00 daily:2:00 daily:02:60 daily:02 daily:02:00:00 weekly:Funday:01:00 weekly:Mon:24:00 weekly:Mon:01 hourly:01:00 "" daily:aa:bb; do
    rs render_systemd_timer "desc" x.service "$s"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    rs render_crontab_line "$s" /l/x.log /w /bin/true
    [ "$status" -eq 2 ]
    rs render_launchd_plist l /h /w /h/logs "$s" /bin/true
    [ "$status" -eq 2 ]
  done
}

@test "missing arguments are refused, not rendered" {
  rs render_systemd_service "d" /srv 100
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  rs render_systemd_timer "d"
  [ "$status" -eq 2 ]
}

@test "an unknown function in command form exits 2" {
  rs render_nothing a b
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  rs
  [ "$status" -eq 2 ]
}

@test "deterministic and pure: sourced and command form agree, two calls agree, nothing is created" {
  before="$(find "$T" | sort)"
  rs render_systemd_timer "desc" x.service weekly:Fri:23:15 30min
  a="$output"
  rs render_systemd_timer "desc" x.service weekly:Fri:23:15 30min
  [ "$output" = "$a" ]
  in_proc render_systemd_timer "desc" x.service weekly:Fri:23:15 30min
  [ "$output" = "$a" ]
  rs render_launchd_plist l /h /w /h/logs weekly:Fri:23:15 /bin/true
  p="$output"
  in_proc render_launchd_plist l /h /w /h/logs weekly:Fri:23:15 /bin/true
  [ "$output" = "$p" ]
  after="$(find "$T" | sort)"
  [ "$before" = "$after" ]
}

@test "sourcing defines the functions and does not exit or print" {
  run bash -c 'set -eu; source "$1"; type render_systemd_timer >/dev/null; echo sourced-ok' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced-ok" ]
}

@test "units pass systemd-analyze verify (skipped where it is not available)" {
  command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"
  rs render_systemd_service "d" "$T" 100 /bin/true
  printf '%s\n' "$output" > "$T/t.service"
  rs render_systemd_timer "d" t.service daily:01:00
  printf '%s\n' "$output" > "$T/t.timer"
  run systemd-analyze --user verify "$T/t.service" "$T/t.timer"
  [ "$status" -eq 0 ]
}

@test "no machine-specific values in the renderer" {
  refute grep -nE '/Users/|/home/' "$LIB"
}
