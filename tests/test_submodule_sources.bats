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
  local failed=0 seen=0 entry repo skill head names p
  while IFS= read -r entry; do
    case "$entry" in -*) continue ;; esac            # subtraction
    [[ "$entry" == */* ]] || continue                # whole-repo line: test (e)
    head="${entry%%/*}"
    case "$head" in *:*) continue ;; esac            # typed line (project:, rules:, ...)
    repo="$head"; skill="${entry#*/}"
    seen=$((seen + 1))
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
  # A loop over zero entries passes: the example baseline must keep per-skill lines.
  [ "$seen" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "every positive whole-repo entry names an existing repos/ dir" {
  local failed=0 seen=0 entry
  while IFS= read -r entry; do
    case "$entry" in -*) continue ;; esac
    [[ "$entry" == */* ]] && continue                # per-skill: test (d)
    case "$entry" in *:*) continue ;; esac           # typed line
    seen=$((seen + 1))
    if [ ! -d "$REPO_ROOT/repos/$entry" ]; then
      echo "no such repo dir: repos/$entry" >&3
      failed=1
    fi
  done < <(active_lines)
  [ "$seen" -gt 0 ]
  [ "$failed" -eq 0 ]
}

@test "docs/SOURCES.md has no SSH-form marker" {
  ! grep -q ' ᵍ' "$REPO_ROOT/docs/SOURCES.md"
}

# The gstack pin must not silently regress below the version the runtime map
# (scripts/lib/runtimes.txt) and its setup flags were verified against.
@test "gstack pin is at least 1.91" {
  [ -f "$REPO_ROOT/repos/gstack/VERSION" ] || skip "repos/gstack not initialised"
  local v major minor
  v="$(tr -d '[:space:]' < "$REPO_ROOT/repos/gstack/VERSION")"
  major="${v%%.*}"
  minor="${v#*.}"; minor="${minor%%.*}"
  # Numeric compare, not string: 1.100 > 1.91 but "1.100" < "1.91" as text.
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 91 ]; }
}

# --- WP-046: SOURCES.md drift is checked offline, against the tracked example baseline -----------
# `sources.sh --check-drift` renders to a temp file and diffs docs/SOURCES.md. Exit 0 current,
# 1 stale, 2 error. It defaults to the example baseline (the only one CI has); GRID_BASELINE pins
# another. No network (the URL rot check stays in --check).

# sources_fixture — a GRID_DIR holding copies of the three inputs, so a test can edit them
sources_fixture() {
  FX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FX/docs"
  cp "$REPO_ROOT/.gitmodules" "$FX/.gitmodules"
  cp "$EXAMPLE" "$FX/baseline-submodules.example.txt"
  cp "$REPO_ROOT/docs/SOURCES.md" "$FX/docs/SOURCES.md"
}

@test "sources.sh --check-drift exits 0 on the real repo" {
  cd "$BATS_TEST_TMPDIR"
  run bash "$REPO_ROOT/scripts/sources.sh" --check-drift
  echo "$output"
  [ "$status" -eq 0 ]
  # a read-only mode: it must not have written a stray file into the cwd
  [ -z "$(ls -A "$BATS_TEST_TMPDIR")" ]
}

@test "sources.sh --check-drift exits 1 after docs/SOURCES.md is edited, and writes nothing" {
  sources_fixture
  printf 'stale\n' >> "$FX/docs/SOURCES.md"
  local before; before="$(cksum < "$FX/docs/SOURCES.md")"
  GRID_DIR="$FX" run bash "$REPO_ROOT/scripts/sources.sh" --check-drift
  [ "$status" -eq 1 ]
  [ "$(cksum < "$FX/docs/SOURCES.md")" = "$before" ]
}

@test "sources.sh --check-drift exits 2 when SOURCES.md or the baseline is missing" {
  sources_fixture
  rm "$FX/docs/SOURCES.md"
  GRID_DIR="$FX" run bash "$REPO_ROOT/scripts/sources.sh" --check-drift
  [ "$status" -eq 2 ]
  cp "$REPO_ROOT/docs/SOURCES.md" "$FX/docs/SOURCES.md"
  GRID_DIR="$FX" GRID_BASELINE="$FX/no-such.txt" run bash "$REPO_ROOT/scripts/sources.sh" --check-drift
  [ "$status" -eq 2 ]
}

@test "sources.sh renders its tiers from GRID_BASELINE, and a missing pinned file exits 2" {
  sources_fixture
  # personal baseline wires nothing from the example's repos: tiers would differ if it were read
  printf 'no-such-repo\n' > "$FX/baseline-submodules.txt"
  GRID_DIR="$FX" GRID_BASELINE="$FX/baseline-submodules.example.txt" run bash "$REPO_ROOT/scripts/sources.sh" "$FX/out.md"
  [ "$status" -eq 0 ]
  diff -q "$FX/out.md" "$FX/docs/SOURCES.md"
  GRID_DIR="$FX" GRID_BASELINE="$FX/no-such.txt" run bash "$REPO_ROOT/scripts/sources.sh" "$FX/out2.md"
  [ "$status" -eq 2 ]
  [ ! -e "$FX/out2.md" ]
}
