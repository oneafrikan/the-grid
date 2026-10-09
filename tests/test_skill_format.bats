#!/usr/bin/env bats
# Tests for skill directory structure and SKILL.md frontmatter validity.
# The "wired" set comes from the real wire.sh (tests/helpers/wired.bash), so it
# cannot drift from wire.sh's own discovery and works on a CI runner that has
# no personal baseline (it falls back to baseline-submodules.example.txt).

load helpers/setup
load helpers/wired

@test "every wired skill dir contains a SKILL.md" {
  local failed=0
  while IFS= read -r skill_dir; do
    if [ ! -f "$skill_dir/SKILL.md" ]; then
      echo "Missing SKILL.md: $skill_dir" >&3
      failed=1
    fi
  done < <(wired_skill_dirs)
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
  done < <(wired_skill_dirs)
  [ "$failed" -eq 0 ]
}

@test "every wired SKILL.md has a description field" {
  local failed=0
  while IFS= read -r skill_dir; do
    if ! grep -q "^description:" "$skill_dir/SKILL.md"; then
      echo "Missing 'description:' in $skill_dir/SKILL.md" >&3
      failed=1
    fi
  done < <(wired_skill_dirs)
  [ "$failed" -eq 0 ]
}

@test "no duplicate skill names in root-level skills (skills we own)" {
  # Only check skills in skills/ — external repos may overlap intentionally.
  local all unique
  all=$(for d in "$REPO_ROOT/skills"/*/; do
    [ -f "${d}SKILL.md" ] && grep "^name:" "${d}SKILL.md" | awk '{print $2}'
  done | sort)
  unique=$(echo "$all" | uniq)
  if [ "$all" != "$unique" ]; then
    echo "Duplicate skill names in root:" >&3
    diff <(echo "$all") <(echo "$unique") >&3
    return 1
  fi
}
