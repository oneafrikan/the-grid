#!/usr/bin/env bats
# Tests for scripts/build-plugins.py — generates the Claude Code plugin marketplace tree.
#
# Most tests run against a mock grid (mktemp -d, GRID_DIR override, `compose: []`) so
# they need no agent-factory venv and never touch ~/.claude. Test (j) exercises the real
# repo and compose, and skips when the venv is absent. (k) runs the real catalog.sh into
# a temp output path; it never reads or rewrites the committed SKILLS.md.

load helpers/setup

BUILD() { python3 "$REPO_ROOT/scripts/build-plugins.py" "$@"; }

# Write the manifest for the mock grid: two bundles, so "all four versions" is checkable.
# $1 (optional) overrides the grid-agents description.
write_manifest() {
  local desc="${1:-The agents bundle.}"
  mkdir -p "$MOCK_GRID/plugins"
  DESC="$desc" python3 - "$MOCK_GRID/plugins/bundles.json" <<'EOF'
import json, os, sys
m = {
  "marketplace": {"name": "mock-grid", "owner": "mock-owner", "description": "Mock marketplace."},
  "version": "1.2.3", "license": "MIT", "repository": "https://example.invalid/mock",
  "bundles": {
    "core":   {"description": "The core bundle.", "skills": ["alpha", "beta"], "compose": [], "agents": []},
    "agents": {"description": os.environ["DESC"], "skills": [], "compose": [], "agents": ["bot"]},
  },
}
json.dump(m, open(sys.argv[1], "w"), indent=2)
EOF
}

setup() {
  common_setup
  make_skill "$MOCK_GRID/skills/alpha" "alpha"
  make_skill "$MOCK_GRID/skills/beta"  "beta"
  # A supporting file, to prove whole skill dirs are copied, not just SKILL.md.
  printf 'ref\n' > "$MOCK_GRID/skills/alpha/ref.md"
  mkdir -p "$MOCK_GRID/agents"
  printf -- "---\nname: bot\ndescription: A bot\n---\nbody\n" > "$MOCK_GRID/agents/bot.md"
  write_manifest
  export GRID_DIR="$MOCK_GRID"
}

teardown() {
  unset GRID_DIR
  common_teardown
}

# Hash every file under the mock grid's generated outputs (path + content).
snapshot() {
  (cd "$MOCK_GRID" && find plugins .claude-plugin -type f | sort | xargs shasum)
}

@test "(a) build then --check exits 0" {
  run BUILD
  [ "$status" -eq 0 ]
  run BUILD --check
  [ "$status" -eq 0 ]
}

@test "(b) a second build changes nothing" {
  BUILD
  before="$(snapshot)"
  BUILD
  [ "$before" = "$(snapshot)" ]
}

@test "(c) --check on a hand-edited file exits 1, names it, and does not modify it" {
  BUILD
  f="$MOCK_GRID/plugins/core/skills/alpha/SKILL.md"
  echo "hand edit" >> "$f"
  before="$(shasum "$f")"
  run BUILD --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugins/core/skills/alpha/SKILL.md"* ]]
  [ "$before" = "$(shasum "$f")" ]
}

@test "(c2) --check reports missing and extra files" {
  BUILD
  rm "$MOCK_GRID/plugins/core/skills/beta/SKILL.md"
  echo x > "$MOCK_GRID/plugins/core/stray.txt"
  run BUILD --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing: plugins/core/skills/beta/SKILL.md"* ]]
  [[ "$output" == *"extra:   plugins/core/stray.txt"* ]]
}

@test "(d) removing a skill from the manifest removes its generated dir" {
  BUILD
  [ -d "$MOCK_GRID/plugins/core/skills/beta" ]
  python3 - "$MOCK_GRID/plugins/bundles.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["bundles"]["core"]["skills"] = ["alpha"]
json.dump(m, open(sys.argv[1], "w"))
EOF
  run BUILD
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_GRID/plugins/core/skills/beta" ]
  [ -f "$MOCK_GRID/plugins/core/skills/alpha/SKILL.md" ]
}

@test "(e) a listed skill without SKILL.md exits 2 naming the skill" {
  rm "$MOCK_GRID/skills/beta/SKILL.md"
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *"beta"* ]]
  # Guard fires before anything is written.
  [ ! -e "$MOCK_GRID/.claude-plugin/marketplace.json" ]
}

@test "(f) a skill name that also exists under repos/ exits 2 naming it" {
  make_skill "$MOCK_GRID/repos/x/alpha" "alpha"
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"repos/"* ]]
}

@test "(g) an unknown manifest key exits 2" {
  python3 - "$MOCK_GRID/plugins/bundles.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["surprise"] = 1
json.dump(m, open(sys.argv[1], "w"))
EOF
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *"surprise"* ]]
}

@test "(g2) an unknown key inside a bundle exits 2" {
  python3 - "$MOCK_GRID/plugins/bundles.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["bundles"]["core"]["hooks"] = []
json.dump(m, open(sys.argv[1], "w"))
EOF
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *"hooks"* ]]
}

@test "(h) marketplace.json and plugin.json parse, have the required keys, and share one version" {
  BUILD
  for f in "$MOCK_GRID/.claude-plugin/marketplace.json" \
           "$MOCK_GRID/plugins/core/.claude-plugin/plugin.json" \
           "$MOCK_GRID/plugins/agents/.claude-plugin/plugin.json"; do
    python3 -m json.tool "$f" >/dev/null
  done
  python3 - "$MOCK_GRID" <<'EOF'
import json, sys
g = sys.argv[1]
mp = json.load(open(f"{g}/.claude-plugin/marketplace.json"))
assert mp["name"] and mp["owner"]["name"] and mp["metadata"]["description"], mp
versions = []
for e in mp["plugins"]:
    assert e["name"] and e["source"], e
    versions.append(e["version"])
    pj = json.load(open(f"{g}/plugins/{e['name']}/.claude-plugin/plugin.json"))
    for k in ("name", "version", "description", "author", "license", "repository"):
        assert pj[k], (e["name"], k)
    # Nothing else: components are discovered by convention.
    assert set(pj) == {"name", "version", "description", "author", "license", "repository"}, pj
    versions.append(pj["version"])
assert len(versions) == 4 and len(set(versions)) == 1, versions
EOF
}

@test "whole skill dirs and root agents are copied" {
  BUILD
  [ -f "$MOCK_GRID/plugins/core/skills/alpha/ref.md" ]
  [ -f "$MOCK_GRID/plugins/agents/agents/bot.md" ]
}

@test "(i) a 201-char bundle description exits 2; 200 is accepted" {
  write_manifest "$(printf 'x%.0s' $(seq 1 201))"
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *"201"* ]]
  write_manifest "$(printf 'x%.0s' $(seq 1 200))"
  run BUILD
  [ "$status" -eq 0 ]
}

@test "a bundle with no components exits 2" {
  python3 - "$MOCK_GRID/plugins/bundles.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["bundles"]["core"]["skills"] = []
json.dump(m, open(sys.argv[1], "w"))
EOF
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *"no components"* ]]
}

@test "compose without the agent-factory venv exits 2 with a clear message" {
  python3 - "$MOCK_GRID/plugins/bundles.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["bundles"]["core"]["compose"] = ["core"]
json.dump(m, open(sys.argv[1], "w"))
EOF
  run BUILD
  [ "$status" -eq 2 ]
  [[ "$output" == *".venv"* ]]
}

@test "an unknown flag exits 2" {
  run BUILD --bogus
  [ "$status" -eq 2 ]
}

@test "(j) real repo: --check passes, agent count is derived, no hostname leaks" {
  [ -x "$REPO_ROOT/agent-factory/.venv/bin/python" ] || skip "agent-factory venv absent"
  unset GRID_DIR
  run BUILD --check
  [ "$status" -eq 0 ]

  tmp="$(mktemp -d)"
  (cd "$REPO_ROOT" && GRID_PRIVATE_ROLES_DIR= GRID_USER_CONFIG=agent-factory/user.public.yaml \
     agent-factory/.venv/bin/python agent-factory/compose.py agent-factory/examples/grid.yaml \
     --target claude-code --out "$tmp" >/dev/null)
  composed="$(find "$tmp/grid/_claude-code/agents" -name '*.md' | wc -l)"
  extra="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['bundles']['grid-agents']['agents']))" \
            "$REPO_ROOT/plugins/bundles.json")"
  shipped="$(find "$REPO_ROOT/plugins/grid-agents/agents" -type f | wc -l)"
  rm -rf "$tmp"
  [ "$shipped" -eq $((composed + extra)) ]

  # The machine hostname must not appear. Match it as a whole token that is not part of a
  # hyphenated name (a skill called "feature-forge" is not a host called "forge").
  host="$(hostname -s)"
  run grep -rlP "(?<![\\w-])\\Q${host}\\E(?![\\w-])" "$REPO_ROOT/plugins/"
  [ -z "$output" ]
}

@test "(k) catalog.sh never lists anything from plugins/" {
  tmp="$(mktemp -d)"
  unset GRID_DIR
  run bash "$REPO_ROOT/scripts/catalog.sh" "$tmp/SKILLS.md"
  [ "$status" -eq 0 ]
  run grep -c 'plugins/' "$tmp/SKILLS.md"
  rm -rf "$tmp"
  [ "$output" = "0" ]
}
