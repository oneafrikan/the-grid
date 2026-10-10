#!/usr/bin/env bash
# render-schedule.sh — the ONE schedule renderer for the-grid.
#
# Pure printers for a systemd user service + timer, a launchd plist, a crontab
# line and the (printed, never executed) activation commands. Used by the
# issue-loop (scripts/instantiate.sh), cli-cron/install.sh and every other
# scheduled the-grid job. No function writes a file, runs a process or touches
# the scheduler: callers write the text and PRINT the activation commands for a human.
#
# Calling:
#   source scripts/lib/render-schedule.sh; render_systemd_timer "desc" x.service daily:02:00
#   bash scripts/lib/render-schedule.sh render_systemd_timer "desc" x.service daily:02:00
# (executed rather than sourced it dispatches $1 when that is one of the functions
# below, else exits 2). Every function prints to stdout and returns 0, or prints
# NOTHING to stdout, one line to stderr and returns 2.
#
# Input rules (violations -> return 2):
#   - path-like args (WORKDIR, HOME_DIR, LOG_DIR, LOG_FILE, LABEL, SERVICE_UNIT and every
#     CMD/ARG word) must match ^[A-Za-z0-9_./@+-]+$. No escaping is attempted, so the
#     systemd, plist and cron text never needs quoting.
#   - DESC must match ^[A-Za-z0-9_./@+ -]+$ (spaces allowed, nothing else).
#   - SCHEDULE is daily:HH:MM or weekly:DOW:HH:MM (DOW one of Mon Tue Wed Thu Fri Sat Sun,
#     HH 00-23, MM 00-59, two digits each).
#   - RANDOM_DELAY (optional) matches ^[0-9]+(s|min|h)?$.
#
# Bash 3.2 compatible. No side effects. printf only, no heredocs.

# --------------------------------------------------------------------------
# validation helpers (internal)
# --------------------------------------------------------------------------

# _rs_fail <message> — one stderr line; callers then `return 2`.
_rs_fail() { echo "render-schedule: $*" >&2; }

# _rs_safe <what> <value> — a path/command word: nothing outside [A-Za-z0-9_./@+-].
_rs_safe() {
  case "$2" in
    ""|*[!A-Za-z0-9_./@+-]*)
      _rs_fail "unsafe or empty $1: '$2' (allowed characters: A-Z a-z 0-9 _ . / @ + -)"
      return 1 ;;
  esac
  return 0
}

# _rs_desc <value> — a description: the safe set plus spaces.
_rs_desc() {
  case "$1" in
    ""|*[!A-Za-z0-9_./@+\ -]*)
      _rs_fail "unsafe or empty DESC: '$1' (allowed characters: A-Z a-z 0-9 _ . / @ + - and space)"
      return 1 ;;
  esac
  return 0
}

# _rs_parse_schedule <SCHEDULE> — sets _RS_KIND (daily|weekly), _RS_DOW, _RS_HH, _RS_MM.
_rs_parse_schedule() {
  local s="$1" rest dow hh mm
  _RS_KIND=""; _RS_DOW=""; _RS_HH=""; _RS_MM=""
  case "$s" in
    daily:*)
      rest="${s#daily:}"
      hh="${rest%%:*}"; mm="${rest#*:}"
      [ "$hh:$mm" = "$rest" ] || { _rs_fail "malformed SCHEDULE '$s' (want daily:HH:MM)"; return 1; }
      _RS_KIND=daily ;;
    weekly:*)
      rest="${s#weekly:}"
      dow="${rest%%:*}"; rest="${rest#*:}"
      hh="${rest%%:*}"; mm="${rest#*:}"
      [ "$hh:$mm" = "$rest" ] || { _rs_fail "malformed SCHEDULE '$s' (want weekly:DOW:HH:MM)"; return 1; }
      case "$dow" in
        Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;;
        *) _rs_fail "malformed SCHEDULE '$s' (DOW must be Mon..Sun)"; return 1 ;;
      esac
      _RS_KIND=weekly; _RS_DOW="$dow" ;;
    *) _rs_fail "malformed SCHEDULE '$s' (want daily:HH:MM or weekly:DOW:HH:MM)"; return 1 ;;
  esac
  case "$hh" in
    [01][0-9]|2[0-3]) ;;
    *) _rs_fail "malformed SCHEDULE '$s' (HH must be 00-23)"; return 1 ;;
  esac
  case "$mm" in
    [0-5][0-9]) ;;
    *) _rs_fail "malformed SCHEDULE '$s' (MM must be 00-59)"; return 1 ;;
  esac
  _RS_HH="$hh"; _RS_MM="$mm"
  return 0
}

# --------------------------------------------------------------------------
# renderers
# --------------------------------------------------------------------------

# render_unit_slug TEXT
#   TEXT with every character outside [A-Za-z0-9_.-] replaced by '-'.
render_unit_slug() {
  printf '%s\n' "$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_.-' '-')"
}

# render_systemd_service DESC WORKDIR TIMEOUT_SECS CMD [ARG...]
#   A Type=oneshot user service. TIMEOUT_SECS is an integer; 0 omits TimeoutStartSec.
#   PATH includes %h/.local/bin (a user service does not inherit a login PATH).
#   There is deliberately no network-online.target line: a user manager has no such unit.
render_systemd_service() {
  local desc="${1:-}" workdir="${2:-}" tmo="${3:-}" w
  if [ $# -lt 4 ]; then _rs_fail "render_systemd_service DESC WORKDIR TIMEOUT_SECS CMD [ARG...]"; return 2; fi
  _rs_desc "$desc" || return 2
  _rs_safe WORKDIR "$workdir" || return 2
  case "$tmo" in
    ""|*[!0-9]*) _rs_fail "TIMEOUT_SECS must be a non-negative integer, got '$tmo'"; return 2 ;;
  esac
  shift 3
  for w in "$@"; do _rs_safe "command word" "$w" || return 2; done
  printf '%s\n' "[Unit]" "Description=$desc" "" "[Service]" "Type=oneshot" \
    "WorkingDirectory=$workdir" \
    "Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    "ExecStart=$*"
  if [ "$tmo" -gt 0 ]; then printf '%s\n' "TimeoutStartSec=$tmo"; fi
  return 0
}

# render_systemd_timer DESC SERVICE_UNIT SCHEDULE [RANDOM_DELAY]
#   OnCalendar=*-*-* HH:MM:00 (daily) or "DOW *-*-* HH:MM:00" (weekly); Persistent=true
#   ALWAYS (a run missed while the machine was off fires at next boot/login);
#   RandomizedDelaySec only when RANDOM_DELAY is given.
render_systemd_timer() {
  local desc="${1:-}" unit="${2:-}" sched="${3:-}" delay="${4:-}" cal
  if [ $# -lt 3 ]; then _rs_fail "render_systemd_timer DESC SERVICE_UNIT SCHEDULE [RANDOM_DELAY]"; return 2; fi
  _rs_desc "$desc" || return 2
  _rs_safe SERVICE_UNIT "$unit" || return 2
  _rs_parse_schedule "$sched" || return 2
  if [ -n "$delay" ]; then
    if ! [[ "$delay" =~ ^[0-9]+(s|min|h)?$ ]]; then
      _rs_fail "malformed RANDOM_DELAY '$delay' (want digits, optionally followed by s, min or h)"
      return 2
    fi
  fi
  if [ "$_RS_KIND" = weekly ]; then cal="$_RS_DOW *-*-* $_RS_HH:$_RS_MM:00"; else cal="*-*-* $_RS_HH:$_RS_MM:00"; fi
  printf '%s\n' "[Unit]" "Description=$desc" "" "[Timer]" "OnCalendar=$cal" "Persistent=true"
  if [ -n "$delay" ]; then printf '%s\n' "RandomizedDelaySec=$delay"; fi
  printf '%s\n' "Unit=$unit" "" "[Install]" "WantedBy=timers.target"
  return 0
}

# render_launchd_plist LABEL HOME_DIR WORKDIR LOG_DIR SCHEDULE CMD [ARG...]
#   A LaunchAgent plist: ProgramArguments = CMD ARG... (no login shell), explicit
#   HOME and PATH (HOME_DIR/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin),
#   StartCalendarInterval (Weekday 0=Sun..6=Sat for weekly), stdout+stderr to LOG_DIR/LABEL.log.
render_launchd_plist() {
  local label="${1:-}" home="${2:-}" workdir="${3:-}" logdir="${4:-}" sched="${5:-}" w wd hh mm
  if [ $# -lt 6 ]; then _rs_fail "render_launchd_plist LABEL HOME_DIR WORKDIR LOG_DIR SCHEDULE CMD [ARG...]"; return 2; fi
  _rs_safe LABEL "$label" || return 2
  _rs_safe HOME_DIR "$home" || return 2
  _rs_safe WORKDIR "$workdir" || return 2
  _rs_safe LOG_DIR "$logdir" || return 2
  _rs_parse_schedule "$sched" || return 2
  shift 5
  for w in "$@"; do _rs_safe "command word" "$w" || return 2; done
  # plist integers: no leading zeros
  hh=$((10#$_RS_HH)); mm=$((10#$_RS_MM))
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>' \
    '    <key>Label</key>' "    <string>$label</string>" \
    '    <key>ProgramArguments</key>' '    <array>'
  for w in "$@"; do printf '%s\n' "        <string>$w</string>"; done
  printf '%s\n' '    </array>' \
    '    <key>WorkingDirectory</key>' "    <string>$workdir</string>" \
    '    <key>EnvironmentVariables</key>' '    <dict>' \
    '        <key>HOME</key>' "        <string>$home</string>" \
    '        <key>PATH</key>' "        <string>$home/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>" \
    '    </dict>' \
    '    <key>StartCalendarInterval</key>' '    <dict>'
  if [ "$_RS_KIND" = weekly ]; then
    case "$_RS_DOW" in Sun) wd=0 ;; Mon) wd=1 ;; Tue) wd=2 ;; Wed) wd=3 ;; Thu) wd=4 ;; Fri) wd=5 ;; *) wd=6 ;; esac
    printf '%s\n' '        <key>Weekday</key>' "        <integer>$wd</integer>"
  fi
  printf '%s\n' '        <key>Hour</key>' "        <integer>$hh</integer>" \
    '        <key>Minute</key>' "        <integer>$mm</integer>" \
    '    </dict>' \
    '    <key>RunAtLoad</key>' '    <false/>' \
    '    <key>StandardOutPath</key>' "    <string>$logdir/$label.log</string>" \
    '    <key>StandardErrorPath</key>' "    <string>$logdir/$label.log</string>" \
    '</dict>' '</plist>'
  return 0
}

# render_crontab_line SCHEDULE LOG_FILE WORKDIR CMD [ARG...]
#   One crontab line: MM HH * * DOW-or-* mkdir -p <log dir> && cd WORKDIR && CMD ARG... >> LOG_FILE 2>&1
#   (DOW 0-6 for weekly). The fires-while-logged-out scheduler that needs no linger.
render_crontab_line() {
  local sched="${1:-}" logfile="${2:-}" workdir="${3:-}" w dow="*" logdir
  if [ $# -lt 4 ]; then _rs_fail "render_crontab_line SCHEDULE LOG_FILE WORKDIR CMD [ARG...]"; return 2; fi
  _rs_parse_schedule "$sched" || return 2
  _rs_safe LOG_FILE "$logfile" || return 2
  _rs_safe WORKDIR "$workdir" || return 2
  shift 3
  for w in "$@"; do _rs_safe "command word" "$w" || return 2; done
  if [ "$_RS_KIND" = weekly ]; then
    case "$_RS_DOW" in Sun) dow=0 ;; Mon) dow=1 ;; Tue) dow=2 ;; Wed) dow=3 ;; Thu) dow=4 ;; Fri) dow=5 ;; *) dow=6 ;; esac
  fi
  case "$logfile" in */*) logdir="${logfile%/*}"; [ -n "$logdir" ] || logdir="/" ;; *) logdir="." ;; esac
  printf '%s %s * * %s mkdir -p %s && cd %s && %s >> %s 2>&1\n' \
    "$_RS_MM" "$_RS_HH" "$dow" "$logdir" "$workdir" "$*" "$logfile"
  return 0
}

# render_activation_commands SCHEDULER NAME
#   The command a HUMAN runs to activate what was written. PRINTED, never executed.
#     systemd  NAME = the timer unit        -> systemctl --user daemon-reload && systemctl --user enable --now NAME
#     launchd  NAME = the plist path        -> launchctl bootstrap gui/$(id -u) NAME
#     cron     NAME = the crontab LINE      -> (crontab -l 2>/dev/null; echo 'LINE') | crontab -
render_activation_commands() {
  local scheduler="${1:-}" name="${2:-}"
  if [ $# -ne 2 ]; then _rs_fail "render_activation_commands SCHEDULER NAME"; return 2; fi
  case "$scheduler" in
    systemd)
      _rs_safe "timer unit" "$name" || return 2
      printf '%s\n' "systemctl --user daemon-reload && systemctl --user enable --now $name" ;;
    launchd)
      _rs_safe "plist path" "$name" || return 2
      # the $(id -u) is printed literally for the human's shell to expand
      # shellcheck disable=SC2016
      printf '%s\n' 'launchctl bootstrap gui/$(id -u) '"$name" ;;
    cron)
      case "$name" in
        ""|*"'"*) _rs_fail "crontab line is empty or contains a single quote"; return 2 ;;
      esac
      # shellcheck disable=SC2016
      printf '%s\n' "(crontab -l 2>/dev/null; echo '$name') | crontab -" ;;
    *) _rs_fail "unknown SCHEDULER '$scheduler' (want systemd, launchd or cron)"; return 2 ;;
  esac
  return 0
}

# --------------------------------------------------------------------------
# command-form dispatch: `bash render-schedule.sh <function> <args...>`
# --------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  fn="${1:-}"
  case "$fn" in
    render_unit_slug|render_systemd_service|render_systemd_timer|render_launchd_plist|render_crontab_line|render_activation_commands)
      shift
      "$fn" "$@"
      exit $? ;;
    *)
      echo "render-schedule: unknown function '$fn' (one of render_unit_slug render_systemd_service render_systemd_timer render_launchd_plist render_crontab_line render_activation_commands)" >&2
      exit 2 ;;
  esac
fi
