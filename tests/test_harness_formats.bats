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

setup() {
  common_setup
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  [ -x "$PY" ] || skip "agent-factory venv not built"
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
