#!/usr/bin/env bash
# Shared test helper — `load helpers/venv`. Needs no other helper.
#
# require_venv <python> — the one way a venv-gated test asks for the agent-factory venv
# (R16.qa.F5). A bare `[ -x "$PY" ] || skip` made 215 tests skip with bats still exiting 0,
# so a machine without the venv passed the gate while testing almost nothing.
#
#   venv usable                       -> returns 0
#   venv missing / PyYAML not importable
#     GRID_REQUIRE_VENV=1 or CI=true  -> prints "venv required ..." and returns 1 (test FAILS)
#     otherwise                       -> skips, with the reason (quick local runs stay possible)
#
# scripts/gate.sh exports GRID_REQUIRE_VENV=1, so the commit gate can no longer go green on
# skipped tests; CI sets CI=true. Importing yaml (not just -x) catches a half-built venv.
require_venv() {
  local py="$1" why=""
  if [ ! -x "$py" ]; then
    why="agent-factory venv not built"
  elif ! "$py" -c 'import yaml' >/dev/null 2>&1; then
    why="agent-factory venv has no PyYAML"
  fi
  [ -n "$why" ] || return 0
  if [ "${GRID_REQUIRE_VENV:-}" = "1" ] || [ "${CI:-}" = "true" ]; then
    echo "venv required ($why): cd agent-factory && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
    return 1
  fi
  skip "$why"
}
