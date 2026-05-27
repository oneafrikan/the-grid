#!/usr/bin/env bats
# Tests for skill directory structure and SKILL.md frontmatter validity.
# all_wired_skill_dirs mirrors wire.sh's discovery logic exactly.

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EXCLUDED=(repos tests .git)

# Returns every skill dir that wire.sh would actually wire.
all_wired_skill_dirs() {
  # Root-level skills (wire.sh step 2)
  for d in "$GRID_ROOT"/*/; do
    local name; name=$(basename "$d")
    [[ " ${EXCLUDED[*]} " == *" $name "* ]] && continue
    [ -f "${d}SKILL.md" ] || continue
    echo "${d%/}"
  done
  # Repo skills (wire.sh step 3) — find at any depth, skip repo root SKILL.md
  for repo_dir in "$GRID_ROOT/repos"/*/; do
    [ -d "$repo_dir" ] || continue
    local rd="${repo_dir%/}"
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

@test "every SKILL.md has a name field" {
  local failed=0
  while IFS= read -r skill_md; do
    if ! grep -q "^name:" "$skill_md"; then
      echo "Missing 'name:' in $skill_md" >&3
      failed=1
    fi
  done < <(find "$GRID_ROOT" -name "SKILL.md" -not -path "*/.git/*")
  [ "$failed" -eq 0 ]
}

@test "every SKILL.md has a description field" {
  local failed=0
  while IFS= read -r skill_md; do
    if ! grep -q "^description:" "$skill_md"; then
      echo "Missing 'description:' in $skill_md" >&3
      failed=1
    fi
  done < <(find "$GRID_ROOT" -name "SKILL.md" -not -path "*/.git/*")
  [ "$failed" -eq 0 ]
}

@test "no duplicate skill names in root-level skills (skills we own)" {
  # Only check skills at the-grid root — external repos may overlap intentionally.
  local all unique
  all=$(for d in "$GRID_ROOT"/*/; do
    local name; name=$(basename "$d")
    [[ " ${EXCLUDED[*]} " == *" $name "* ]] && continue
    [ -f "${d}SKILL.md" ] && grep "^name:" "${d}SKILL.md" | awk '{print $2}'
  done | sort)
  unique=$(echo "$all" | uniq)
  if [ "$all" != "$unique" ]; then
    echo "Duplicate skill names in root:" >&3
    diff <(echo "$all") <(echo "$unique") >&3
    return 1
  fi
}
