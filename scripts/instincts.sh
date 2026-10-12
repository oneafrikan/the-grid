#!/usr/bin/env bash
# instincts.sh — dispatcher for the instincts feature (openspec change `instincts`).
#
# Habit learning from your own sessions: capture, weekly analysis, injection.
# This file only routes subcommands; the logic lives in scripts/instincts/*.py
# (shared rules in scripts/instincts/lib.py). Later groups add subcommands here.
#
# Usage:
#   instincts.sh project-id [DIR]   print the project id of the repo at DIR (default .);
#                                   exit 1 with "no git remote" when there is none
#   instincts.sh scrub              read stdin, print it with secrets redacted
#   instincts.sh capture            hook entry: read one hook JSON payload on stdin,
#                                   append one observation; always exit 0, no stdout
#   instincts.sh inject             SessionStart hook: print habit hints (silent if none/opted out)
#   instincts.sh promote            list global-promotion candidates (writes no instinct)
#   instincts.sh approve ID         approve a pending instinct of this repo, else promote a global candidate
#   instincts.sh show [PROJECT]     table of merged instincts (default: current repo)
#   instincts.sh retire ID [PROJECT] [--global]  retire an instinct (this host's file; --global for a global one)
#   instincts.sh forget PROJECT --yes delete local observations + this host's instincts
#   instincts.sh clusters           clusters and strong global instincts, as plain text for Tank
#   instincts.sh analyse [--all] [--project ID] [--dry-run] [--force] [--no-sync]
#                                   weekly analysis of local observations (one cheap model
#                                   call per project, capped); --dry-run prints the digest and
#                                   plan and calls nothing; a second run in the same ISO week
#                                   is a no-op unless --force; a real run ends with `sync`
#                                   unless --no-sync
#   instincts.sh sync               pull/commit/push this host's instincts in the private repo
#                                   (best effort: failures warn, exit stays 0)
#   instincts.sh schedule           PRINT the weekly job (launchd or systemd text, activation
#                                   commands, crontab line); installs nothing
#   instincts.sh status [--project ID]
#                                   funnel (ret/valid/kept), drop reasons and WARN rules
#   instincts.sh eval-prompt --validate
#                                   free checks of the labelled prompt cases (no model call)
#   instincts.sh eval-prompt --yes [--runs N] [--budget USD] [--max-total USD] [--case NAME]
#                                   PAID live eval of the prompt; also needs GRID_EVALS=1
#   instincts.sh help               this text
#
# Exit codes: 0 ok, 1 command-specific failure, 2 usage error (unknown subcommand).
#
# All data this feature stores is PRIVATE and lives outside the repo
# (${GRID_STATE_DIR:-~/.grid} and the private repo); nothing here writes inside it.

set -u

# Resolve our own directory (follows no symlinks; the repo layout is fixed).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/instincts/lib.py"
ANALYSE="$SCRIPT_DIR/instincts/analyse.py"
EVALCASES="$SCRIPT_DIR/instincts/evalcases.py"

usage() {
  cat <<'EOF'
instincts.sh — learn working habits from your own sessions

Usage:
  instincts.sh project-id [DIR]   print the project id for the repo at DIR (default .)
  instincts.sh scrub              redact secrets from stdin to stdout
  instincts.sh capture            record one hook event from stdin (used by the hooks)
  instincts.sh inject             SessionStart hook: print habit hints for this project
  instincts.sh promote            list instincts ready to become global (pending approval)
  instincts.sh approve ID         approve a pending instinct of this repo, else promote a global candidate
  instincts.sh show [PROJECT]     list merged instincts for PROJECT (id; default: this repo)
  instincts.sh retire ID [PROJECT] [--global]  retire an instinct on this host
  instincts.sh forget PROJECT --yes delete local observations and this host's instincts
  instincts.sh clusters           clusters and strong global instincts (input for tank)
  instincts.sh analyse [--all] [--project ID] [--dry-run] [--force] [--no-sync]
                                  weekly analysis of local observations
  instincts.sh sync               commit and push this host's instincts to the private repo
  instincts.sh schedule           print the weekly schedule (nothing is installed)
  instincts.sh status [--project ID]
                                  analysis funnel and warnings
  instincts.sh eval-prompt --validate
                                  check the labelled prompt cases (free, no model call)
  instincts.sh eval-prompt --yes [--runs N] [--budget USD] [--max-total USD] [--case NAME]
                                  live prompt eval; costs money, needs GRID_EVALS=1
  instincts.sh help               show this help

Exit codes: 0 ok, 1 failure (project-id: no git remote; analyse: a project errored),
2 unknown subcommand or bad arguments.
EOF
}

# cmd_schedule — render the weekly analysis job and PRINT it. Writes no file and never
# runs crontab, launchctl, systemctl or loginctl: activation is a human step, so the
# commands are printed for the person to run. All text comes from the one shared
# renderer (scripts/lib/render-schedule.sh); there is no second renderer here.
# Exit 2 on any argument (there is deliberately no --install) or when the renderer
# rejects the repo/state path (a character it cannot escape); nothing is printed then.
cmd_schedule() {
  if [ $# -gt 0 ]; then
    echo "instincts: schedule takes no arguments (it only prints; install by hand)" >&2
    return 2
  fi
  local root state logdir logfile sched label unit job
  # Repo root from this script's own location, never a hardcoded clone path.
  root="$(cd "$SCRIPT_DIR/.." && pwd)"
  # shellcheck source=scripts/lib/render-schedule.sh
  . "$root/scripts/lib/render-schedule.sh" || return 2
  state="${GRID_STATE_DIR:-$HOME/.grid}"
  logdir="$state/logs"
  logfile="$logdir/instincts.log"
  sched="weekly:Mon:06:00"          # Monday 06:00 local time
  label="io.the-grid.instincts"     # launchd label
  unit="grid-instincts"             # systemd unit base name
  job="$root/scripts/instincts.sh"  # CMD `bash`, then ARGs as separate words (no quotes)

  # Render EVERYTHING first; any rejection exits 2 before a byte is printed.
  local plist_text="" svc_text="" tmr_text="" cron_line="" activate="" cron_activate="" plist_path=""
  cron_line="$(render_crontab_line "$sched" "$logfile" "$root" bash "$job" analyse --all)" || return 2
  cron_activate="$(render_activation_commands cron "$cron_line")" || return 2
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    plist_path="$HOME/Library/LaunchAgents/$label.plist"
    plist_text="$(render_launchd_plist "$label" "$HOME" "$root" "$logdir" "$sched" bash "$job" analyse --all)" || return 2
    activate="$(render_activation_commands launchd "$plist_path")" || return 2
  else
    # 1800 s cap: a hung analysis must not wedge the unit forever.
    svc_text="$(render_systemd_service "the-grid weekly instincts analysis" "$root" 1800 bash "$job" analyse --all)" || return 2
    tmr_text="$(render_systemd_timer "the-grid weekly instincts analysis" "$unit.service" "$sched")" || return 2
    activate="$(render_activation_commands systemd "$unit.timer")" || return 2
  fi

  # The units and the cron line cannot carry these variables (that would need quoting the
  # renderer deliberately does not do), so say so rather than let the setting look effective.
  if [ -n "${GRID_STATE_DIR:-}${GRID_PRIVATE_DIR:-}${GRID_HOST:-}" ]; then
    echo "instincts: note: GRID_STATE_DIR, GRID_PRIVATE_DIR and GRID_HOST are not carried into the scheduled job; it runs with their defaults. Only the log path uses the state dir ($state)." >&2
  fi

  echo "# Weekly instincts analysis (Mon 06:00 local). Nothing below has been installed."
  # The job is not free and not offline: say so before anyone pastes it.
  # shellcheck disable=SC2016
  echo '# Each run makes up to 5 paid model calls (cap 0.05 USD each) and needs `claude` on the job PATH (~/.local/bin is on it).'
  echo
  if [ -n "$plist_text" ]; then
    echo "# launchd: save as $plist_path"
    printf '%s\n' "$plist_text"
  else
    echo "# systemd user service: save as ~/.config/systemd/user/$unit.service"
    printf '%s\n' "$svc_text"
    echo
    echo "# systemd user timer: save as ~/.config/systemd/user/$unit.timer"
    printf '%s\n' "$tmr_text"
  fi
  echo
  echo "# Activate by hand:"
  printf '%s\n' "$activate"
  echo
  echo "# Alternative: this crontab line (run the command below to add it, or use crontab -e)"
  printf '%s\n' "$cron_line"
  printf '%s\n' "$cron_activate"
  return 0
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
  help|-h|--help)
    usage ;;
  project-id|scrub|promote|approve|show|retire|forget|clusters)
    # -I: isolated mode, so a stray PYTHONPATH or cwd file cannot shadow stdlib.
    exec python3 -I "$LIB" "$cmd" "$@" ;;
  capture)
    # Hook entry point. A hook must never fail or print, so: stderr to /dev/null and a
    # forced exit 0 (also covers python3 missing or crashing before capture.py's own
    # catch-all). stdin passes through to the python process.
    python3 -I "$SCRIPT_DIR/instincts/capture.py" "$@" 2>/dev/null
    exit 0 ;;
  inject)
    # SessionStart hook body; inject.py puts its own directory on sys.path (-I drops it).
    exec python3 -I "$SCRIPT_DIR/instincts/inject.py" "$@" ;;
  analyse|status|sync)
    # analyse.py adds its own directory to sys.path (python3 -I does not).
    exec python3 -I "$ANALYSE" "$cmd" "$@" ;;
  eval-prompt)
    # evalcases.py adds its own directory to sys.path (python3 -I does not).
    exec python3 -I "$EVALCASES" "$@" ;;
  schedule)
    cmd_schedule "$@"
    exit $? ;;
  *)
    echo "instincts: unknown subcommand '$cmd'" >&2
    usage >&2
    exit 2 ;;
esac
