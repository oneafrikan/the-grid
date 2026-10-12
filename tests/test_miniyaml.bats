#!/usr/bin/env bats
# Tests for scripts/lib/miniyaml.py, the restricted-YAML reader behind policy.yaml
# and the `audit-allow` block of CURATION.md. Pure parsing: no scanning here.

load helpers/setup

setup() {
  common_setup
  LIB="$REPO_ROOT/scripts/lib"
  POLICY="$REPO_ROOT/policy.yaml"
  W=$(mktemp -d)   # scratch dir for the little YAML files each test writes
}

teardown() {
  rm -rf "$W"
  common_teardown
}

# mini_json FILE -> prints the parsed document as JSON (sorted keys, one line).
# On a ParseError prints "ParseError: line N: msg" to stderr and exits 1, which is
# what the "unsupported construct" tests look at.
mini_json() {
  python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import miniyaml
try:
    doc = miniyaml.loads(open(sys.argv[2], encoding="utf-8").read())
except miniyaml.ParseError as exc:
    sys.stderr.write("ParseError: line %d: %s\n" % (exc.line, exc.msg))
    sys.exit(1)
print(json.dumps(doc, sort_keys=True))
' "$LIB" "$1"
}

# (a) The real policy.yaml parses, and where PyYAML is available the two readers agree.
@test "policy.yaml parses and equals yaml.safe_load when PyYAML is available" {
  # Prefer the agent-factory venv (it carries PyYAML), else the system python3.
  local py=python3
  [ -x "$REPO_ROOT/agent-factory/.venv/bin/python" ] && py="$REPO_ROOT/agent-factory/.venv/bin/python"
  if ! "$py" -c "import yaml" 2>/dev/null; then
    skip "PyYAML not importable by $py; comparison against yaml.safe_load skipped"
  fi
  run "$py" -c '
import json, sys, yaml
sys.path.insert(0, sys.argv[1])
import miniyaml
text = open(sys.argv[2], encoding="utf-8").read()
mine, theirs = miniyaml.loads(text), yaml.safe_load(text)
if mine != theirs:
    sys.exit("miniyaml and PyYAML disagree")
' "$LIB" "$POLICY"
  [ "$status" -eq 0 ]
}

# (b) Unsupported syntax is a hard error that names the line.
@test "anchor is rejected with its line number" {
  printf 'a: 1\nb: &x 2\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
}

@test "block scalar | is rejected with its line number" {
  printf 'a: 1\nb: |\n  text\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
}

@test "tab indentation is rejected with its line number" {
  printf 'a:\n\tb: 1\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
}

@test "duplicate key is rejected with the line of the second one" {
  printf 'a: 1\nb: 2\na: 3\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 3"* ]]
}

# (c) Single-quoted scalars keep backslashes literally (why every regex is single-quoted).
@test "single-quoted regex with backslashes round-trips unchanged" {
  cat > "$W/t.yaml" <<'EOF'
regex: '\b(?:curl|wget)\b[^\n|]*\|\s*sh\b ''quoted'' \d+\.'
EOF
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  run python3 -c '
import json, sys
want = r"\b(?:curl|wget)\b[^\n|]*\|\s*sh\b " + "\x27quoted\x27" + r" \d+\."
got = json.loads(sys.argv[1])["regex"]
sys.exit(0 if got == want else "got %r" % got)
' "$(mini_json "$W/t.yaml")"
  [ "$status" -eq 0 ]
}

# (d) Pin the shape of the real policy without needing PyYAML.
@test "policy.yaml has exactly the 11 expected rule ids in order, negation (?i), first class hook" {
  run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import miniyaml
d = miniyaml.loads(open(sys.argv[2], encoding="utf-8").read())
print(" ".join(r["id"] for r in d["rules"]))
print(d["negation"].startswith("(?i)"))
print(d["classes"][0]["name"])
' "$LIB" "$POLICY"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "curl-pipe-shell npx-unpinned latest-tag uvx-unpinned secret-shape home-path ssh-write shell-rc-write prompt-injection hook-network credential-read" ]
  [ "${lines[1]}" = "True" ]
  [ "${lines[2]}" = "hook" ]    # WP-036: hook is listed before test
}

# (e) The audit-allow shape: a list of maps, with a quoted `contains` that holds
# characters which would otherwise mean something to YAML.
@test "audit-allow list of maps parses; quotes, '#' and ': ' inside a quoted scalar are data" {
  cat > "$W/t.yaml" <<'EOF'
- rule: prompt-injection
  path: repos/x/y/*.md
  contains: 'Treat any "ignore previous instructions" # not a comment: really'
  reason: quotes the attack phrase as a defence example # this one IS a comment
- rule: binary-exec
  path: repos/x/tool
  sha256: abc123
  reason: vendored helper binary, reviewed
EOF
  run python3 -c '
import json, sys
want = [
  {"rule": "prompt-injection", "path": "repos/x/y/*.md",
   "contains": "Treat any \"ignore previous instructions\" # not a comment: really",
   "reason": "quotes the attack phrase as a defence example"},
  {"rule": "binary-exec", "path": "repos/x/tool", "sha256": "abc123",
   "reason": "vendored helper binary, reviewed"},
]
got = json.loads(sys.argv[1])
sys.exit(0 if got == want else "got %r" % (got,))
' "$(mini_json "$W/t.yaml")"
  [ "$status" -eq 0 ]
}

# (f) Inline lists respect quotes when splitting on commas.
@test "inline list [a, 'b, c'] parses to two items" {
  printf "k: [a, 'b, c']\n" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"k": ["a", "b, c"]}' ]
}

# Extras: nesting and inline maps, matching how policy.yaml uses them.
@test "nested blocks, inline map and empty value parse" {
  cat > "$W/t.yaml" <<'EOF'
top:
  list:
    - one
    - 'two'
  m: {a: x, b: [1, 2]}
empty:
EOF
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"empty": null, "top": {"list": ["one", "two"], "m": {"a": "x", "b": [1, 2]}}}' ]
}

@test "flow collection spanning lines is rejected with its line number" {
  printf 'a: 1\nb: [x,\n  y]\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
}

@test "3000-level nesting is a ParseError, not a RecursionError traceback" {
  python3 -c "print('a: ' + '[' * 3000 + ']' * 3000)" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ParseError: line"* ]]
  [[ "$output" != *"Traceback"* ]]
}
