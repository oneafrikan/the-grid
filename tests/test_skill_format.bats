#!/usr/bin/env bats
# Tests for skill directory structure and SKILL.md frontmatter validity
# Runs against actual the-grid content (not mocks)

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EXCLUDED=("repos" "tests")

# Returns all skill dirs at grid root and inside repos/, skipping excluded dirs
all_skill_dirs() {
  # Root-level skills
  for d in "$GRID_ROOT"/*/; do
    local name; name=$(basename "$d")
    [[ " ${EXCLUDED[*]} " == *" $name "* ]] && continue
    [ -d "$d" ] && echo "$d"
  done
  # Skills inside repos/ submodules (one level deep)
  find "$GRID_ROOT/repos" -mindepth 2 -maxdepth 2 -type d 2>/dev/null
}

@test "every skill directory contains a SKILL.md" {
  local failed=0
  while IFS= read -r skill_dir; do
    if [ ! -f "$skill_dir/SKILL.md" ]; then
      echo "Missing SKILL.md: $skill_dir" >&3
      failed=1
    fi
  done < <(all_skill_dirs)
  [ "$failed" -eq 0 ]
}

@test "every SKILL.md has a name field" {
  local failed=0
  while IFS= read -r skill_md; do
    if ! grep -q "^name:" "$skill_md"; then
      echo "Missing 'name:' in $skill_md" >&3
      failed=1
    fi
  done < <(find "$GRID_ROOT" -name "SKILL.md" -not -path "*/tests/*")
  [ "$failed" -eq 0 ]
}

@test "every SKILL.md has a description field" {
  local failed=0
  while IFS= read -r skill_md; do
    if ! grep -q "^description:" "$skill_md"; then
      echo "Missing 'description:' in $skill_md" >&3
      failed=1
    fi
  done < <(find "$GRID_ROOT" -name "SKILL.md" -not -path "*/tests/*")
  [ "$failed" -eq 0 ]
}

@test "no duplicate skill names across the-grid and repos/" {
  local all unique
  all=$(find "$GRID_ROOT" -name "SKILL.md" -not -path "*/tests/*" \
    -exec grep "^name:" {} \; | awk '{print $2}' | sort)
  unique=$(echo "$all" | uniq)
  if [ "$all" != "$unique" ]; then
    echo "Duplicate skill names:" >&3
    diff <(echo "$all") <(echo "$unique") >&3
    return 1
  fi
}
