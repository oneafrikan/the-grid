#!/usr/bin/env bats
# The factory-chain runbook names real scripts; a renamed or removed script must fail here
# instead of leaving a reader with a command that does not exist.

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOC=automation-factory/docs/factory-chain.md

@test "factory-chain runbook: every repo script path it names exists" {
  cd "$GRID_ROOT"
  [ -f "$DOC" ]
  # Only paths rooted in a the-grid dir are checked: the project-side paths the runbook also
  # shows (loop/run-issue.sh, ...) exist in the cut project, not in this checkout.
  paths="$(grep -oE '(project-factory|agent-factory|automation-factory|scripts)/[A-Za-z0-9_./-]+\.(sh|py)' "$DOC" | sort -u)"
  # A doc that names no script would pass vacuously.
  [ -n "$paths" ]
  while IFS= read -r p; do
    [ -f "$p" ] || { echo "missing: $p" >&2; return 1; }
  done <<< "$paths"
}

@test "factory-chain runbook: names the three entry points and ends with the required line" {
  cd "$GRID_ROOT"
  grep -qF 'project-factory/scripts/cut-project.sh' "$DOC"
  grep -qF 'agent-factory/deploy.py' "$DOC"
  grep -qF 'scripts/instantiate.sh' "$DOC"
  [ "$(tail -n 1 "$DOC")" = "Not yet scripted: see issue #21" ]
}
