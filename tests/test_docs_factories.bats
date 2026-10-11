#!/usr/bin/env bats
# Guards against re-documenting the dropped skills-factory (#40).

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "public docs do not mention skills-factory" {
  cd "$GRID_ROOT"
  run grep -n "skills-factory" README.md CLAUDE.md automation-factory/README.md project-factory/README.md
  # grep exits 1 when nothing matches
  [ "$status" -eq 1 ]
}

@test "skills-factory/ is absent or has tracked files" {
  cd "$GRID_ROOT"
  # An untracked/empty directory would be a dangling reference; absent or tracked is fine.
  if [ -d skills-factory ]; then
    [ -n "$(git ls-files skills-factory)" ]
  fi
}
