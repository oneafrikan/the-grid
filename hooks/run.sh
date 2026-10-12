#!/usr/bin/env bash
# hooks/run.sh <id> — the one launcher every the-grid hook command goes through.
#
#   bash "${GRID_DIR:-$HOME/.the-grid}/hooks/run.sh" pre-bash-no-bypass < payload.json
#
# What it does, in order:
#   1. rejects an id that is not [a-z0-9-]+ (exit 2); this is the path-traversal
#      guard, and it needs neither jq nor catalogue.json so it works (and fails the
#      right way) on a machine without jq
#   2. GRID_HOOKS=off                      -> exit 0, nothing runs
#   3. id listed in GRID_DISABLED_HOOKS    -> exit 0 (comma-separated list)
#      (2 and 3 come before the script-exists test, so a stale settings entry for a
#      removed hook can still be switched off)
#   4. well-formed id with no hooks/scripts/<id>.sh -> exit 2
#   5. exec bash hooks/scripts/<id>.sh     -> stdin (the hook payload) passes through
#
# Exit codes are Claude Code's: only 2 blocks a PreToolUse call; any other non-zero
# is a visible, non-blocking error.
#
# No readlink -f: it does not exist on stock macOS.

id="${1:-}"

# 1. Validate the id before anything else touches the filesystem.
if ! [[ "$id" =~ ^[a-z0-9-]+$ ]]; then
  echo "the-grid hooks/run.sh: invalid hook id '$id' (allowed: lowercase letters, digits, hyphen)" >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd -P)"

# 2. Global kill switch, read from the environment of the shell that launched claude.
#    Checked BEFORE the script-exists test: a stale settings entry naming a removed
#    hook would otherwise exit 2 on every Bash call with no way to turn it off.
[ "${GRID_HOOKS:-}" = "off" ] && exit 0

# 3. Per-hook kill switch: ",a,b," contains ",<id>," (spaces around names tolerated).
disabled=",${GRID_DISABLED_HOOKS:-},"
disabled="${disabled// /}"
case "$disabled" in
  *",$id,"*) exit 0 ;;
esac

# The id is well-formed (step 1), so it cannot traverse; now it must name a script.
if [ ! -f "$HERE/scripts/$id.sh" ]; then
  echo "the-grid hooks/run.sh: unknown hook '$id' (no $HERE/scripts/$id.sh). Remove the stale settings entry, or restart claude with GRID_DISABLED_HOOKS=$id or GRID_HOOKS=off." >&2
  exit 2
fi

# 5. Hand over to the hook script; exec keeps stdin and makes its exit code ours.
exec bash "$HERE/scripts/$id.sh"
