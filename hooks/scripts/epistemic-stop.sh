#!/usr/bin/env bash
# hooks/scripts/epistemic-stop.sh — Stop hook, launched by hooks/run.sh.
#
# Advisory hook: when the last assistant message claims completion without saying RAN,
# READ or UNTESTED, it will ask once per turn for one of them. It never guards anything,
# so it FAILS OPEN: a missing jq, a bad payload or any other surprise exits 0 and the
# session stops as normal.
#
# This is the skeleton. It has the loop guard and the fail-open plumbing only; claim
# detection is added by the next issue. Until then the hook is registered but never blocks.
#
# Observed Stop payload keys (real claude 2.1.x probe, 2026-10-21): session_id,
# transcript_path, cwd, prompt_id, permission_mode, effort, hook_event_name,
# stop_hook_active, last_assistant_message (a string), background_tasks, session_crons.
# stop_hook_active is false on the first Stop of a turn and true on the second (after an
# exit 2 continued the turn).

LC_ALL=C; export LC_ALL
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"

# Advisory, so a missing jq must never get in the way: "open" exits 0 with a stderr note.
grid_require_jq open

payload="$(cat)"

# Parse once, up front. jq stderr goes to /dev/null: a hook's stderr is shown to the model
# on exit 2 and to the operator otherwise, and a parse complaint is noise either way. A
# parse error or a payload that is not a JSON object (array, string, empty stdin) means we
# cannot trust any field, so leave quietly.
if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>/dev/null; then
  exit 0
fi

# Loop guard, first check after parsing. A second Stop in the same turn (stop_hook_active
# true, i.e. our own exit 2 already continued the turn) must never block again, so a
# session cannot be trapped in a loop.
active="$(printf '%s' "$payload" | jq -r '.stop_hook_active' 2>/dev/null)"
if [ "$active" = "true" ]; then
  exit 0
fi

# detection is added in the next issue
exit 0
