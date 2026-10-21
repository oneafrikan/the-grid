#!/usr/bin/env bats
# The committed demo tape (docs/demo/demo.tape, a vhs script; the GIF is rendered by hand).
# Pins the invariants the tape must keep so a re-render stays faithful to the README
# (openspec change front-door, tasks 9.1 and 9.2).
#
# Read-only: parses text files from the repo root. It never runs vhs and never touches
# the real ~/.claude.

# Pin the locale so grep/awk behave the same on every machine.
export LC_ALL=C

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Sandbox HOME and git config like every other test file (tests/test_repo_health.bats lints this).
load helpers/setup

setup() {
  common_setup
}

teardown() {
  common_teardown
}
TAPE="$GRID_ROOT/docs/demo/demo.tape"
GIF="$GRID_ROOT/docs/demo/bootstrap-to-tron.gif"

# Helper: readme_quickstart — the README quickstart command (clone through --with-agents).
readme_quickstart() {
  grep -m1 -E '^git clone .*--with-agents$' "$GRID_ROOT/README.md"
}

# Helper: sleep_total_seconds — sum of every `Sleep <n>[ms|s|m]` line, in seconds.
# A bare number is seconds, as in vhs. Comment lines are ignored (anchored at line start).
sleep_total_seconds() {
  awk '
    /^Sleep[ \t]+[0-9.]+(ms|s|m)?[ \t]*$/ {
      v = $2
      if (v ~ /ms$/)      { sub(/ms$/, "", v); t += v / 1000 }
      else if (v ~ /m$/)  { sub(/m$/, "", v);  t += v * 60 }
      else                { sub(/s$/, "", v);  t += v }
    }
    END { printf "%.3f\n", t }
  ' "$TAPE"
}

@test "demo tape: file exists" {
  [ -f "$TAPE" ]
}

@test "demo tape: Output line ends in .gif" {
  grep -qE '^Output .+\.gif$' "$TAPE"
}

@test "demo tape: requires git and claude" {
  grep -qE '^Require git$' "$TAPE"
  grep -qE '^Require claude$' "$TAPE"
}

@test "demo tape: has a bootstrap.sh --with-agents line and a /tron line" {
  grep -qE '^Type ".*bootstrap\.sh --with-agents' "$TAPE"
  grep -qE '^Type "/tron"' "$TAPE"
}

@test "demo tape: holds no absolute user path" {
  ! grep -qF '/Users/' "$TAPE" || false
  ! grep -qF '/home/' "$TAPE" || false
}

@test "demo tape: visible Sleep values total at most 20 s" {
  total="$(sleep_total_seconds)"
  echo "Sleep total: ${total}s" >&2
  # awk does the float compare; bash [ ] cannot.
  awk -v t="$total" 'BEGIN { exit !(t <= 20) }'
}

@test "demo tape: README quickstart is a prefix of the hidden Type line" {
  cmd="$(readme_quickstart)"
  [ -n "$cmd" ]
  # The hidden line is the first Type after `Hide`; its text sits between the quotes.
  hidden="$(awk '/^Hide$/ { h = 1; next } h && /^Type "/ { print; exit }' "$TAPE" \
    | sed -e 's/^Type "//' -e 's/" Enter$//')"
  [ -n "$hidden" ]
  [ "${hidden:0:${#cmd}}" = "$cmd" ]
}

@test "demo tape: rendered GIF, when present, is at most 3 MB" {
  [ -f "$GIF" ] || skip "docs/demo/bootstrap-to-tron.gif not rendered yet"
  [ "$(wc -c < "$GIF")" -le $((3 * 1024 * 1024)) ]
}
