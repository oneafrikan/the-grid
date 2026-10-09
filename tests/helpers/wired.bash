#!/usr/bin/env bash
# Shared test helper — `load helpers/wired` (after `load helpers/setup`, which
# defines REPO_ROOT).
#
# wired_skill_dirs runs the REAL wire.sh into a throwaway dir against the
# personal baseline if present, else the tracked example, and prints each wired
# skill dir (the link target, trailing slash stripped). Asking wire.sh instead
# of re-implementing its discovery means the tests can never drift from it.
#
# Links to a repo root (the runtime-root link, for example
# skills/gstack -> repos/gstack) are not skills and are left out.
#
# GRID_HOST=__baseline__ is the shared sentinel: no machine overlay matches it,
# so the answer is the baseline alone. GRID_SKIP_CATALOG=1 stops wire.sh
# writing SKILLS.md / .wired.manifest into the repo.
#
# NOTE (group 2 form): SKILLS_DIR / AGENTS_DIR point into a temp dir. Task 8.5
# of the foundations change switches this to GRID_DRY_HOME once wire.sh has it.
wired_skill_dirs() {
  local base="$REPO_ROOT/baseline-submodules.txt" tmp t
  [ -f "$base" ] || base="$REPO_ROOT/baseline-submodules.example.txt"
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/skills" "$tmp/agents"
  GRID_DIR="$REPO_ROOT" GRID_BASELINE="$base" GRID_HOST=__baseline__ \
    GRID_SKIP_CATALOG=1 SKILLS_DIR="$tmp/skills" AGENTS_DIR="$tmp/agents" \
    bash "$REPO_ROOT/scripts/wire.sh" >/dev/null
  while IFS= read -r t; do
    t="${t%/}"
    [ "$(dirname "$t")" = "$REPO_ROOT/repos" ] && continue
    printf '%s\n' "$t"
  done < <(find "$tmp/skills" -maxdepth 1 -type l -exec readlink {} \;)
  rm -rf "$tmp"
}
