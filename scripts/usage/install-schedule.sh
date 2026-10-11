#!/usr/bin/env bash
# install-schedule.sh [--uninstall] — write (never activate) the weekly usage job.
#
# Renders the scheduler text for scripts/usage/weekly.sh through the shared
# scripts/lib/render-schedule.sh (weekly Monday 09:00). There are no templates
# here and no second renderer. Activation is a HUMAN step: this script writes
# unit/plist files (or prints the crontab line) and PRINTS the commands to run.
# It never runs launchctl, systemctl, crontab or loginctl; the only scheduler
# call is the read-only probe `systemctl --user show-environment`, used to choose
# between systemd and cron.
#
# Env (all optional):
#   GRID_SCHEDULER    launchd|systemd|cron (default: Darwin -> launchd; Linux with a
#                     working systemd user manager -> systemd; otherwise cron)
#   LAUNCH_AGENTS_DIR default ~/Library/LaunchAgents
#   SYSTEMD_USER_DIR  default ~/.config/systemd/user
#   GRID_STATE_DIR    default ~/.grid (log location baked into the schedule)
#
# Exit: 0 ok; 1 usage error; 2 GRID_DIR or the state dir has a character the
# renderer cannot escape (nothing is written).
#
# Idempotent: a second run rewrites nothing and prints "unchanged" per file.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRID_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE="${GRID_STATE_DIR:-$HOME/.grid}"
# shellcheck source=../lib/render-schedule.sh
. "$GRID_DIR/scripts/lib/render-schedule.sh"

LABEL="io.the-grid.usage"      # launchd label
UNIT="grid-usage"              # systemd unit base name
SCHEDULE="weekly:Mon:09:00"    # Monday 09:00 local time
JOB="$GRID_DIR/scripts/usage/weekly.sh"

uninstall=0
case "${1:-}" in
  "") ;;
  --uninstall) uninstall=1 ;;
  *) echo "usage: install-schedule.sh [--uninstall]" >&2; exit 1 ;;
esac

# --- choose the scheduler ----------------------------------------------------
scheduler="${GRID_SCHEDULER:-}"
if [ -z "$scheduler" ]; then
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    scheduler=launchd
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    scheduler=systemd
  else
    scheduler=cron
  fi
fi
case "$scheduler" in
  launchd|systemd|cron) ;;
  *) echo "install-schedule: unknown GRID_SCHEDULER '$scheduler' (want launchd, systemd or cron)" >&2; exit 1 ;;
esac

# --- render everything FIRST; any rejection exits 2 before a file is touched ---
LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
SD_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
plist_path="$LA_DIR/$LABEL.plist"
svc_path="$SD_DIR/$UNIT.service"
tmr_path="$SD_DIR/$UNIT.timer"
plist_text=""; svc_text=""; tmr_text=""; cron_line=""

fail_unsafe() {
  echo "install-schedule: GRID_DIR ($GRID_DIR), the state dir ($STATE) or an install path contains a character the schedule renderer cannot escape; use only A-Z a-z 0-9 _ . / @ + -. Nothing written." >&2
  exit 2
}

case "$scheduler" in
  launchd)
    # The renderer logs to <LOG_DIR>/<LABEL>.log, so launchd's own stdout/stderr
    # lands in $STATE/io.the-grid.usage.log (weekly.sh's own lines go to usage.log).
    plist_text="$(render_launchd_plist "$LABEL" "$HOME" "$GRID_DIR" "$STATE" "$SCHEDULE" /bin/bash "$JOB")" || fail_unsafe
    # The plist path is printed inside a command, so it must be renderer-safe too.
    render_activation_commands launchd "$plist_path" >/dev/null || fail_unsafe ;;
  systemd)
    # 1800 s cap: a hung extract must not wedge the unit forever.
    svc_text="$(render_systemd_service "the-grid weekly usage extract" "$GRID_DIR" 1800 /bin/bash "$JOB")" || fail_unsafe
    # RandomizedDelaySec=1h spreads machines that share a schedule; Persistent=true is always set.
    tmr_text="$(render_systemd_timer "the-grid weekly usage extract" "$UNIT.service" "$SCHEDULE" 1h)" || fail_unsafe ;;
  cron)
    cron_line="$(render_crontab_line "$SCHEDULE" "$STATE/usage.log" "$GRID_DIR" /bin/bash "$JOB")" || fail_unsafe ;;
esac

# --- file helpers -------------------------------------------------------------
# write_file <path> <text> — create or replace only when the content differs.
write_file() {
  local path="$1" text="$2"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$text" ]; then
    echo "unchanged $path"
    return 0
  fi
  mkdir -p "$(dirname "$path")" || exit 1
  printf '%s\n' "$text" > "$path" || exit 1
  echo "wrote $path"
}

# remove_file <path> — remove exactly a file this script installs.
remove_file() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    rm -f "$1" && echo "removed $1"
  else
    echo "absent $1"
  fi
}

# --- install / uninstall ------------------------------------------------------
if [ "$uninstall" -eq 0 ]; then
  case "$scheduler" in
    launchd)
      write_file "$plist_path" "$plist_text"
      echo "Activate (run yourself):"
      # $(id -u) is printed literally for the human's shell to expand.
      # shellcheck disable=SC2016
      echo '  launchctl bootout gui/$(id -u)/'"$LABEL"' 2>/dev/null; '"$(render_activation_commands launchd "$plist_path")" ;;
    systemd)
      write_file "$svc_path" "$svc_text"
      write_file "$tmr_path" "$tmr_text"
      echo "Activate (run yourself):"
      echo "  $(render_activation_commands systemd "$UNIT.timer")"
      if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        echo "Headless machine: keep the user manager alive while logged out:"
        # shellcheck disable=SC2016
        echo '  loginctl enable-linger "$USER"'
      fi ;;
    cron)
      echo "Nothing written. Add this line to your crontab:"
      echo "$cron_line"
      echo "Activate (run yourself):"
      echo "  $(render_activation_commands cron "$cron_line")" ;;
  esac
else
  case "$scheduler" in
    launchd)
      remove_file "$plist_path"
      echo "Deactivate (run yourself):"
      # shellcheck disable=SC2016
      echo '  launchctl bootout gui/$(id -u)/'"$LABEL" ;;
    systemd)
      remove_file "$tmr_path"
      remove_file "$svc_path"
      echo "Deactivate (run yourself):"
      echo "  systemctl --user disable --now $UNIT.timer; systemctl --user daemon-reload" ;;
    cron)
      echo "Install wrote nothing for cron. Remove the line containing $JOB from your crontab:"
      echo "  crontab -e" ;;
  esac
fi
exit 0
