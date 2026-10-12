#!/usr/bin/env bats
# Format conformance for generated harness artefacts (change `multi-harness`, group 3 on).
#
# Runs tests/lib/validate_harness.py (stdlib only) over the committed compose goldens, and
# pins the Codex emitter's escaping. Needs the agent-factory venv (PyYAML) to import
# compose.py; skipped where it isn't built. Later harness groups (OpenCode, Gemini) add
# their own sections below: register a checker in validate_harness.py, then add a block
# here that runs it over that target's goldens. These are the author's own checks;
# independent verification belongs to qa-engineer.

load helpers/setup
load helpers/venv

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  VALIDATE="$REPO_ROOT/tests/lib/validate_harness.py"
  GOLDENS="$REPO_ROOT/tests/fixtures/compose/golden"
  TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TMP"
  common_teardown
}

# golden_files <target> <ext> — every golden agent file of that target, C-sorted
golden_files() {
  find "$GOLDENS/$1" -path '*/agents/*' -name "*.$2" -type f | LC_ALL=C sort
}

# lacks <ERE> FILE... — succeeds only if NO file has a matching line. A bare `! grep` in a
# test body never fails the test (bash exempts negated commands from errexit), so the
# negation lives in a function whose exit status is the last command's.
lacks() {
  ! grep -qE "$1" "${@:2}"
}

# need_tomllib — skip the test on a python3 without tomllib (< 3.11), as the validator does
need_tomllib() {
  python3 -c 'import tomllib' 2>/dev/null || skip "python3 has no tomllib (< 3.11)"
}

# ---------------------------------------------------------------- codex

@test "codex: the validator accepts every golden .toml" {
  need_tomllib
  mapfile -t files < <(golden_files codex toml)
  # Guard against a vacuous pass: the fixture has three specialists.
  [ "${#files[@]}" -eq 3 ]
  run python3 -I "$VALIDATE" codex-agent "${files[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "codex: goldens map the allowlist to sandbox_mode and never write model" {
  local d; d=$(dirname "$(golden_files codex toml | head -1)")
  grep -qx 'sandbox_mode = "read-only"' "$d/fx-fx-readonly.toml"
  lacks '^sandbox_mode' "$d/fx-fx-eng.toml"
  lacks '^sandbox_mode' "$d/fx-product-manager.toml"
  lacks '^model' "$d"/*.toml
  # Orchestrators are skills, never agent files.
  [ "$(ls "$d" | wc -l)" -eq 3 ]
  lacks 'orchestrator|tech-lead|growth-hacker' <(ls "$d")
}

@test "codex: the validator rejects bad TOML and a missing required key" {
  need_tomllib
  printf 'name = "x"\ndescription = "d"\ndeveloper_instructions = """\nbody\n"""\n' > "$TMP/ok.toml"
  run python3 -I "$VALIDATE" codex-agent "$TMP/ok.toml"
  [ "$status" -eq 0 ]
  printf 'name = "x"\ndescription = "d"\n' > "$TMP/nokey.toml"
  run python3 -I "$VALIDATE" codex-agent "$TMP/nokey.toml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"developer_instructions"* ]]
  printf 'name = "unterminated\n' > "$TMP/bad.toml"
  run python3 -I "$VALIDATE" codex-agent "$TMP/bad.toml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid TOML"* ]]
  # Non-string value for a required key is also a failure.
  printf 'name = 3\ndescription = "d"\ndeveloper_instructions = "b"\n' > "$TMP/num.toml"
  run python3 -I "$VALIDATE" codex-agent "$TMP/num.toml"
  [ "$status" -eq 1 ]
}

@test "validator: unknown subcommand is a usage error, a missing file a failure" {
  run python3 -I "$VALIDATE" nonesuch "$TMP/x"
  [ "$status" -eq 2 ]
  need_tomllib
  run python3 -I "$VALIDATE" codex-agent "$TMP/does-not-exist.toml"
  [ "$status" -eq 1 ]
}

@test "codex: toml_multiline and toml_basic round-trip hostile text through tomllib" {
  need_tomllib
  run "$PY" - "$REPO_ROOT/agent-factory" <<'PYEOF'
import sys, tomllib
sys.path.insert(0, sys.argv[1])
import compose
# backslash, triple quote, tab, non-ASCII, a literal backslash-n lookalike, and a body
# ending in quotes (which would otherwise merge with the closing delimiter).
body = 'a \\ b """ c\ttab é \\n not-a-newline\n""" and ending quotes ""'
parsed = tomllib.loads("v = " + compose.toml_multiline(body) + "\n")["v"]
assert parsed == body, (parsed, body)
# Bodies that are only quotes, and one ending in a newline.
for b in ('"', '""', '"""', '""""', 'x\n'):
    got = tomllib.loads("v = " + compose.toml_multiline(b) + "\n")["v"]
    assert got == b, (got, b)
# Control characters TOML forbids are dropped, not written into an invalid file.
assert tomllib.loads("v = " + compose.toml_multiline("a\x00b\rc\x7fd") + "\n")["v"] == "abcd"
# Single-line strings: quotes, backslashes and newlines stay on one line and round-trip.
s = 'say "hi" \\ there\nsecond\tline é'
assert tomllib.loads("v = " + compose.toml_basic(s) + "\n")["v"] == s
print("ok")
PYEOF
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "codex: recomposing wipes a stray file from _codex and writes no file for orchestrators" {
  export GRID_PRIVATE_ROLES_DIR="$REPO_ROOT/tests/fixtures/compose/roles"
  export GRID_USER_CONFIG="$REPO_ROOT/agent-factory/user.public.yaml"
  export GRID_MODELS_FILE="$REPO_ROOT/agent-factory/models.yaml"
  mkdir -p "$TMP/fx/_codex/agents"
  printf 'stale\n' > "$TMP/fx/_codex/agents/stray.toml"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
    --target codex --out "$TMP"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/fx/_codex/agents/stray.toml" ]
  [ -f "$TMP/fx/_codex/agents/fx-fx-readonly.toml" ]
  [ "$(ls "$TMP/fx/_codex/agents" | wc -l)" -eq 3 ]
}

@test "codex: an allowlist containing Edit or Write gets no sandbox_mode; one without both does" {
  # The shared fixture has no allowlisted role that can edit, so build the cases here:
  # a private roles tree (copy of the fixtures) plus three extra roles and a tiny config.
  local roles="$TMP/roles" r
  cp -R "$REPO_ROOT/tests/fixtures/compose/roles" "$roles"
  for r in zz-edit zz-write zz-ro; do
    cp -R "$roles/fx-eng" "$roles/$r"
    sed -i "s/^name: .*/name: $r/" "$roles/$r/role.yaml"
  done
  printf 'tools: [Read, Edit, Bash]\n' >> "$roles/zz-edit/role.yaml"
  printf 'tools: [Read, Write]\n'      >> "$roles/zz-write/role.yaml"
  printf 'tools: [Read, Grep]\n'       >> "$roles/zz-ro/role.yaml"
  printf 'project: zz\nslug: zz\nagents:\n  - role: zz-edit\n  - role: zz-write\n  - role: zz-ro\n' > "$TMP/zz.yaml"
  export GRID_PRIVATE_ROLES_DIR="$roles"
  export GRID_USER_CONFIG="$REPO_ROOT/agent-factory/user.public.yaml"
  export GRID_MODELS_FILE="$REPO_ROOT/agent-factory/models.yaml"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target codex --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  local d="$TMP/out/zz/_codex/agents"
  lacks '^sandbox_mode' "$d/zz-zz-edit.toml"
  lacks '^sandbox_mode' "$d/zz-zz-write.toml"
  grep -qx 'sandbox_mode = "read-only"' "$d/zz-zz-ro.toml"
}

# ================================================================ opencode (group 4) ====
# OpenCode subagents are <name>.md with YAML frontmatter (`description`, `mode`, optional
# `permission`) and the prompt as the body. The skill checks below apply to every harness that
# reads the shared skills dir. Author's own checks, not independent verification.

@test "opencode: the validator accepts every golden .md" {
  mapfile -t files < <(golden_files opencode md)
  # Guard against a vacuous pass: the fixture has three specialists.
  [ "${#files[@]}" -eq 3 ]
  run python3 -I "$VALIDATE" opencode-agent "${files[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "opencode: goldens map the allowlist to permission and never write model or tools" {
  local d; d=$(dirname "$(golden_files opencode md | head -1)")
  # fx-readonly has [Read, Grep, Glob, Bash]: no edit and no web access, but Bash allowed.
  grep -qx '  edit: deny' "$d/fx-fx-readonly.md"
  grep -qx '  webfetch: deny' "$d/fx-fx-readonly.md"
  lacks 'bash:' "$d/fx-fx-readonly.md"
  grep -qx 'mode: subagent' "$d/fx-fx-readonly.md"
  # No allowlist, no permission block.
  lacks '^permission' "$d/fx-fx-eng.md" "$d/fx-product-manager.md"
  # `model` is never written; `tools` is deprecated in OpenCode so it is never written either.
  lacks '^(model|tools):' "$d"/*.md
  # Orchestrators are skills, never agent files.
  [ "$(ls "$d" | wc -l)" -eq 3 ]
  lacks 'orchestrator|tech-lead|growth-hacker' <(ls "$d")
}

@test "opencode: the frontmatter parses as YAML with description first, then mode" {
  # Descriptions can contain ': ' and quotes, so a hand-built frontmatter could break; read it
  # back with PyYAML.
  run "$PY" - "$(dirname "$(golden_files opencode md | head -1)")" <<'PYEOF'
import sys, pathlib, yaml
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.md")):
    text = f.read_text(encoding="utf-8")
    assert text.startswith("---\n"), f
    fm_text, body = text[4:].split("\n---\n", 1)
    fm = yaml.safe_load(fm_text)
    assert fm["mode"] == "subagent", f
    assert list(fm)[:2] == ["description", "mode"], list(fm)   # fixed key order
    assert fm["description"].strip(), f
    assert "You are the **" in body, f
print("ok")
PYEOF
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "opencode: the validator rejects a missing description, the wrong mode and a bad permission" {
  printf -- '---\ndescription: d\nmode: subagent\npermission:\n  edit: deny\n---\nbody\n' > "$TMP/ok.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/ok.md"
  [ "$status" -eq 0 ]
  printf -- '---\nmode: subagent\n---\nbody\n' > "$TMP/nodesc.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/nodesc.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"description"* ]]
  printf -- '---\ndescription: d\nmode: primary\n---\nbody\n' > "$TMP/primary.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/primary.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode"* ]]
  printf -- '---\ndescription: d\nmode: subagent\npermission:\n  edit: maybe\n---\nbody\n' > "$TMP/perm.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/perm.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"permission"* ]]
  printf 'no frontmatter here\n' > "$TMP/nofm.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/nofm.md"
  [ "$status" -eq 1 ]
}

@test "opencode: each allowlist tool maps to exactly its permission key (temp roles)" {
  # The shared fixture has one allowlisted role (no Edit/Write/WebFetch, with Bash), so it can
  # only prove ONE direction of each condition. Build the other cases from temp roles: one role
  # per row, each with a different allowlist.
  local roles="$TMP/roles" r
  cp -R "$REPO_ROOT/tests/fixtures/compose/roles" "$roles"
  mk() {   # mk <role> <tools yaml list, or empty for no allowlist>
    cp -R "$roles/fx-eng" "$roles/$1"
    sed -i "s/^name: .*/name: $1/" "$roles/$1/role.yaml"
    [ -z "$2" ] || printf 'tools: %s\n' "$2" >> "$roles/$1/role.yaml"
  }
  mk zz-edit   '[Read, Edit]'                   # edit allowed; bash and web denied
  mk zz-write  '[Read, Write]'                  # Write alone also allows edit
  mk zz-nobash '[Read, Grep]'                   # no Bash: bash denied
  mk zz-fetch  '[Read, WebFetch]'               # WebFetch alone allows webfetch
  mk zz-search '[Read, WebSearch]'              # WebSearch alone allows webfetch
  mk zz-all    '[Read, Edit, Bash, WebFetch]'   # nothing denied: no permission block at all
  mk zz-none   ''                               # no allowlist: no permission block
  printf 'project: zz\nslug: zz\nagents:\n' > "$TMP/zz.yaml"
  for r in zz-edit zz-write zz-nobash zz-fetch zz-search zz-all zz-none; do
    printf '  - role: %s\n' "$r" >> "$TMP/zz.yaml"
  done
  export GRID_PRIVATE_ROLES_DIR="$roles"
  export GRID_USER_CONFIG="$REPO_ROOT/agent-factory/user.public.yaml"
  export GRID_MODELS_FILE="$REPO_ROOT/agent-factory/models.yaml"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target opencode --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  local d="$TMP/out/zz/_opencode/agents"
  # Every generated file must itself be valid.
  run python3 -I "$VALIDATE" opencode-agent "$d"/*.md
  [ "$status" -eq 0 ]
  # An allowed capability has no key; the denied ones are written in the fixed order
  # edit, bash, webfetch.
  lacks 'edit:' "$d/zz-zz-edit.md" "$d/zz-zz-write.md"
  grep -qx '  bash: deny' "$d/zz-zz-edit.md"
  grep -qx '  webfetch: deny' "$d/zz-zz-edit.md"
  grep -qx '  edit: deny' "$d/zz-zz-nobash.md"
  grep -qx '  bash: deny' "$d/zz-zz-nobash.md"
  grep -qx '  webfetch: deny' "$d/zz-zz-nobash.md"
  [ "$(grep -E '^  (edit|bash|webfetch):' "$d/zz-zz-nobash.md" | cut -d: -f1 | tr -d ' ' | paste -sd, -)" = "edit,bash,webfetch" ]
  lacks 'webfetch:' "$d/zz-zz-fetch.md" "$d/zz-zz-search.md"
  grep -qx '  edit: deny' "$d/zz-zz-fetch.md"
  grep -qx '  edit: deny' "$d/zz-zz-search.md"
  lacks '^permission' "$d/zz-zz-all.md" "$d/zz-zz-none.md"
}

# ---------------------------------------------------------------- skill (shared dir)

# mkskill DIR NAME DESC — a skill dir with the given frontmatter name and description
mkskill() {
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$2" "$3" > "$1/SKILL.md"
}

@test "skill: the validator accepts a well-formed skill dir" {
  mkskill "$TMP/good-skill" good-skill "A fine description."
  run python3 -I "$VALIDATE" skill "$TMP/good-skill"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "skill: the validator rejects a bad dir name, a name mismatch and a bad description" {
  # Dir name: uppercase, underscore, double hyphen, leading and trailing hyphen break the regex.
  local bad
  for bad in Upper under_score dbl--hyphen -lead trail-; do
    mkskill "$TMP/$bad" "$bad" "d"
    run python3 -I "$VALIDATE" skill "$TMP/$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"dir name"* ]]
  done
  # Dir name longer than 64 chars fails; exactly 64 passes.
  local long ok64
  long=$(printf 'a%.0s' $(seq 1 65)); ok64=$(printf 'a%.0s' $(seq 1 64))
  mkskill "$TMP/$long" "$long" "d"
  run python3 -I "$VALIDATE" skill "$TMP/$long"
  [ "$status" -eq 1 ]
  [[ "$output" == *"64"* ]]
  mkskill "$TMP/$ok64" "$ok64" "d"
  run python3 -I "$VALIDATE" skill "$TMP/$ok64"
  [ "$status" -eq 0 ]
  # Frontmatter name differs from the dir.
  mkskill "$TMP/mismatch" other-name "d"
  run python3 -I "$VALIDATE" skill "$TMP/mismatch"
  [ "$status" -eq 1 ]
  [[ "$output" == *"name"* ]]
  # Description: empty and 1025 chars fail, exactly 1024 passes.
  mkskill "$TMP/empty-desc" empty-desc ""
  run python3 -I "$VALIDATE" skill "$TMP/empty-desc"
  [ "$status" -eq 1 ]
  mkskill "$TMP/too-long" too-long "$(printf 'x%.0s' $(seq 1 1025))"
  run python3 -I "$VALIDATE" skill "$TMP/too-long"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1024"* ]]
  mkskill "$TMP/max-ok" max-ok "$(printf 'x%.0s' $(seq 1 1024))"
  run python3 -I "$VALIDATE" skill "$TMP/max-ok"
  [ "$status" -eq 0 ]
  # No frontmatter at all, and no SKILL.md at all.
  mkdir -p "$TMP/nofm"; printf 'plain\n' > "$TMP/nofm/SKILL.md"
  run python3 -I "$VALIDATE" skill "$TMP/nofm"
  [ "$status" -eq 1 ]
  mkdir -p "$TMP/nofile"
  run python3 -I "$VALIDATE" skill "$TMP/nofile"
  [ "$status" -eq 1 ]
}

@test "skill: every entry wire.sh links into the shared dir passes the validator" {
  # A fixture wire for OpenCode: portable skills go to $GRID_HARNESS_HOME/.agents/skills.
  # `template` (frontmatter name template-skill != dir) is filtered out by wire.sh, so what
  # remains must all be valid. The count guard keeps the test from passing vacuously.
  mkdir -p "$MOCK_GRID/machines"
  make_skill "$MOCK_GRID/skills/skill-alpha" skill-alpha
  make_skill "$MOCK_GRID/skills/skill-beta" skill-beta
  make_skill "$MOCK_GRID/skills/template" template-skill
  GRID_DIR="$MOCK_GRID" GRID_HARNESS=opencode run bash "$REPO_ROOT/scripts/wire.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  local shared="$GRID_HARNESS_HOME/.agents/skills"
  mapfile -t entries < <(find "$shared" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
  [ "${#entries[@]}" -eq 2 ]
  run python3 -I "$VALIDATE" skill "${entries[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ================================================================ gemini-cli (multi-harness group 5)
# Gemini CLI subagents: ~/.gemini/agents/<name>.md, YAML frontmatter `name`, `description`,
# optional `tools` (written as a block list), never `model`. Self-contained block: it appends
# to this file so it rebases cleanly next to the OpenCode block (group 4).

# gemini_env: pin compose.py to the fixture roles and the neutral public identity, as
# scripts/compose-goldens.sh does (so no personal value reaches a test result).
gemini_env() {
  export GRID_PRIVATE_ROLES_DIR="$REPO_ROOT/tests/fixtures/compose/roles"
  export GRID_USER_CONFIG="$REPO_ROOT/agent-factory/user.public.yaml"
  export GRID_MODELS_FILE="$REPO_ROOT/agent-factory/models.yaml"
}

# gemini_roles ROLE=TOOLS... : copy the fixture roles into $TMP/roles and add one role per
# argument (ROLE=comma-separated tools, e.g. zz-a=Read,Teleport) plus $TMP/zz.yaml listing
# them. Lets a test exercise a tool list the shared fixture does not have.
gemini_roles() {
  local roles="$TMP/roles" spec r t cfg=$'project: zz\nslug: zz\nagents:\n'
  cp -R "$REPO_ROOT/tests/fixtures/compose/roles" "$roles"
  for spec in "$@"; do
    r="${spec%%=*}"; t="${spec#*=}"
    cp -R "$roles/fx-eng" "$roles/$r"
    sed -i "s/^name: .*/name: $r/" "$roles/$r/role.yaml"
    printf 'tools: [%s]\n' "${t//,/, }" >> "$roles/$r/role.yaml"
    cfg+="  - role: $r"$'\n'
  done
  printf '%s' "$cfg" > "$TMP/zz.yaml"
  gemini_env
  export GRID_PRIVATE_ROLES_DIR="$roles"
}

@test "gemini: the validator accepts every golden .md" {
  mapfile -t files < <(golden_files gemini-cli md)
  # Guard against a vacuous pass: the fixture has three specialists.
  [ "${#files[@]}" -eq 3 ]
  run python3 -I "$VALIDATE" gemini-agent "${files[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "gemini: goldens list the mapped tools in order for the read-only role, none and no model elsewhere" {
  local d; d=$(dirname "$(golden_files gemini-cli md | head -1)")
  # Exact frontmatter slice: the block list, in the allowlist's order (Read, Grep, Glob, Bash).
  run sed -n '/^tools:/,/^---$/p' "$d/fx-fx-readonly.md"
  [ "$output" = $'tools:\n- read_file\n- read_many_files\n- grep_search\n- glob\n- list_directory\n- run_shell_command\n---' ]
  lacks '^tools:' "$d/fx-fx-eng.md" "$d/fx-product-manager.md"
  lacks '^model:' "$d"/*.md
  # Orchestrators are skills, never agent files.
  [ "$(ls "$d" | wc -l)" -eq 3 ]
  lacks 'orchestrator|tech-lead|growth-hacker' <(ls "$d")
}

@test "gemini: the validator rejects a bad name, an empty description, no frontmatter, a string tools value and a model" {
  printf -- '---\nname: ok_name-1\ndescription: d\ntools:\n- read_file\n---\nbody\n' > "$TMP/ok.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/ok.md"
  [ "$status" -eq 0 ]
  printf -- '---\nname: Bad Name\ndescription: d\n---\nbody\n' > "$TMP/badname.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/badname.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"name"* ]]
  printf -- '---\nname: x\ndescription:\n---\nbody\n' > "$TMP/nodesc.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/nodesc.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"description"* ]]
  printf 'name: x\ndescription: d\n' > "$TMP/nofm.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/nofm.md"
  [ "$status" -eq 1 ]
  # Claude's comma-string `tools: Read, Grep` is not a Gemini list.
  printf -- '---\nname: x\ndescription: d\ntools: Read, Grep\n---\n' > "$TMP/str.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/str.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tools"* ]]
  printf -- '---\nname: x\ndescription: d\nmodel: sonnet\n---\n' > "$TMP/model.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/model.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"model"* ]]
}

@test "gemini: an unmapped tool exits 1 with E_TOOL_UNMAPPED naming role and tool, and writes no _gemini-cli dir" {
  gemini_roles zz-bad=Read,Teleport
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target gemini-cli --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_TOOL_UNMAPPED"* ]]
  [[ "$output" == *"zz-bad"* ]]
  [[ "$output" == *"Teleport"* ]]
  [ ! -e "$TMP/out/zz/_gemini-cli" ]
}

@test "gemini: an unmapped tool in a later role leaves an existing _gemini-cli tree untouched" {
  # The check runs before the wipe, so a failed compose must not destroy the previous output.
  gemini_roles zz-ok=Read zz-bad=Teleport
  mkdir -p "$TMP/out/zz/_gemini-cli/agents"
  printf 'keep\n' > "$TMP/out/zz/_gemini-cli/agents/keep.md"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target gemini-cli --out "$TMP/out"
  [ "$status" -eq 1 ]
  [ "$(cat "$TMP/out/zz/_gemini-cli/agents/keep.md")" = "keep" ]
  [ "$(ls "$TMP/out/zz/_gemini-cli/agents" | wc -l)" -eq 1 ]
}

@test "gemini: every mapped tool, de-duplicated, in the role's listed order" {
  # The fixture only exercises Read/Grep/Glob/Bash; build a role touching the other mappings,
  # with repeats to prove the first occurrence wins.
  gemini_roles zz-all=Write,Read,WebSearch,Edit,Read,WebFetch,Glob,Grep,Bash,Glob
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target gemini-cli --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  run sed -n '/^tools:/,/^---$/p' "$TMP/out/zz/_gemini-cli/agents/zz-zz-all.md"
  [ "$output" = $'tools:\n- write_file\n- read_file\n- read_many_files\n- google_web_search\n- replace\n- web_fetch\n- glob\n- list_directory\n- grep_search\n- run_shell_command\n---' ]
}

@test "gemini: recomposing wipes a stray file from _gemini-cli and writes no file for orchestrators" {
  gemini_env
  mkdir -p "$TMP/fx/_gemini-cli/agents"
  printf 'stale\n' > "$TMP/fx/_gemini-cli/agents/stray.md"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
    --target gemini-cli --out "$TMP"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/fx/_gemini-cli/agents/stray.md" ]
  [ -f "$TMP/fx/_gemini-cli/agents/fx-fx-readonly.md" ]
  [ "$(ls "$TMP/fx/_gemini-cli/agents" | wc -l)" -eq 3 ]
}

@test "gemini: the body and description match the Claude Code subagent" {
  # One prompt on every harness: the Gemini file's body equals the claude-code body.
  gemini_env
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
    --target gemini-cli --out "$TMP/g"
  [ "$status" -eq 0 ]
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
    --target claude-code --out "$TMP/c"
  [ "$status" -eq 0 ]
  local g="$TMP/g/fx/_gemini-cli/agents/fx-fx-readonly.md" c="$TMP/c/fx/_claude-code/agents/fx-fx-readonly.md"
  # Everything after the closing frontmatter fence.
  [ "$(awk 'f{print} /^---$/{n++; if(n==2) f=1}' "$g")" = "$(awk 'f{print} /^---$/{n++; if(n==2) f=1}' "$c")" ]
  [ "$(grep -A1 '^description:' "$g")" = "$(grep -A1 '^description:' "$c")" ]
}

# ---------------------------------------------------------------- real roles, every target

# The goldens above use the fixture roles. These compose the REAL core roles for each
# non-Claude target and run the format validators over the output, so a real role that
# breaks a harness format (an unmapped tool, bad TOML escaping, a missing description) is
# caught here. A test, not a gate step: CI has no composed output to `--check`. The
# identity is the neutral public one and private roles are disabled, so the result does not
# depend on the machine.
@test "real core roles compose for codex, opencode and gemini-cli and pass the validators" {
  need_tomllib
  export GRID_PRIVATE_ROLES_DIR=""
  export GRID_USER_CONFIG="$REPO_ROOT/agent-factory/user.public.yaml"
  export GRID_MODELS_FILE="$REPO_ROOT/agent-factory/models.yaml"
  local t
  for t in codex opencode gemini-cli; do
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/agent-factory/examples/core.yaml" \
      --target "$t" --out "$TMP"
    echo "$output"
    [ "$status" -eq 0 ]
  done
  mapfile -t codex < <(find "$TMP/core/_codex/agents" -name '*.toml' -type f | LC_ALL=C sort)
  mapfile -t opencode < <(find "$TMP/core/_opencode/agents" -name '*.md' -type f | LC_ALL=C sort)
  mapfile -t gemini < <(find "$TMP/core/_gemini-cli/agents" -name '*.md' -type f | LC_ALL=C sort)
  # Guard against a vacuous pass: core has four specialists on every target.
  [ "${#codex[@]}" -eq 4 ]
  [ "${#opencode[@]}" -eq 4 ]
  [ "${#gemini[@]}" -eq 4 ]
  run python3 -I "$VALIDATE" codex-agent "${codex[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
  run python3 -I "$VALIDATE" opencode-agent "${opencode[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
  run python3 -I "$VALIDATE" gemini-agent "${gemini[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}
