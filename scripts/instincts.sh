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
#   instincts.sh approve ID         promote candidate ID to a global instinct
#   instincts.sh show [PROJECT]     table of merged instincts (default: current repo)
#   instincts.sh retire ID [PROJECT]  retire an instinct (this host's file)
#   instincts.sh forget PROJECT --yes delete local observations + this host's instincts
#   instincts.sh clusters           clusters and strong global instincts, as plain text for Tank
#   instincts.sh analyse [--all] [--project ID] [--dry-run] [--force]
#                                   weekly analysis of local observations (one cheap model
#                                   call per project, capped); --dry-run prints the digest and
#                                   plan and calls nothing; a second run in the same ISO week
#                                   is a no-op unless --force
#   instincts.sh status [--project ID]
#                                   funnel (ret/valid/kept), drop reasons and WARN rules
#   instincts.sh eval-prompt --validate
#                                   free checks of the labelled prompt cases (no model call)
#   instincts.sh eval-prompt --yes [--runs N] [--budget USD] [--case NAME]
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
  instincts.sh approve ID         make a pending candidate a global instinct
  instincts.sh show [PROJECT]     list merged instincts for PROJECT (id; default: this repo)
  instincts.sh retire ID [PROJECT]  retire an instinct on this host
  instincts.sh forget PROJECT --yes delete local observations and this host's instincts
  instincts.sh clusters           clusters and strong global instincts (input for tank)
  instincts.sh analyse [--all] [--project ID] [--dry-run] [--force]
                                  weekly analysis of local observations
  instincts.sh status [--project ID]
                                  analysis funnel and warnings
  instincts.sh eval-prompt --validate
                                  check the labelled prompt cases (free, no model call)
  instincts.sh eval-prompt --yes [--runs N] [--budget USD] [--case NAME]
                                  live prompt eval; costs money, needs GRID_EVALS=1
  instincts.sh help               show this help

Exit codes: 0 ok, 1 failure (project-id: no git remote; analyse: a project errored),
2 unknown subcommand or bad arguments.
EOF
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
  analyse|status)
    # analyse.py adds its own directory to sys.path (python3 -I does not).
    exec python3 -I "$ANALYSE" "$cmd" "$@" ;;
  eval-prompt)
    # evalcases.py adds its own directory to sys.path (python3 -I does not).
    exec python3 -I "$EVALCASES" "$@" ;;
  *)
    echo "instincts: unknown subcommand '$cmd'" >&2
    usage >&2
    exit 2 ;;
esac
