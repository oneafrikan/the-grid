#!/usr/bin/env bats
# Tests for scripts/budget.py (listing-budget measurement + gate check) and
# scripts/lib/baseline_wired.py. Every test builds a MOCK grid in a temp dir and
# points GRID_DIR at it, so nothing reads the real repo, ~/.claude or the real home.

load helpers/setup

BUDGET="$REPO_ROOT/scripts/budget.py"

setup() {
  common_setup
  # The baseline scope runs the mock grid's OWN scripts/wire.sh, so give the mock
  # a copy of the real one (plus its sourced lib dir and the runtimes map).
  mkdir -p "$MOCK_GRID/scripts" "$MOCK_GRID/docs"
  cp "$REPO_ROOT/scripts/wire.sh" "$MOCK_GRID/scripts/wire.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$MOCK_GRID/scripts/lib"
  # A developer's own GRID_BASELINE must not leak into the tests.
  unset GRID_BASELINE GRID_HOST
}

teardown() {
  common_teardown
}

# --- helpers ------------------------------------------------------------------

# budget <args...> — run budget.py against the mock grid ($status / $output set).
budget() { GRID_DIR="$MOCK_GRID" run python3 "$BUDGET" "$@"; }

# jget <json> <dotted.path> — print one value out of a JSON document.
jget() {
  python3 -c 'import functools, json, sys
d = json.loads(sys.argv[1])
print(functools.reduce(lambda a, k: a[int(k)] if isinstance(a, list) else a[k], sys.argv[2].split("."), d))' "$1" "$2"
}

# write_target <skills> <orch> <agents> <baseline> <per_entry> <body_bytes>
write_target() {
  printf '{"schema":1,"truncate_at":1536,"per_entry_max_chars":%s,"owned":{"skills_max_chars":%s,"orchestrator_roles_max_chars":%s,"agent_roles_max_chars":%s,"skill_body_max_bytes":%s},"baseline":{"skills_max_chars":%s}}\n' \
    "$5" "$1" "$2" "$3" "$6" "$4" > "$MOCK_GRID/docs/budget-target.json"
}

# skill_raw <name> <frontmatter lines...> — an owned skill with hand-written frontmatter.
skill_raw() {
  local name="$1"; shift
  mkdir -p "$MOCK_GRID/skills/$name"
  { echo "---"; printf '%s\n' "$@"; echo "---"; echo "body"; } > "$MOCK_GRID/skills/$name/SKILL.md"
}

# --- (a) totals match hand-counted entries ------------------------------------

@test "totals match hand-counted entries: folded, when_to_use, disabled, 1536 cut" {
  long="$(head -c 2000 /dev/zero | tr '\0' x)"
  skill_raw alpha  "name: alpha"  "description: Does a thing"                 # 5+12+4  = 21
  skill_raw folded "name: folded" "description: >" "  line one" "  line two"  # 6+17+4  = 27
  skill_raw wtu    "name: wtu"    "description: abc" "when_to_use: def"        # 3+7+4   = 14
  skill_raw off    "name: off"    "description: never listed" "disable-model-invocation: true"  # 3+0+4 = 7
  skill_raw long   "name: long"   "description: $long"                         # 4+1536+4 = 1544
  budget --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" owned.skills.count)" = "5" ]
  [ "$(jget "$output" owned.skills.chars)" = "1613" ]
}

@test "quoted scalars: '' and \\\" escapes are decoded before counting" {
  skill_raw sq "name: sq" "description: 'it''s ok'"          # it's ok = 7 -> 2+7+4 = 13
  skill_raw dq "name: dq" 'description: "say \"hi\""'        # say "hi" = 8 -> 2+8+4 = 14
  budget --json
  [ "$(jget "$output" owned.skills.chars)" = "27" ]
}

@test "roles: description if present, else '<title>. <summary>'; orchestrators counted apart" {
  mkdir -p "$MOCK_GRID/agent-factory/roles"/{legacy,explicit,boss}
  # legacy: title carries a trailing YAML comment, summary is a folded >- block
  printf 'name: legacy\ntitle: Legacy Role   # nameplate\nsummary: >-\n  Does old\n  things.\norchestrator: false\n' \
    > "$MOCK_GRID/agent-factory/roles/legacy/role.yaml"            # "Legacy Role. Does old things." = 29 -> 6+29+4 = 39
  printf 'name: explicit\ntitle: T\nsummary: ignored\ndescription: Short one.\n' \
    > "$MOCK_GRID/agent-factory/roles/explicit/role.yaml"          # 8+10+4 = 22
  printf 'name: boss\ntitle: Boss\nsummary: Runs it.\norchestrator: true\n' \
    > "$MOCK_GRID/agent-factory/roles/boss/role.yaml"              # "Boss. Runs it." = 14 -> 4+14+4 = 22
  budget --json
  [ "$(jget "$output" owned.agent_roles.chars)" = "61" ]
  [ "$(jget "$output" owned.agent_roles.count)" = "2" ]
  [ "$(jget "$output" owned.orchestrator_roles.chars)" = "22" ]
  # The fallback still gives a number, but a role without description: is now a --check
  # failure (the composed listing text differs from "<title>. <summary>"; WP-060).
  write_target 1000 1000 1000 0 250 100000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-factory/roles/legacy/role.yaml: role legacy has no description"* ]] || false
  [[ "$output" == *"agent-factory/roles/boss/role.yaml: role boss has no description"* ]] || false
  [[ "$output" != *"roles/explicit"* ]] || false
}

# --- (b) --check against the target -------------------------------------------

@test "--check passes at the target and fails when a description grows by 1 char" {
  skill_raw alpha "name: alpha" "description: Does a thing"       # 21
  write_target 21 0 0 0 5000 100000
  budget --check
  # 3 = owned OK, baseline scope skipped (no baseline file) - never 1
  [ "$status" -eq 3 ]
  skill_raw alpha "name: alpha" "description: Does a thingX"
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owned.skills_max_chars: 22 chars > target 21"* ]] || false
}

@test "--check fails loudly when the target file is missing" {
  skill_raw alpha "name: alpha" "description: Does a thing"
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/budget-target.json: missing"* ]] || false
}

# --- (c) per-entry limits name the file ---------------------------------------

@test "an owned entry over per_entry_max_chars fails --check and names the file" {
  skill_raw wordy "name: wordy" "description: twenty five chars exactly"  # 25 chars
  write_target 1000 0 0 0 20 100000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/wordy/SKILL.md: description is 25 chars (max 20)"* ]] || false
}

@test "a literal | description over several lines fails --check; a folded > one passes" {
  skill_raw lit  "name: lit"  "description: |" "  line one" "  line two"
  skill_raw fold "name: fold" "description: >" "  line one" "  line two"
  write_target 1000 0 0 0 5000 100000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/lit/SKILL.md: description spans more than one line"* ]] || false
  [[ "$output" != *"skills/fold/SKILL.md"* ]] || false
}

@test "a disable-model-invocation skill is exempt from the per-entry limit" {
  skill_raw off "name: off" "description: far too long for the limit" "disable-model-invocation: true"
  write_target 1000 0 0 0 5 100000
  budget --check
  [ "$status" -eq 3 ]
}

@test "an owned SKILL.md over skill_body_max_bytes fails --check and names the file" {
  skill_raw big "name: big" "description: x"
  head -c 300 /dev/zero | tr '\0' y >> "$MOCK_GRID/skills/big/SKILL.md"
  write_target 1000 0 0 0 5000 200
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/big/SKILL.md: SKILL.md is "* ]] || false
}

# --- target keys fail CLOSED (WP-046, R20.qa.F7) -----------------------------------
# Removing (or nulling) a limit from the committed target used to disable that check silently;
# a wrong schema version was never read. All three must now exit 1 and name the key.

# edit_target <python expr on d> — rewrite the mock grid's target JSON
edit_target() {
  python3 - "$MOCK_GRID/docs/budget-target.json" "$1" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path))
exec(expr)
json.dump(d, open(path, "w"))
PY
}

@test "target without per_entry_max_chars fails --check (not silently skipped)" {
  skill_raw a "name: a" "description: x"
  write_target 1000 0 0 0 5000 4000
  edit_target 'del d["per_entry_max_chars"]'
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"per_entry_max_chars"* ]] || false
}

@test "target with a null per_entry_max_chars fails --check" {
  skill_raw a "name: a" "description: x"
  write_target 1000 0 0 0 5000 4000
  edit_target 'd["per_entry_max_chars"] = None'
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"per_entry_max_chars"* ]] || false
}

@test "target without owned.skill_body_max_bytes fails --check" {
  skill_raw a "name: a" "description: x"
  write_target 1000 0 0 0 5000 4000
  edit_target 'del d["owned"]["skill_body_max_bytes"]'
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skill_body_max_bytes"* ]] || false
}

@test "target with schema 2 (or no schema) fails --check" {
  skill_raw a "name: a" "description: x"
  write_target 1000 0 0 0 5000 4000
  edit_target 'd["schema"] = 2'
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema"* ]] || false
  edit_target 'del d["schema"]'
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema"* ]] || false
}

@test "a complete target with schema 1 still passes (exit 3: baseline not measurable here)" {
  skill_raw a "name: a" "description: x"
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 3 ]
}

# --- exact limits (WP-059): the boundary itself passes, one more fails --------------

@test "a description of exactly 250 chars passes the per-entry limit; 251 fails" {
  skill_raw edge "name: edge" "description: $(head -c 250 /dev/zero | tr '\0' d)"
  write_target 1000 0 0 0 250 100000
  budget --check
  [ "$status" -eq 3 ]                      # owned scope ok; baseline not measurable here
  skill_raw edge "name: edge" "description: $(head -c 251 /dev/zero | tr '\0' d)"
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/edge/SKILL.md: description is 251 chars (max 250)"* ]] || false
}

@test "a SKILL.md of exactly 4000 bytes passes the body limit; 4001 fails" {
  skill_raw body "name: body" "description: x"
  f="$MOCK_GRID/skills/body/SKILL.md"
  size="$(wc -c < "$f" | tr -d ' ')"
  head -c $((4000 - size)) /dev/zero | tr '\0' y >> "$f"
  [ "$(wc -c < "$f" | tr -d ' ')" = 4000 ]
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 3 ]
  printf 'y' >> "$f"
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/body/SKILL.md: SKILL.md is 4001 bytes"* ]] || false
}

@test "the wire.sh child of a baseline measurement does not inherit the caller's environment" {
  # A stub wire.sh that records its environment.
  printf '#!/usr/bin/env bash\nenv > "$GRID_ENVDUMP"\n' > "$MOCK_GRID/scripts/wire.sh"
  printf 'x\n' > "$OTHER_DIR/baseline.txt"
  export GRID_BASELINE="$OTHER_DIR/baseline.txt" GRID_ENVDUMP="$OTHER_DIR/env.dump"
  export CANARY_TOKEN=canary-secret-value ANOTHER_SECRET=also-secret
  run python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts/lib")
from baseline_wired import baseline_wired
baseline_wired(sys.argv[2])' "$REPO_ROOT" "$MOCK_GRID"
  [ "$status" -eq 0 ]
  [ -s "$GRID_ENVDUMP" ]
  grep -q '^PATH=' "$GRID_ENVDUMP"
  grep -q '^GRID_DRY_HOME=' "$GRID_ENVDUMP"
  [ -z "$(grep -E 'CANARY_TOKEN|ANOTHER_SECRET' "$GRID_ENVDUMP")" ]
}

# --- sections/ integrity (budget-and-usage group 4) ------------------------------

# split_skill <name> <section file...> — a small skill with an index line per section.
split_skill() {
  local name="$1"; shift
  mkdir -p "$MOCK_GRID/skills/$name/sections"
  { printf -- '---\nname: %s\ndescription: x\n---\nbody\n\n## Sections\nRead a section only when its condition applies.\n' "$name"
    for f in "$@"; do printf -- '- sections/%s: read when needed\n' "$f"; done
  } > "$MOCK_GRID/skills/$name/SKILL.md"
  for f in "$@"; do echo "detail" > "$MOCK_GRID/skills/$name/sections/$f"; done
}

@test "a split skill whose sections are all indexed passes --check" {
  split_skill ok a.md b.md
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 3 ]
}

@test "an unreferenced sections/*.md fails --check and names the file" {
  split_skill s a.md
  echo "orphan" > "$MOCK_GRID/skills/s/sections/orphan.md"
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/s/sections/orphan.md: not listed in SKILL.md"* ]] || false
}

@test "a referenced section that does not exist fails --check and names the skill" {
  split_skill s a.md
  rm "$MOCK_GRID/skills/s/sections/a.md"
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/s/SKILL.md: lists sections/a.md but the file does not exist"* ]] || false
}

@test "a section over 6000 bytes fails --check; exactly 6000 passes" {
  split_skill s a.md
  write_target 1000 0 0 0 5000 4000
  head -c 6000 /dev/zero | tr '\0' z > "$MOCK_GRID/skills/s/sections/a.md"
  budget --check
  [ "$status" -eq 3 ]
  printf z >> "$MOCK_GRID/skills/s/sections/a.md"
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/s/sections/a.md: section is 6001 bytes"* ]] || false
}

@test "a SKILL.md over 4000 bytes fails --check even when its sections are fine" {
  split_skill s a.md
  head -c 4000 /dev/zero | tr '\0' y >> "$MOCK_GRID/skills/s/SKILL.md"
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/s/SKILL.md: SKILL.md is "* ]] || false
}

@test "a skill without sections/ under the limit passes --check" {
  skill_raw plain "name: plain" "description: x"
  write_target 1000 0 0 0 5000 4000
  budget --check
  [ "$status" -eq 3 ]
}

@test "wire.sh keeps sections/foo.md readable through the skill symlink" {
  split_skill s foo.md
  GRID_DIR="$MOCK_GRID" SKILLS_DIR="$MOCK_SKILLS" run bash "$REPO_ROOT/scripts/wire.sh"
  [ "$status" -eq 0 ]
  [ -L "$MOCK_SKILLS/s" ]
  [ "$(cat "$MOCK_SKILLS/s/sections/foo.md")" = "detail" ]
}

# --- (d) --update-target ratchet ----------------------------------------------

@test "--update-target lowers a number, and refuses to raise one without --allow-raise" {
  skill_raw alpha "name: alpha" "description: Does a thing"       # measures 21
  write_target 100 0 0 0 5000 100000
  budget --update-target
  [ "$status" -eq 0 ]
  [ "$(jget "$(cat "$MOCK_GRID/docs/budget-target.json")" owned.skills_max_chars)" = "21" ]

  write_target 5 0 0 0 5000 100000
  budget --update-target
  [ "$status" -eq 1 ]
  [[ "$output" == *"--allow-raise"* ]] || false
  # all-or-nothing: the refused run left the file untouched
  [ "$(jget "$(cat "$MOCK_GRID/docs/budget-target.json")" owned.skills_max_chars)" = "5" ]

  budget --update-target --allow-raise
  [ "$status" -eq 0 ]
  [ "$(jget "$(cat "$MOCK_GRID/docs/budget-target.json")" owned.skills_max_chars)" = "21" ]
}

@test "--update-target refuses to write a ratchet while an owned file cannot be measured (NF-055 VF5)" {
  skill_raw q "name: q" '"description": Quoted key probe text'
  write_target 100 0 0 0 250 100000
  local before
  before="$(cat "$MOCK_GRID/docs/budget-target.json")"
  budget --update-target
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/q/SKILL.md"* ]] || false
  # the refused run left the file untouched
  [ "$(cat "$MOCK_GRID/docs/budget-target.json")" = "$before" ]
}

# --- (e)(f)(i)(j) baseline scope ------------------------------------------------

@test "baseline scope is skipped (exit 3) without a baseline file" {
  skill_raw alpha "name: alpha" "description: Does a thing"
  write_target 21 0 0 0 5000 100000
  budget --check
  [ "$status" -eq 3 ]
  budget --json
  [ "$(jget "$output" baseline.skipped)" = "True" ]
}

@test "baseline scope is measured when a baseline file and a repo skill exist" {
  make_skill "$MOCK_GRID/repos/x/skills/y" "y"                     # "Test skill y": 1+12+4 = 17
  printf 'x\n' > "$OTHER_DIR/baseline.txt"
  export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  budget --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" baseline.skills.count)" = "1" ]
  [ "$(jget "$output" baseline.skills.chars)" = "17" ]
  # and baseline_wired() itself reports the skill
  run python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts/lib")
from baseline_wired import baseline_wired
r = baseline_wired(sys.argv[2]); print(r and [(e["name"], e["repo"]) for e in r])' "$REPO_ROOT" "$MOCK_GRID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"('y', 'x')"* ]] || false
}

@test "baseline is None when a submodule is uninitialised" {
  git -C "$MOCK_GRID" init -q
  printf 'x\n' > "$OTHER_DIR/baseline.txt"; export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  # a gitlink with no checkout shows as '-<sha> path' in `git submodule status`
  git -C "$MOCK_GRID" update-index --add --cacheinfo 160000,1234567890123456789012345678901234567890,repos/x
  git -C "$MOCK_GRID" config -f .gitmodules submodule.repos/x.path repos/x
  git -C "$MOCK_GRID" config -f .gitmodules submodule.repos/x.url ./nowhere
  budget --json
  [ "$(jget "$output" baseline.skipped)" = "True" ]
}

@test "a per-machine overlay does not change the baseline measurement" {
  make_skill "$MOCK_GRID/repos/x/skills/y" "y"
  make_skill "$MOCK_GRID/repos/x/skills/z" "z"
  printf 'x\n' > "$OTHER_DIR/baseline.txt"; export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  export GRID_HOST=testhost
  budget --json
  before="$output"
  [ "$(jget "$before" baseline.skills.count)" = "2" ]
  mkdir -p "$MOCK_GRID/machines"; printf -- '-x/y\n' > "$MOCK_GRID/machines/testhost.txt"
  budget --json
  [ "$output" = "$before" ]
}

@test "a baseline measurement never touches the real home (GRID_DRY_HOME honoured)" {
  H="$(mktemp -d)"
  mkdir -p "$H/.claude/skills"; echo keep > "$H/.claude/skills/sentinel"
  make_skill "$MOCK_GRID/repos/x/skills/y" "y"
  printf 'x\n' > "$OTHER_DIR/baseline.txt"; export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  snap() { ( cd "$H" && find . | LC_ALL=C sort && find . -type f -exec cat {} + ); }
  before="$(snap)"
  # Even an inherited SKILLS_DIR/AGENTS_DIR pointing into the home must be ignored.
  # PYTHONDONTWRITEBYTECODE: Apple system python writes stdlib .pyc into $HOME/Library/Caches;
  # that is the interpreter, not budget.py, touching HOME.
  HOME="$H" PYTHONDONTWRITEBYTECODE=1 SKILLS_DIR="$H/.claude/skills" AGENTS_DIR="$H/.claude/agents" budget --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" baseline.skills.count)" = "1" ]
  [ "$(snap)" = "$before" ]
  rm -rf "$H"
}

@test "the gstack runtime-root link counts as exactly one entry named gstack" {
  mkdir -p "$MOCK_GRID/repos/gstack"
  printf -- '---\nname: gstack\ndescription: Headless browser and QA.\n---\n' > "$MOCK_GRID/repos/gstack/SKILL.md"
  printf 'gstack\n' > "$OTHER_DIR/baseline.txt"; export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  budget --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" baseline.skills.count)" = "1" ]
  [ "$(jget "$output" entries.baseline_skills.0.name)" = "gstack" ]
  [ "$(jget "$output" entries.baseline_skills.0.path)" = "repos/gstack/SKILL.md" ]
}

# --- (g)(h) ---------------------------------------------------------------------

@test "a role under roles/_retired is not counted" {
  mkdir -p "$MOCK_GRID/agent-factory/roles"/{live,_retired/old}
  printf 'name: live\ntitle: Live\nsummary: Counts.\n' > "$MOCK_GRID/agent-factory/roles/live/role.yaml"
  printf 'name: old\ntitle: Old\nsummary: Does not count.\n' > "$MOCK_GRID/agent-factory/roles/_retired/old/role.yaml"
  budget --json
  [ "$(jget "$output" owned.agent_roles.count)" = "1" ]
}

@test "running twice gives identical --json output" {
  skill_raw alpha "name: alpha" "description: Does a thing"
  make_skill "$MOCK_GRID/repos/x/skills/y" "y"
  printf 'x\n' > "$OTHER_DIR/baseline.txt"; export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  budget --json; first="$output"
  budget --json; [ "$output" = "$first" ]
}

# --- frontmatter the gate cannot measure faithfully fails closed (WP-060) ------------------
# Before this, a BOM, a quoted key or an indented `---` made the description disappear from the
# measurement and --check still printed OK. Each form below must now fail by NAME. (Whether the
# real harness reads these forms as YAML is an operator check; the gate fails closed regardless.)

@test "a UTF-8 BOM before the frontmatter fails --check, naming the file and BOM" {
  mkdir -p "$MOCK_GRID/skills/bom"
  printf '\xef\xbb\xbf---\nname: bom\ndescription: %s\n---\nbody\n' "$(head -c 251 /dev/zero | tr '\0' d)" \
    > "$MOCK_GRID/skills/bom/SKILL.md"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/bom/SKILL.md: "*"BOM"* ]] || false
}

@test "a BOM-prefixed description is still measured (the total is not hidden by the failure)" {
  mkdir -p "$MOCK_GRID/skills/bom"
  printf '\xef\xbb\xbf---\nname: bom\ndescription: Does a thing\n---\nbody\n' > "$MOCK_GRID/skills/bom/SKILL.md"
  budget --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" owned.skills.chars)" = "19" ]     # 3 + 12 + 4
}

@test "invalid UTF-8 in a SKILL.md fails --check with a named message and no traceback" {
  mkdir -p "$MOCK_GRID/skills/bad"
  printf -- '---\nname: bad\ndescription: caf\xe9\n---\nbody\n' > "$MOCK_GRID/skills/bad/SKILL.md"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/bad/SKILL.md: "*"UTF-8"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
}

@test "invalid UTF-8 in a role.yaml fails --check with a named message and no traceback" {
  mkdir -p "$MOCK_GRID/agent-factory/roles/bad"
  printf 'name: bad\ndescription: caf\xe9\n' > "$MOCK_GRID/agent-factory/roles/bad/role.yaml"
  write_target 1000 1000 1000 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL agent-factory/roles/bad/role.yaml: "*"UTF-8"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
}

@test "a budget-target.json that is not an object exits non-zero with a named message, no traceback" {
  skill_raw alpha "name: alpha" "description: Does a thing"
  local body
  for body in '[]' '"x"' '3' 'null'; do
    printf '%s\n' "$body" > "$MOCK_GRID/docs/budget-target.json"
    budget --check
    echo "$body -> $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/budget-target.json must be a JSON object"* ]] || false
    [[ "$output" != *"Traceback"* ]] || false
  done
}

@test "a budget-target.json with a mistyped section or number exits non-zero, no traceback" {
  skill_raw alpha "name: alpha" "description: Does a thing"
  local body
  for body in '{"schema":1,"owned":[]}' '{"schema":1,"baseline":3}' \
              '{"schema":1,"per_entry_max_chars":"250"}' '{"schema":1,"truncate_at":"x"}' \
              '{"schema":1,"owned":{"skills_max_chars":true}}'; do
    printf '%s\n' "$body" > "$MOCK_GRID/docs/budget-target.json"
    budget --check
    echo "$body -> $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/budget-target.json"* ]] || false
    [[ "$output" != *"Traceback"* ]] || false
  done
}

@test "a deeply nested budget-target.json exits non-zero with a named message, no traceback (NF-055 VF3)" {
  skill_raw alpha "name: alpha" "description: Does a thing"
  local n=100000
  # json.load raises RecursionError (not ValueError) on nesting this deep.
  python3 -c "import sys; sys.stdout.write('[' * $n)" > "$MOCK_GRID/docs/budget-target.json"
  budget --check
  echo "$output" | head -c 600
  [ "$status" -ne 0 ]
  [[ "$output" == *"docs/budget-target.json"*"nested"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
  python3 -c "import sys; sys.stdout.write('{\"a\":' * $n)" > "$MOCK_GRID/docs/budget-target.json"
  budget --update-target
  [ "$status" -ne 0 ]
  [[ "$output" == *"docs/budget-target.json"*"nested"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
}

@test "a quoted top-level key fails --check and names the file" {
  skill_raw q "name: q" '"description": Quoted key probe text'
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/q/SKILL.md: "*"quoted"* ]] || false
}

@test "single-quoted keys fail too, and quoted VALUES stay fine" {
  skill_raw sq "name: sq" "'description': x"
  skill_raw ok "name: ok" "description: 'a quoted value'"
  write_target 1000 0 0 0 250 100000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/sq/SKILL.md: "* ]] || false
  [[ "$output" != *"skills/ok/SKILL.md"* ]] || false
}

@test "an indented --- inside a block scalar fails --check; the text after it is still counted" {
  skill_raw ind "name: ind" "description: >" "  first" "  ---" "  after"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/ind/SKILL.md: "*"---"* ]] || false
  # The block ends only at a column-0 `---`, as YAML does: "first --- after" is 15 chars.
  budget --json
  [ "$(jget "$output" entries.skills.0.listing_chars)" = "15" ]
}

@test "a duplicate top-level key fails --check and names the file and the key" {
  skill_raw dup "name: dup" "description: first" "description: second"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/dup/SKILL.md: "*"duplicate"*"description"* ]] || false
}

# WP-047: skill_frontmatter.py and the catalogue read an unclosed fence as NO frontmatter (the
# skill falls back to its directory name); measuring the body as if it were frontmatter would
# disagree with them silently, so the gate names it instead.
@test "an unclosed frontmatter fence fails --check, naming the file and the missing fence" {
  mkdir -p "$MOCK_GRID/skills/open"
  printf -- '---\nname: open\ndescription: never closed\nbody text\n' > "$MOCK_GRID/skills/open/SKILL.md"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/open/SKILL.md: "*"closing"* ]] || false
}

@test "an owned skill with no description key fails --check; a disabled one is exempt" {
  skill_raw nodesc "name: nodesc"
  skill_raw off "name: off" "disable-model-invocation: true"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/nodesc/SKILL.md: "*"no description"* ]] || false
  [[ "$output" != *"skills/off/SKILL.md"* ]] || false
}

@test "a SKILL.md with no frontmatter block fails --check and names the file" {
  mkdir -p "$MOCK_GRID/skills/plain"
  printf 'just text, no frontmatter\n' > "$MOCK_GRID/skills/plain/SKILL.md"
  write_target 1000 0 0 0 250 100000
  budget --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/plain/SKILL.md: "* ]] || false
}

@test "a role.yaml without description: fails --check and names the role" {
  mkdir -p "$MOCK_GRID/agent-factory/roles/nodesc"
  printf 'name: nodesc\ntitle: T\nsummary: S\n' > "$MOCK_GRID/agent-factory/roles/nodesc/role.yaml"
  write_target 1000 1000 1000 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL agent-factory/roles/nodesc/role.yaml: role nodesc has no description"* ]] || false
}

@test "a dangling SKILL.md or role.yaml symlink fails --check and names the path (NF-055 VF6)" {
  mkdir -p "$MOCK_GRID/skills/dang" "$MOCK_GRID/agent-factory/roles/dang"
  ln -s "$MOCK_GRID/nowhere/SKILL.md" "$MOCK_GRID/skills/dang/SKILL.md"
  ln -s "$MOCK_GRID/nowhere/role.yaml" "$MOCK_GRID/agent-factory/roles/dang/role.yaml"
  write_target 1000 1000 1000 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/dang/SKILL.md: "*"dangling"* ]] || false
  [[ "$output" == *"budget: FAIL agent-factory/roles/dang/role.yaml: "*"dangling"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
}

@test "a dangling skill directory symlink, or SKILL.md/role.yaml that is a directory, fails --check by path (NF-060 VG3)" {
  mkdir -p "$MOCK_GRID/skills/isdir/SKILL.md" "$MOCK_GRID/agent-factory/roles/isdir/role.yaml"
  ln -s "$MOCK_GRID/nowhere" "$MOCK_GRID/skills/dangdir"
  write_target 1000 1000 1000 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/dangdir/SKILL.md: "*"dangling"* ]] || false
  [[ "$output" == *"budget: FAIL skills/isdir/SKILL.md: "*"not a regular file"* ]] || false
  [[ "$output" == *"budget: FAIL agent-factory/roles/isdir/role.yaml: "*"not a regular file"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
}

@test "a baseline (upstream) skill with a quoted key only warns: the exit status is unchanged" {
  mkdir -p "$MOCK_GRID/repos/x/skills/q"
  printf -- '---\nname: q\n"description": Quoted key probe text\n---\nbody\n' > "$MOCK_GRID/repos/x/skills/q/SKILL.md"
  printf 'x\n' > "$OTHER_DIR/baseline.txt"
  export GRID_BASELINE="$OTHER_DIR/baseline.txt"
  write_target 1000 0 0 1000 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget: WARN repos/x/skills/q/SKILL.md: "*"quoted"* ]] || false
  [[ "$output" != *"FAIL"* ]] || false
}

# --- line breaks YAML does not share with str.splitlines() (NF-055 VF2) ----------------------
# splitlines() also breaks on U+0085, U+2028, U+2029, \x0b, \x0c, \x1c-\x1e, which YAML 1.2
# readers keep inside the line, so `description: short<sep><300 chars>` was measured as "short"
# and --check printed OK. The reader now splits on \n (CRLF tolerated) only and FAILS CLOSED on
# any of these characters in the frontmatter, the same stance as scripts/lib/fmshape.py.

# linebreak_cases — "label<TAB>printf escape" for every separator under test.
linebreak_cases() {
  printf '%s\t%s\n' NEL '\xc2\x85' LS '\xe2\x80\xa8' PS '\xe2\x80\xa9' VT '\x0b' FF '\x0c' \
    FS '\x1c' GS '\x1d' RS '\x1e' CR '\r'
}

@test "a line-separator character inside a SKILL.md description fails --check by name (no under-count)" {
  local label esc long
  long="$(head -c 300 /dev/zero | tr '\0' x)"
  write_target 1000 0 0 0 250 100000
  while IFS=$'\t' read -r label esc; do
    rm -rf "$MOCK_GRID/skills"; mkdir -p "$MOCK_GRID/skills/sep"
    # shellcheck disable=SC2059   # the escape is the point
    printf -- "---\nname: sep\ndescription: short${esc}${long}\n---\nbody\n" > "$MOCK_GRID/skills/sep/SKILL.md"
    budget --check
    echo "$label -> $status $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"budget: FAIL skills/sep/SKILL.md: "*"line"* ]] || false
    [[ "$output" != *"Traceback"* ]] || false
  done < <(linebreak_cases)
}

@test "a line-separator character in a role.yaml fails --check by name" {
  local label esc
  write_target 1000 1000 1000 0 250 100000
  while IFS=$'\t' read -r label esc; do
    rm -rf "$MOCK_GRID/agent-factory"; mkdir -p "$MOCK_GRID/agent-factory/roles/sep"
    # shellcheck disable=SC2059
    printf -- "name: sep\ndescription: short${esc}name: other\n" > "$MOCK_GRID/agent-factory/roles/sep/role.yaml"
    budget --check
    echo "$label -> $status $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"budget: FAIL agent-factory/roles/sep/role.yaml: "*"line"* ]] || false
  done < <(linebreak_cases)
}

@test "a separator that only hides the closing fence is still reported (the region is cut on \\n alone)" {
  # `---` after U+2028 is column 0 to a YAML 1.1 reader, mid-line to a \n-only one: the two
  # disagree about where the frontmatter ends, so the gate must not pick one silently.
  mkdir -p "$MOCK_GRID/skills/fence"
  printf -- '---\nname: fence\ndescription: short\xe2\x80\xa8---\nbody\n' > "$MOCK_GRID/skills/fence/SKILL.md"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"budget: FAIL skills/fence/SKILL.md: "* ]] || false
}

@test "separators in the BODY (after the closing fence) do not matter; CRLF line endings still measure" {
  mkdir -p "$MOCK_GRID/skills/body" "$MOCK_GRID/skills/crlf"
  printf -- '---\nname: body\ndescription: Does a thing\n---\nbody\xe2\x80\xa8more\x0cstill\n' > "$MOCK_GRID/skills/body/SKILL.md"
  printf -- '---\r\nname: crlf\r\ndescription: Does a thing\r\n---\r\nbody\r\n' > "$MOCK_GRID/skills/crlf/SKILL.md"
  write_target 1000 0 0 0 250 100000
  budget --check
  echo "$output"
  [ "$status" -eq 3 ] || [ "$status" -eq 0 ]
  [[ "$output" != *"FAIL"* ]] || false
  budget --json
  [ "$(jget "$output" entries.skills.0.listing_chars)" = "12" ]     # body
  [ "$(jget "$output" entries.skills.1.listing_chars)" = "12" ]     # crlf: no stray \r counted
}

# --- fence-adjacent separators (NF-060 VG2) ---------------------------------------------------
# A separator glued to a fence line (`---<sep>`) is not a fence to a reader that cuts on \n
# alone, but IS one to a reader that also breaks on it. Whichever side it sits on, the file
# must fail --check by name (never measure silently, never a traceback).

# fence_seps — printf escapes for the separators that can sit next to `---`.
fence_seps() { printf '%s\n' '\x0b' '\x0c' '\xc2\x85' '\xe2\x80\xa8' '\xe2\x80\xa9' '\x1c'; }

@test "a separator after the OPENING fence fails --check by name for every separator" {
  local esc
  write_target 1000 0 0 0 250 100000
  while IFS= read -r esc; do
    rm -rf "$MOCK_GRID/skills"; mkdir -p "$MOCK_GRID/skills/open"
    # shellcheck disable=SC2059   # the escape is the point
    printf -- "---${esc}\nname: open\ndescription: Does a thing\n---\nbody\n" > "$MOCK_GRID/skills/open/SKILL.md"
    budget --check
    echo "$esc -> $status $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"budget: FAIL skills/open/SKILL.md: "* ]] || false
    [[ "$output" != *"Traceback"* ]] || false
  done < <(fence_seps)
}

@test "a separator after the CLOSING fence fails --check by name for every separator" {
  local esc
  write_target 1000 0 0 0 250 100000
  while IFS= read -r esc; do
    rm -rf "$MOCK_GRID/skills"; mkdir -p "$MOCK_GRID/skills/close"
    # shellcheck disable=SC2059
    printf -- "---\nname: close\ndescription: Does a thing\n---${esc}\nbody\n" > "$MOCK_GRID/skills/close/SKILL.md"
    budget --check
    echo "$esc -> $status $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"budget: FAIL skills/close/SKILL.md: "* ]] || false
    [[ "$output" != *"Traceback"* ]] || false
  done < <(fence_seps)
}

# --- a long whitespace run must not hang the scalar reader (NF-060 VG1) ---------------------
# The comment strip was `re.sub(r"\s+#.*$", ...)`, quadratic on a long whitespace run (a 1 MB
# run took over 100 s). It is a linear scan now; these run under `timeout 5` so a regression is
# a failure (status 124), not a hung CI job.

@test "a 1 MB whitespace run inside a SKILL.md description finishes in under 5 s" {
  local variant
  write_target 5000000 0 0 0 5000000 100000
  mkdir -p "$MOCK_GRID/skills/ws"
  for variant in plain comment continuation; do
    case "$variant" in
      plain)        python3 -c 'import sys; sys.stdout.write("---\nname: ws\ndescription: a" + " " * (1 << 20) + "b\n---\nbody\n")' ;;
      comment)      python3 -c 'import sys; sys.stdout.write("---\nname: ws\ndescription: a" + " " * (1 << 20) + "# c\n---\nbody\n")' ;;
      continuation) python3 -c 'import sys; sys.stdout.write("---\nname: ws\ndescription: a\n  b" + " " * (1 << 20) + "c\n---\nbody\n")' ;;
    esac > "$MOCK_GRID/skills/ws/SKILL.md"
    GRID_DIR="$MOCK_GRID" run timeout 5 python3 "$BUDGET" --check
    echo "$variant -> $status"
    [ "$status" -ne 124 ]
    [[ "$output" != *"Traceback"* ]] || false
  done
}

@test "a 1 MB whitespace run inside a role.yaml description finishes in under 5 s" {
  write_target 0 5000000 5000000 0 5000000 100000
  mkdir -p "$MOCK_GRID/agent-factory/roles/ws"
  python3 -c 'import sys; sys.stdout.write("name: ws\ndescription: a" + " " * (1 << 20) + "b\n")' > "$MOCK_GRID/agent-factory/roles/ws/role.yaml"
  GRID_DIR="$MOCK_GRID" run timeout 5 python3 "$BUDGET" --check
  echo "$status"
  [ "$status" -ne 124 ]
  [[ "$output" != *"Traceback"* ]] || false
}

@test "comment stripping keeps its meaning: ' #' and tab-# end the value, a bare # or '#' first does not" {
  skill_raw c1 "name: c1" "description: keep this # drop this"        # "keep this"           = 9
  skill_raw c2 "name: c2" $'description: keep	# drop this'            # tab before #: "keep" = 4
  skill_raw c3 "name: c3" "description: a#b stays"                     # no space before #     = 9
  skill_raw c4 "name: c4" "description: x   #   # y"                  # first # wins: "x"    = 1
  skill_raw c5 "name: c5" "description: a#b # c"                       # glued # is skipped, the later " #" ends it: "a#b" = 3
  budget --json
  [ "$status" -eq 0 ]
  [ "$(jget "$output" entries.skills.0.listing_chars)" = "9" ]
  [ "$(jget "$output" entries.skills.1.listing_chars)" = "4" ]
  [ "$(jget "$output" entries.skills.2.listing_chars)" = "9" ]
  [ "$(jget "$output" entries.skills.3.listing_chars)" = "1" ]
  [ "$(jget "$output" entries.skills.4.listing_chars)" = "3" ]
}

# --- the real repo --------------------------------------------------------------

@test "the real repo passes its own committed target on the example baseline (exit 0, or 3 when submodules are uninitialised)" {
  # Pinned to the TRACKED example baseline, never the developer's own (a personal baseline
  # has no business deciding this test; R16.qa.F9). 3 = baseline half not measurable here.
  run env -u GRID_DIR GRID_BASELINE="$REPO_ROOT/baseline-submodules.example.txt" python3 "$BUDGET" --check
  echo "$output"
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

@test "the committed target carries a real baseline ratchet, not 0 (WP-046, D64)" {
  # baseline.skills_max_chars: 0 made the check fail wherever it could measure the baseline.
  run python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["baseline"]["skills_max_chars"] > 0 else 1)' "$REPO_ROOT/docs/budget-target.json"
  [ "$status" -eq 0 ]
}

# --- owned skill descriptions (budget-and-usage group 3) ------------------------

@test "every listed owned skill description is one line, <= 250 chars, with no 'invokes /'" {
  # Real repo, read-only. Listed = no `disable-model-invocation: true` in frontmatter.
  run python3 - "$REPO_ROOT" <<'PY'
import glob, re, sys
bad = []
for p in sorted(glob.glob(sys.argv[1] + "/skills/*/SKILL.md")):
    text = open(p, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    fm = m.group(1) if m else ""
    if re.search(r"^disable-model-invocation:\s*true\s*$", fm, re.M):
        continue  # not listed, exempt
    lines = fm.split("\n")
    idx = [i for i, l in enumerate(lines) if l.startswith("description:")]
    if not idx:
        bad.append(p + ": no description")
        continue
    i = idx[0]
    desc = lines[i][len("description:"):].strip()
    # One line means a value on the key line and no folded or indented continuation.
    if not desc or desc in (">", ">-", "|", "|-") or (i + 1 < len(lines) and lines[i + 1][:1] in (" ", "\t")):
        bad.append(p + ": description is not a single line")
    if len(desc) > 250:
        bad.append("%s: description is %d chars" % (p, len(desc)))
    if "invokes /" in desc:
        bad.append(p + ": contains 'invokes /'")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}
