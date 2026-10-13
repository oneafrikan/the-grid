#!/usr/bin/env bats
# Tests for skill directory structure and SKILL.md frontmatter validity.
# The "wired" set comes from the real wire.sh (tests/helpers/wired.bash), so it
# cannot drift from wire.sh's own discovery and works on a CI runner that has
# no personal baseline (it falls back to baseline-submodules.example.txt).

load helpers/setup
load helpers/wired

# A fake REPO_ROOT whose scripts/wire.sh is the given body, so the helper can be pointed at a
# wire.sh that fails or wires nothing (R16.qa.F4). $1 = wire.sh body.
fake_wire_root() {
  local root="$BATS_TEST_TMPDIR/fakeroot"
  mkdir -p "$root/scripts"
  : > "$root/baseline-submodules.example.txt"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$root/scripts/wire.sh"
  printf '%s\n' "$root"
}

@test "wired_skill_dirs fails when wire.sh fails" {
  local root; root="$(fake_wire_root 'exit 1')"
  REPO_ROOT="$root" run wired_skill_dirs
  [ "$status" -eq 1 ]
  [[ "$output" == *"wire.sh exited 1"* ]] || false
}

@test "wired_skill_dirs fails when wire.sh wires nothing" {
  local root; root="$(fake_wire_root 'mkdir -p "$GRID_DRY_HOME/.claude/skills"')"
  REPO_ROOT="$root" run wired_skill_dirs
  [ "$status" -eq 1 ]
  [[ "$output" == *"wired no skill dirs"* ]] || false
}

@test "every wired skill dir contains a SKILL.md" {
  local failed=0 dirs
  # Capture first: `done < <(wired_skill_dirs)` would swallow the helper's failure status.
  dirs="$(wired_skill_dirs)"
  while IFS= read -r skill_dir; do
    if [ ! -f "$skill_dir/SKILL.md" ]; then
      echo "Missing SKILL.md: $skill_dir" >&3
      failed=1
    fi
  done <<< "$dirs"
  [ "$failed" -eq 0 ]
}

# Frontmatter checks cover WIRED skills only — library repos are upstream
# community content (often imperfect) that we index but never load.
@test "every wired SKILL.md has a name field" {
  local failed=0 dirs
  # Capture first: `done < <(wired_skill_dirs)` would swallow the helper's failure status.
  dirs="$(wired_skill_dirs)"
  while IFS= read -r skill_dir; do
    if ! grep -q "^name:" "$skill_dir/SKILL.md"; then
      echo "Missing 'name:' in $skill_dir/SKILL.md" >&3
      failed=1
    fi
  done <<< "$dirs"
  [ "$failed" -eq 0 ]
}

@test "every wired SKILL.md has a description field" {
  local failed=0 dirs
  # Capture first: `done < <(wired_skill_dirs)` would swallow the helper's failure status.
  dirs="$(wired_skill_dirs)"
  while IFS= read -r skill_dir; do
    if ! grep -q "^description:" "$skill_dir/SKILL.md"; then
      echo "Missing 'description:' in $skill_dir/SKILL.md" >&3
      failed=1
    fi
  done <<< "$dirs"
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

# --- Text left behind by the skills section split (WP-069) --------------------------------
# Moving prose into sections/ made `../../X` point one level too shallow and left
# "above"/"below" pointing at content that now lives in another file.

# broken_skill_links <skills dir>: prints "<file> -> <target>" for every relative markdown
# link in skills/*/SKILL.md and skills/*/sections/*.md that does not resolve from the
# file's OWN directory. Links inside code fences and inline code are examples, not links.
broken_skill_links() {
  python3 -I - "$1" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "*", "SKILL.md")) +
               glob.glob(os.path.join(root, "*", "sections", "*.md")))
for f in files:
    fence = False
    for line in open(f, encoding="utf-8"):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        line = re.sub(r"`[^`]*`", "", line)
        for target in re.findall(r"\]\(([^)\s]+)\)", line):
            if re.match(r"[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            path = target.split("#", 1)[0]
            if path and not os.path.exists(os.path.join(os.path.dirname(f), path)):
                print("%s -> %s" % (os.path.relpath(f, root), target))
PY
}

@test "every relative markdown link in skills/*/SKILL.md and sections/*.md resolves from the file's own directory" {
  run broken_skill_links "$REPO_ROOT/skills"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output" >&3; false; }
}

@test "the link checker catches a link one directory too shallow" {
  mkdir -p "$BATS_TEST_TMPDIR/sk/x/sections"
  echo "[ok](../../good.md)" > "$BATS_TEST_TMPDIR/sk/good.md"
  printf '[bad](../../SKILLS.md)\n```\n[fenced](../../nope.md)\n```\n' > "$BATS_TEST_TMPDIR/sk/x/sections/a.md"
  echo "[up](../good.md)" > "$BATS_TEST_TMPDIR/sk/x/SKILL.md"
  run broken_skill_links "$BATS_TEST_TMPDIR/sk"
  [ "$output" = "x/sections/a.md -> ../../SKILLS.md" ]
}

@test "no above/below pointer to moved content in mine-learnings, grid-help, un-claudish" {
  # `! grep` does not fail a bats test (errexit ignores negated commands); test the status.
  if grep -n 'LEARNINGS.md format" below' "$REPO_ROOT/skills/mine-learnings/SKILL.md"; then false; fi
  if grep -n 'summary below' "$REPO_ROOT/skills/grid-help/SKILL.md"; then false; fi
  if grep -n 'kill-list above' "$REPO_ROOT/skills/un-claudish/SKILL.md"; then false; fi
}

@test "handoff SKILL.md has no 'create the directory if it doesn't exist' (contradicts ask-before-creating)" {
  if grep -in "create the directory if it doesn't exist" "$REPO_ROOT/skills/handoff/SKILL.md"; then false; fi
  grep -q 'ask before creating' "$REPO_ROOT/skills/handoff/SKILL.md"
}

@test "skill-scout names the wiring script by its real path (bash scripts/wire.sh)" {
  if grep -n 'bash wire\.sh' "$REPO_ROOT/skills/skill-scout/SKILL.md"; then false; fi
}
