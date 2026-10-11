#!/usr/bin/env bats
# Tests for scripts/grid, group 1 of change `manifest-lock-install`: the CLI
# skeleton, the grid.yaml reader, the typed-entry reader, the grid.lock reader
# with its input validation, and the `audit` passthrough.
#
# Every fixture is built inside the test (temp dirs + printf/python3); nothing
# touches the network, the real ~/.grid or the real ~/.claude. These tests
# verify my own implementation (a self-check); independent verification is for
# qa-engineer / sdet.

load helpers/setup

setup() {
  common_setup
  GRID="$REPO_ROOT/scripts/grid"
  F=$(mktemp -d)            # fixture grid dir: its own grid.yaml / grid.lock / scripts/
  mkdir -p "$F/scripts"
  # Never let a test reach the real state dir.
  export GRID_STATE_DIR="$F/state"
}

teardown() {
  rm -rf "$F"
  unset GRID_STATE_DIR
  common_teardown
}

# gpy 'CODE' [ARG...] -> run CODE with the scripts/grid module loaded as `g`
# (importlib + SourceFileLoader: the file has no .py suffix). Extra arguments
# arrive as sys.argv[3:]. A GridError prints its message to stderr and exits
# with its code, exactly as main() would. Bytecode writing is switched off so
# the import leaves no __pycache__ in the repo.
gpy() {
  python3 -c '
import sys, importlib.machinery, importlib.util
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("grid_cli", sys.argv[1])
spec = importlib.util.spec_from_loader("grid_cli", loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)
try:
    exec(sys.argv[2])
except g.GridError as exc:
    sys.stderr.write(str(exc) + "\n")
    sys.exit(exc.code)
' "$GRID" "$1" "${@:2}"
}

# write_yaml TEXT -> $F/grid.yaml (printf %b so tests can write \n).
write_yaml() { printf '%b' "$1" > "$F/grid.yaml"; }

# load_yaml -> parse $F/grid.yaml and print the result as JSON.
load_yaml() {
  gpy 'import json; print(json.dumps(g.load_grid_yaml(sys.argv[3]), sort_keys=True))' "$F"
}

VALID_YAML='version: 1\nsources:\n  alpha:\n    url: https://example.com/a.git\nwired:\n  baseline: b.txt\n'

# --- (a) the executable and the Python 3.8 floor ------------------------------

@test "scripts/grid is executable" {
  [ -x "$GRID" ]
}

@test "scripts/grid parses as Python 3.8 syntax and leaves no __pycache__" {
  # Other suites (usage, audit) may legitimately leave __pycache__ dirs behind, so
  # compare before/after rather than asserting there is none.
  local before after
  before=$(find "$REPO_ROOT/scripts" -name __pycache__ | LC_ALL=C sort)
  run python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 8))' "$GRID"
  [ "$status" -eq 0 ]
  # Running the CLI (which imports miniyaml) must not create one either.
  run python3 "$GRID" --grid-dir "$F" install
  [ "$status" -eq 2 ]
  after=$(find "$REPO_ROOT/scripts" -name __pycache__ | LC_ALL=C sort)
  [ "$before" = "$after" ]
}

# --- (b) grid.yaml --------------------------------------------------------------

@test "the real grid.yaml loads" {
  run gpy 'import json; print(json.dumps(g.load_grid_yaml(sys.argv[3]), sort_keys=True))' "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version": 1'* ]]
  [[ "$output" == *'"baseline": "baseline-submodules.example.txt"'* ]]
}

@test "every repo in an untyped baseline line is a key under sources" {
  run gpy '
doc = g.load_grid_yaml(sys.argv[3])
adds, _ = g.read_wired_entries([sys.argv[3] + "/" + doc["wired"]["baseline"]])
missing = sorted(set(a.split("/")[0] for a in adds) - set(doc["sources"]))
print("missing:", missing)
sys.exit(1 if missing else 0)' "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "a minimal valid grid.yaml loads and ref defaults to HEAD" {
  write_yaml "$VALID_YAML"
  run load_yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ref": "HEAD"'* ]]
  [[ "$output" == *'"url": "https://example.com/a.git"'* ]]
}

@test "grid.yaml: a list where a scalar is expected exits 2 naming the key" {
  write_yaml 'version: 1\nsources:\n  alpha:\n    url:\n      - https://example.com/a.git\nwired:\n  baseline: b.txt\n'
  run load_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"sources.alpha.url"* ]]
}

@test "grid.yaml: an unknown top-level key exits 2 naming it" {
  write_yaml "${VALID_YAML}bogus: 1\n"
  run load_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown key 'bogus'"* ]]
}

@test "grid.yaml: an unknown nested key exits 2 naming it" {
  write_yaml 'version: 1\nsources:\n  alpha:\n    url: https://example.com/a.git\n    branch: main\nwired:\n  baseline: b.txt\n'
  run load_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown key 'branch'"* ]]
}

@test "grid.yaml: version 2 exits 2 naming the key" {
  write_yaml 'version: 2\nsources:\n  alpha:\n    url: https://example.com/a.git\nwired:\n  baseline: b.txt\n'
  run load_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"'version' must be 1"* ]]
}

@test "grid.yaml: a missing required key exits 2 naming it" {
  write_yaml 'version: 1\nsources:\n  alpha:\n    url: https://example.com/a.git\n'
  run load_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"'wired'"* ]]
}

@test "grid.yaml: a syntax error exits 2 with the line number" {
  write_yaml 'version: 1\nsources: [unterminated\n'
  run load_yaml
  [ "$status" -eq 2 ]
  [[ "$output" == *"line 2"* ]]
}

@test "grid.yaml: reserved rules/harnesses keys load with the exact notice" {
  write_yaml "${VALID_YAML}rules:\n  - sql\nharnesses:\n  - codex\n"
  run load_yaml
  [ "$status" -eq 0 ]
  [[ "$output" == *"grid: grid.yaml key 'rules' is reserved and ignored by this version"* ]]
  [[ "$output" == *"grid: grid.yaml key 'harnesses' is reserved and ignored by this version"* ]]
}

# --- (c) typed entries -----------------------------------------------------------

@test "read_wired_entries ignores every typed entry and keeps the untyped ones" {
  printf '%s\n' \
    '# a comment' \
    'project:x' '-project:x' 'rules:sql' '-rules:sql' 'harness:codex' '-harness:codex' 'future:y' \
    'repo   # trailing comment' 'repo/skill' '-repo' '-repo/skill' '' > "$F/m.txt"
  run gpy '
adds, denies = g.read_wired_entries([sys.argv[3], sys.argv[3] + ".missing"])
print("adds=" + ",".join(adds))
print("denies=" + ",".join(denies))' "$F/m.txt"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "adds=repo,repo/skill" ]
  [ "${lines[1]}" = "denies=repo,repo/skill" ]
}

# --- (d) the audit passthrough ---------------------------------------------------

@test "grid audit returns the exit code of scripts/audit.sh unchanged" {
  printf '#!/usr/bin/env bash\nexit 7\n' > "$F/scripts/audit.sh"
  run python3 "$GRID" --grid-dir "$F" audit --owned
  [ "$status" -eq 7 ]
}

@test "grid audit forwards every argument untouched, options first" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/args"\nexit 0\n' "$F" > "$F/scripts/audit.sh"
  run python3 "$GRID" --grid-dir "$F" audit --owned --format json some/dir
  [ "$status" -eq 0 ]
  [ "$(cat "$F/args")" = "$(printf '%s\n' --owned --format json some/dir)" ]
}

@test "grid audit without scripts/audit.sh exits 2" {
  run python3 "$GRID" --grid-dir "$F" audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"audit.sh not found"* ]]
}

# --- (e) no stub subcommands remain ---------------------------------------------------
# (Group 4 implemented doctor, repair and uninstall, the last stubs; their tests
# live in test_grid_health.bats.)

# --- (f) git floor ------------------------------------------------------------------

@test "git below 2.25 exits 2 with the floor message" {
  local stub; stub=$(mktemp -d)
  printf '#!/bin/sh\necho "git version 2.20.1"\n' > "$stub/git"
  chmod +x "$stub/git"
  PATH="$stub:$PATH" run python3 "$GRID" --grid-dir "$F" install
  rm -rf "$stub"
  [ "$status" -eq 2 ]
  [[ "$output" == *"grid: git 2.25 or newer is required (found 2.20.1)"* ]]
}

@test "git at the floor passes the version check" {
  local stub; stub=$(mktemp -d)
  printf '#!/bin/sh\necho "git version 2.25.0"\n' > "$stub/git"
  chmod +x "$stub/git"
  PATH="$stub:$PATH" run python3 "$GRID" --grid-dir "$F" install
  rm -rf "$stub"
  # Past the floor check it reaches install proper, which stops on the fixture's
  # missing grid.yaml (exit 2) rather than on the git version.
  [ "$status" -eq 2 ]
  [[ "$output" == *"grid.yaml not found"* ]]
  [[ "$output" != *"or newer is required"* ]]
}

# --- (g) shared helpers --------------------------------------------------------------

@test "resolve_grid_dir returns a realpath; host_key and state_dir honour their env vars" {
  ln -s "$F" "$F.link"
  GRID_HOST=somehost run gpy '
print(g.resolve_grid_dir(sys.argv[3]))
print(g.host_key())
print(g.state_dir())' "$F.link"
  rm -f "$F.link"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(cd "$F" && pwd -P)" ]
  [ "${lines[1]}" = "somehost" ]
  [ "${lines[2]}" = "$F/state" ]
}

@test "atomic_write writes once and leaves an unchanged file alone" {
  run gpy '
import os
p = sys.argv[3] + "/sub/out.txt"
print(g.atomic_write(p, "a\n"))
ino = os.stat(p).st_ino
print(g.atomic_write(p, "a\n"))
print(os.stat(p).st_ino == ino)
print(g.atomic_write(p, "b\n"))
print(open(p).read().strip())
print(sorted(os.listdir(os.path.dirname(p))))' "$F"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "True" ]
  [ "${lines[1]}" = "False" ]
  [ "${lines[2]}" = "True" ]
  [ "${lines[3]}" = "True" ]
  [ "${lines[4]}" = "b" ]
  [ "${lines[5]}" = "['out.txt']" ]   # no temp file left behind
}

@test "run_git puts the failing command in the error" {
  # GIT_DIR pointing nowhere must not matter: run_git scrubs it.
  GIT_DIR=/nonexistent run gpy '
print(g.run_git(["--version"], timeout=30).strip().split(" ")[0])
try:
    g.run_git(["rev-parse", "--verify", "no-such-ref-xyz"], timeout=30)
except g.GridError as exc:
    print(str(exc).splitlines()[0])
    sys.exit(2)'
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "git" ]
  [[ "${lines[1]}" == "grid: git failed (exit "*"): git rev-parse --verify no-such-ref-xyz" ]]
}

# --- (h) grid.lock reader and input validation ----------------------------------------

SHA40=1111111111111111111111111111111111111111
HASH64=sha256:2222222222222222222222222222222222222222222222222222222222222222

# write_lock FIELD VALUE -> $F/grid.lock with one valid skill entry, FIELD set to VALUE
# (VALUE "__unset__" removes the field).
write_lock() {
  python3 -c '
import json, sys
entry = {"hash": sys.argv[3], "kind": "skill", "name": "docx", "path": "skills/docx",
         "sha": sys.argv[2], "source": "alpha", "tree": sys.argv[2]}
if sys.argv[5] == "__unset__":
    del entry[sys.argv[4]]
else:
    entry[sys.argv[4]] = sys.argv[5]
extra = json.loads(sys.argv[6]) if len(sys.argv) > 6 else []
doc = {"lockVersion": 1, "entries": [entry] + extra}
open(sys.argv[1], "w").write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
' "$F/grid.lock" "$SHA40" "$HASH64" "$1" "$2" "${3:-[]}"
}

# read_lock -> run the validating reader against the fixture grid (source `alpha` only).
read_lock() {
  gpy 'import json
entries = g.read_grid_lock(sys.argv[3], {"alpha": {"url": "u", "ref": "HEAD"}})
print(json.dumps([e["dest"] for e in entries]))' "$F"
}

@test "a valid grid.lock entry loads with its dest" {
  write_lock name docx
  run read_lock
  [ "$status" -eq 0 ]
  [ "$output" = '["repos/alpha/skills/docx"]' ]
}

@test "grid.lock: bad entries exit 2 naming the entry and write nothing" {
  local before after case_ field value
  # field|value pairs: each is invalid for the reason in the design's Input validation.
  for case_ in 'path|../x' 'path|/abs' 'path|a/../b' 'path|-x' 'path|a b' 'path|' 'path|a//b' \
               'path|a\b' 'source|..' 'source|nosuch' 'sha|111111111111111111111111111111111111111' \
               'sha|1111111111111111111111111111111111111111A' \
               'tree|xyz' 'hash|2222222222222222222222222222222222222222222222222222222222222222' \
               'name|a	b' 'path|__unset__'; do
    field="${case_%%|*}"; value="${case_#*|}"
    [ "$value" = "__unset__" ] && field=path
    write_lock "$field" "$value"
    before=$(find "$F" | LC_ALL=C sort | tr '\n' ' ')
    run read_lock
    after=$(find "$F" | LC_ALL=C sort | tr '\n' ' ')
    if [ "$status" -ne 2 ]; then echo "case '$case_': status $status, output: $output" >&2; false; fi
    # The message names the entry (kind, name, source).
    [[ "$output" == *"skill"* ]]
    [[ "$output" == *"grid.lock entry 0"* ]]
    [ "$before" = "$after" ]
  done
}

@test "grid.lock: a path whose parent is a symlink out of repos/<source> is rejected" {
  mkdir -p "$F/repos/alpha" "$F/outside"
  ln -s "$F/outside" "$F/repos/alpha/skills"
  write_lock name docx
  run read_lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"escapes repos/alpha"* ]]
}

@test "grid.lock: entries of an unknown kind are skipped with one notice per kind" {
  write_lock name docx '[{"kind":"rule","name":"r1"},{"kind":"rule","name":"r2"},{"kind":"hook","name":"h"}]'
  run read_lock
  [ "$status" -eq 0 ]
  [[ "$output" == *'["repos/alpha/skills/docx"]'* ]]
  local n
  n=$(printf '%s\n' "$output" | grep -c "kind 'rule'")
  [ "$n" -eq 1 ]
  [[ "$output" == *"kind 'hook'"* ]]
}

@test "grid.lock: a missing file or bad JSON exits 2" {
  run read_lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"grid.lock not found"* ]]
  printf '{not json' > "$F/grid.lock"
  run read_lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "validate_ref accepts branch names and rejects a leading dash" {
  run gpy 'g.validate_ref("main"); g.validate_ref("release/1.2"); print("ok")'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  run gpy '
try:
    g.validate_ref("-x")
except ValueError:
    print("rejected")'
  [ "$output" = "rejected" ]
}
