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

usage() {
  cat <<'EOF'
instincts.sh — learn working habits from your own sessions

Usage:
  instincts.sh project-id [DIR]   print the project id for the repo at DIR (default .)
  instincts.sh scrub              redact secrets from stdin to stdout
  instincts.sh capture            record one hook event from stdin (used by the hooks)
  instincts.sh help               show this help

Exit codes: 0 ok, 1 failure (project-id: no git remote), 2 unknown subcommand.
EOF
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
  help|-h|--help)
    usage ;;
  project-id|scrub)
    # -I: isolated mode, so a stray PYTHONPATH or cwd file cannot shadow stdlib.
    exec python3 -I "$LIB" "$cmd" "$@" ;;
  capture)
    # Hook entry point. A hook must never fail or print, so: stderr to /dev/null and a
    # forced exit 0 (also covers python3 missing or crashing before capture.py's own
    # catch-all). stdin passes through to the python process.
    python3 -I "$SCRIPT_DIR/instincts/capture.py" "$@" 2>/dev/null
    exit 0 ;;
  *)
    echo "instincts: unknown subcommand '$cmd'" >&2
    usage >&2
    exit 2 ;;
esac
