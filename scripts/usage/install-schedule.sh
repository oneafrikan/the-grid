#!/usr/bin/env bash
# install-schedule.sh [--uninstall] — write (never activate) the weekly usage job.
#
# Renders the scheduler text for scripts/usage/weekly.sh through the shared
# scripts/lib/render-schedule.sh (weekly Monday 09:00). There are no templates
# here and no second renderer. Activation is a HUMAN step: this script writes
# unit/plist files (or prints the crontab line) and PRINTS the commands to run.
# It never runs launchctl, systemctl, crontab or loginctl; the only scheduler
# call is the read-only probe `systemctl --user show-environment`, used to choose
# between systemd and cron when installing.
#
# Env (all optional):
#   GRID_SCHEDULER    launchd|systemd|cron (default: Darwin -> launchd; Linux with a
#                     working systemd user manager -> systemd; otherwise cron)
#   LAUNCH_AGENTS_DIR default ~/Library/LaunchAgents
#   SYSTEMD_USER_DIR  default ~/.config/systemd/user
#   GRID_STATE_DIR    default ~/.grid. Must be an absolute path. Only the log location is
#                     baked into the schedule (launchd plist, cron line; systemd logs to
#                     the journal), so only those two validate it. It is NOT carried into
#                     the scheduled job: weekly.sh there runs with its defaults.
#   GRID_PRIVATE_DIR, GRID_HOST  absolute path / name for the job; likewise NOT carried
#                     into the scheduled job (a note is printed when any is set here).
#
# Exit: 0 ok; 1 usage error or an unwritable file/dir; 2 GRID_DIR or the state dir has a
# character the renderer cannot escape, or GRID_STATE_DIR / GRID_PRIVATE_DIR is relative
# (nothing is written).
#
# Idempotent: a second run rewrites nothing and prints "unchanged" per file.
# --uninstall removes the files of EVERY scheduler by their fixed names, so it works
# whatever the install-time scheduler probe says now and from any clone path.

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

LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
SD_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
plist_path="$LA_DIR/$LABEL.plist"
svc_path="$SD_DIR/$UNIT.service"
tmr_path="$SD_DIR/$UNIT.timer"
plist_text=""; svc_text=""; tmr_text=""; cron_line=""

# --- render everything FIRST (install only); any rejection exits 2 before a file is touched ---
# Uninstall skips this block on purpose: it needs no rendering, and a rendering
# refusal (e.g. a clone moved to a path with a space) must never block removal.
fail_unsafe() {
  echo "install-schedule: GRID_DIR ($GRID_DIR), the state dir ($STATE) or an install path contains a character the schedule renderer cannot escape; use only A-Z a-z 0-9 _ . / @ + -. Nothing written." >&2
  exit 2
}

if [ "$uninstall" -eq 0 ]; then
  # A relative path would be resolved by cron/launchd against THEIR working directory
  # (the clone), not the caller's, so the log redirect would land in the wrong place.
  for v in GRID_STATE_DIR GRID_PRIVATE_DIR; do
    val="${!v:-}"
    case "$val" in
      ""|/*) ;;
      *) echo "install-schedule: $v must be an absolute path (got '$val'). Nothing written." >&2; exit 2 ;;
    esac
  done

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

  # The units and the cron line cannot carry these variables (that would need quoting the
  # renderer deliberately does not do), so say so rather than let the setting look effective.
  if [ -n "${GRID_STATE_DIR:-}${GRID_PRIVATE_DIR:-}${GRID_HOST:-}" ]; then
    echo "install-schedule: note: GRID_STATE_DIR, GRID_PRIVATE_DIR and GRID_HOST are not carried into the scheduled job; it runs weekly.sh with their defaults. Only the log path uses the state dir ($STATE)." >&2
  fi
fi

# --- file helpers -------------------------------------------------------------
# write_file <path> <text> — create or replace only when the content differs.
# The text goes to a private temp file (mode 0600, same directory) that is renamed over
# the path, so a symlink at the path is REPLACED, never followed (a link would otherwise
# redirect the write to whatever it points at), and a reader never sees a half-written file.
write_file() {
  local path="$1" text="$2" dir name tmp note=""
  if [ -f "$path" ] && [ ! -L "$path" ] && [ "$(cat "$path")" = "$text" ]; then
    echo "unchanged $path"
    return 0
  fi
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    echo "install-schedule: $path is a directory; not replacing it" >&2
    exit 1
  fi
  dir="$(dirname "$path")"
  name="${path##*/}"
  mkdir -p "$dir" || { echo "install-schedule: cannot create $dir" >&2; exit 1; }
  tmp="$(umask 077; mktemp "$dir/.$name.XXXXXX")" || { echo "install-schedule: cannot write in $dir" >&2; exit 1; }
  printf '%s\n' "$text" > "$tmp" || { rm -f "$tmp"; echo "install-schedule: cannot write $tmp" >&2; exit 1; }
  # mv onto a symlink that points at a directory would move INTO it; drop the link first.
  if [ -L "$path" ]; then rm -f "$path"; note=" (replaced symlink)"; fi
  mv -f "$tmp" "$path" || { rm -f "$tmp"; echo "install-schedule: cannot replace $path" >&2; exit 1; }
  echo "wrote $path$note"
}

# remove_file <path> — remove exactly a file this script installs; echo whether it was there.
# Sets REMOVED_ANY=1 when something was removed.
REMOVED_ANY=0
remove_file() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    rm -f "$1" && echo "removed $1" && REMOVED_ANY=1
  else
    echo "absent $1"
  fi
}

# --- install / uninstall ------------------------------------------------------
if [ "$uninstall" -eq 0 ]; then
  case "$scheduler" in
    launchd)
      # launchd does not create the log directory the plist points at (the job would
      # start and its output would have nowhere to go), so create it now.
      mkdir -p "$STATE" || { echo "install-schedule: cannot create $STATE" >&2; exit 1; }
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
  # Remove by the fixed file names of every scheduler (never by re-detecting one):
  # the install-time probe can answer differently now (no user bus, root, ssh).
  launchd_removed=0; systemd_removed=0
  REMOVED_ANY=0; remove_file "$plist_path"; launchd_removed=$REMOVED_ANY
  REMOVED_ANY=0; remove_file "$tmr_path"; systemd_removed=$REMOVED_ANY
  remove_file "$svc_path"; [ "$REMOVED_ANY" -eq 1 ] && systemd_removed=1
  # Advice for the chosen scheduler, plus any other scheduler whose files were just removed.
  echo "Deactivate (run yourself):"
  if [ "$scheduler" = launchd ] || [ "$launchd_removed" -eq 1 ]; then
    # shellcheck disable=SC2016
    echo '  launchctl bootout gui/$(id -u)/'"$LABEL"
  fi
  if [ "$scheduler" = systemd ] || [ "$systemd_removed" -eq 1 ]; then
    echo "  systemctl --user disable --now $UNIT.timer; systemctl --user daemon-reload"
  fi
  if [ "$scheduler" = cron ]; then
    echo "  Install wrote nothing for cron. Remove the line containing $JOB from your crontab:"
    echo "  crontab -e"
  fi
fi
exit 0
