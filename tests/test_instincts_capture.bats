#!/usr/bin/env bats
# Tests for scripts/instincts/capture.py via `instincts.sh capture`
# (openspec change `instincts`, group 2).
#
# Payloads are built from the real captured fixture tests/fixtures/hooks/pretooluse-bash.json
# (event name, tool and cwd overridden). Every repo and dir lives under $BATS_TEST_TMPDIR and
# state is env-redirected there, so nothing touches the real ~/.grid. Secrets are ASSEMBLED
# AT RUNTIME from parts (a literal token would trip secret scanners); all values are synthetic.
#
# Self-check by the implementer; independent verification belongs to qa-engineer / sdet.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SH="$REPO_ROOT/scripts/instincts.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/hooks/pretooluse-bash.json"

setup() {
  # Env that would redirect git or change capture behaviour must not leak in from the caller.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GRID_HOST GRID_INSTINCTS GRID_INSTINCTS_SKIP \
        GRID_LOOP_HEADLESS GRID_AUTOHANDOFF_CHILD GRID_CRON GRID_PRIVATE_DIR
  export PYTHONDONTWRITEBYTECODE=1
  export GRID_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GRID_LEARNING_DIR="$BATS_TEST_TMPDIR/learning"
  # A temp git repo with a fake origin remote and the opt-in flag on.
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ/.grid"
  git -C "$PROJ" init -q
  git -C "$PROJ" remote add origin https://example.test/owner/repo.git
  printf 'learning: on\n' > "$PROJ/.grid/project.yaml"
  PID="$("$SH" project-id "$PROJ")"
  OBSDIR="$GRID_STATE_DIR/instincts/$PID"
}

# payload <event> <tool> <key=json-value>... — print a hook payload derived from the fixture.
# `tool_input` / `prompt` / `agent_id` etc. are passed as JSON values; cwd defaults to $PROJ.
payload() {
  python3 - "$FIXTURE" "$PROJ" "$@" <<'PY'
import json, sys
fixture, proj, event, tool, *pairs = sys.argv[1:]
p = json.load(open(fixture))
p.update(hook_event_name=event, tool_name=tool, cwd=proj)
if tool == "-":
    del p["tool_name"], p["tool_input"]
for kv in pairs:
    k, _, v = kv.partition("=")
    p[k] = json.loads(v)
print(json.dumps(p))
PY
}

# capture <payload-json> — pipe one payload to the dispatcher.
capture() { printf '%s' "$1" | "$SH" capture; }

# bash_payload <command> — a PostToolUse Bash payload for that command.
bash_payload() {
  payload PostToolUse Bash "tool_input=$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1")"
}

# obs_files — list the observation files written (empty when none).
obs_files() { ls "$OBSDIR"/obs-*.jsonl 2>/dev/null || true; }

# only_file — the single observation file; fails when there is not exactly one.
only_file() {
  local f; f="$(obs_files)"
  if [ -z "$f" ] || [ "$(printf '%s\n' "$f" | wc -l)" -ne 1 ]; then
    echo "files: [$f]"; return 1
  fi
  printf '%s' "$f"
}

# absent <file> <grep args...> — fail unless grep finds no match. (A bare `! grep` does
# not fail a bats test, so negative assertions go through this helper.)
absent() {
  local f="$1"; shift
  if grep -q "$@" "$f"; then echo "unexpected match in $f for: $*"; return 1; fi
}

# assert_no_file — capture wrote nothing at all.
assert_no_file() { [ -z "$(obs_files)" ] || { echo "unexpected: $(obs_files)"; return 1; }; }

# field <file> <n> <key> — print key of JSON line n.
field() { sed -n "${2}p" "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$3"; }

# --- happy path ---------------------------------------------------------------------

@test "bash call writes exactly one valid line with the expected fields" {
  run capture "$(bash_payload 'bats tests/ | tail')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  f="$(only_file)"
  [ "$(wc -l < "$f")" -eq 1 ]
  python3 - "$f" <<'PY'
import json, re, sys
o = json.loads(open(sys.argv[1]).readline())
assert set(o) == {"ts", "sid", "ev", "tool", "in", "err"}, o
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", o["ts"]), o
assert o["sid"] == "00000000", o          # first 8 chars of the fixture session id
assert (o["ev"], o["tool"], o["in"], o["err"]) == ("tool", "Bash", "bats tests/ | tail", False), o
PY
}

@test "file is mode 0600 and the directories are 0700" {
  capture "$(bash_payload 'ls')"
  f="$(only_file)"
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(stat -c %a "$OBSDIR")" = 700 ]
  [ "$(stat -c %a "$GRID_STATE_DIR/instincts")" = 700 ]
  # File name is obs-<ISO year>-W<ww>.jsonl
  [[ "$(basename "$f")" =~ ^obs-[0-9]{4}-W[0-9]{2}\.jsonl$ ]]
}

@test "PostToolUseFailure sets err true; so does a truthy tool_response.is_error" {
  capture "$(payload PostToolUseFailure Bash 'tool_input={"command":"false"}')"
  capture "$(payload PostToolUse Bash 'tool_input={"command":"false"}' 'tool_response={"is_error":true,"output":"OUTPUTMARK"}')"
  f="$(only_file)"
  [ "$(field "$f" 1 err)" = True ]
  [ "$(field "$f" 2 err)" = True ]
  # tool output is never read into the record
  absent "$f" OUTPUTMARK
}

@test "a secret in the command is redacted in the file" {
  tok="ghp_$(printf 'a1B2c3D4e5F6g7H8i9J0%s' 'k1L2')"
  capture "$(bash_payload "curl -H 'Authorization: Bearer $tok' https://example.test; export API_KEY=abcd1234efgh5678")"
  f="$(only_file)"
  absent "$f" "$tok"
  absent "$f" abcd1234efgh5678
  grep -q '\[REDACTED\]' "$f"
}

@test "a long command is capped at 300 chars and \$HOME becomes ~, project root becomes ." {
  long="$(printf 'x%.0s' $(seq 1 400))"
  capture "$(bash_payload "echo $long")"
  [ "$(field "$(only_file)" 1 in | tr -d '\n' | wc -c)" -le 300 ]
  rm -rf "$GRID_STATE_DIR"
  capture "$(bash_payload "cat $HOME/notes.txt $PROJ/src/a.sh")"
  v="$(field "$(only_file)" 1 in)"
  [ "$v" = "cat ~/notes.txt ./src/a.sh" ] || { echo "got: $v"; return 1; }
}

@test "an Edit records the project-relative path and no content" {
  capture "$(payload PostToolUse Edit "tool_input={\"file_path\":\"$PROJ/src/app.py\",\"old_string\":\"OLDMARK\",\"new_string\":\"NEWMARK\"}")"
  f="$(only_file)"
  [ "$(field "$f" 1 tool)" = Edit ]
  [ "$(field "$f" 1 in)" = src/app.py ]
  absent "$f" -e OLDMARK -e NEWMARK
}

@test "Write, MultiEdit and NotebookEdit are recorded by path only" {
  capture "$(payload PostToolUse Write "tool_input={\"file_path\":\"$PROJ/a.md\",\"content\":\"BODYMARK\"}")"
  capture "$(payload PostToolUse MultiEdit "tool_input={\"file_path\":\"$PROJ/b.md\",\"edits\":[]}")"
  capture "$(payload PostToolUse NotebookEdit "tool_input={\"notebook_path\":\"$PROJ/n.ipynb\",\"new_source\":\"BODYMARK\"}")"
  f="$(only_file)"
  [ "$(wc -l < "$f")" -eq 3 ]
  [ "$(field "$f" 1 in)" = a.md ]
  [ "$(field "$f" 2 in)" = b.md ]
  [ "$(field "$f" 3 in)" = n.ipynb ]
  absent "$f" BODYMARK
}

@test "a path outside the project keeps only the file name" {
  capture "$(payload PostToolUse Write 'tool_input={"file_path":"/opt/elsewhere/z.txt"}')"
  [ "$(field "$(only_file)" 1 in)" = "(outside)/z.txt" ]
}

@test "a prompt is truncated to 240 chars" {
  long="$(printf 'p%.0s' $(seq 1 500))"
  capture "$(payload UserPromptSubmit - "prompt=\"$long\"")"
  f="$(only_file)"
  [ "$(field "$f" 1 ev)" = prompt ]
  [ "$(field "$f" 1 in | tr -d '\n' | wc -c)" -eq 240 ]
  # prompt lines carry no tool or err
  [ "$(sed -n 1p "$f" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)))')" = "['ev', 'in', 'sid', 'ts']" ]
}

@test "a prompt starting with / records only the command word" {
  capture "$(payload UserPromptSubmit - 'prompt="/handoff some free text about things"')"
  [ "$(field "$(only_file)" 1 in)" = /handoff ]
}

@test "a secret in a prompt is redacted" {
  capture "$(payload UserPromptSubmit - 'prompt="use password=hunter2hunter2 for this"')"
  f="$(only_file)"
  absent "$f" hunter2
  grep -q '\[REDACTED\]' "$f"
}

# --- skip conditions: each writes nothing, exits 0, prints nothing ------------------------

# skipped <payload> — capture exits 0 with empty stdout and no file exists.
skipped() {
  run capture "$1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_file
}

@test "skip: GRID_INSTINCTS=0" {
  export GRID_INSTINCTS=0
  skipped "$(bash_payload ls)"
}

@test "skip: GRID_INSTINCTS_SKIP=1" {
  export GRID_INSTINCTS_SKIP=1
  skipped "$(bash_payload ls)"
}

@test "skip: GRID_LOOP_HEADLESS=1" {
  export GRID_LOOP_HEADLESS=1
  skipped "$(bash_payload ls)"
}

@test "skip: GRID_AUTOHANDOFF_CHILD=1" {
  export GRID_AUTOHANDOFF_CHILD=1
  skipped "$(bash_payload ls)"
}

@test "skip: GRID_CRON=1" {
  export GRID_CRON=1
  skipped "$(bash_payload ls)"
}

@test "an empty unattended variable does not skip" {
  export GRID_CRON=""
  capture "$(bash_payload ls)"
  only_file >/dev/null
}

@test "skip: payload carries agent_id (subagent)" {
  skipped "$(payload PostToolUse Bash 'tool_input={"command":"ls"}' 'agent_id="agent-1"')"
}

@test "skip: learning is off in project.yaml" {
  printf 'learning: off\n' > "$PROJ/.grid/project.yaml"
  skipped "$(bash_payload ls)"
}

@test "skip: no project.yaml at all" {
  rm "$PROJ/.grid/project.yaml"
  skipped "$(bash_payload ls)"
}

@test "skip: no git remote" {
  git -C "$PROJ" remote remove origin
  skipped "$(bash_payload ls)"
  # nothing under the state dir either (no project id to name a directory)
  [ ! -d "$GRID_STATE_DIR/instincts" ]
}

@test "skip: cwd is not a git repo" {
  d="$BATS_TEST_TMPDIR/plain"; mkdir -p "$d"
  skipped "$(bash_payload ls | python3 -c 'import json,sys; p=json.load(sys.stdin); p["cwd"]=sys.argv[1]; print(json.dumps(p))' "$d")"
}

@test "skip: tool is not captured (Read, Grep)" {
  skipped "$(payload PostToolUse Read 'tool_input={"file_path":"/x"}')"
  skipped "$(payload PostToolUse Grep 'tool_input={"pattern":"x"}')"
}

@test "skip: PreToolUse is not captured" {
  skipped "$(payload PreToolUse Bash 'tool_input={"command":"ls"}')"
}

@test "skip: command or path touches a sensitive file" {
  skipped "$(bash_payload 'cat .env')"
  skipped "$(bash_payload 'cat .env.local')"
  skipped "$(bash_payload 'ssh -i ~/.ssh/id_rsa host')"
  skipped "$(bash_payload 'cp id_ed25519 /tmp/k')"
  skipped "$(bash_payload 'openssl x509 -in cert.pem')"
  skipped "$(bash_payload 'cat ~/.aws/credentials')"
  skipped "$(bash_payload 'cat ~/.netrc')"
  skipped "$(payload PostToolUse Edit "tool_input={\"file_path\":\"$PROJ/.env\"}")"
  skipped "$(payload PostToolUse Write "tool_input={\"file_path\":\"$PROJ/certs/server.pem\"}")"
}

@test "a lookalike name such as environment.md is not mistaken for .env" {
  capture "$(payload PostToolUse Edit "tool_input={\"file_path\":\"$PROJ/docs/environment.md\"}")"
  [ "$(field "$(only_file)" 1 in)" = docs/environment.md ]
}

@test "skip: the week file is already over 2 MB" {
  capture "$(bash_payload ls)"
  f="$(only_file)"
  size_before="$(wc -c < "$f")"
  # Pad the existing week file past the cap (padding is not valid obs; only size matters).
  head -c 2200000 /dev/zero | tr '\0' 'x' >> "$f"
  size_padded="$(wc -c < "$f")"
  run capture "$(bash_payload 'echo more')"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$f")" -eq "$size_padded" ]
  [ "$size_padded" -gt "$size_before" ]
}

# --- robustness ----------------------------------------------------------------------

@test "malformed JSON exits 0 with no output and no file" {
  run capture 'this is { not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_file
  run capture ''
  [ "$status" -eq 0 ]
  run capture '[1,2,3]'
  [ "$status" -eq 0 ]
  assert_no_file
}

@test "an unwritable state dir still exits 0 silently" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  chmod 500 "$BATS_TEST_TMPDIR/ro"
  GRID_STATE_DIR="$BATS_TEST_TMPDIR/ro/inner" run capture "$(bash_payload ls)"
  chmod 700 "$BATS_TEST_TMPDIR/ro"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a state dir inside the repo is refused (nothing written, still exit 0)" {
  GRID_STATE_DIR="$REPO_ROOT/.capture-test-state" run capture "$(bash_payload ls)"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO_ROOT/.capture-test-state" ]
}

@test "capture works from a subdirectory of the project" {
  mkdir -p "$PROJ/sub/dir"
  capture "$(bash_payload ls | python3 -c 'import json,sys; p=json.load(sys.stdin); p["cwd"]=sys.argv[1]; print(json.dumps(p))' "$PROJ/sub/dir")"
  only_file >/dev/null
}

@test "importing capture leaves no __pycache__ in the repo tree" {
  capture "$(bash_payload ls)"
  [ ! -d "$REPO_ROOT/scripts/instincts/__pycache__" ]
}

@test "20 consecutive captures append exactly 20 lines" {
  p="$(bash_payload 'git status')"
  start="$(date +%s.%N)"
  for _ in $(seq 1 20); do capture "$p"; done
  end="$(date +%s.%N)"
  # Wall time is informational only (recorded in the PR description); no assertion on it.
  echo "# 20 captures wall time: $(python3 -c 'import sys; print(round(float(sys.argv[2])-float(sys.argv[1]), 2))' "$start" "$end")s" >&3
  f="$(only_file)"
  [ "$(wc -l < "$f")" -eq 20 ]
}
