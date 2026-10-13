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
    # newline="": keep CR as written (text mode would turn CRLF into LF before miniyaml saw it,
    # as audit.py does not: it decodes raw bytes).
    doc = miniyaml.loads(open(sys.argv[2], encoding="utf-8", newline="").read())
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

# (a2) WP-047: every other document miniyaml reads in this repo agrees with PyYAML too
# (grid.yaml and each audit-allow block of CURATION.md), so a stricter scalar rule can
# never silently change what a shipped file means.
@test "grid.yaml and the CURATION.md audit-allow blocks equal yaml.safe_load when PyYAML is available" {
  local py=python3
  [ -x "$REPO_ROOT/agent-factory/.venv/bin/python" ] && py="$REPO_ROOT/agent-factory/.venv/bin/python"
  if ! "$py" -c "import yaml" 2>/dev/null; then
    skip "PyYAML not importable by $py"
  fi
  run "$py" -c '
import re, sys, yaml
sys.path.insert(0, sys.argv[1])
import miniyaml
docs = [open(sys.argv[2] + "/grid.yaml", encoding="utf-8").read()]
cur = open(sys.argv[2] + "/CURATION.md", encoding="utf-8").read()
docs += re.findall(r"```yaml audit-allow\n(.*?)```", cur, re.S)
for text in docs:
    if miniyaml.loads(text) != yaml.safe_load(text):
        sys.exit("miniyaml and PyYAML disagree on:\n" + text[:200])
' "$LIB" "$REPO_ROOT"
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
@test "policy.yaml has exactly the 26 expected rule ids in order, negation (?i), first class hook" {
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
  [ "${lines[0]}" = "curl-pipe-shell npx-unpinned latest-tag uvx-unpinned secret-shape home-path ssh-write shell-rc-write prompt-injection hook-network credential-read decode-and-exec download-then-run eval-cat exec-urlopen powershell-iex pip-git-install runner-unpinned exfil-pipe destructive-system claude-config-write hook-declared mcp-declared lifecycle-script allowed-tools-bash plugin-hooks-declared" ]
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

# --- WP-047: never silently mis-type what PyYAML reads differently -------------------------
# The rule for every bare scalar: if miniyaml and PyYAML would read it as different values,
# miniyaml rejects it (quote it to get a string). Each form below was once accepted and
# mis-typed. `rejected 'DOC' N` writes DOC (a printf format) and wants "ParseError: line N:".

rejected() {
  printf -- "$1" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == "ParseError: line $2:"* ]]
}

@test "True (mixed-case boolean) is rejected, not read as a string" {
  rejected 'a: 1\nb: True\n' 2
}

@test "FALSE (upper-case boolean) is rejected, not read as a string" {
  rejected 'a: FALSE\n' 1
}

@test "mixed-case boolean inside an inline list is rejected" {
  rejected 'a: [x, True]\n' 1
}

@test "leading-zero integer 010 is rejected (PyYAML reads octal 8)" {
  rejected 'a: 010\n' 1
}

@test "leading-zero integer 0777 is rejected" {
  rejected 'a: 0777\n' 1
}

@test "leading-zero 09 is rejected (an int here, a string in PyYAML)" {
  rejected 'a: 09\n' 1
}

@test "hex integer 0x1F is rejected" {
  rejected 'a: 0x1F\n' 1
}

@test "binary integer 0b11 is rejected" {
  rejected 'a: 0b11\n' 1
}

@test "octal-prefixed 0o17 is rejected" {
  rejected 'a: 0o17\n' 1
}

@test "underscore in a number 1_0 is rejected" {
  rejected 'a: 1_0\n' 1
}

@test "explicit plus sign +1 is rejected" {
  rejected 'a: +1\n' 1
}

@test "sexagesimal 1:30 is rejected (PyYAML reads 90)" {
  rejected 'a: 1:30\n' 1
}

@test "sexagesimal 12:30:45 is rejected" {
  rejected 'a: 12:30:45\n' 1
}

@test "date 2026-10-11 is rejected (PyYAML reads a date)" {
  rejected 'a: 2026-10-11\n' 1
}

@test "timestamp 2026-10-11T10:00:00Z is rejected" {
  rejected 'a: 2026-10-11T10:00:00Z\n' 1
}

@test ".inf and .nan are rejected" {
  rejected 'a: .inf\n' 1
  rejected 'a: .NaN\n' 1
}

@test "'=' and '<<' as values are rejected (PyYAML has no constructor for them)" {
  rejected 'a: =\n' 1
  rejected 'a: <<\n' 1
}

@test "the << merge key is rejected" {
  rejected 'a: 1\n<<: {b: 2}\n' 2
}

@test "nested sequence '- - a' is rejected" {
  rejected '- - a\n' 1
}

@test "a '- ' value inside an inline list is rejected" {
  rejected 'a: [- a]\n' 1
}

@test "'#' comment inside an inline list is rejected" {
  rejected 'a: [x #y]\n' 1
}

@test "a TAB before '#' is rejected (PyYAML does not treat it as a comment start)" {
  rejected 'a: b\t# c\n' 1
}

@test "Arabic-Indic digits are a string, as in PyYAML, not an integer" {
  printf 'a: \xd9\xa1\xd9\xa2\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a": "\u0661\u0662"}' ]
}

@test "plain numbers, 1.2.3 and quoted look-alikes still parse as before" {
  printf "a: 0\nb: -5\nc: 1.2.3\nd: '010'\ne: \"2026-10-11\"\nf: 12\n" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a": 0, "b": -5, "c": "1.2.3", "d": "010", "e": "2026-10-11", "f": 12}' ]
}

# Differential check against PyYAML: whatever miniyaml accepts must equal yaml.safe_load.
# The scalar set is every word of length 1-3 over an alphabet that builds numbers, dates,
# times, booleans and specials, plus a curated list; six templates put each one in a block
# map, a block list, and (nested) flow lists and maps. Rejecting is always allowed.
@test "differential: nothing miniyaml accepts reads differently in PyYAML" {
  local py=python3
  [ -x "$REPO_ROOT/agent-factory/.venv/bin/python" ] && py="$REPO_ROOT/agent-factory/.venv/bin/python"
  if ! "$py" -c "import yaml" 2>/dev/null; then
    skip "PyYAML not importable by $py"
  fi
  run "$py" -c '
import itertools, sys, yaml
sys.path.insert(0, sys.argv[1])
import miniyaml
curated = ["True","TRUE","False","FALSE","true","false","010","0777","0x1F","0o17","0b11",
  "1_0","+1","1:30","12:30:45","2026-10-11","2026-10-11T10:00:00Z","0","-0","1.5","1e3","null",
  "~","yes","No","on","OFF","a:b","1:2:3:4","09","-010","+0","1__0","1_","60:00","1:30:00.5",
  ".inf",".NaN","-.inf","=","<<","hello world","a#b","2026-13-45","0_7","0xdeadBEEF","- a",
  "x #y","b\t# c","\u0661\u0662","abc","-","?","? a","1.2.3","- -"]
alphabet = "019_:+-.xeEtT "
words = ["".join(p) for n in (1, 2, 3) for p in itertools.product(alphabet, repeat=n)]
templates = ["a: @\n", "- @\n", "a: [@]\n", "a: [x, @]\n", "a: {k: @}\n", "a:\n  - @\n"]
def same(a, b):
    if type(a) is not type(b):
        return False
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b or (a != a and b != b)   # NaN
bad = []
for t in templates:
    for w in curated + words:
        text = t.replace("@", w)
        try:
            mine = miniyaml.loads(text)
        except miniyaml.ParseError:
            continue
        try:
            theirs = yaml.safe_load(text)
        except Exception:
            bad.append("PyYAML rejects, miniyaml accepts: %r -> %r" % (text, mine)); continue
        if not same(mine, theirs):
            bad.append("%r: miniyaml %r, PyYAML %r" % (text, mine, theirs))
print("\n".join(bad[:20]))
sys.exit(1 if bad else 0)
' "$LIB"
  echo "$output"
  [ "$status" -eq 0 ]
}

# --- WP-047: no non-ParseError escapes, BOM ------------------------------------------------

@test "a 5000-digit integer is a ParseError, not a ValueError traceback" {
  python3 -c "print('a: ' + '9' * 5000)" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == "ParseError: line 1:"* ]]
}

@test "3000-level block nesting is a ParseError naming a real line" {
  python3 -c "
for i in range(3000):
    print(' ' * i + 'a:')
print(' ' * 3000 + 'b: 1')" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == "ParseError: line "[1-9]* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "3000-level flow nesting names line 1, not line 0" {
  python3 -c "print('a: ' + '[' * 3000 + ']' * 3000)" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [[ "$output" == "ParseError: line 1:"* ]]
}

@test "a leading UTF-8 BOM is ignored, as PyYAML does" {
  printf '\xef\xbb\xbfowned_roots: [skills]\nb: 2\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"b": 2, "owned_roots": ["skills"]}' ]
}

@test "a BOM does not shift the line number of a later error" {
  rejected '\xef\xbb\xbfa: 1\nb: True\n' 2
}

# --- WP-047: strengthen what the file pins (24 recorded single-edit mutants) --------------

@test "yes, no, on, off and null are rejected as ambiguous" {
  rejected 'a: yes\n' 1
  rejected 'a: No\n' 1
  rejected 'a: on\n' 1
  rejected 'a: OFF\n' 1
  rejected 'a: null\n' 1
  rejected 'a: ~\n' 1
}

@test "floats are rejected as ambiguous" {
  rejected 'a: 1.5\n' 1
  rejected 'a: .5\n' 1
  rejected 'a: 1e3\n' 1
}

@test "true and false (lower case) are booleans, not strings" {
  printf 'a: true\nb: false\nc: [true, false]\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a": true, "b": false, "c": [true, false]}' ]
}

@test "CRLF line endings parse like LF, including blank and comment lines" {
  printf 'a: 1\r\n\r\n# note\r\nb:\r\n  - x\r\n  - y\r\nc: z\r\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a": 1, "b": ["x", "y"], "c": "z"}' ]
}

@test "a bad escape in a double-quoted string is rejected with its line" {
  rejected 'a: 1\nb: "x\\qy"\n' 2
}

@test "double-quoted JSON escapes are decoded" {
  printf 'a: "x\\ty"\n' > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a": "x\ty"}' ]
}

@test "duplicate key in an inline map is rejected" {
  rejected 'a: {k: 1, k: 2}\n' 1
}

@test "text after a quoted value is rejected" {
  rejected "a: 'x' y\n" 1
  rejected 'a: "x" y\n' 1
}

@test "text after an inline list is rejected" {
  rejected 'a: [x] y\n' 1
}

@test "a more-indented line after a scalar is rejected as unexpected indentation" {
  rejected 'a: 1\n  b: 2\n' 2
}

@test "a document that starts indented and then returns to column 0 is rejected" {
  rejected '  a: 1\nb: 2\n' 2
}

@test "a trailing comment after a quoted value is allowed" {
  printf "a: 'x' # note\nb: [1, 2] # note\n" > "$W/t.yaml"
  run mini_json "$W/t.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a": "x", "b": [1, 2]}' ]
}

@test "a bare string containing ': ' is rejected" {
  rejected 'a: x: y\n' 1
}

@test "an unterminated quote and an unterminated inline list are rejected" {
  rejected "a: 'x\n" 1
  rejected 'a: [x\n' 1
}
