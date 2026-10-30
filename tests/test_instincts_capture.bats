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

load helpers/portable

setup() {
  # Env that would redirect git or change capture behaviour must not leak in from the caller.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GRID_HOST GRID_INSTINCTS GRID_INSTINCTS_SKIP \
        GRID_LOOP_HEADLESS GRID_AUTOHANDOFF_CHILD GRID_CRON GRID_PRIVATE_DIR
  export PYTHONDONTWRITEBYTECODE=1
  export GRID_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GRID_LEARNING_DIR="$BATS_TEST_TMPDIR/learning"
  # A temp git repo with a fake origin remote and the opt-in flag on.
  # Canonical (pwd -P) root: macOS /var is a symlink to /private/var, and the capture code
  # resolves the project root physically, so a /var/... path would not be seen as inside it.
  PROJ="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/proj"
  mkdir -p "$PROJ/.grid"
  git -C "$PROJ" init -q
  git -C "$PROJ" remote add origin https://example.test/owner/repo.git
  printf 'learning: on\n' > "$PROJ/.grid/project.yaml"
  PID="$("$SH" project-id "$PROJ")"
  OBSDIR="$GRID_STATE_DIR/instincts/$PID"
  mark_enabled
}

# mark_enabled — the machine-local opt-in marker the emitter writes (flag AND marker are
# both required; see lib.learning_enabled). Content = the project root.
mark_enabled() {
  mkdir -p "$GRID_STATE_DIR/instincts/enabled"
  (cd "$PROJ" && pwd -P) > "$GRID_STATE_DIR/instincts/enabled/$PID"
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

# file_payload <event> <tool> <path-key> <path> [<key> <json-value>]... — payload for a file tool.
# tool_input is built in python: bash 3.2 (macOS) mangles a quoted `{\"k\":...}` string inside
# "$(...)", splitting it at the commas, so the JSON must never be written inline in a test.
file_payload() {
  local event="$1" tool="$2" pk="$3" path="$4"; shift 4
  payload "$event" "$tool" "tool_input=$(python3 -c '
import json, sys
k, path, *rest = sys.argv[1:]
d = {k: path}
for i in range(0, len(rest), 2):
    d[rest[i]] = json.loads(rest[i + 1])
print(json.dumps(d))' "$pk" "$path" "$@")"
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
  [ "$(file_mode "$f")" = 600 ]
  [ "$(file_mode "$OBSDIR")" = 700 ]
  [ "$(file_mode "$GRID_STATE_DIR/instincts")" = 700 ]
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

@test "a secret in the command never reaches the file (line dropped, or redacted)" {
  tok="ghp_$(printf 'a1B2c3D4e5F6g7H8i9J0%s' 'k1L2')"
  capture "$(bash_payload "curl -H 'Authorization: Bearer $tok' https://example.test; export API_KEY=abcd1234efgh5678")"
  # The line holds a keyword with a value and a 20+ char digit-bearing run: dropped whole.
  assert_no_file
  # A secret shape with no keyword and no long run is redacted instead.
  capture "$(bash_payload "docker login -u me -p hunter2x")"
  f="$(only_file)"
  absent "$f" hunter2x
  grep -q '\[REDACTED\]' "$f"
}

@test "a long command is capped at 300 chars and \$HOME becomes ~, project root becomes ." {
  long="$(printf 'x%.0s' $(seq 1 400))"
  capture "$(bash_payload "echo $long")"
  [ "$(field "$(only_file)" 1 in | tr -d '\n' | wc -c)" -le 300 ]
  rm -rf "$GRID_STATE_DIR"; mark_enabled
  capture "$(bash_payload "cat $HOME/notes.txt $PROJ/src/a.sh")"
  v="$(field "$(only_file)" 1 in)"
  [ "$v" = "cat ~/notes.txt ./src/a.sh" ] || { echo "got: $v"; return 1; }
}

@test "an Edit records the project-relative path and no content" {
  capture "$(file_payload PostToolUse Edit file_path "$PROJ/src/app.py" old_string '"OLDMARK"' new_string '"NEWMARK"')"
  f="$(only_file)"
  [ "$(field "$f" 1 tool)" = Edit ]
  [ "$(field "$f" 1 in)" = src/app.py ]
  absent "$f" -e OLDMARK -e NEWMARK
}

@test "Write, MultiEdit and NotebookEdit are recorded by path only" {
  capture "$(file_payload PostToolUse Write file_path "$PROJ/a.md" content '"BODYMARK"')"
  capture "$(file_payload PostToolUse MultiEdit file_path "$PROJ/b.md" edits '[]')"
  capture "$(file_payload PostToolUse NotebookEdit notebook_path "$PROJ/n.ipynb" new_source '"BODYMARK"')"
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

@test "a secret in a prompt never reaches the file" {
  capture "$(payload UserPromptSubmit - 'prompt="use password=hunter2hunter2 for this"')"
  assert_no_file
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
  # no observation directory either (no project id to name one)
  [ -z "$(ls "$GRID_STATE_DIR/instincts" | grep -v '^enabled$')" ]
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
  skipped "$(file_payload PostToolUse Edit file_path "$PROJ/.env")"
  skipped "$(file_payload PostToolUse Write file_path "$PROJ/certs/server.pem")"
}

@test "a lookalike name such as environment.md is not mistaken for .env" {
  capture "$(file_payload PostToolUse Edit file_path "$PROJ/docs/environment.md")"
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

# --- WP-028: free text, PII, paths, opt-in marker, retention ---------------------------

AT='@'

# prompt_payload <text> — a UserPromptSubmit payload carrying that prompt.
prompt_payload() {
  payload UserPromptSubmit - "prompt=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")"
}

@test "prompts holding a natural-language secret, an email, an SSN or a long token record nothing" {
  for p in "my password is hunter2x please remember it" \
           "send the report to jane.doe${AT}corp.example.com" \
           "her SSN is 123-45-6789" \
           "the deploy key aB3dE5gH7jK9mN1pQ3sT5vW7 is live" \
           "hunter2x is the password"; do
    capture "$(prompt_payload "$p")"
  done
  assert_no_file
}

@test "a prompt keeps its clean lines when another line is dropped" {
  capture "$(prompt_payload $'fix the failing test\nmy password is hunter2x')"
  f="$(only_file)"
  absent "$f" hunter2x
  [ "$(field "$f" 1 in)" = "fix the failing test" ]
}

@test "commands naming a host, an email or an IP record nothing" {
  for c in "scp me${AT}box.example.com:/x ." \
           "git config user.email a${AT}b.example" \
           "ssh deploy${AT}10.1.2"".3" \
           'ping db.internal' \
           "curl http://192.168.0"".7:8080/health" \
           'ping6 2001:db8::1'; do
    capture "$(bash_payload "$c")"
  done
  assert_no_file
}

@test "user@host:/path with a single-label host records nothing (path rewrites run first)" {
  # The path rewrite turns `me@devbox:/tmp/x` into `me@devbox:(outside)/x` and a project-root path into
  # `me@devbox:./x`; the scp-host drop has to see through both, or the user name and host leak.
  for c in "scp f.txt me${AT}devbox:/tmp/x" \
           "scp f.txt me${AT}devbox:$PROJ/out" \
           "scp f.txt me${AT}devbox:$HOME/out" \
           "rsync -a . me${AT}devbox:/srv/app/" \
           "scp me${AT}devbox:/var/log/x ."; do
    capture "$(bash_payload "$c")"
  done
  assert_no_file
}

@test "file names that look like hosts are kept (settings.local.json, lib.py, README.md)" {
  capture "$(bash_payload 'cat .claude/settings.local.json lib.py README.md')"
  [ "$(field "$(only_file)" 1 in)" = "cat .claude/settings.local.json lib.py README.md" ]
}

@test "an absolute path outside the project and HOME is stored as (outside)/<name>" {
  capture "$(bash_payload 'cat /ho''me/u/work/x')"
  capture "$(bash_payload 'ls /etc/ssl/certs; cp a /srv/data/out.txt')"
  capture "$(bash_payload 'curl https://localhost/a/b')"
  f="$(only_file)"
  [ "$(field "$f" 1 in)" = "cat (outside)/x" ]
  [ "$(field "$f" 2 in)" = "ls (outside)/certs; cp a (outside)/out.txt" ]
  # URL paths are not filesystem paths
  [ "$(field "$f" 3 in)" = "curl https://localhost/a/b" ]
}

@test "each credential-file name drops the whole observation" {
  for c in 'cat ~/.pgpass' 'cat ~/.npmrc' 'cat ~/.kube/config' 'cat ~/.docker/config.json' \
           'cp id_ecdsa k' 'cp id_dsa k' 'openssl pkcs12 -in a.p12' 'openssl pkcs12 -in a.pfx' \
           'cat server.key' 'source .envrc' 'cat terraform.tfstate' 'cat secrets.yml' \
           'cat ~/.git-credentials' 'cat ~/.pypirc' 'ls ~/.ssh/'; do
    capture "$(bash_payload "$c")"
  done
  capture "$(file_payload PostToolUse Edit file_path "$PROJ/deploy/prod.tfstate")"
  capture "$(file_payload PostToolUse Write file_path "$PROJ/k/server.key")"
  assert_no_file
}

@test "names that merely contain a sensitive word are kept (monkey, keyboard.md)" {
  capture "$(bash_payload 'cat monkey.txt keyboard.md')"
  only_file >/dev/null
}

@test "opt-in: a trailing 'learning: off' after 'learning: on' stops capture" {
  printf 'learning: on\nname: x\nlearning: off\n' > "$PROJ/.grid/project.yaml"
  skipped "$(bash_payload ls)"
}

@test "opt-in: the flag without the machine-local marker records nothing" {
  rm "$GRID_STATE_DIR/instincts/enabled/$PID"
  skipped "$(bash_payload ls)"
  # ... and the marker without the flag records nothing either
  mark_enabled
  printf 'learning: off\n' > "$PROJ/.grid/project.yaml"
  skipped "$(bash_payload ls)"
}

@test "opt-in: another clone that claims the same remote records nothing until the emitter runs there" {
  other="$BATS_TEST_TMPDIR/other-clone"
  mkdir -p "$other/.grid"
  git -C "$other" init -q
  git -C "$other" remote add origin https://example.test/owner/repo.git
  printf 'learning: on\n' > "$other/.grid/project.yaml"
  PROJ="$other" skipped "$(PROJ="$other" bash_payload ls)"
  # the original checkout still records
  capture "$(bash_payload ls)"
  only_file >/dev/null
}

@test "opt-in: bare yes is off and quoted 'on' is on, as in the emitter" {
  printf 'learning: yes\n' > "$PROJ/.grid/project.yaml"
  skipped "$(bash_payload ls)"
  printf "learning: 'on'\n" > "$PROJ/.grid/project.yaml"
  capture "$(bash_payload ls)"
  only_file >/dev/null
}

@test "retention: a week file past 28 days is removed when a new week file is created" {
  mkdir -p "$OBSDIR"
  old="$(python3 -c 'import datetime as d; y,w,_=(d.date.today()-d.timedelta(days=60)).isocalendar(); print("obs-%d-W%02d.jsonl"%(y,w))')"
  recent="$(python3 -c 'import datetime as d; y,w,_=(d.date.today()-d.timedelta(days=14)).isocalendar(); print("obs-%d-W%02d.jsonl"%(y,w))')"
  echo '{}' > "$OBSDIR/$old"; echo '{}' > "$OBSDIR/$recent"
  capture "$(bash_payload ls)"
  [ ! -e "$OBSDIR/$old" ]
  [ -e "$OBSDIR/$recent" ]
  [ "$(ls "$OBSDIR" | wc -l)" -eq 2 ]
}

@test "short write: an unterminated line does not swallow the next record" {
  capture "$(bash_payload 'echo first')"
  f="$(only_file)"
  # Pad to just under 1 KiB, then capture under a 1 KiB file-size limit: the append is cut short.
  python3 -c 'import sys; n=len(open(sys.argv[1]).read()); open(sys.argv[1],"a").write("{\"pad\":\"" + "x"*(1000-n-10) + "\"}\n")' "$f"
  run bash -c 'ulimit -f 1; printf "%s" "$1" | "$2" capture' _ "$(bash_payload "echo $(printf 'y%.0s' $(seq 1 200))")" "$SH"
  # A later capture without the limit must land on its own line.
  capture "$(bash_payload 'echo last')"
  python3 - "$f" <<'PY'
import json, sys
good = []
for ln in open(sys.argv[1]).read().split("\n"):
    try:
        good.append(json.loads(ln))
    except ValueError:
        pass
assert any(o.get("in") == "echo last" for o in good), "last record lost"
assert any(o.get("in") == "echo first" for o in good)
PY
}

@test "observation files are created 0600 even under a permissive umask" {
  umask 000
  capture "$(bash_payload ls)"
  [ "$(file_mode "$(only_file)")" = 600 ]
}

# --- WP-028 round 2: whitespace other than a space must not glue a secret flag to its value ----

# SEPS — printf escapes for the separators under test: tab, VT, FF, NBSP, ideographic space,
# U+2028, U+2029, U+0085. Each is a real gap between words for some tool or terminal.
SEPS=('\t' '\v' '\f' '\302\240' '\343\200\200' '\342\200\250' '\342\200\251' '\302\205')

@test "whitespace: a tab, VT, FF, NBSP, ideographic space, U+2028/9 or NEL before a secret flag still redacts" {
  # Deleting the separator (rather than reading it as a space) glued `mysql -p x` into
  # `mysql-px`, and the rules, which need whitespace before the flag, matched nothing.
  local sep cmd
  for sep in "${SEPS[@]}"; do
    for cmd in "mysql${sep}-p${sep}hunter2x" \
               "docker${sep}login${sep}-u${sep}me${sep}-p${sep}hunter2x" \
               "curl${sep}-u${sep}user:hunter2x${sep}https://example.test/x" \
               "zip${sep}-P${sep}hunter2x${sep}out.zip${sep}in.txt" \
               "sshpass${sep}-p${sep}hunter2x${sep}ssh${sep}host"; do
      capture "$(bash_payload "$(printf "$cmd")")"
    done
  done
  # Something was stored (so the absence below is not vacuous) and no stored line holds the secret.
  f="$(only_file)"
  [ "$(wc -l < "$f")" -gt 0 ]
  absent "$f" hunter2x
}

@test "whitespace: a tab-separated secret flag is redacted, not glued (exact stored form)" {
  capture "$(bash_payload "$(printf 'mysql\t-p\thunter2x')")"
  f="$(only_file)"
  absent "$f" hunter2x
  [ "$(field "$f" 1 in)" = "mysql -p [REDACTED]" ]
}

# --- H-14: short secrets in tools outside the first list, separators, fail-safe default ----------
# S is letters only and short, so neither the line drop nor the long-run rule can save it:
# only the scrubber or the fail-safe rule keeps it out. Built at runtime from parts.

# h14_cmds — one command per line, each holding $S; `\n` stands for a newline, `<ZW>` for U+200B.
h14_cmds() {
  cat <<EOF
7z a -p $S out.7z in
7z a -p$S out.7z in
rar a -hp$S out.rar in
vault login $S
twine upload -p $S dist/*
twine upload dist/* --password $S
az login --service-principal -u x -p $S --tenant t
ldapsearch -x -D cn=admin -w $S -b dc=x
smbclient //srv/share -U user%$S
xfreerdp /v:srv /u:bob /p:$S
sudo -S ls <<<$S
sudo -S ls <<< $S
echo $S | sudo -S ls
export session=$S
dbpw=$S make
git clone https://$S@host/x
DOCKER login -p $S
Docker Login --password $S
docker login <BSNL> -p $S
docker login -u me <BSNL><BSNL> -p $S
mysql<ZW>-p<ZW>$S db
docker<ZW>login<ZW>-p<ZW>$S
vault<ESC>login<DEL>$S
pa<ACUTE>ssword=$S
tok<ACUTE>en=$S
acme-tool -p $S
acme-tool -w $S
acme-tool -p$S
FOO=1 acme-tool -P $S
EOF
}

# h14_expand <line> — turn the placeholders into the real characters.
h14_expand() {
  python3 -c 'import sys
s = sys.argv[1]
for k, v in {"<BSNL>": "\\\n", "<ZW>": "\u200b", "<ESC>": "\x1b", "<DEL>": "\x7f", "<ACUTE>": "\u0301"}.items():
    s = s.replace(k, v)
print(s, end="")' "$1"
}

@test "H-14: short secrets of unlisted tools, separator tricks and combining marks never reach the stored line" {
  S="sword""fishq"
  local line n=0
  while IFS= read -r line; do
    capture "$(bash_payload "$(h14_expand "$line")")"
    n=$((n + 1))
  done < <(h14_cmds)
  [ "$n" -gt 25 ]
  # a canary proves the file exists and capture still records ordinary calls
  capture "$(bash_payload 'git status')"
  f="$(only_file)"
  [ "$(wc -l < "$f")" -gt 1 ]
  absent "$f" "$S"
  grep -q 'git status' "$f"
}

@test "H-14: the stored forms are redacted in place (exact)" {
  S="sword""fishq"
  capture "$(bash_payload "vault login $S")"
  capture "$(bash_payload "7z a -p $S out.7z")"
  capture "$(bash_payload "xfreerdp /v:srv /p:$S")"
  capture "$(bash_payload "ldapsearch -x -w $S -b dc=x")"
  f="$(only_file)"
  [ "$(field "$f" 1 in)" = "vault login [REDACTED]" ]
  [ "$(field "$f" 2 in)" = "7z a -p [REDACTED] out.7z" ]
  [ "$(field "$f" 3 in)" = "xfreerdp (outside)/v:srv (outside)/p:[REDACTED]" ]
  [ "$(field "$f" 4 in)" = "ldapsearch -x -w [REDACTED] -b dc=x" ]
}

@test "H-14: an unlisted tool with a -p/-w style flag value records nothing at all" {
  S="sword""fishq"
  local c
  for c in "acme-tool -p $S" "acme-tool -w $S" "acme-tool -p$S" "acme-tool run -P $S --x" \
           "cd x && acme-tool -p $S" "sudo acme-tool -w $S" "bash -c 'acme-tool -p $S'"; do
    capture "$(bash_payload "$c")"
  done
  assert_no_file
}

@test "H-14: ordinary -p, -P and -w uses are still recorded" {
  local c
  for c in "mkdir -p newdir" "psql -p 5432 db" "pytest -p no:cacheprovider" "ssh -p 22 host" \
           "docker run -p 8080:80 img" "grep -w word f" "git commit -m 'bump -w width'"; do
    capture "$(bash_payload "$c")"
  done
  f="$(only_file)"
  [ "$(wc -l < "$f")" -eq 7 ]
  [ "$(field "$f" 1 in)" = "mkdir -p newdir" ]
}

@test "H-14: a Write, Edit or prompt is not subject to the command flag rule" {
  capture "$(payload PostToolUse Edit 'tool_input={"file_path":"src/acme -p x.py"}')"
  capture "$(payload UserPromptSubmit - 'prompt="please run mkdir -p out then acme-tool -p 5432"')"
  [ "$(wc -l < "$(only_file)")" -eq 2 ]
}

# --- H-14 fix round 1: a backslash-newline between a flag and its value (full capture path) -----

@test "H-14: a continuation between a flag and its value never leaves the value in the stored line" {
  S="sword""fishq"
  local bs='\' lf=$'\n' cr=$'\r' nl cmd n=0
  for nl in "${bs}${lf}" "${bs}${cr}${lf}" "${bs}${lf}${bs}${lf}"; do
    for cmd in "docker login -u me -p ${nl}${S}" "docker login -u me ${nl}-p ${nl}${S}" \
               "mysql -u root ${nl} -p ${nl}${S} db" "mysql -p${nl}${S}" "rar a -p${nl}${S} a b" \
               "acme-tool -p ${nl}${S}" "acme-tool ${nl}-w${nl}${S}" "TOKEN=${nl}${S} run" \
               "mysql -p ${S:0:5}${nl}${S:5} db"; do
      capture "$(bash_payload "$cmd")"
      n=$((n + 1))
    done
  done
  capture "$(bash_payload 'git status')"
  f="$(only_file)"
  [ "$(wc -l < "$f")" -gt 1 ]
  absent "$f" "$S"
  absent "$f" "${S:0:5}"
  absent "$f" "${S:5}"
  [ "$n" -eq 27 ]
}

@test "H-14: a continuation after a redacted flag is stored clean (exact)" {
  S="sword""fishq"
  capture "$(bash_payload "$(printf 'docker login -u me -p \\\n%s' "$S")")"
  capture "$(bash_payload "$(printf 'mysql -p\\\r\n%s db' "$S")")"
  f="$(only_file)"
  [ "$(field "$f" 1 in)" = "docker login -u me -p [REDACTED]" ]
  [ "$(field "$f" 2 in)" = "mysql -p[REDACTED] db" ]
}

@test "H-14: a continuation that precedes no value is stored as before" {
  capture "$(bash_payload "$(printf 'ls \\\n-p')")"
  capture "$(bash_payload "$(printf 'mkdir -p \\\n out')")"
  capture "$(bash_payload "$(printf 'mkdir \\\n-p \\\nout')")"
  f="$(only_file)"
  [ "$(wc -l < "$f")" -eq 3 ]
}
