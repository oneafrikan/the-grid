#!/usr/bin/env bats
# Tests for scripts/lib/fmyaml.py, the YAML structure scanner behind the frontmatter checks of
# scripts/audit.py. Pure parsing: no scanning here. A self-check of my own implementation;
# independent verification is for qa-engineer / sdet.

load helpers/setup

setup() {
  common_setup
  LIB="$REPO_ROOT/scripts/lib"
}

teardown() {
  common_teardown
}

# fm_probe TEXT -> prints "ok <hooks-key-count>" or "error <message>" for the frontmatter TEXT
# (the text between the fences, printf %b escapes honoured).
fm_probe() {
  python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import fmyaml
body = sys.argv[2].encode().decode("unicode_escape")
fm = fmyaml.analyse(["---"] + body.split("\n") + ["---", "body"])
print("error " + fm.error[1] if fm.error else "ok %d" % len(fm.hooks))
' "$LIB" "$1"
}

@test "finds a hooks key in every spelling: block, nested, flow, quoted, escaped, anchored, explicit" {
  local c
  while IFS= read -r c; do
    run fm_probe "$c"
    [ "$output" = "ok 1" ] || { echo "case: $c -> $output" >&2; return 1; }
  done <<'EOF'
hooks:\n  Stop: []
a:\n  b:\n    hooks: x
{hooks: {a: b}}
{name: x, hooks: [1, 2]}
"hooks":\n  Stop: []
'hooks': x
"\\x68ooks": x
"\\u0068ooks": x
"ho\\\n  oks": x
? hooks\n: x
&k hooks: x
!!str hooks: x
x: &c {hooks: 1}\n<<: *c
x: [{hooks: 1}]
x:\n  - a: 1\n    hooks: 2
hooks : x
EOF
}

@test "a hooks-less frontmatter has no hooks key, even when block scalars hold look-alike text" {
  local c
  while IFS= read -r c; do
    run fm_probe "$c"
    [ "$output" = "ok 0" ] || { echo "case: $c -> $output" >&2; return 1; }
  done <<'EOF'
name: x\ndescription: |\n  hooks: not a key\n  ...\n  ---
name: x\ndescription: >\n  hooks:\n\n  more
name: x\ndescription: "the hooks: word"
name: x\ndescription: plain hooks in text
name: x\nlist:\n  - hooks\n  - 'hooks'
EOF
}

@test "malformed or unsupported YAML is an error (the caller fails closed), never a silent skip" {
  local c
  while IFS= read -r c; do
    run fm_probe "$c"
    [[ "$output" == error* ]] || { echo "case: $c -> $output" >&2; return 1; }
  done <<'EOF'
a: b: c
a:\n   b: 1\n  c: 2
a: [1, 2
a: {x: 1
a: "open
a: 'open
a: |\n  ok\n...\nb: 1
a: &
a: *
a:\n\tb: 1
?
EOF
}

@test "budgets: oversize text, deep nesting and a node flood are errors, not hangs" {
  run python3 -c '
import sys, time
sys.path.insert(0, sys.argv[1])
import fmyaml
t = time.time()
big = fmyaml.analyse(["---", "a: " + "x" * 200000, "---"])
assert big.error and "larger" in big.error[1], big.error
deep = fmyaml.analyse(["---", "a: " + "[" * 3000 + "]" * 3000, "---"])
assert deep.error and "too deep" in deep.error[1], deep.error
blk = fmyaml.analyse(["---"] + [" " * i + "k%d:" % i for i in range(0, 200)] + ["---"])
assert blk.error and "too deep" in blk.error[1], blk.error
flood = fmyaml.analyse(["---", "a: [" + ",".join("x" for _ in range(30000)) + "]", "---"])
assert flood.error and "nodes" in flood.error[1], flood.error
assert time.time() - t < 20
' "$LIB"
  [ "$status" -eq 0 ]
}

@test "frontmatter extraction: only a column-0 '---' ends it; an indented '---' or any '...' does not" {
  run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import fmyaml
fm = fmyaml.analyse(["---", "a: |", "  ---", "  ...", "hooks: x", "---", "b: 1"])
assert fm.end == 5 and not fm.error and len(fm.hooks) == 1, (fm.end, fm.error, fm.hooks)
fm = fmyaml.analyse(["---  ", "hooks: x", "---\t", ""])
assert fm.end == 2 and len(fm.hooks) == 1
assert fmyaml.analyse(["no fence", "hooks: x"]) is None
fm = fmyaml.analyse(["---", "hooks: x"])
assert fm.error and fm.end is None
' "$LIB"
  [ "$status" -eq 0 ]
}

# Differential check against PyYAML where it is available: for every snippet both readers must agree
# on "parses / does not parse" and on "has a hooks key somewhere". (PyYAML is NOT needed at run time.)
@test "agrees with PyYAML on parse success and hooks-key presence over a snippet corpus" {
  local py=python3
  [ -x "$REPO_ROOT/agent-factory/.venv/bin/python" ] && py="$REPO_ROOT/agent-factory/.venv/bin/python"
  "$py" -c "import yaml" 2>/dev/null || skip "PyYAML not importable by $py"
  run "$py" -c '
import sys, yaml
sys.path.insert(0, sys.argv[1])
import fmyaml

def has_hooks(o):
    if isinstance(o, dict):
        return any(k == "hooks" or has_hooks(k) or has_hooks(v) for k, v in o.items())
    if isinstance(o, list):
        return any(has_hooks(i) for i in o)
    return False

corpus = [
 "name: x\nhooks:\n  Stop:\n    - command: a",
 "name: x\ndescription: |\n  ...\n  ---\nhooks: y",
 "name: x\ndescription: >-\n  folded\n  text\n\nhooks:\n  A: 1",
 "{name: x, hooks: {A: [1, 2]}}",
 "x: &c {hooks: 1}\n<<: *c",
 "x: &c\n  hooks: 1\ny:\n  <<: *c",
 "a:\n- 1\n- 2\nb: 3",
 "a:\n  - b: 1\n    c: 2\n  - d",
 "a: \"line one\n  line two\"\nb: 1",
 "a: \x27it\x27\x27s\x27\nb: [x, \"y\", {k: v}]",
 "a: plain\n  continued\n  more\nb: 1",
 "a: 1 # comment\n# whole\nb: 2",
 "? complex\n: value\nhooks: 1",
 "a: [1,\n  2,\n  3]\nb: {x: 1,\n  y: 2}",
 "a: |+\n  keep\n\nb: 1",
 "a: |2\n    indented\nb: 1",
 "a: !!str 1\nb: &x 2\nc: *x",
 "a:\n  b:\n    c:\n      hooks: 1",
 "a: b: c",
 "a:\n   b: 1\n  c: 2",
 "a: [1, 2",
 "a: \"open",
 "a: *",
 "a:\n\tb: 1",
 "- a\n- b\nhooks: 1",
 "\"hooks\": 1",
 "a: 1\n...\nb: 2",
 "a: b\n  c: d",
 "hooks: [a, b]\nhooks2: 1",
]
bad = []
for text in corpus:
    try:
        theirs = yaml.safe_load(text); ok = True
    except Exception:
        theirs, ok = None, False
    fm = fmyaml.analyse(["---"] + text.split("\n") + ["---"])
    mine_ok = fm.error is None
    if ok != mine_ok or (ok and has_hooks(theirs) != bool(fm.hooks)):
        bad.append((text, ok, mine_ok, fm.error))
if bad:
    sys.exit("disagreements: %r" % bad)
' "$LIB"
  echo "$output" >&2
  [ "$status" -eq 0 ]
}
