#!/usr/bin/env bash
# hooks/scripts/epistemic-stop.sh — Stop hook, launched by hooks/run.sh.
#
# Advisory hook: when the last assistant message claims completion without saying RAN,
# READ or UNTESTED, it will ask once per turn for one of them. It never guards anything,
# so it FAILS OPEN: a missing jq, a bad payload or any other surprise exits 0 and the
# session stops as normal.
#
# It blocks (exit 2) once per turn on a completion claim that carries no RAN, READ or
# UNTESTED. Everything else exits 0.
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

# The message comes straight from the payload, so no transcript is read here (a transcript
# fallback for a missing field is a separate piece of work). No model is called either: this
# is a plain pattern test, so the hook costs nothing unless it fires. String only: a missing
# field, null, number or object leaves msg empty, and an empty message exits 0 (fail open).
msg="$(printf '%s' "$payload" | jq -r 'if (.last_assistant_message | type) == "string" then .last_assistant_message else empty end' 2>/dev/null)"
if [ -z "$msg" ]; then
  exit 0
fi

# Whole-word boundaries, written out instead of \b because \b is not portable to BSD grep.
# A word character is [:alnum:] or underscore; start/end of line also count as a boundary.
pre='(^|[^[:alnum:]_])'
post='([^[:alnum:]_]|$)'

# Claim test, case-insensitive. The list is crude on purpose: a chatty "done thinking about
# X?" or a quoted snippet containing "complete" will fire. That trade-off is accepted. The
# hook asks at most once per turn (loop guard above) and a firing costs one model turn, so a
# false positive is cheap, while a false negative is only a missed prompt, never a failure.
claims='done|complete|completed|finished|fixed|implemented|all tests pass|all tests passed|all tests passing|test passing|tests passing|tests are passing|test are passing|works now|ready for review|ready to merge'
if ! printf '%s\n' "$msg" | grep -Eiq "${pre}(${claims})${post}"; then
  exit 0
fi

# Warrant test, case-sensitive (no -i) and whole word. The uppercase keywords are a
# deliberate marker, so lowercase "ran" or "read" in ordinary prose is not a warrant, and
# RANDOM or READABLE does not count because the boundary rejects them.
if printf '%s\n' "$msg" | grep -Eq "${pre}(RAN|READ|UNTESTED)${post}"; then
  exit 0
fi

# Claim with no warrant: one stderr line (shown to the model on exit 2), nothing on stdout.
echo "State RAN, READ or UNTESTED for each completion claim (see AGENTS_base)" >&2
exit 2
