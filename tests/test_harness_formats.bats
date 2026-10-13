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

# Arrays below are filled with `while read` loops, not the bash 4 builtin: macOS bash 3.2 has
# no such builtin (R16.qa.F13; the portability test at the end of this file enforces it).

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
  files=(); while IFS= read -r _l; do files+=("$_l"); done < <(golden_files codex toml)
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
  files=(); while IFS= read -r _l; do files+=("$_l"); done < <(golden_files opencode md)
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
  entries=(); while IFS= read -r _l; do entries+=("$_l"); done < <(find "$shared" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
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
  files=(); while IFS= read -r _l; do files+=("$_l"); done < <(golden_files gemini-cli md)
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

@test "gemini: an unmapped tool exits 1 with E_TOOL_UNKNOWN (lint, before any emitter) naming role and tool, and writes no _gemini-cli dir" {
  gemini_roles zz-bad=Read,Teleport
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target gemini-cli --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"E_TOOL_UNKNOWN"* ]]
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
  codex=(); while IFS= read -r _l; do codex+=("$_l"); done < <(find "$TMP/core/_codex/agents" -name '*.toml' -type f | LC_ALL=C sort)
  opencode=(); while IFS= read -r _l; do opencode+=("$_l"); done < <(find "$TMP/core/_opencode/agents" -name '*.md' -type f | LC_ALL=C sort)
  gemini=(); while IFS= read -r _l; do gemini+=("$_l"); done < <(find "$TMP/core/_gemini-cli/agents" -name '*.md' -type f | LC_ALL=C sort)
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

# ================================================================ WP-050: writer safety ====
# Every writer vets its target dir, renders before it touches disk, swaps atomically and (for
# the legacy default target) wipes only its own output. Author's own checks, not independent
# verification.

# snap DIR — path + content hash of every file under DIR, so "left alone" is checkable
snap() {
  (cd "$1" && find . -type f -o -type l | LC_ALL=C sort | xargs -r shasum)
}

@test "writers: every target composed into one --out, then the default target: siblings survive and --check passes" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" t
  for t in claude-code codex opencode gemini-cli portable paperclip openclaw-native; do
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target "$t" --out "$TMP/out"
    echo "$t: $output"
    [ "$status" -eq 0 ]
  done
  # A leftover from a role that no longer exists: only the legacy wipe should remove it.
  mkdir -p "$TMP/out/fx/gone-role"
  printf 'x\n' > "$TMP/out/fx/gone-role/SOUL.md"
  local before; before="$(snap "$TMP/out/fx" | grep -v '/gone-role/')"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  for t in claude-code codex opencode gemini-cli portable paperclip openclaw; do
    [ -d "$TMP/out/fx/_$t" ]
  done
  [ ! -e "$TMP/out/fx/gone-role" ]
  [ -f "$TMP/out/fx/agents.yaml" ]
  # Every _<target> dir is byte-identical to before the default-target run.
  [ "$(snap "$TMP/out/fx" | grep '/_')" = "$(printf '%s\n' "$before" | grep '/_')" ]
  # --check on the default target ignores the sibling _* dirs ...
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --check --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  # ... but still sees drift in its own output.
  printf 'x\n' > "$TMP/out/fx/stray.txt"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --check --out "$TMP/out"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stray.txt"* ]]
  # No swap leftovers anywhere.
  [ -z "$(find "$TMP/out" -name '*.tmp' -o -name '*.old')" ]
}

@test "writers: an unsafe project name never reaches disk outside --out (every writer, called directly)" {
  gemini_env
  # Nested two levels under $TMP so that even an unguarded "..", "../.." or "." writer can only
  # damage this test's own temp tree, never /tmp itself.
  local base="$TMP/sb/deep"
  mkdir -p "$base/victim/_claude-code" "$base/victim/_codex" "$base/out"
  printf 'keep\n' > "$base/victim/_claude-code/keep.txt"
  printf 'keep\n' > "$base/victim/_codex/keep.txt"
  printf 'keep\n' > "$base/victim/keep.txt"
  printf 'keep\n' > "$base/keep-top.txt"
  run "$PY" "$BATS_TEST_DIRNAME/lib/writer_guard_probe.py" "$REPO_ROOT/agent-factory" \
    "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" "$base/out" "$base/victim"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$base/victim/_claude-code/keep.txt")" = keep ]
  [ "$(cat "$base/victim/_codex/keep.txt")" = keep ]
  [ "$(cat "$base/victim/keep.txt")" = keep ]
  [ "$(cat "$base/keep-top.txt")" = keep ]
  [ -d "$base/out" ]
}

@test "writers: a write-phase failure leaves the prior tree intact, with a clean error" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" t
  for t in claude-code codex portable openclaw; do
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target "$t" --out "$TMP/out"
    [ "$status" -eq 0 ]
  done
  local before; before="$(snap "$TMP/out")"
  chmod a-w "$TMP/out/fx"
  for t in claude-code codex portable openclaw; do
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target "$t" --out "$TMP/out"
    echo "$t: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"error:"* ]]
    [[ "$output" != *"Traceback"* ]]
  done
  chmod u+w "$TMP/out/fx"
  [ "$before" = "$(snap "$TMP/out")" ]
  [ -z "$(find "$TMP/out" -name '*.tmp' -o -name '*.old')" ]
}

@test "writers: a symlinked <out>/<name> or _<target> is refused with a clean error and never written through" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" t
  mkdir -p "$TMP/real" "$TMP/out"
  printf 'keep\n' > "$TMP/real/keep.txt"
  ln -s "$TMP/real" "$TMP/out/fx"
  for t in claude-code codex portable paperclip openclaw-native openclaw; do
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target "$t" --out "$TMP/out"
    echo "$t: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [[ "$output" != *"Traceback"* ]]
  done
  [ "$(ls "$TMP/real")" = "keep.txt" ]
  rm "$TMP/out/fx"
  mkdir -p "$TMP/out/fx"
  ln -s "$TMP/real" "$TMP/out/fx/_claude-code"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target claude-code --out "$TMP/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(ls "$TMP/real")" = "keep.txt" ]
  # --check must not call a symlinked tree "up to date".
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target claude-code --check --out "$TMP/out"
  [ "$status" -ne 0 ]
  [[ "$output" != *"up to date"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "--check sees a symlink and an empty dir inside a composed tree" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target codex --out "$TMP/out"
  [ "$status" -eq 0 ]
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target codex --check --out "$TMP/out"
  [ "$status" -eq 0 ]
  ln -s /etc/hostname "$TMP/out/fx/_codex/agents/link.toml"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target codex --check --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"link.toml"* ]]
  rm "$TMP/out/fx/_codex/agents/link.toml"
  mkdir "$TMP/out/fx/_codex/agents/emptydir"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target codex --check --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"emptydir"* ]]
}

# ================================================================ WP-051: emitter honesty ====
# Unknown tools are rejected everywhere, the wording claims only what each harness enforces,
# and the validator and mutation gaps found by the review are closed.

@test "emitters: an unknown, empty or malformed tools list is E_TOOL_UNMAPPED on every harness (direct call)" {
  # load_config's lint stops these first on a normal compose (E_TOOL_UNKNOWN, tested in
  # test_compose_lint.bats); this calls the emitters directly, as another importer could.
  gemini_roles zz-task=Read,Task zz-frob=Read,Frobnicate zz-lower=Read,read
  run "$PY" - "$REPO_ROOT/agent-factory" "$TMP/roles" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import compose

bad = []
def expect_unmapped(label, fn, agent):
    try:
        fn(agent, "zz")
    except SystemExit as e:
        if "E_TOOL_UNMAPPED" not in str(e.code):
            bad.append(f"{label}: exited with {e.code!r}")
    else:
        bad.append(f"{label}: accepted")

emitters = {"codex": compose.emit_codex_agent, "opencode": compose.emit_opencode_agent,
            "gemini-cli": compose.emit_gemini_agent, "claude-code": compose.emit_cc_subagent}
for role in ("zz-task", "zz-frob", "zz-lower"):
    for name, fn in emitters.items():
        expect_unmapped(f"{name} {role}", fn, {"role": role})

# Empty list, string, None element: patch role_meta so no file edit is needed.
real_meta = compose.role_meta
for label, tools in (("empty", []), ("string", "Read"), ("null-element", ["Read", None]), ("blank", [" "])):
    def fake(role, _t=tools):
        m = dict(real_meta("zz-task")); m["tools"] = _t; return m
    compose.role_meta = fake
    for name, fn in emitters.items():
        expect_unmapped(f"{name} tools={label}", fn, {"role": "zz-task"})
compose.role_meta = real_meta

print("\n".join(bad))
sys.exit(1 if bad else 0)
PYEOF
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "emitters: a role with no tools key still composes on every harness" {
  gemini_env
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
    --target codex --out "$TMP/out"
  [ "$status" -eq 0 ]
}

@test "codex: a role that can edit or write but has no Bash prints a shell warning; others do not" {
  gemini_roles zz-write=Read,Write zz-edit=Read,Edit,Bash zz-ro=Read,Grep
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target codex --out "$TMP/out"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"role zz-write gets a shell on Codex"* ]]
  [[ "$output" != *"role zz-edit gets a shell"* ]]
  [[ "$output" != *"role zz-ro gets a shell"* ]]
  # Files are unchanged by the warning: no sandbox_mode for the editing roles.
  lacks '^sandbox_mode' "$TMP/out/zz/_codex/agents/zz-zz-write.toml"
}

@test "wording: no emitter or doc claims read-only roles are read-only on every harness" {
  run grep -n "errs safe\|stay read-only on every harness" \
    "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/docs/harnesses.md"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qi "best-effort" "$REPO_ROOT/docs/harnesses.md"
  grep -q "^### What each harness enforces" "$REPO_ROOT/docs/harnesses.md"
}

@test "validator: codex rejects an unknown sandbox_mode" {
  need_tomllib
  local m
  for m in read-only workspace-write danger-full-access; do
    printf 'name = "x"\ndescription = "d"\nsandbox_mode = "%s"\ndeveloper_instructions = "b"\n' "$m" > "$TMP/ok.toml"
    run python3 -I "$VALIDATE" codex-agent "$TMP/ok.toml"
    [ "$status" -eq 0 ]
  done
  for m in yolo READ-ONLY ""; do
    printf 'name = "x"\ndescription = "d"\nsandbox_mode = "%s"\ndeveloper_instructions = "b"\n' "$m" > "$TMP/bad.toml"
    run python3 -I "$VALIDATE" codex-agent "$TMP/bad.toml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sandbox_mode"* ]]
  done
  printf 'name = "x"\ndescription = "d"\nsandbox_mode = 3\ndeveloper_instructions = "b"\n' > "$TMP/bad.toml"
  run python3 -I "$VALIDATE" codex-agent "$TMP/bad.toml"
  [ "$status" -eq 1 ]
}

@test "validator: opencode rejects flow-style permission, an unknown permission key and an unknown frontmatter key" {
  printf -- '---\ndescription: d\nmode: subagent\npermission: {edit: yolo}\n---\nbody\n' > "$TMP/flow.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/flow.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"permission"* ]]
  printf -- '---\ndescription: d\nmode: subagent\npermission: {edit: deny}\n---\nbody\n' > "$TMP/flowok.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/flowok.md"
  [ "$status" -eq 1 ]
  printf -- '---\ndescription: d\nmode: subagent\npermission:\n  frobnicate: deny\n---\nbody\n' > "$TMP/key.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/key.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"frobnicate"* ]]
  printf -- '---\ndescription: d\nmode: subagent\nsurprise: 1\n---\nbody\n' > "$TMP/top.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/top.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"surprise"* ]]
  # The three keys the emitter writes still pass.
  printf -- '---\ndescription: d\nmode: subagent\npermission:\n  edit: deny\n  bash: deny\n  webfetch: deny\n---\nbody\n' > "$TMP/all.md"
  run python3 -I "$VALIDATE" opencode-agent "$TMP/all.md"
  [ "$status" -eq 0 ]
}

@test "validator: gemini rejects a bogus tool name and a file with no body" {
  printf -- '---\nname: x\ndescription: d\ntools:\n- read_file\n- teleport\n---\nbody\n' > "$TMP/tool.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/tool.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"teleport"* ]]
  printf -- '---\nname: x\ndescription: d\ntools:\n- read_file\n---\n' > "$TMP/nobody.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/nobody.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"body"* ]]
  printf -- '---\nname: x\ndescription: d\n---\n   \n\n' > "$TMP/blank.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/blank.md"
  [ "$status" -eq 1 ]
  # Every mapped Gemini tool name is accepted.
  printf -- '---\nname: x\ndescription: d\ntools:\n- read_file\n- read_many_files\n- grep_search\n- glob\n- list_directory\n- run_shell_command\n- replace\n- write_file\n- web_fetch\n- google_web_search\n---\nbody\n' > "$TMP/all.md"
  run python3 -I "$VALIDATE" gemini-agent "$TMP/all.md"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "validator: a directory argument is reported as such, not as a traceback" {
  need_tomllib      # the codex-agent leg exits 3 ("cannot run") on Python < 3.11 (NF-055 VF1)
  mkdir "$TMP/adir"
  local c
  for c in opencode-agent gemini-agent codex-agent; do
    run python3 -I "$VALIDATE" "$c" "$TMP/adir"
    echo "$c: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is a directory"* ]]
    [[ "$output" != *"Traceback"* ]]
  done
}

# bare_names and per-agent `bare` (mutations M16 and M17 survived: no test used either).
@test "bare names: bare_names:true and a per-agent bare:true drop the slug prefix on codex, opencode and gemini-cli" {
  gemini_roles zz-a=Read zz-b=Read
  local t ext
  # whole project bare
  printf 'bare_names: true\n' >> "$TMP/zz.yaml"
  for t in codex opencode gemini-cli; do
    ext=md; [ "$t" = codex ] && ext=toml
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz.yaml" --target "$t" --out "$TMP/out1"
    echo "$t: $output"
    [ "$status" -eq 0 ]
    [ -f "$TMP/out1/zz/_$t/agents/zz-a.$ext" ]
    [ -f "$TMP/out1/zz/_$t/agents/zz-b.$ext" ]
    [ ! -e "$TMP/out1/zz/_$t/agents/zz-zz-a.$ext" ]
  done
  # one agent bare, the other prefixed
  printf 'project: zz\nslug: zz\nagents:\n  - role: zz-a\n  - role: zz-b\n    bare: true\n' > "$TMP/zz2.yaml"
  for t in codex opencode gemini-cli; do
    ext=md; [ "$t" = codex ] && ext=toml
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$TMP/zz2.yaml" --target "$t" --out "$TMP/out2"
    [ "$status" -eq 0 ]
    [ -f "$TMP/out2/zz/_$t/agents/zz-zz-a.$ext" ]
    [ -f "$TMP/out2/zz/_$t/agents/zz-b.$ext" ]
    [ ! -e "$TMP/out2/zz/_$t/agents/zz-zz-b.$ext" ]
  done
}

# The writers' symlink refusals (mutations M15 and M25 survived).
@test "writers: a symlinked _codex, _opencode, _gemini-cli or _portable is refused and never written through" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" t
  mkdir -p "$TMP/real" "$TMP/out/fx"
  printf 'keep\n' > "$TMP/real/keep.txt"
  for t in codex opencode gemini-cli portable; do
    ln -s "$TMP/real" "$TMP/out/fx/_$t"
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target "$t" --out "$TMP/out"
    echo "$t: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"symlink"* ]]
    [[ "$output" != *"Traceback"* ]]
    rm "$TMP/out/fx/_$t"
  done
  [ "$(ls "$TMP/real")" = "keep.txt" ]
}

# --dry-run (mutation M32 survived: nothing checked that orchestrators are left out).
@test "dry-run: a harness target lists specialists only, never an orchestrator" {
  gemini_env
  local t
  for t in codex opencode gemini-cli; do
    run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$REPO_ROOT/tests/fixtures/compose/fixture.yaml" \
      --target "$t" --dry-run --out "$TMP/out"
    echo "$t: $output"
    [ "$status" -eq 0 ]
    lacks 'ceo-orchestrator|tech-lead|growth-hacker' <(printf '%s\n' "$output")
    [[ "$output" == *"fx-eng"* ]]
    [[ "$output" == *"3 specialists"* ]]
  done
  [ ! -e "$TMP/out" ]
}

@test "validator: its Gemini tool list matches compose.GEMINI_TOOLS (no drift between the two)" {
  run "$PY" - "$REPO_ROOT/agent-factory" "$VALIDATE" <<'PYEOF'
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
import compose
spec = importlib.util.spec_from_file_location("validate_harness", sys.argv[2])
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
want = {g for names in compose.GEMINI_TOOLS.values() for g in names}
assert v.GEMINI_TOOL_NAMES == want, sorted(v.GEMINI_TOOL_NAMES ^ want)
assert set(compose.KNOWN_TOOLS) == set(compose.GEMINI_TOOLS)
PYEOF
  echo "$output"
  [ "$status" -eq 0 ]
}

# macOS runs bash 3.2, which has no map[f]ile or read[a]rray builtin (R16.qa.F13). The
# patterns use a bracket so this test's own text does not match itself.
@test "portability: this file uses no bash 4 array builtins (macOS bash 3.2)" {
  run grep -nE 'map[f]ile|read[a]rray' "$BATS_TEST_FILENAME"
  echo "$output"
  [ "$status" -eq 1 ]
}

# A missing requirement must not look like a pass (R16.qa.F13): the validator exits 3, so a
# caller that forgot its own tomllib skip sees a distinct code instead of a silent 0.
# `sys.modules["tomllib"] = None` makes `import tomllib` raise ImportError, as on Python < 3.11.
@test "validator: a missing tomllib exits 3, not 0" {
  printf 'name = "x"\ndescription = "d"\ndeveloper_instructions = "b"\n' > "$TMP/ok.toml"
  run python3 -I -c '
import runpy, sys
sys.modules["tomllib"] = None
sys.argv = sys.argv[1:]            # now: validate_harness.py codex-agent FILE
runpy.run_path(sys.argv[0], run_name="__main__")
' "$VALIDATE" codex-agent "$TMP/ok.toml"
  echo "$output"
  [ "$status" -eq 3 ]
}

# ============================================== NF-044 (VS7): delete scope of the swap dirs ====
# The writers used to delete any <target>.tmp / <target>.old (and <project>.tmp / .old) next to
# the output, which could be a user's own dir. Now only debris compose.py itself marked is
# cleared; anything else is refused untouched. Author's own checks, not independent verification.

# A user dir (no compose.py marker) at each swap name: canary inside, deep sandbox so a wrong
# delete can only reach this test's own tree.
@test "NF-044: a user dir at a swap name is refused and never deleted (install_tree and install_project)" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" out="$TMP/sb/deep/out" t d
  mkdir -p "$out/fx"
  # Targets that use install_tree: <out>/fx/_<target>.tmp|.old. Default target: <out>/fx.tmp|.old.
  for d in "$out/fx/_claude-code.tmp" "$out/fx/_claude-code.old" "$out/fx.tmp" "$out/fx.old"; do
    mkdir -p "$d"
    printf 'mine\n' > "$d/canary.txt"
  done
  for t in claude-code default; do
    if [ "$t" = default ]; then
      run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --out "$out"
    else
      run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target "$t" --out "$out"
    fi
    echo "$t: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to delete"* ]]
    [[ "$output" != *"Traceback"* ]]
  done
  for d in "$out/fx/_claude-code.tmp" "$out/fx/_claude-code.old" "$out/fx.tmp" "$out/fx.old"; do
    [ "$(cat "$d/canary.txt")" = mine ]
  done
  # nothing was composed over the refusal
  [ ! -e "$out/fx/_claude-code" ]
  [ ! -e "$out/fx/agents.yaml" ]
}

@test "NF-044: a symlink at a swap name is refused, never followed" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" out="$TMP/sb/deep/out"
  mkdir -p "$out/fx" "$TMP/sb/deep/victim"
  printf 'mine\n' > "$TMP/sb/deep/victim/canary.txt"
  ln -s "$TMP/sb/deep/victim" "$out/fx/_claude-code.old"
  ln -s "$TMP/sb/deep/victim" "$out/fx.tmp"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target claude-code --out "$out"
  [ "$status" -ne 0 ]
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --out "$out"
  [ "$status" -ne 0 ]
  [ "$(cat "$TMP/sb/deep/victim/canary.txt")" = mine ]
  [ -L "$out/fx/_claude-code.old" ]
  [ -L "$out/fx.tmp" ]
}

@test "NF-044: debris compose.py itself left (dir plus its marker) is still cleared, and a run leaves no marker" {
  gemini_env
  local cfg="$REPO_ROOT/tests/fixtures/compose/fixture.yaml" out="$TMP/sb/deep/out"
  mkdir -p "$out/fx/_claude-code.tmp" "$out/fx.old"
  printf 'x\n' > "$out/fx/_claude-code.tmp/half.txt"
  printf 'x\n' > "$out/fx.old/half.txt"
  : > "$out/fx/_claude-code.tmp.compose-owned"
  : > "$out/fx.old.compose-owned"
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --target claude-code --out "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  run "$PY" "$REPO_ROOT/agent-factory/compose.py" "$cfg" --out "$out"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(find "$out" -name '*.tmp' -o -name '*.old' -o -name '*compose-owned*')" ]
  [ -d "$out/fx/_claude-code" ]
}

# VS1 (cheap part): the writers re-check for a symlink right before the first rename, so a link
# swapped in after vet_target() is refused. Called directly because the swap cannot be raced
# reliably from a test; the in-function re-check is what is under test.
@test "NF-044: install_tree and install_project refuse a project dir that is a symlink at swap time" {
  local sb="$TMP/sb/deep"
  mkdir -p "$sb/victim/_claude-code" "$sb/out"
  printf 'keep\n' > "$sb/victim/_claude-code/canary.txt"
  printf 'keep\n' > "$sb/victim/canary-top.txt"
  ln -s "$sb/victim" "$sb/out/fx"
  run env REPO_ROOT="$REPO_ROOT" OUT="$sb/out" "$PY" -c '
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["REPO_ROOT"] + "/agent-factory")
import compose
out = Path(os.environ["OUT"])
for fn, args in ((compose.install_tree, (out / "fx" / "_claude-code", {"a.txt": "x"})),
                 (compose.install_project, (out / "fx", {"a.txt": "x"}))):
    try:
        fn(*args)
    except SystemExit as e:
        assert "symlink" in str(e.code), e.code
    else:
        raise SystemExit("accepted a symlinked project dir: " + fn.__name__)
print("refused both")'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$sb/victim/_claude-code/canary.txt")" = keep ]
  [ "$(cat "$sb/victim/canary-top.txt")" = keep ]
  [ ! -e "$sb/victim/a.txt" ]
}
