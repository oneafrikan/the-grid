#!/usr/bin/env bats
# Tests for compose.py role lint + --check. Needs the agent-factory venv
# (PyYAML); skipped where it isn't built. Bad roles are injected through
# GRID_PRIVATE_ROLES_DIR so the real roles/ tree is never touched.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  COMPOSE="$REPO_ROOT/agent-factory/compose.py"
  PRIV=$(mktemp -d)
  export GRID_PRIVATE_ROLES_DIR="$PRIV"
}

teardown() {
  rm -rf "$PRIV"
  unset GRID_PRIVATE_ROLES_DIR GRID_AUTHORED_ROLES_FILE
  common_teardown
}

# make_role <name> — a minimal valid role in the private tree
make_role() {
  mkdir -p "$PRIV/$1"
  printf 'name: %s\ntitle: T\nsummary: S.\ndefault_model: sonnet\norchestrator: false\n' "$1" > "$PRIV/$1/role.yaml"
  printf '# soul\n' > "$PRIV/$1/SOUL.md"
  printf '# skill\n' > "$PRIV/$1/SKILL.md"
}

@test "lint-roles passes on the real roles plus a valid injected role" {
  make_role good
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "lint-roles: name that differs from the directory is E_NAME_MISMATCH" {
  make_role bad
  sed -i.bak 's/^name: bad/name: other/' "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_NAME_MISMATCH: bad/role.yaml"* ]] || false
}

@test "lint-roles: invalid model is E_MODEL_INVALID" {
  make_role bad
  sed -i.bak 's/sonnet/gpt9/' "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_MODEL_INVALID: bad/role.yaml"* ]] || false
}

@test "lint-roles: typo'd key is E_FIELD_UNKNOWN" {
  make_role bad
  echo 'sumary: oops' >> "$PRIV/bad/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FIELD_UNKNOWN"* ]] || false
}

@test "lint-roles: missing and empty required files are named" {
  make_role bad
  rm "$PRIV/bad/SOUL.md"
  : > "$PRIV/bad/SKILL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_FILE_MISSING: bad/SOUL.md"* ]] || false
  [[ "$output" == *"E_FILE_EMPTY: bad/SKILL.md"* ]] || false
}

@test "lint-roles: unresolved placeholder is E_TOKEN_UNRESOLVED" {
  make_role bad
  echo 'Hello {{NAME}}' >> "$PRIV/bad/SOUL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_TOKEN_UNRESOLVED: bad/SOUL.md"* ]] || false
}

@test "compose aborts naming the broken role when a config uses it" {
  make_role bad
  : > "$PRIV/bad/SKILL.md"
  printf 'project: t\nagents:\n  - role: bad\n' > "$OTHER_DIR/c.yaml"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"E_FILE_EMPTY"* ]] || false
  [ ! -e "$OTHER_DIR/out" ]    # fail-closed: nothing half-written
}

@test "compose --check fails on a stale file and does not repair it" {
  make_role r1
  printf 'project: t\nagents:\n  - role: r1\n' > "$OTHER_DIR/c.yaml"
  "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out" --check
  [ "$status" -eq 0 ]
  echo "tampered" >> "$OTHER_DIR/out/t/_claude-code/agents/t-r1.md"
  run "$PY" "$COMPOSE" "$OTHER_DIR/c.yaml" --target claude-code --out "$OTHER_DIR/out" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale"* ]] || false
  grep -q tampered "$OTHER_DIR/out/t/_claude-code/agents/t-r1.md"   # still tampered
}

@test "lint-roles ignores an archive dir (_retired) so retired roles can't break the gate" {
  mkdir -p "$PRIV/_retired/old-role"          # deliberately malformed: empty dir
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

# --- authoring contract (docs/role-authoring.md) --------------------------------

# make_authored_role <name> — a role that satisfies the authoring contract
make_authored_role() {
  make_role "$1"
  cat > "$PRIV/$1/AGENTS.md" <<EOT
# Operating Rules
## Scope
Owns things.
## What to get right hardest
1. a
2. b
3. c
4. d
## Hard rules
- one: verify before claiming, with the command and its evidence
- two: say what is planned and not yet built
- three: paste failing output verbatim
- four: use an independent check and say who
## Receiving work
- x
EOT
  cat > "$PRIV/$1/SOUL.md" <<EOT
# Soul
## Role identity
x
## Core character (role layer)
x
## Decision-making (role layer)
x
## Escalation rules (role layer)
x
## Working style (role layer)
x
## What the T is NOT
x
EOT
  printf '%s\n' "$1" > "$OTHER_DIR/authored.txt"
  export GRID_AUTHORED_ROLES_FILE="$OTHER_DIR/authored.txt"
}

@test "authoring lint passes a role that meets the contract" {
  make_authored_role good
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "authoring lint: missing Hard rules section is E_SECTION_MISSING" {
  make_authored_role bad
  sed -i.bak '/^## Hard rules/,/^- four/d' "$PRIV/bad/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SECTION_MISSING: bad/AGENTS.md"* ]] || false
}

@test "authoring lint: ranked list shorter than 4 is E_SECTION_SHAPE" {
  make_authored_role bad
  sed -i.bak '/^4\. d$/d' "$PRIV/bad/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SECTION_SHAPE"* ]] || false
}

@test "authoring lint: oversized AGENTS.md is E_SIZE" {
  make_authored_role bad
  head -c 5000 /dev/zero | tr '\0' 'x' >> "$PRIV/bad/AGENTS.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SIZE"* ]] || false
}

@test "authoring lint: missing SOUL heading is named" {
  make_authored_role bad
  sed -i.bak '/^## Working style/,/^x$/d' "$PRIV/bad/SOUL.md"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_SECTION_MISSING: bad/SOUL.md"* ]] || false
}

@test "authoring lint ignores roles not on the authored list" {
  make_role loose                     # no AGENTS.md at all
  printf 'someone-else\n' > "$OTHER_DIR/authored.txt"
  export GRID_AUTHORED_ROLES_FILE="$OTHER_DIR/authored.txt"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

# --- private roles default location ---------------------------------------------

@test "private roles are picked up from ~/.the-grid-private/roles when the env var is unset" {
  fakehome=$(mktemp -d)
  mkdir -p "$fakehome/.the-grid-private/roles/zz-private"
  printf 'name: zz-private\ntitle: T\nsummary: S.\ndefault_model: sonnet\n' > "$fakehome/.the-grid-private/roles/zz-private/role.yaml"
  # no SOUL.md/SKILL.md: if the dir is picked up, lint must complain about it
  unset GRID_PRIVATE_ROLES_DIR
  HOME="$fakehome" run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 1 ]
  [[ "$output" == *"zz-private"* ]] || false
  rm -rf "$fakehome"
}

@test "an EMPTY GRID_PRIVATE_ROLES_DIR disables the fallback" {
  fakehome=$(mktemp -d)
  mkdir -p "$fakehome/.the-grid-private/roles/zz-private"
  GRID_PRIVATE_ROLES_DIR= HOME="$fakehome" run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
  rm -rf "$fakehome"
}

# bare_names: true names Claude Code skills/agents '<role>'; default keeps '<slug>-<role>'.
@test "bare_names drops the slug prefix for claude-code output; default keeps it" {
  cfg=$(mktemp -d)
  out=$(mktemp -d)
  printf 'project: bn\nslug: bn\nbare_names: true\nagents:\n  - role: morpheus\n' > "$cfg/bare.yaml"
  printf 'project: pfx\nslug: pfx\nagents:\n  - role: morpheus\n' > "$cfg/pfx.yaml"
  run "$PY" "$COMPOSE" "$cfg/bare.yaml" --target claude-code --out "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/bn/_claude-code/skills/morpheus/SKILL.md" ]
  run "$PY" "$COMPOSE" "$cfg/pfx.yaml" --target claude-code --out "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/pfx/_claude-code/skills/pfx-morpheus/SKILL.md" ]
  rm -rf "$cfg" "$out"
}

# per-agent bare: true bare-names only that agent; its siblings keep the slug prefix.
@test "per-agent bare names one agent and leaves siblings prefixed" {
  cfg=$(mktemp -d)
  out=$(mktemp -d)
  printf 'project: mix\nslug: mix\nagents:\n  - role: morpheus\n    bare: true\n  - role: tank\n' > "$cfg/mix.yaml"
  run "$PY" "$COMPOSE" "$cfg/mix.yaml" --target claude-code --out "$out"
  [ "$status" -eq 0 ]
  [ -f "$out/mix/_claude-code/skills/morpheus/SKILL.md" ]
  [ -f "$out/mix/_claude-code/agents/mix-tank.md" ]
  rm -rf "$cfg" "$out"
}

# Skill description only mentions dev-team coordination for orchestrators that have reports.
@test "orchestrator skill description omits the dev-team line when it delegates to no one" {
  cfg=$(mktemp -d)
  out=$(mktemp -d)
  printf 'project: dd\nslug: dd\nagents:\n  - role: morpheus\n' > "$cfg/dd.yaml"
  run "$PY" "$COMPOSE" "$cfg/dd.yaml" --target claude-code --out "$out"
  [ "$status" -eq 0 ]
  ! grep -q 'dev-team feature' "$out/dd/_claude-code/skills/dd-morpheus/SKILL.md" || false
  rm -rf "$cfg" "$out"
}

# An authored role (listed in the authored-roles file) with a malformed role.yaml: lint_role
# reports E_YAML_PARSE, and lint_authoring must not crash on the same file with a traceback
# (it re-reads role.yaml via role_meta). Injected through the private tree and the
# GRID_AUTHORED_ROLES_FILE override so the real roles and authored list are untouched.
# Same, when role.yaml parses fine but to a non-mapping (a bare string, a list): lint_role
# reports E_YAML_SHAPE and lint_authoring must not call .get on it.
@test "lint-roles: an authored role whose role.yaml is a string or a list reports E_YAML_SHAPE, no traceback" {
  make_role shaped
  printf '# agents\n' > "$PRIV/shaped/AGENTS.md"
  printf 'shaped\n' > "$PRIV/authored.txt"
  export GRID_AUTHORED_ROLES_FILE="$PRIV/authored.txt"
  local body
  for body in 'just a string' '- a
- list'; do
    printf '%s\n' "$body" > "$PRIV/shaped/role.yaml"
    run "$PY" "$COMPOSE" --lint-roles
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"E_YAML_SHAPE"* ]] || false
    [[ "$output" != *"Traceback"* ]] || false
  done
}

@test "lint-roles: an authored role with malformed role.yaml reports E_YAML_PARSE, no traceback" {
  make_role broken
  printf '# agents\n' > "$PRIV/broken/AGENTS.md"
  printf 'name: [\n' > "$PRIV/broken/role.yaml"
  printf 'broken\n' > "$PRIV/authored.txt"
  export GRID_AUTHORED_ROLES_FILE="$PRIV/authored.txt"
  run "$PY" "$COMPOSE" --lint-roles
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_YAML_PARSE"* ]] || false
  [[ "$output" != *"Traceback"* ]] || false
}

# ---- WP-050: project / role names, duplicates, private roles dir, paperclip leads -------

# cfg_with_project <yaml scalar> — a one-agent config whose `project:` is the given YAML text
cfg_with_project() {
  CFG=$(mktemp -d)/c.yaml
  printf 'project: %s\nslug: zz\nagents:\n  - role: morpheus\n' "$1" > "$CFG"
}

@test "an unsafe or malformed project name exits non-zero, in every mode, and writes nothing" {
  # Nested, and with TMPDIR pointed inside the sandbox too (--check renders into a temp dir):
  # an unvalidated ".." can then only reach this test's own tree, never /tmp itself.
  local sb out bad t; sb=$(mktemp -d)
  out="$sb/a/b/out"
  mkdir -p "$out" "$sb/a/b/tmp"
  # YAML scalars: parent/current dir, a path, upper case, a trailing newline (re.match's `$`
  # would let it through), empty, a number, a list, over-long.
  for bad in '..' '.' 'a/b' '../victim' 'Up' '"x\n"' '""' '123' '[a]' "$(printf 'a%.0s' $(seq 1 70))"; do
    cfg_with_project "$bad"
    for t in openclaw claude-code codex portable paperclip; do
      TMPDIR="$sb/a/b/tmp" run "$PY" "$COMPOSE" "$CFG" --target "$t" --out "$out"
      echo "project=$bad target=$t: $output"
      [ "$status" -ne 0 ]
      [[ "$output" != *"Traceback"* ]]
    done
    TMPDIR="$sb/a/b/tmp" run "$PY" "$COMPOSE" "$CFG" --check --out "$out"
    [ "$status" -ne 0 ]
    TMPDIR="$sb/a/b/tmp" run "$PY" "$COMPOSE" "$CFG" --dry-run --out "$out"
    [ "$status" -ne 0 ]
    rm -rf "$(dirname "$CFG")"
  done
  [ -z "$(ls -A "$out")" ]
  [ -z "$(ls -A "$sb/a/b/tmp")" ]
  [ "$(ls "$sb/a/b" | sort | tr '\n' ' ')" = "out tmp " ]
  rm -rf "$sb"
}

@test "a valid kebab-case project still composes" {
  local out; out=$(mktemp -d)
  cfg_with_project 'my-proj1'
  run "$PY" "$COMPOSE" "$CFG" --target claude-code --out "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$out/my-proj1/_claude-code" ]
  rm -rf "$out" "$(dirname "$CFG")"
}

@test "a trailing newline in slug is rejected like any other bad slug" {
  local cfg; cfg=$(mktemp -d)/c.yaml
  printf 'project: zz\nslug: "ab\\n"\nagents:\n  - role: morpheus\n' > "$cfg"
  run "$PY" "$COMPOSE" "$cfg" --target claude-code --out "$(dirname "$cfg")/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"slug"* ]]
  rm -rf "$(dirname "$cfg")"
}

@test "a role listed twice exits 1 naming both entries; so does a bare-name collision" {
  local d; d=$(mktemp -d)
  printf 'project: zz\nslug: zz\nagents:\n  - role: morpheus\n  - role: oracle\n  - role: morpheus\n' > "$d/dup.yaml"
  run "$PY" "$COMPOSE" "$d/dup.yaml" --target claude-code --out "$d/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agents[0]"* ]]
  [[ "$output" == *"agents[2]"* ]]
  [[ "$output" == *"morpheus"* ]]
  [ ! -e "$d/out" ]
  # Two different roles whose composed Claude Code names collide: 'zz-<foo>' bare vs slug-prefixed.
  make_role foo
  make_role zz-foo
  printf 'project: zz\nslug: zz\nagents:\n  - role: foo\n  - role: zz-foo\n    bare: true\n' > "$d/clash.yaml"
  run "$PY" "$COMPOSE" "$d/clash.yaml" --target claude-code --out "$d/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zz-foo"* ]]
  [[ "$output" == *"agents[0]"* ]]
  [[ "$output" == *"agents[1]"* ]]
  [ ! -e "$d/out" ]
  rm -rf "$d"
}

@test "role names that are not a plain lower-case name give E_ROLE_NAME and are never looked up" {
  local d bad; d=$(mktemp -d)
  # A fully valid role one level down: a path-shaped name that reaches it must still be refused
  # (PRIV/sub/good exists, so the old code found a directory there and went on to read it).
  make_role good
  mkdir -p "$PRIV/sub"
  cp -R "$PRIV/good" "$PRIV/sub/good"
  for bad in 'Up_Case' '"sp ace"' '"../x"' '"a/b"' '"sub/good"' '"x\n"' '"-lead"' '[a]' '12'; do
    printf 'project: zz\nslug: zz\nagents:\n  - role: %s\n' "$bad" > "$d/c.yaml"
    run "$PY" "$COMPOSE" "$d/c.yaml" --target claude-code --out "$d/out"
    echo "role=$bad: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"E_ROLE_NAME"* ]]
    [[ "$output" != *"Traceback"* ]]
  done
  [ ! -e "$d/out" ]
  rm -rf "$d"
}

@test "lint-roles: a role directory with an unsafe name is E_ROLE_NAME" {
  make_role Up_Case
  make_role "sp ace"
  run "$PY" "$COMPOSE" --lint-roles
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_ROLE_NAME: Up_Case"* ]]
  [[ "$output" == *"E_ROLE_NAME: sp ace"* ]]
}

@test "a non-empty GRID_PRIVATE_ROLES_DIR that is not a directory is a hard error" {
  local d; d=$(mktemp -d)
  printf 'x\n' > "$d/afile"
  for p in "$d/nonexistent" "$d/afile"; do
    GRID_PRIVATE_ROLES_DIR="$p" run "$PY" "$COMPOSE" --lint-roles
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GRID_PRIVATE_ROLES_DIR not found: $p"* ]]
    [[ "$output" != *"Traceback"* ]]
  done
  rm -rf "$d"
}

@test "paperclip: a config without the apex or any lead exits with a clean message, not a KeyError" {
  local d t; d=$(mktemp -d)
  for t in finance-desk learning-desk core; do
    run "$PY" "$COMPOSE" "$REPO_ROOT/agent-factory/examples/$t.yaml" --target paperclip --out "$d"
    echo "$t: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"paperclip needs"* ]]
    [[ "$output" != *"KeyError"* ]]
    [[ "$output" != *"Traceback"* ]]
    run "$PY" "$COMPOSE" "$REPO_ROOT/agent-factory/examples/$t.yaml" --target paperclip --dry-run --out "$d"
    [ "$status" -ne 0 ]
    [[ "$output" != *"Traceback"* ]]
  done
  [ -z "$(ls -A "$d")" ]
  rm -rf "$d"
}

@test "paperclip: a config with the apex and only some leads composes the leads it has" {
  local d; d=$(mktemp -d)
  printf 'project: zz\nslug: zz\nagents:\n  - role: ceo-orchestrator\n    delegates_to: [tech-lead]\n  - role: tech-lead\n    delegates_to: []\n' > "$d/c.yaml"
  run "$PY" "$COMPOSE" "$d/c.yaml" --target paperclip --out "$d/out"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$d/out/zz/_paperclip/manifest.json" ]
  grep -q '"role": "tech-lead"' "$d/out/zz/_paperclip/manifest.json"
  rm -rf "$d"
}

# ---- WP-051: tool names and description text ----------------------------------------------

@test "lint-roles: a tool name outside the known eight is E_TOOL_UNKNOWN (case-sensitive)" {
  local bad
  for bad in Task Frobnicate read bash 'Read '; do
    make_role zz-t
    printf 'tools: ["%s"]\n' "$bad" >> "$PRIV/zz-t/role.yaml"
    run "$PY" "$COMPOSE" --lint-roles
    echo "tool=$bad: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"E_TOOL_UNKNOWN: zz-t/role.yaml"* ]]
    rm -rf "$PRIV/zz-t"
  done
  make_role zz-t
  printf 'tools: [Read, Grep, Glob, Bash, Edit, Write, WebFetch, WebSearch]\n' >> "$PRIV/zz-t/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "lint-roles: a control character in description, title or summary is E_TEXT_CONTROL" {
  local key
  for key in description title summary; do
    make_role zz-c
    # title and summary already exist (make_role); a duplicate YAML key is an error, so drop
    # the line before appending the bad one.
    awk -v k="$key" '$0 !~ "^" k ":"' "$PRIV/zz-c/role.yaml" > "$PRIV/zz-c/role.new"
    mv "$PRIV/zz-c/role.new" "$PRIV/zz-c/role.yaml"
    printf '%s: "bad\\x07text"\n' "$key" >> "$PRIV/zz-c/role.yaml"
    run "$PY" "$COMPOSE" --lint-roles
    echo "key=$key: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"E_TEXT_CONTROL: zz-c/role.yaml"* ]]
    [[ "$output" == *"$key"* ]]
    rm -rf "$PRIV/zz-c"
  done
  # Tab and newline are fine.
  make_role zz-c
  printf 'description: "tab\\there"\n' >> "$PRIV/zz-c/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}

@test "lint-roles: a description over 250 chars is a warning that does not fail the run" {
  make_role zz-long
  printf 'description: %s\n' "$(printf 'x%.0s' $(seq 1 251))" >> "$PRIV/zz-long/role.yaml"
  make_role zz-edge
  printf 'description: %s\n' "$(printf 'x%.0s' $(seq 1 250))" >> "$PRIV/zz-edge/role.yaml"
  run "$PY" "$COMPOSE" --lint-roles
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"W_DESCRIPTION_LONG: zz-long/role.yaml"* ]]
  [[ "$output" != *"W_DESCRIPTION_LONG: zz-edge"* ]]
}

# ---- NF-042: `stacks:` / `skills:` names are validated before they become read paths ------

# cfg_with_list <key> <yaml flow-list text> — a one-agent config with stacks:/skills: set
cfg_with_list() {
  CFG=$(mktemp -d)/c.yaml
  printf 'project: zz\nslug: zz\nagents:\n  - role: morpheus\n    %s: %s\n' "$1" "$2" > "$CFG"
}

@test "NF-042: unsafe stacks:/skills: names are refused in every mode, with a stable code" {
  local sb out bad key t; sb=$(mktemp -d)
  out="$sb/out"; mkdir -p "$out"
  # parent dir, current dir, absolute, separators, backslash, empty, NUL, newline/control,
  # upper case, a non-string, a nested list, over-long.
  for key in stacks skills; do
    for bad in '".."' '"."' '"/etc"' '"a/b"' '"../victim"' '"a\\b"' '""' '"a\0b"' '"x\n"' '"a\tb"' '"a\u001bb"' '"Up"' '123' '[a]' "\"$(printf 'a%.0s' $(seq 1 70))\""; do
      cfg_with_list "$key" "[$bad]"
      for t in --check --dry-run; do
        run "$PY" "$COMPOSE" "$CFG" $t --out "$out"
        echo "$key=$bad $t: $output"
        [ "$status" -ne 0 ]
        [[ "$output" != *"Traceback"* ]]
      done
      run "$PY" "$COMPOSE" "$CFG" --target claude-code --out "$out"
      [ "$status" -ne 0 ]
      [[ "$output" != *"Traceback"* ]]
      if [ "$key" = stacks ]; then [[ "$output" == *"E_STACK_NAME"* ]]; else [[ "$output" == *"E_SKILL_NAME"* ]]; fi
      rm -rf "$(dirname "$CFG")"
    done
  done
  # a bare scalar (not a list) is refused too, and nothing was written
  cfg_with_list stacks '"../x"'
  run "$PY" "$COMPOSE" "$CFG" --check --out "$out"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$out")" ]
  rm -rf "$sb" "$(dirname "$CFG")"
}

@test "NF-042: a well-formed stack name that does not exist is still the old not-found error" {
  cfg_with_list stacks '[no-such-stack]'
  run "$PY" "$COMPOSE" "$CFG" --check --out "$(dirname "$CFG")/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-stack"* ]]
  [[ "$output" != *"E_STACK_NAME"* ]]
  rm -rf "$(dirname "$CFG")"
}

@test "NF-042: a shipped stack name still composes" {
  local out; out=$(mktemp -d)
  cfg_with_list stacks '[lamp]'
  run "$PY" "$COMPOSE" "$CFG" --target claude-code --out "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  rm -rf "$out" "$(dirname "$CFG")"
}

@test "NF-042: a stack fragment outside its stack dir is refused, not read" {
  local sb; sb=$(mktemp -d)
  mkdir -p "$sb/stacks/evil"
  printf 'secret-canary\n' > "$sb/outside.md"
  printf 'name: evil\nfragments: [../../outside.md]\n' > "$sb/stacks/evil/stack.yaml"
  run env SB="$sb" REPO_ROOT="$REPO_ROOT" "$PY" -c '
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/agent-factory")
from pathlib import Path
import compose
compose.STACKS_DIR = Path(os.environ["SB"]) / "stacks"
print(compose.render_stack_overlay(["evil"]))'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"E_STACK_FRAGMENT"* ]]
  [[ "$output" != *"secret-canary"* ]]
  rm -rf "$sb"
}

# A stacks:/skills: value that is not a list is reported (with the stable code), never iterated:
# a bare string would otherwise be walked character by character, a number would crash.
@test "H-08: a non-list stacks:/skills: value is refused with a message, not iterated or crashed on" {
  local key bad out; out=$(mktemp -d)
  for key in stacks skills; do
    for bad in lamp 5 '{a: b}' 'true'; do
      cfg_with_list "$key" "$bad"
      run "$PY" "$COMPOSE" "$CFG" --check --out "$out"
      echo "$key=$bad: $output"
      [ "$status" -ne 0 ]
      [[ "$output" != *"Traceback"* ]]
      [[ "$output" == *"\`$key\` must be a list of names"* ]]
      if [ "$key" = stacks ]; then [[ "$output" == *"E_STACK_NAME"* ]]; else [[ "$output" == *"E_SKILL_NAME"* ]]; fi
      [[ "$output" != *"has no dir at"* ]]
      rm -rf "$(dirname "$CFG")"
    done
  done
  rm -rf "$out"
}

# A stack or skill dir that is (or sits under) a symlink would pull content from outside the repo.
@test "H-08: a symlinked stack dir, skills dir, or stacks/ root is refused, not followed" {
  local sb; sb=$(mktemp -d)
  mkdir -p "$sb/real/lamp" "$sb/stacks" "$sb/skills/ok"
  printf 'name: lamp\n' > "$sb/real/lamp/stack.yaml"
  ln -s "$sb/real/lamp" "$sb/stacks/lnk"             # one linked stack dir
  mkdir "$sb/stacks/plain"
  ln -s "$sb/real" "$sb/stacks-root"                 # a linked stacks/ root
  ln -s "$sb/skills/ok" "$sb/skills/lnk"             # one linked skill dir
  run env SB="$sb" REPO_ROOT="$REPO_ROOT" "$PY" - <<'PYEOF'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["REPO_ROOT"] + "/agent-factory")
import compose
sb = Path(os.environ["SB"])
def verdict(key, base, name):
    compose.STACKS_DIR, compose.SKILLS_DIR = (base, compose.SKILLS_DIR) if key == "stacks" else (compose.STACKS_DIR, base)
    cfg = sb / "c.yaml"                       # inside the sandbox dir the test removes
    cfg.write_text(f"project: zz\nslug: zz\nagents:\n  - role: morpheus\n    {key}: [{name}]\n")
    try:
        compose.load_config(cfg)
    except ValueError as e:
        return str(e)
    return "ACCEPTED"
real_stacks, real_skills = compose.STACKS_DIR, compose.SKILLS_DIR
(sb / "stacks" / "plain").joinpath("stack.yaml").write_text("name: plain\n")
assert "symlink" in verdict("stacks", sb / "stacks", "lnk"), "linked stack dir accepted"
assert "symlink" in verdict("skills", sb / "skills", "lnk"), "linked skill dir accepted"
assert "symlink" in verdict("stacks", sb / "stacks-root", "lamp"), "linked stacks/ root accepted"
assert verdict("stacks", sb / "stacks", "plain") == "ACCEPTED", "a plain stack dir is refused"
assert verdict("skills", sb / "skills", "ok") == "ACCEPTED", "a plain skill dir is refused"
print("ok")
PYEOF
  echo "$output"
  [ "$status" -eq 0 ]
  rm -rf "$sb"
}

# tank: the Hard rules list is imperatives only; the instinct definition lives in Scope (R24.qa.F13).
@test "tank AGENTS.md: the Hard rules list holds no definition, and lint-roles still passes" {
  local f="$REPO_ROOT/agent-factory/roles/tank/AGENTS.md" hard
  hard="$(awk '/^## Hard rules/{on=1;next} /^## /{on=0} on' "$f")"
  [ -n "$hard" ]
  if printf '%s\n' "$hard" | grep -q "An instinct in one project is a lead"; then false; fi
  grep -q "An instinct in one project is a lead" "$f"
  run "$PY" "$COMPOSE" --lint-roles
  [ "$status" -eq 0 ]
}
