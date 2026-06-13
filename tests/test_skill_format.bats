#!/usr/bin/env bats
# Tests for skill directory structure and SKILL.md frontmatter validity.
# all_wired_skill_dirs mirrors wire.sh's discovery logic exactly.

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Wiring allowlist (mirror wire.sh): only these submodules are wired; the rest
# are library-only (upstream community content we neither wire nor validate).
WIRED_REPOS=(); wire_all_repos=1
if [ -f "$GRID_ROOT/wired-submodules.txt" ]; then
  wire_all_repos=0
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && WIRED_REPOS+=("$line")
  done < "$GRID_ROOT/wired-submodules.txt"
fi
repo_is_wired() {
  [ "$wire_all_repos" -eq 1 ] && return 0
  local n="$1" r
  for r in "${WIRED_REPOS[@]:-}"; do [ "$r" = "$n" ] && return 0; done
  return 1
}

# Returns every skill dir that wire.sh would actually wire.
all_wired_skill_dirs() {
  # skills/ dir (wire.sh step 3)
  for d in "$GRID_ROOT/skills"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    echo "${d%/}"
  done
  # Repo skills (wire.sh step 3) — only wired (allowlisted) submodules.
  for repo_dir in "$GRID_ROOT/repos"/*/; do
    [ -d "$repo_dir" ] || continue
    local rd="${repo_dir%/}"
    repo_is_wired "$(basename "$rd")" || continue
    while IFS= read -r skill_md; do
      local skill_dir; skill_dir=$(dirname "$skill_md")
      [ "$skill_dir" = "$rd" ] && continue
      echo "$skill_dir"
    done < <(find "$rd" -name "SKILL.md" -not -path "*/.git/*")
  done
}

@test "every wired skill dir contains a SKILL.md" {
  local failed=0
  while IFS= read -r skill_dir; do
    if [ ! -f "$skill_dir/SKILL.md" ]; then
      echo "Missing SKILL.md: $skill_dir" >&3
      failed=1
    fi
  done < <(all_wired_skill_dirs)
  [ "$failed" -eq 0 ]
}

# Frontmatter checks cover WIRED skills only — library repos are upstream
# community content (often imperfect) that we index but never load.
@test "every wired SKILL.md has a name field" {
  local failed=0
  while IFS= read -r skill_dir; do
    if ! grep -q "^name:" "$skill_dir/SKILL.md"; then
      echo "Missing 'name:' in $skill_dir/SKILL.md" >&3
      failed=1
    fi
  done < <(all_wired_skill_dirs)
  [ "$failed" -eq 0 ]
}

@test "every wired SKILL.md has a description field" {
  local failed=0
  while IFS= read -r skill_dir; do
    if ! grep -q "^description:" "$skill_dir/SKILL.md"; then
      echo "Missing 'description:' in $skill_dir/SKILL.md" >&3
      failed=1
    fi
  done < <(all_wired_skill_dirs)
  [ "$failed" -eq 0 ]
}

@test "no duplicate skill names in root-level skills (skills we own)" {
  # Only check skills in skills/ — external repos may overlap intentionally.
  local all unique
  all=$(for d in "$GRID_ROOT/skills"/*/; do
    [ -f "${d}SKILL.md" ] && grep "^name:" "${d}SKILL.md" | awk '{print $2}'
  done | sort)
  unique=$(echo "$all" | uniq)
  if [ "$all" != "$unique" ]; then
    echo "Duplicate skill names in root:" >&3
    diff <(echo "$all") <(echo "$unique") >&3
    return 1
  fi
}
