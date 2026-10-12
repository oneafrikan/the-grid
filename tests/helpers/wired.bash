#!/usr/bin/env bash
# Shared test helper — `load helpers/wired` (after `load helpers/setup`, which
# defines REPO_ROOT).
#
# wired_skill_dirs runs the REAL wire.sh into a throwaway home against the
# personal baseline if present, else the tracked example, and prints each wired
# skill dir (the link target, trailing slash stripped). Asking wire.sh instead
# of re-implementing its discovery means the tests can never drift from it.
#
# Links to a repo root (the runtime-root link, for example
# skills/gstack -> repos/gstack) are not skills and are left out.
#
# It FAILS (non-zero, reason on stderr) when wire.sh exits non-zero or when no skill dir
# comes out (R16.qa.F4): callers loop over the output, and a loop over nothing passes, so
# a broken wire.sh used to leave every format test green. Callers must capture the output
# first (`dirs="$(wired_skill_dirs)"`) so the status is not lost to `done < <(...)`.
#
# GRID_HOST=__baseline__ is the shared sentinel: no machine overlay matches it,
# so the answer is the baseline alone. GRID_DRY_HOME forces every wire.sh target
# under the throwaway home and stops it writing SKILLS.md / .wired.manifest into
# the repo; callers set ONLY GRID_DRY_HOME, never SKILLS_DIR/AGENTS_DIR/etc.
wired_skill_dirs() {
  local base="$REPO_ROOT/baseline-submodules.txt" tmp t rc=0 n=0
  [ -f "$base" ] || base="$REPO_ROOT/baseline-submodules.example.txt"
  tmp="$(mktemp -d)"
  # Output goes to a file, not into the loop's process substitution, so wire.sh's own exit
  # status is observed instead of discarded.
  GRID_DIR="$REPO_ROOT" GRID_BASELINE="$base" GRID_HOST=__baseline__ \
    GRID_DRY_HOME="$tmp/home" bash "$REPO_ROOT/scripts/wire.sh" >"$tmp/wire.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "wired_skill_dirs: wire.sh exited $rc:" >&2
    cat "$tmp/wire.log" >&2
    rm -rf "$tmp"
    return 1
  fi
  while IFS= read -r t; do
    t="${t%/}"
    [ "$(dirname "$t")" = "$REPO_ROOT/repos" ] && continue
    printf '%s\n' "$t"
    n=$((n + 1))
  done < <(find "$tmp/home/.claude/skills" -maxdepth 1 -type l -exec readlink {} \;)
  rm -rf "$tmp"
  if [ "$n" -eq 0 ]; then
    echo "wired_skill_dirs: wire.sh succeeded but wired no skill dirs" >&2
    return 1
  fi
}
