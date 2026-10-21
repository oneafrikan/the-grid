#!/usr/bin/env bats
# Canon protection: GitHub must request the owner's review on any change under knowledge/canon/.
# Spec: openspec/changes/epistemic-enforcement, canon-protection ("CODEOWNERS covers canon").

load helpers/setup
bats_require_minimum_version 1.5.0

setup() {
  common_setup
  KN="$REPO_ROOT/scripts/knowledge.py"
  PROJ="$BATS_TEST_TMPDIR/proj"
}

teardown() {
  common_teardown
}

@test "CODEOWNERS has a knowledge/canon/ rule with an owner and no other rule line" {
  # Drop comments and blank lines; exactly one rule line must remain, so a wider
  # pattern (or a second path) cannot be added without this test changing.
  run grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.github/CODEOWNERS"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^knowledge/canon/\ @[A-Za-z0-9._-]+$ ]]
}

@test "PR template carries the canon checkbox with the exact detection command" {
  # The merger runs this one command to learn whether a human must merge; the
  # base is origin/main because the retired next branch no longer exists.
  run grep -F -- '- [ ] No path under `knowledge/canon/` changed, or a human is merging this: `git diff --name-only origin/main...HEAD -- knowledge/canon`' "$REPO_ROOT/.github/pull_request_template.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md block says canon is never merged without a human" {
  # Take the block that starts at the line naming the path and the rule, up to
  # the next blank line, so the three words must sit together and not be
  # satisfied by unrelated mentions elsewhere in the file.
  block="$(awk '/knowledge\/canon\// && /never merged/ {p=1} p && /^$/ {exit} p' "$REPO_ROOT/CLAUDE.md")"
  [ -n "$block" ]
  [[ "$block" == *'knowledge/canon/'* ]]
  [[ "$block" == *'never merged'* ]]
  [[ "$block" == *'human'* ]]
  [[ "$block" == *'origin/main...HEAD'* ]]
}

# --- no automatic write path into canon on a direct branch -------------------------------------
# Spec: epistemic-enforcement, canon-protection ("No automatic write path into canon on a direct
# branch"). A canon change must reach the repo only through `apply --proposal-for` and a human
# merged PR; the plain `plan` + `apply --plan` sweep must never write there.

# fixture — a git repo with one empty base commit. Identity comes from the environment (no
# address in this file) and no user or system git config is read.
fixture() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL=t@example.com GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$PROJ"
  git -C "$PROJ" init -q
  git -C "$PROJ" commit -q --allow-empty -m base
}

# canon_signal — file one signal that claims stage canonical, commit it, print its file name.
canon_signal() {
  KNOWLEDGE_NOW=20261018T100030Z python3 -I "$KN" file --root "$PROJ" --filer agent-a \
    --claim "claim one" --stage canonical --warrant "seen in CI" | xargs basename
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -q -m signals
}

# ledger_py <expression over L> — evaluate an expression over the list of ledger records.
ledger_py() {
  python3 -I -c "import json,sys; L=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; print($1)" \
    "$PROJ/signals/done/ledger.jsonl"
}

@test "apply --plan: a pending canonical claim leaves knowledge/canon unchanged and is recorded as escalated" {
  fixture
  name=$(canon_signal)
  python3 -I "$KN" plan --root "$PROJ" >"$BATS_TEST_TMPDIR/plan.json"
  KNOWLEDGE_NOW=20261019T120000Z run --separate-stderr python3 -I "$KN" apply --root "$PROJ" \
    --plan "$BATS_TEST_TMPDIR/plan.json"
  [ "$status" -eq 0 ]
  # No canon directory, no file anywhere under knowledge/, and git sees nothing there.
  [ ! -e "$PROJ/knowledge/canon" ]
  [ -z "$(git -C "$PROJ" status --porcelain -- knowledge)" ]
  [ -z "$(find "$PROJ/knowledge" -type f 2>/dev/null)" ]
  # The sweep still did its bookkeeping: one ledger line, escalated, with no entry written.
  [ "$(ledger_py "[(r['signal'], r['disposition'], r['entry']) for r in L]")" \
    = "[('$name', 'escalated', None)]" ]
}

@test "apply --plan: a forged plan item with stage canonical exits 2 and writes nothing" {
  fixture
  name=$(canon_signal)
  printf '{"signals": [{"file": "%s", "disposition": "written", "stage": "canonical", "entry": "K-00000000"}]}\n' \
    "$name" >"$BATS_TEST_TMPDIR/forged.json"
  KNOWLEDGE_NOW=20261019T120000Z run --separate-stderr python3 -I "$KN" apply --root "$PROJ" \
    --plan "$BATS_TEST_TMPDIR/forged.json"
  [ "$status" -eq 2 ]
  [ ! -e "$PROJ/knowledge" ]
  # The signal was not moved and no ledger was started: the whole tree is untouched.
  [ -e "$PROJ/signals/$name" ]
  [ ! -e "$PROJ/signals/done" ]
  [ -z "$(git -C "$PROJ" status --porcelain)" ]
}

# canon_static_check <path to knowledge.py> — AST tripwire for the canon write path. Prints one
# line per violation and exits 1 if there are any.
#
# It checks, on the source text only:
#   1. write_canon_entry is defined once, and every reference to it (call, alias, callback,
#      attribute) sits inside _cmd_proposal.
#   2. every reference to _cmd_proposal sits in the `if proposal_for is not None` branch of
#      _cmd_apply, i.e. the --proposal-for code path.
#   3. no other function that writes (open for writing, _write_text, os.makedirs, os.replace,
#      shutil.move, write_text, rename, or a `git mv` argv) also mentions a string containing
#      "canon" outside its docstring. This catches a path built from the word canon in the same
#      function as the write, including `_STAGE_DIRS["canonical"]`.
# It does NOT prove the absence of a canon write: a path assembled across functions (a helper
# returning the canon directory, a stage name read from a file) is invisible to it. The dynamic
# tests above cover that. It is a tripwire for the obvious edit, not a proof.
canon_static_check() {
  python3 -I -c '
import ast, sys

WRITER, CALLER, DISPATCH = "write_canon_entry", "_cmd_proposal", "_cmd_apply"
WRITE_NAMES = {"_write_text", "makedirs", "replace", "move", "rename", "write_text",
               "write_bytes", "copy", "copyfile", "copytree", "symlink", "link"}
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
errors = []


def name_of(node):
    """The called name: `f` for f(...) and `x.f` for x.f(...)."""
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return None


def is_write(call):
    fn = name_of(call.func)
    if fn in WRITE_NAMES:
        return True
    if fn == "open":
        mode = call.args[1] if len(call.args) > 1 else None
        for kw in call.keywords:
            if kw.arg == "mode":
                mode = kw.value
        return isinstance(mode, ast.Constant) and isinstance(mode.value, str) \
            and any(c in mode.value for c in "wax+")
    # A subprocess argv that is a list holding the word mv (git mv).
    return any(isinstance(a, ast.List)
               and any(isinstance(e, ast.Constant) and e.value == "mv" for e in a.elts)
               for a in call.args)


def docstring(fn):
    first = fn.body[0] if fn.body else None
    ok = isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
        and isinstance(first.value.value, str)
    return first.value if ok else None


funcs = [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
if sum(1 for f in funcs if f.name == WRITER) != 1:
    errors.append("%s is not defined exactly once" % WRITER)
if sum(1 for f in funcs if f.name == CALLER) != 1:
    errors.append("%s is not defined exactly once" % CALLER)

# Rule 1 and 2: where the writer and its caller are referenced, by enclosing function name.
dispatch = [f for f in funcs if f.name == DISPATCH]
branch = set()
for fn in dispatch:
    for node in ast.walk(fn):
        if isinstance(node, ast.If) and any(isinstance(t, ast.Name) and t.id == "proposal_for"
                                            for t in ast.walk(node.test)):
            branch.update(id(n) for stmt in node.body for n in ast.walk(stmt))


class Refs(ast.NodeVisitor):
    def __init__(self):
        self.stack = []

    def visit_FunctionDef(self, node):
        self.stack.append(node.name)
        self.generic_visit(node)
        self.stack.pop()

    visit_AsyncFunctionDef = visit_FunctionDef

    def seen(self, node, ident):
        where = self.stack[-1] if self.stack else "<module>"
        if ident == WRITER and where not in (CALLER, WRITER):
            errors.append("%s referenced in %s" % (WRITER, where))
        if ident == CALLER and id(node) not in branch:
            errors.append("%s referenced outside the proposal_for branch of %s (in %s)"
                          % (CALLER, DISPATCH, where))

    def visit_Name(self, node):
        self.seen(node, node.id)

    def visit_Attribute(self, node):
        self.seen(node, node.attr)
        self.generic_visit(node)


Refs().visit(tree)

# Rule 3: a writing function (other than the writer) that also mentions "canon".
for fn in funcs:
    if fn.name == WRITER:
        continue
    doc = docstring(fn)
    nodes = [n for n in ast.walk(fn) if n is not doc]
    writes = [n for n in nodes if isinstance(n, ast.Call) and is_write(n)]
    canon = [n for n in nodes if isinstance(n, ast.Constant) and isinstance(n.value, str)
             and "canon" in n.value.lower()]
    if writes and canon:
        errors.append("%s writes and mentions canon (line %d)" % (fn.name, canon[0].lineno))

for e in errors:
    print(e)
sys.exit(1 if errors else 0)
' "$1"
}

@test "knowledge.py: write_canon_entry is the only canon writer and only the --proposal-for path reaches it" {
  run canon_static_check "$KN"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "static canon check: trips on a second caller, an aliased writer and a canon write elsewhere" {
  # Prove the tripwire can fail, so a silent pass above means something. Each mutant appends one
  # function to a copy of knowledge.py in the temp dir; the real file is never touched.
  mutant() {
    cp "$KN" "$BATS_TEST_TMPDIR/mutant.py"
    printf '\n%s\n' "$1" >>"$BATS_TEST_TMPDIR/mutant.py"
    run canon_static_check "$BATS_TEST_TMPDIR/mutant.py"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$2"* ]]
  }
  mutant 'def _evil(root, sig, name, today):
    write_canon_entry(root, sig, name, today)' "write_canon_entry referenced in _evil"
  mutant 'def _evil():
    return write_canon_entry' "write_canon_entry referenced in _evil"
  mutant 'def _evil(root):
    with open(root + "/knowledge/canon/x.md", "w") as fh:
        fh.write("x")' "_evil writes and mentions canon"
  mutant 'def _evil(root, rel):
    _write_text(root, "knowledge/%s/x.md" % _STAGE_DIRS["canonical"], "x")' "_evil writes and mentions canon"
  mutant 'def _evil(root):
    return _cmd_proposal(root, "x")' "_cmd_proposal referenced outside"
}
