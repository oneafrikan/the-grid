#!/usr/bin/env bats
# Tests for scripts/stamp-counts.py - generated counts in README/index.html. Every case runs
# against a temp GRID_DIR, never the real README or SKILLS.md.

load helpers/setup

setup() {
  common_setup
  G=$(mktemp -d)
  mkdir -p "$G/agent-factory/examples"
  # Fixture headline in exactly the shape catalog.sh writes (em dash included).
  printf '# cat\n\n**10 skills indexed** — 6 wired live (2 root-owned + 4 from allowlisted repos), 4 in library (indexed & searchable, not wired).\n' \
    > "$G/SKILLS.md"
  # Three roles, one indented deeper than the others.
  printf 'project: x\nagents:\n  - role: a\n  - role: b\n    - role: c\n  - skills: [role]\n' \
    > "$G/agent-factory/examples/x.yaml"
  M='<!--count:indexed-->0<!--/count--> <!--count:wired-->0<!--/count--> <!--count:roles-->0<!--/count-->'
  printf 'readme %s\n' "$M" > "$G/README.md"
  printf 'japanese %s\n' "$M" > "$G/README.ja.md"
  printf '<p>%s</p>\n' "$M" > "$G/index.html"
}

teardown() {
  rm -rf "$G"
  common_teardown
}

stamp() { GRID_DIR="$G" python3 "$REPO_ROOT/scripts/stamp-counts.py" "$@"; }

@test "stamps README.md, README.*.md and index.html from the headline and the role count" {
  run stamp
  [ "$status" -eq 0 ]
  for f in README.md README.ja.md index.html; do
    grep -q '<!--count:indexed-->10<!--/count-->' "$G/$f"
    grep -q '<!--count:wired-->6<!--/count-->' "$G/$f"
    grep -q '<!--count:roles-->3<!--/count-->' "$G/$f"
  done
}

@test "a second run is a byte-identical no-op" {
  stamp
  before="$(cksum "$G/README.md" "$G/README.ja.md" "$G/index.html")"
  run stamp
  [ "$status" -eq 0 ]
  [ "$(cksum "$G/README.md" "$G/README.ja.md" "$G/index.html")" = "$before" ]
}

@test "--check fails on a stale value naming the file, and passes after stamping" {
  run stamp --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"README.ja.md"* ]] || false
  [[ "$output" == *"index.html"* ]] || false
  stamp
  run stamp --check
  [ "$status" -eq 0 ]
}

@test "--check writes nothing" {
  before="$(cksum "$G/README.md")"
  run stamp --check
  [ "$status" -eq 1 ]
  [ "$(cksum "$G/README.md")" = "$before" ]
}

@test "an unknown NAME exits 2 and names the file" {
  printf '<!--count:bogus-->1<!--/count-->\n' >> "$G/README.md"
  run stamp
  [ "$status" -eq 2 ]
  [[ "$output" == *"bogus"* ]] || false
  [[ "$output" == *"README.md"* ]] || false
}

@test "an unparsable headline with markers present exits 2" {
  printf '# cat\n\n232 skills, whatever\n' > "$G/SKILLS.md"
  run stamp
  [ "$status" -eq 2 ]
}

@test "a missing SKILLS.md with markers present exits 2" {
  rm "$G/SKILLS.md"
  run stamp
  [ "$status" -eq 2 ]
}

@test "no markers anywhere exits 0 and needs no SKILLS.md" {
  printf 'plain\n' > "$G/README.md"
  printf 'plain\n' > "$G/README.ja.md"
  printf 'plain\n' > "$G/index.html"
  printf 'garbage\n' > "$G/SKILLS.md"
  run stamp
  [ "$status" -eq 0 ]
  run stamp --check
  [ "$status" -eq 0 ]
}

@test "catalog.sh still exits 0 and writes SKILLS.md with python3 hidden from PATH" {
  mkdir -p "$G/skills"
  make_skill "$G/skills/skill-alpha" "skill-alpha"
  rm "$G/SKILLS.md"
  PATH="$(path_without 'python3*' python)" GRID_DIR="$G" run bash "$REPO_ROOT/scripts/catalog.sh"
  [ "$status" -eq 0 ]
  [ -f "$G/SKILLS.md" ]
  # python3 was hidden, so nothing was stamped
  grep -q '<!--count:indexed-->0<!--/count-->' "$G/README.md"
}

@test "catalog.sh restamps the counts after writing the default SKILLS.md" {
  mkdir -p "$G/skills"
  make_skill "$G/skills/skill-alpha" "skill-alpha"
  GRID_DIR="$G" run bash "$REPO_ROOT/scripts/catalog.sh"
  [ "$status" -eq 0 ]
  grep -q '<!--count:indexed-->1<!--/count-->' "$G/README.md"
  grep -q '<!--count:roles-->3<!--/count-->' "$G/README.md"
}

@test "the real SKILLS.md headline parses: all six markers get numeric values" {
  cp "$REPO_ROOT/SKILLS.md" "$G/SKILLS.md"
  printf '<!--count:indexed-->0<!--/count--> <!--count:wired-->0<!--/count--> <!--count:root_owned-->0<!--/count--> <!--count:upstream_wired-->0<!--/count--> <!--count:library-->0<!--/count--> <!--count:roles-->0<!--/count-->\n' \
    > "$G/README.md"
  rm "$G/README.ja.md" "$G/index.html"
  run stamp
  [ "$status" -eq 0 ]
  n="$(grep -oE '<!--count:[a-z_]+-->[0-9]+<!--/count-->' "$G/README.md" | wc -l)"
  [ "$n" -eq 6 ]
}
