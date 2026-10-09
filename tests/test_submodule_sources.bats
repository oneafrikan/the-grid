#!/usr/bin/env bats
# Guards for submodule sources and the tracked example baseline:
#   - .gitmodules uses HTTPS URLs only (a fresh machine without the right SSH
#     identity must still be able to clone every submodule);
#   - .nojekyll exists (keeps the legacy Pages source from walking repos/**);
#   - the example baseline stays truthful: header counts match, and every
#     entry still resolves to a real skill in the pinned submodule.
# The PERSONAL baseline is gitignored, so these tests read the example only.

load helpers/setup

EXAMPLE="$REPO_ROOT/baseline-submodules.example.txt"

# Print the active (comment-stripped, whitespace-stripped, non-empty) lines of
# the example baseline, one per line.
active_lines() {
  local line
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && printf '%s\n' "$line"
  done < "$EXAMPLE"
}

@test "no .gitmodules URL uses an SSH form" {
  ! grep -Eq '^[[:space:]]*url[[:space:]]*=[[:space:]]*(git@|ssh://)' "$REPO_ROOT/.gitmodules"
}

@test ".nojekyll exists at the repo root" {
  [ -f "$REPO_ROOT/.nojekyll" ]
}

@test "example baseline section header counts match the per-skill line counts" {
  local failed=0 line repo n have
  while IFS= read -r line; do
    # Header shape: "# --- <repo> ... (N skills) ---"
    if [[ "$line" =~ ^#\ ---\ ([A-Za-z0-9_.-]+)\ .*\(([0-9]+)\ skills\)\ ---$ ]]; then
      repo="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
      have="$(active_lines | grep -c "^$repo/" || true)"
      # Whole-repo sections (openspec, ponytail) have no <repo>/ lines: their
      # counts move with every upstream bump, so they are not tested.
      [ "$have" -gt 0 ] || continue
      if [ "$have" -ne "$n" ]; then
        echo "header says $n skills for $repo but the file lists $have" >&3
        failed=1
      fi
    fi
  done < "$EXAMPLE"
  [ "$failed" -eq 0 ]
}

@test "every positive per-skill entry resolves to a skill dir in its submodule" {
  # shellcheck source=../scripts/lib/find-skill-mds.sh
  . "$REPO_ROOT/scripts/lib/find-skill-mds.sh"
  local failed=0 entry repo skill head names p
  while IFS= read -r entry; do
    case "$entry" in -*) continue ;; esac            # subtraction
    [[ "$entry" == */* ]] || continue                # whole-repo line: test (e)
    head="${entry%%/*}"
    case "$head" in *:*) continue ;; esac            # typed line (project:, rules:, ...)
    repo="$head"; skill="${entry#*/}"
    # Uninitialised submodule: report, do not fail (CI inits them all).
    if [ -z "$(ls -A "$REPO_ROOT/repos/$repo" 2>/dev/null)" ]; then
      echo "skipped (repos/$repo not initialised): $entry" >&3
      continue
    fi
    # Discovery runs once per repo (cached in a temp file): it shells out to
    # git per repo and per-entry reruns made this test take minutes.
    names="$BATS_TEST_TMPDIR/names-$repo"
    if [ ! -f "$names" ]; then
      find_skill_mds "$REPO_ROOT/repos/$repo" | while IFS= read -r p; do
        basename "$(dirname "$p")"
      done > "$names"
    fi
    if ! grep -qx "$skill" "$names"; then
      echo "unresolved baseline entry: $entry" >&3
      failed=1
    fi
  done < <(active_lines)
  [ "$failed" -eq 0 ]
}

@test "every positive whole-repo entry names an existing repos/ dir" {
  local failed=0 entry
  while IFS= read -r entry; do
    case "$entry" in -*) continue ;; esac
    [[ "$entry" == */* ]] && continue                # per-skill: test (d)
    case "$entry" in *:*) continue ;; esac           # typed line
    if [ ! -d "$REPO_ROOT/repos/$entry" ]; then
      echo "no such repo dir: repos/$entry" >&3
      failed=1
    fi
  done < <(active_lines)
  [ "$failed" -eq 0 ]
}

@test "docs/SOURCES.md has no SSH-form marker" {
  ! grep -q ' ᵍ' "$REPO_ROOT/docs/SOURCES.md"
}
