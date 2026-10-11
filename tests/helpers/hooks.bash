#!/usr/bin/env bash
# Hook test helpers (hook-profiles) — sourced via `load helpers/hooks` AFTER
# `load helpers/setup` (it relies on REPO_ROOT). Payloads and transcript lines are
# always built from the captured fixtures in tests/fixtures/hooks/ with jq --arg,
# never hand-typed or string-concatenated JSON, so quotes and newlines survive and a
# renamed payload key in a future Claude Code shows up as a failing test.

HOOK_FIXTURES="$REPO_ROOT/tests/fixtures/hooks"

# hook_payload <command> [cwd]: the captured PreToolUse(Bash) payload with
# .tool_input.command (and .cwd when given) replaced.
hook_payload() {
  jq --arg c "$1" --arg d "${2:-}" \
    '.tool_input.command = $c | if $d != "" then .cwd = $d else . end' \
    "$HOOK_FIXTURES/pretooluse-bash.json"
}

# sessionend_payload <session_id> <transcript> <cwd>: the captured SessionEnd payload.
sessionend_payload() {
  jq --arg s "$1" --arg t "$2" --arg d "$3" \
    '.session_id = $s | .transcript_path = $t | .cwd = $d' \
    "$HOOK_FIXTURES/sessionend.json"
}

# tx <kind> <text>: one captured transcript line (shapes/<kind>.json) with every
# "__TEXT__" value replaced by <text>, printed compact (one JSON line). A
# transcript is built by appending tx lines to a temp file.
tx() {
  jq -c --arg t "$2" 'walk(if . == "__TEXT__" then $t else . end)' "$HOOK_FIXTURES/shapes/$1.json"
}

# wait_for <seconds> <cmd...>: poll <cmd> every 0.1 s until it succeeds or the time
# is up. The only allowed wait in detached-worker tests.
wait_for() {
  local secs="$1" i tries
  shift
  tries=$((secs * 10))
  for ((i = 0; i < tries; i++)); do
    "$@" && return 0
    sleep 0.1
  done
  "$@"
}

# run_hook <id> <payload-json>: run a hook through the launcher with the payload
# on stdin. Sets $status / $output (bats `run`); stderr is merged into $output.
run_hook() {
  local id="$1" payload="$2"
  run bash -c 'printf "%s" "$1" | bash "$2/hooks/run.sh" "$3" 2>&1' _ "$payload" "$REPO_ROOT" "$id"
}

# expect_block <command> [cwd]: pre-bash-no-bypass must exit 2 for <command>.
# On failure the command is printed so a table row is attributable.
expect_block() {
  run_hook "${HOOK_ID:-pre-bash-no-bypass}" "$(hook_payload "$1" "${2:-}")"
  if [ "$status" -ne 2 ]; then
    echo "expected BLOCK (exit 2), got $status for: $1" >&2
    echo "$output" >&2
    return 1
  fi
}

# expect_pass <command> [cwd]: pre-bash-no-bypass must exit 0 for <command>.
expect_pass() {
  run_hook "${HOOK_ID:-pre-bash-no-bypass}" "$(hook_payload "$1" "${2:-}")"
  if [ "$status" -ne 0 ]; then
    echo "expected PASS (exit 0), got $status for: $1" >&2
    echo "$output" >&2
    return 1
  fi
}

# catalogue_problems <grid-dir>: one line per problem between <grid-dir>/hooks/
# catalogue.json and <grid-dir>/hooks/scripts/: a catalogue id with no script, a
# script with no catalogue entry, an entry whose cost is missing or blank.
# Prints nothing when everything agrees.
catalogue_problems() {
  local grid="$1" cat id f
  cat="$grid/hooks/catalogue.json"
  while IFS= read -r id; do
    [ -f "$grid/hooks/scripts/$id.sh" ] || echo "catalogue id '$id' has no hooks/scripts/$id.sh"
  done < <(jq -r '.hooks[].id' "$cat")
  for f in "$grid"/hooks/scripts/*.sh; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .sh)"
    jq -e --arg id "$id" 'any(.hooks[]; .id == $id)' "$cat" >/dev/null || echo "script '$id.sh' has no catalogue entry"
  done
  while IFS= read -r id; do
    echo "catalogue entry '$id' has an empty cost"
  done < <(jq -r '.hooks[] | select(((.cost // "") | gsub("[[:space:]]"; "")) == "") | .id' "$cat")
}
