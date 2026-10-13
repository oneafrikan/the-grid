#!/usr/bin/env bats
# Tests for the auto-handoff hook (hooks/scripts/auto-handoff.sh), its detached worker
# (hooks/lib/auto-handoff-worker.sh), the transcript digest (hooks/lib/transcript-digest.sh)
# and the appended system prompt (hooks/lib/auto-handoff-system.md).
#
# Scenarios come from openspec/changes/hook-profiles/specs/auto-handoff/spec.md (the
# "Detached spawn", "Skip sessions" and "Capped, verified run" requirements, plus the
# session opt-out). The machine-wiring scenarios belong to group 4.
#
# Safety: `claude` is ALWAYS the stub from tests/helpers/stubs.bash (or the tripwire
# path from common_setup); HOME, the log/state/fallback/private dirs and the quarantine
# root are temp dirs. No model is called, nothing real is touched. Transcripts are built
# from the captured fixture shapes with `tx`, never hand-typed JSON. Secret-shaped values
# are assembled from fragments at run time.
#
# These are the author's own checks; independent verification belongs to qa-engineer.

bats_require_minimum_version 1.5.0

load helpers/setup
load helpers/hooks
load helpers/stubs

SID="11111111-1111-4111-8111-111111111111"

setup() {
  common_setup
  # Temp HOME AFTER common_setup (it captured REAL_HOME for the sandbox check).
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  # The quarantine root is machine-local state; keep it in the sandbox too.
  export GRID_STATE_DIR="$MOCK_HOOK_ROOT/gridstate"
  # The stub claude: prepends PATH and exports GRID_CLAUDE as the stub.
  make_stubs
  # The worker starts the child under `env -i` (WP-016); the stub reads its own STUB_* and
  # GRID_* inputs from the environment, so those are the variables that must be kept.
  export GRID_AUTOHANDOFF_KEEP_ENV='STUB_*,GRID_*'
  LOG="$GRID_HOOK_LOG_DIR/auto-handoff.log"
  TXN="$BATS_TEST_TMPDIR/transcript.jsonl"
  WORKER="$REPO_ROOT/hooks/lib/auto-handoff-worker.sh"
  mkproj proj
}

teardown() {
  # No detached process may outlive its test: kill the stub's pid, then anything whose
  # command line carries this test's temp dir (the worker is given the transcript path).
  if [ -n "${STUB_DIR:-}" ] && [ -f "$STUB_DIR/claude.pid" ]; then
    kill "$(cat "$STUB_DIR/claude.pid")" 2>/dev/null || true
  fi
  pkill -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  # Wait for those processes to be GONE before the sandbox is removed. A worker answers TERM
  # (and finishes a log or run-record write after its last decision line), and a write that
  # lands after the rm -rf re-creates logs/ and runs.jsonl under TMPDIR: the gate's
  # "tests leaked temp files" failure (NF-001, seen in CI with exactly those two files).
  local _i
  for ((_i = 0; _i < 50; _i++)); do
    pgrep -f "$BATS_TEST_TMPDIR" > /dev/null 2>&1 || break
    sleep 0.1
  done
  pkill -9 -f "$BATS_TEST_TMPDIR" 2>/dev/null || true
  clean_stubs
  common_teardown
}

# ---------------------------------------------------------------------------
# helpers local to this file
# ---------------------------------------------------------------------------

# age_tree <dir>: backdate every file (not under .git) so the worker's "new file" scan,
# which counts anything newer than 2 s before the child started, ignores the fixture.
age_tree() {
  find "$1" -path '*/.git' -prune -o -type f -exec touch -t 202001010000 {} +
}

# mkproj <name>: scratch git repo $P (one commit) with an empty LOGS/ directory.
mkproj() {
  P="$MOCK_HOOK_ROOT/work/$1"
  mkdir -p "$P/LOGS"
  git -C "$P" init -q
  git -C "$P" config user.email t@example.com
  git -C "$P" config user.name t
  echo base > "$P/base.txt"
  git -C "$P" add base.txt
  git -C "$P" commit -q -m base
  age_tree "$P"
}

# mk_tx <n>: a transcript of <n> human turns, each answered by an assistant text line.
mk_tx() {
  : > "$TXN"
  local i
  for ((i = 1; i <= $1; i++)); do
    tx human-string "question $i" >> "$TXN"
    tx assistant-text "answer $i" >> "$TXN"
  done
}

# run_worker: run the worker synchronously (no detach) for $SID / $TXN / $P.
run_worker() {
  run bash "$WORKER" "$SID" "$TXN" "$P" other
}

# fire: send the SessionEnd payload through the real launcher, as Claude Code would.
fire() {
  sessionend_payload "$SID" "$TXN" "$P" | bash "$REPO_ROOT/hooks/run.sh" auto-handoff
}

# log_has <text>: the hook log holds a line containing <text>.
log_has() { grep -qF -- "$1" "$LOG"; }

# terminal_logged: the detached worker has written its final decision line.
terminal_logged() { grep -Eq 'action=(done|error|skip)' "$LOG" 2>/dev/null; }

# commits <repo>: number of commits on HEAD.
commits() { git -C "$1" rev-list --count HEAD; }

# claude_line: the first logged argv line of the stub claude.
claude_line() { grep '^claude ' "$STUB_LOG" | head -1; }

# edit_rule <abs dir>: the path-scoped write rule Claude Code enforces. `//` anchors at
# the filesystem root, so it is "/" in front of the absolute path.
edit_rule() { printf 'Edit(/%s/**)' "$1"; }

# run_outcome: the outcome of the last run-record line.
run_outcome() { tail -1 "$GRID_RUN_LOG" | jq -r .outcome; }

# fake_token: a GitHub-token-shaped string assembled at run time.
fake_token() { printf 'gh%s_%s' p "$(printf 'a%.0s' $(seq 36))"; }

# ---------------------------------------------------------------------------
# Detached spawn
# ---------------------------------------------------------------------------

@test "hook returns in under 1 s while the worker is still running" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=5
  start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  fire
  end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 1 ? 0 : 1)' "$start" "$end"
  # the worker is alive in the background: the stub started and has not finished
  wait_for 10 test -s "$STUB_DIR/claude.pid"
  kill -0 "$(cat "$STUB_DIR/claude.pid")"
  # and it completes on its own
  wait_for 15 log_has "action=done"
}

@test "worker survives its parent: its process group is not the hook's" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  fire
  wait_for 10 terminal_logged
  mine="$(ps -o pgid= -p $$ | tr -d ' ')"
  theirs="$(cat "$STUB_DIR/claude.pgid")"
  [ -n "$theirs" ]
  [ "$mine" != "$theirs" ]
  log_has "action=done"
}

@test "bad payloads are skipped, not spawned" {
  mk_tx 6
  # non-JSON stdin
  run bash -c 'printf "not json" | bash "$1/hooks/run.sh" auto-handoff' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # empty transcript_path
  sessionend_payload "$SID" "" "$P" | bash "$REPO_ROOT/hooks/run.sh" auto-handoff
  # cwd that is not a directory
  sessionend_payload "$SID" "$TXN" "$MOCK_HOOK_ROOT/nope" | bash "$REPO_ROOT/hooks/run.sh" auto-handoff
  # session_id that would escape the state dir
  sessionend_payload "../x" "$TXN" "$P" | bash "$REPO_ROOT/hooks/run.sh" auto-handoff
  [ "$(grep -c 'action=skip reason=bad-payload' "$LOG")" -eq 4 ]
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "the child's own session end does not respawn" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs GRID_AUTOHANDOFF_CHILD=1
  fire
  [ ! -e "$LOG" ]
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "the recursion guard reaches the child" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/claude.child-env")" = "1" ]
}

@test "hook without jq exits 0 with a note and starts nothing" {
  mk_tx 6
  # a PATH with bash and dirname only: no jq
  nojq="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$nojq"
  ln -s "$(command -v bash)" "$nojq/bash"
  ln -s "$(command -v dirname)" "$nojq/dirname"
  payload="$(sessionend_payload "$SID" "$TXN" "$P")"
  run bash -c 'printf "%s" "$1" | env PATH="$2" bash "$3/hooks/run.sh" auto-handoff 2>&1' _ "$payload" "$nojq" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  contains "$output" "jq not found"
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "session opt-out: GRID_DISABLED_HOOKS=auto-handoff starts nothing" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs GRID_DISABLED_HOOKS=auto-handoff
  fire
  [ ! -e "$LOG" ]
  [ ! -e "$STUB_DIR/claude.pid" ]
}

# ---------------------------------------------------------------------------
# Skip sessions
# ---------------------------------------------------------------------------

@test "slash command seen: skipped as already-ran" {
  mk_tx 6
  tx slash-handoff "scratch" >> "$TXN"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=skip reason=already-ran"
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "skill tool seen: skipped as already-ran" {
  mk_tx 6
  tx assistant-skill-tool "scratch" >> "$TXN"
  run_worker
  log_has "action=skip reason=already-ran"
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "handoff file written earlier: skipped as already-ran even after 10 more turns" {
  tx human-string "start" > "$TXN"
  tx assistant-write-handoff "body" >> "$TXN"
  local i
  for ((i = 1; i <= 10; i++)); do tx human-string "more $i" >> "$TXN"; done
  run_worker
  log_has "action=skip reason=already-ran"
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "mentions of a handoff are not a handoff" {
  mk_tx 6
  # the command tag inside a tool result (as when a transcript is cat-ed)
  tx tool-result '<command-name>/handoff</command-name>' >> "$TXN"
  # an assistant line that merely says it
  tx assistant-text 'run /handoff' >> "$TXN"
  # a Write to notes/handoff.md (does not end in -handoff.md)
  tx assistant-write-handoff body | jq -c '.message.content[0].input.file_path = "notes/handoff.md"' >> "$TXN"
  # a Write to x-handoff.md, but on a sidechain line (ignored)
  tx assistant-write-handoff body | jq -c '.isSidechain = true | .message.content[0].input.file_path = "x-handoff.md"' >> "$TXN"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  refute log_has "reason=already-ran"
  [ -e "$STUB_DIR/claude.pid" ]
  log_has "action=done"
}

@test "short session skipped with its turn count" {
  mk_tx 3
  run_worker
  log_has "action=skip reason=short-session turns=3"
  [ ! -e "$STUB_DIR/claude.pid" ]
  [ "$(run_outcome)" = "skipped" ]
}

@test "only real human turns are counted" {
  : > "$TXN"
  tx human-string "one" >> "$TXN"
  tx human-blocks "two" >> "$TXN"
  tx human-string "three" >> "$TXN"
  local i
  for ((i = 0; i < 40; i++)); do tx tool-result "r" >> "$TXN"; done
  for ((i = 0; i < 5; i++)); do tx meta-user "m" >> "$TXN"; tx sidechain-user "s" >> "$TXN"; tx attachment "a" >> "$TXN"; done
  run_worker
  log_has "action=skip reason=short-session turns=3"
}

@test "a corrupt line and a truncated last line are tolerated" {
  tx human-string "q1" > "$TXN"
  tx human-string "q2" >> "$TXN"
  tx human-string "q3" >> "$TXN"
  echo "this is not json {{{" >> "$TXN"
  tx human-string "q4" >> "$TXN"
  tx human-string "q5" >> "$TXN"
  tx human-string "q6" >> "$TXN"
  # truncated, with no trailing newline
  tx human-string "q7" | head -c 60 >> "$TXN"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done reason=ok turns=6"
}

@test "second end of the same session is skipped, a resumed one with new turns is not" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  : > "$LOG"
  run_worker
  log_has "action=skip reason=no-new-turns"
  # the session gains 5 human turns and ends again: handed off again (new body, so the
  # stub's deterministic file name still produces a committable change)
  local i
  for ((i = 7; i <= 11; i++)); do tx human-string "question $i" >> "$TXN"; done
  : > "$LOG"
  STUB_HANDOFF_BODY="second" run_worker
  log_has "action=done"
}

@test "force bypasses the content checks only" {
  mk_tx 6
  tx slash-handoff "scratch" >> "$TXN"
  export STUB_CLAUDE_MODE=handoff-logs GRID_AUTOHANDOFF_FORCE=1
  run_worker
  log_has "action=done"
  # an unreadable transcript is still refused
  TXN="$BATS_TEST_TMPDIR/missing.jsonl"
  : > "$LOG"
  run_worker
  log_has "action=skip reason=no-transcript"
}

@test "every skip is one line of the documented shape, and recorded as skipped" {
  mk_tx 2
  run_worker
  grep -Eq "^ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z session=$SID action=skip reason=short-session turns=2\$" "$LOG"
  [ "$(run_outcome)" = "skipped" ]
}

# ---------------------------------------------------------------------------
# Capped, verified run
# ---------------------------------------------------------------------------

@test "invocation shape: flags, write-only rules, working directory" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  line="$(claude_line)"
  contains "$line" "claude -p /handoff "
  contains "$line" "--model sonnet"
  contains "$line" "--max-turns 25"
  contains "$line" "--max-budget-usd 1.00"
  contains "$line" "--tools Read,Write,Bash "
  contains "$line" "--disallowedTools Edit Bash(git:*)"
  contains "$line" "--append-system-prompt-file $REPO_ROOT/hooks/lib/auto-handoff-system.md"
  contains "$line" "--permission-mode default"   # pinned since WP-016, see the isolation tests
  allowed="${line#*--allowedTools }"
  allowed="${allowed%% --disallowedTools*}"
  contains "$allowed" "Read "
  contains "$allowed" "$(edit_rule "$(cd "$P" && pwd -P)/LOGS")"
  contains "$allowed" "$(edit_rule "$GRID_HANDOFF_FALLBACK_DIR/proj")"
  lacks "$allowed" "git"
  lacks "$allowed" "Write"
  # no bare Edit: every Edit entry carries a path
  refute grep -qE '(^| )Edit( |$)' <<< "$allowed"
  [ "$(cat "$STUB_DIR/claude.cwd")" = "$P" ]
  # the digest and fallback dirs are passed with --add-dir
  contains "$line" "--add-dir $GRID_HANDOFF_FALLBACK_DIR/proj"
}

@test "the system prompt carries the write-only rules" {
  f="$REPO_ROOT/hooks/lib/auto-handoff-system.md"
  [ "$(wc -c < "$f")" -lt 1500 ]
  for phrase in 'do not run git' 'never push' 'write nothing else' \
                'if a write is denied, write both files to the fallback dir' \
                'run single commands only' 'GRID_HANDOFF_FALLBACK_DIR'; do
    grep -qF -- "$phrase" "$f" || { echo "missing: $phrase" >&2; return 1; }
  done
  refute grep -qE 'https?://' "$f"
}

@test "success is verified: LOGS pair committed, log done, run record ok" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  before="$(commits "$P")"
  run_worker
  grep -Eq "action=done reason=ok turns=6 commit=[0-9a-f]+ push=no-not-private" "$LOG"
  [ "$(commits "$P")" -eq $((before + 1)) ]
  [ "$(run_outcome)" = "ok" ]
  # exactly the two handoff files are in the new commit
  [ "$(git -C "$P" show --name-only --format= HEAD | sort | tr '\n' ' ')" = \
    "LOGS/2026-01-01-testhost-stub-context.md LOGS/2026-01-01-testhost-stub-handoff.md " ]
}

@test "files in the fallback dir are accepted (not a git repo: left uncommitted)" {
  mk_tx 6
  rmdir "$P/LOGS"
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  grep -Eq "action=done reason=ok turns=6 commit=none" "$LOG"
  [ -f "$GRID_HANDOFF_FALLBACK_DIR/proj/2026-01-01-testhost-stub-handoff.md" ]
  [ "$(run_outcome)" = "ok" ]
}

@test "silent failure is detected: exit 0 and no handoff file" {
  mk_tx 6
  export STUB_CLAUDE_EXIT=0
  run_worker
  log_has "action=error reason=no-handoff-file"
  [ "$(run_outcome)" = "error" ]
}

@test "a stale handoff file is not success" {
  mk_tx 6
  echo old > "$P/LOGS/2019-01-01-old-handoff.md"
  touch -t 202001010000 "$P/LOGS/2019-01-01-old-handoff.md"
  run_worker
  log_has "action=error reason=no-handoff-file"
}

@test "child failure is reported with its exit code" {
  mk_tx 6
  export STUB_CLAUDE_EXIT=3
  run_worker
  log_has "action=error reason=claude-exit-3"
  [ "$(run_outcome)" = "error" ]
}

@test "the real claude is unreachable from tests: the tripwire logs exit 127" {
  mk_tx 6
  export GRID_CLAUDE=/nonexistent/grid-claude-tripwire
  run_worker
  log_has "action=error reason=claude-exit-127"
}

@test "wall-clock timeout kills the child and is logged" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=30 GRID_AUTOHANDOFF_TIMEOUT=2
  run_worker
  log_has "action=error reason=timeout"
  pid="$(cat "$STUB_DIR/claude.pid")"
  ! kill -0 "$pid" 2>/dev/null
}

@test "unexpected file: a planted git hook and a changed git config refuse the commit" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-extra
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF ".git/hooks/x"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF ".git/config"
  [ "$(commits "$P")" -eq "$before" ]
  # nothing moved or deleted
  [ -f "$P/.git/hooks/x" ]
  grep -qF "[stub] changed = 1" "$P/.git/config"
  [ -f "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
  [ ! -e "$GRID_STATE_DIR/handoff-quarantine" ]
}

@test "unexpected file: a changed git config alone is enough" {
  mk_tx 6
  # the stub writes this exact hook; with an identical file already there only the
  # .git/config append differs
  mkdir -p "$P/.git/hooks"
  printf '#!/bin/sh\n' > "$P/.git/hooks/x"
  export STUB_CLAUDE_MODE=handoff-extra
  before="$(commits "$P")"
  run_worker
  grep -F "reason=unexpected-file" "$LOG" | grep -qF ".git/config"
  refute bash -c 'grep -F "reason=unexpected-file" "$1" | grep -qF ".git/hooks/x"' _ "$LOG"
  [ "$(commits "$P")" -eq "$before" ]
}

@test "stray file blocks the commit and nothing is moved" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-stray
  before="$(commits "$P")"
  run_worker
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "a/b/c/d/e/stray.md"
  [ "$(commits "$P")" -eq "$before" ]
  [ -f "$P/a/b/c/d/e/stray.md" ]
  [ -f "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
  [ -f "$P/LOGS/2026-01-01-testhost-stub-context.md" ]
  [ ! -e "$GRID_STATE_DIR/handoff-quarantine" ]
}

@test "mapped handoff location: the rule covers it and no LOGS rule is granted" {
  mk_tx 6
  mkdir -p "$HOME/.the-grid-private" "$P/notes/handoffs"
  rmdir "$P/LOGS"
  printf '| directory | location |\n|---|---|\n| proj | notes/handoffs |\n' > "$HOME/.the-grid-private/handoff-locations.md"
  export STUB_CLAUDE_MODE=handoff-target STUB_HANDOFF_DIR="$P/notes/handoffs"
  run_worker
  allowed="$(claude_line)"; allowed="${allowed#*--allowedTools }"; allowed="${allowed%% --disallowedTools*}"
  contains "$allowed" "$(edit_rule "$P/notes/handoffs")"
  lacks "$allowed" "LOGS"
  log_has "action=done"
  git -C "$P" show --name-only --format= HEAD | grep -q "^notes/handoffs/2026-01-01-testhost-stub-handoff.md$"
}

@test "mapped location matches the directory case-insensitively: | proj | LOGS | finds Logs/ (R24.qa.F9)" {
  mk_tx 6
  mkdir -p "$HOME/.the-grid-private" "$P/Logs"
  rmdir "$P/LOGS"
  printf '| proj | LOGS |\n' > "$HOME/.the-grid-private/handoff-locations.md"
  export STUB_CLAUDE_MODE=handoff-target STUB_HANDOFF_DIR="$P/Logs"
  run_worker
  allowed="$(claude_line)"; allowed="${allowed#*--allowedTools }"; allowed="${allowed%% --disallowedTools*}"
  contains "$allowed" "$(edit_rule "$P/Logs")"
  log_has "action=done"
  git -C "$P" show --name-only --format= HEAD | grep -q "^Logs/2026-01-01-testhost-stub-handoff.md$"
}

@test "a matched row whose directory is missing grants no rule and does not fall through to LOGS" {
  mk_tx 6
  mkdir -p "$HOME/.the-grid-private"
  # P/LOGS exists (the default), but the row names a directory that does not.
  [ -d "$P/LOGS" ]
  printf '| proj | notes/handoffs |\n' > "$HOME/.the-grid-private/handoff-locations.md"
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  log_has "action=done"
  allowed="$(claude_line)"; allowed="${allowed#*--allowedTools }"; allowed="${allowed%% --disallowedTools*}"
  lacks "$allowed" "$P/LOGS"
  lacks "$allowed" "$P/notes"
  contains "$(claude_line)" "Target directory: none"
  [ ! -e "$P/notes" ]
}

@test "mapped location outside cwd is committed in its own repo" {
  mk_tx 6
  OR="$MOCK_HOOK_ROOT/other-repo"
  mkdir -p "$OR"
  git -C "$OR" init -q
  git -C "$OR" config user.email t@example.com
  git -C "$OR" config user.name t
  echo o > "$OR/o.txt"; git -C "$OR" add o.txt; git -C "$OR" commit -q -m base
  age_tree "$OR"
  mkdir -p "$HOME/.the-grid-private"
  printf '| proj | %s |\n' "$OR" > "$HOME/.the-grid-private/handoff-locations.md"
  export STUB_CLAUDE_MODE=handoff-target STUB_HANDOFF_DIR="$OR"
  before_p="$(commits "$P")"; before_o="$(commits "$OR")"
  run_worker
  log_has "action=done"
  [ "$(commits "$OR")" -eq $((before_o + 1)) ]
  [ "$(git -C "$OR" log -1 --name-only --format= | sort | tr '\n' ' ')" = \
    "2026-01-01-testhost-stub-context.md 2026-01-01-testhost-stub-handoff.md " ]
  [ "$(commits "$P")" -eq "$before_p" ]
  [ -z "$(git -C "$P" status --porcelain)" ]
}

@test "secret in a handoff file: quarantined, nothing committed, value never logged" {
  mk_tx 6
  tok="$(fake_token)"
  export STUB_CLAUDE_MODE=handoff-logs STUB_HANDOFF_BODY="$tok"
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=secret"
  refute grep -qF -- "$tok" "$LOG"
  [ "$(commits "$P")" -eq "$before" ]
  [ -f "$GRID_STATE_DIR/handoff-quarantine/$SID/2026-01-01-testhost-stub-handoff.md" ]
  [ -f "$GRID_STATE_DIR/handoff-quarantine/$SID/2026-01-01-testhost-stub-context.md" ]
  [ ! -e "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
  [ "$(run_outcome)" = "error" ]
}

@test "only the handoff files are committed; the operator's staged file stays staged" {
  mk_tx 6
  echo staged > "$P/staged.txt"
  git -C "$P" add staged.txt
  touch -t 202001010000 "$P/staged.txt"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  [ "$(git -C "$P" show --name-only --format= HEAD | grep -c .)" -eq 2 ]
  [ "$(git -C "$P" diff --cached --name-only)" = "staged.txt" ]
}

# mkprivate: GRID_PRIVATE_DIR becomes a clone of a temp bare repo with one pushed commit
# and a LOGS/ dir, and $P/LOGS a symlink into it (the real-world layout).
mkprivate() {
  BARE="$MOCK_HOOK_ROOT/bare.git"
  git init -q --bare "$BARE"
  rmdir "$GRID_PRIVATE_DIR"
  git clone -q "$BARE" "$GRID_PRIVATE_DIR" 2>/dev/null
  git -C "$GRID_PRIVATE_DIR" config user.email t@example.com
  git -C "$GRID_PRIVATE_DIR" config user.name t
  echo p > "$GRID_PRIVATE_DIR/p.txt"
  git -C "$GRID_PRIVATE_DIR" add p.txt
  git -C "$GRID_PRIVATE_DIR" commit -q -m base
  git -C "$GRID_PRIVATE_DIR" push -q -u origin HEAD 2>/dev/null
  mkdir -p "$GRID_PRIVATE_DIR/LOGS"
  age_tree "$GRID_PRIVATE_DIR"
  rmdir "$P/LOGS"
  ln -s "$GRID_PRIVATE_DIR/LOGS" "$P/LOGS"
  # A tracked link is old: a link newer than the run's stamp now counts as a new symlink.
  touch -h -t 202001010000 "$P/LOGS"
}

@test "private repo: pushed when the handoff is the only unpushed commit" {
  mk_tx 6
  mkprivate
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  grep -Eq "action=done reason=ok turns=6 commit=[0-9a-f]+ push=yes" "$LOG"
  [ "$(git -C "$BARE" log --format=%s -1 HEAD)" = "docs: auto-handoff 2026-01-01-testhost-stub" ]
}

@test "private repo: not pushed when another commit is unpushed" {
  mk_tx 6
  mkprivate
  git -C "$GRID_PRIVATE_DIR" commit -q --allow-empty -m other
  bare_before="$(git -C "$BARE" rev-parse HEAD)"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  grep -Eq "action=done reason=ok turns=6 commit=[0-9a-f]+ push=no-other-commits" "$LOG"
  [ "$(git -C "$BARE" rev-parse HEAD)" = "$bare_before" ]
}

@test "digest is private and removed" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  [ "$(cat "$STUB_DIR/claude.umask")" = "0077" ]
  line="$(claude_line)"
  digest_dir="${line#*--add-dir }"; digest_dir="${digest_dir%% *}"
  [ -n "$digest_dir" ]
  [ ! -e "$digest_dir" ]
  # the stub saw a real digest
  grep -q "question 1" "$STUB_DIR/claude.digest"
}

# ---------------------------------------------------------------------------
# Digest
# ---------------------------------------------------------------------------

@test "digest is compact: capped, with the first and last human turns kept" {
  : > "$TXN"
  tx human-string "FIRST-TURN-MARKER" >> "$TXN"
  local i filler
  filler="$(head -c 1500 /dev/zero | tr '\0' 'q')"
  for ((i = 1; i <= 200; i++)); do
    tx assistant-text "$filler $i" >> "$TXN"
    tx human-string "$filler $i" >> "$TXN"
  done
  tx human-string "LAST-TURN-MARKER" >> "$TXN"
  run bash "$REPO_ROOT/hooks/lib/transcript-digest.sh" "$TXN" "$BATS_TEST_TMPDIR/digest.md" 20000
  [ "$status" -eq 0 ]
  size="$(wc -c < "$BATS_TEST_TMPDIR/digest.md")"
  [ "$size" -le 20400 ]
  grep -q "FIRST-TURN-MARKER" "$BATS_TEST_TMPDIR/digest.md"
  grep -q "LAST-TURN-MARKER" "$BATS_TEST_TMPDIR/digest.md"
  grep -q "elided" "$BATS_TEST_TMPDIR/digest.md"
}

@test "digest keeps prose and tool-call lines and drops tool results" {
  big="$(head -c 100000 /dev/zero | tr '\0' 'z')"
  : > "$TXN"
  tx human-string "please run it" >> "$TXN"
  tx assistant-bash-tool "x" >> "$TXN"
  tx tool-result "$big" >> "$TXN"
  tx assistant-text "all done here" >> "$TXN"
  tx sidechain-user "SIDECHAIN-TEXT" >> "$TXN"
  run bash "$REPO_ROOT/hooks/lib/transcript-digest.sh" "$TXN" "$BATS_TEST_TMPDIR/digest.md" 300000
  [ "$status" -eq 0 ]
  grep -q "please run it" "$BATS_TEST_TMPDIR/digest.md"
  grep -q "all done here" "$BATS_TEST_TMPDIR/digest.md"
  grep -q "^tool: Bash " "$BATS_TEST_TMPDIR/digest.md"
  refute grep -q "zzzzzzzzzz" "$BATS_TEST_TMPDIR/digest.md"
  refute grep -q "SIDECHAIN-TEXT" "$BATS_TEST_TMPDIR/digest.md"
}

# ---------------------------------------------------------------------------
# WP-016: write confinement (hardening, refs private WP-016; D-extra-1 option B).
# The stub claude ignores permission rules, so these tests pin what the WORKER does: which
# paths it grants, what it detects afterwards, and how it launches the child. Whether the
# real Claude Code honours the rule form is an operator check (OPERATOR-TASKS B1), and
# nothing below depends on it.
# ---------------------------------------------------------------------------

# allowed_rules: the --allowedTools part of the logged stub invocation.
allowed_rules() {
  local l; l="$(claude_line)"; l="${l#*--allowedTools }"; printf '%s' "${l%% --disallowedTools*}"
}

# git_shim <sh snippet>: put a `git` first on PATH that runs <snippet> whenever the
# subcommand is `commit`, then hands over to the real git. (The worker's own git calls
# have hooks disabled, so a shim is how a test makes the commit slow or failing.)
git_shim() {
  local real; real="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/gitshim"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = commit ] && { %s; }; done\nexec "%s" "$@"\n' "$1" "$real" > "$BATS_TEST_TMPDIR/gitshim/git"
  chmod +x "$BATS_TEST_TMPDIR/gitshim/git"
  export PATH="$BATS_TEST_TMPDIR/gitshim:$PATH"
}

# clear_run: forget the previous worker run (stub call log, hook log) so a test can run twice.
clear_run() { : > "$STUB_LOG"; : > "$LOG"; }

@test "a tracked LOGS symlink to a dir outside cwd and private is refused: no rule, nothing written there" {
  mk_tx 6
  OUTD="$MOCK_HOOK_ROOT/outside"; mkdir -p "$OUTD"
  rmdir "$P/LOGS"; ln -s "$OUTD" "$P/LOGS"
  touch -h -t 202001010000 "$P/LOGS"          # a tracked, old link, as in a real checkout
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  lacks "$(allowed_rules)" "$OUTD"
  lacks "$(allowed_rules)" "$(cd "$OUTD" && pwd -P)"
  [ -z "$(ls -A "$OUTD")" ]
  log_has "target-refused=symlink-outside"
  log_has "action=done"                       # the run itself still works, via the fallback dir
}

@test "the the-grid layout (LOGS symlinked into the private repo) still resolves and commits" {
  mk_tx 6
  mkprivate
  touch -h -t 202001010000 "$P/LOGS"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  contains "$(allowed_rules)" "$(edit_rule "$(cd "$GRID_PRIVATE_DIR/LOGS" && pwd -P)")"
  refute log_has "target-refused"
  grep -Eq "action=done reason=ok turns=6 commit=[0-9a-f]+" "$LOG"
}

@test "table rows pointing at HOME, above cwd or into ~/.ssh are refused" {
  mkdir -p "$HOME/.ssh"
  export STUB_CLAUDE_MODE=handoff-fallback
  local row n=0
  for row in '~' '../..' '~/.ssh'; do
    n=$((n + 1))
    mk_tx 6
    printf '| proj | %s |\n' "$row" > "$GRID_PRIVATE_DIR/handoff-locations.md"
    SID="11111111-1111-4111-8111-11111111111$n"
    clear_run
    run_worker
    refute log_has "action=error"
    log_has "target-refused="
    lacks "$(allowed_rules)" "$(edit_rule "$HOME")"
    lacks "$(allowed_rules)" "$(edit_rule "$HOME/.ssh")"
    lacks "$(allowed_rules)" "$(edit_rule "$MOCK_HOOK_ROOT")"
  done
}

@test "a table row outside cwd and outside any git work tree is refused" {
  mk_tx 6
  mkdir -p "$MOCK_HOOK_ROOT/plain"
  printf '| proj | %s |\n' "$MOCK_HOOK_ROOT/plain" > "$GRID_PRIVATE_DIR/handoff-locations.md"
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  lacks "$(allowed_rules)" "$MOCK_HOOK_ROOT/plain"
  log_has "target-refused=not-a-git-work-tree"
}

@test "the locations table is read from GRID_PRIVATE_DIR first, then from ~/.the-grid-private" {
  mk_tx 6
  mkdir -p "$P/notes/handoffs" "$P/other" "$HOME/.the-grid-private"
  rmdir "$P/LOGS"
  printf '| proj | notes/handoffs |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  printf '| proj | other |\n' > "$HOME/.the-grid-private/handoff-locations.md"
  export STUB_CLAUDE_MODE=handoff-target STUB_HANDOFF_DIR="$P/notes/handoffs"
  run_worker
  contains "$(allowed_rules)" "$(edit_rule "$P/notes/handoffs")"
  lacks "$(allowed_rules)" "$P/other"
  log_has "action=done"
}

# Glob metacharacters in a directory name would be placed unescaped into a permission rule
# (where `*` may widen it). Such a path gets no rule; the fallback dir (whose name is
# sanitised the same way) is used instead.
@test "cwd names with glob metacharacters get no rule and use the fallback" {
  export STUB_CLAUDE_MODE=handoff-target
  local name san n=0
  for name in 'st*r' 'a[b]' 'p(re)n' $'a\nb'; do
    n=$((n + 1))
    mkproj "$name"
    mk_tx 6
    san="$(printf '%s' "${name//$'\n'/_}" | sed 's/[][*?{}()!]/_/g')"
    STUB_HANDOFF_DIR="$GRID_HANDOFF_FALLBACK_DIR/$san"
    export STUB_HANDOFF_DIR
    SID="11111111-1111-4111-8111-22222222222$n"
    clear_run
    run_worker
    log_has "action=done"
    # No Edit rule outside the (sanitised) fallback dir: the path with the metacharacter is not granted.
    [ "$(allowed_rules | grep -o 'Edit(/[^ ]*' | grep -vc "/fallback/$san/")" -eq 0 ]
    [ -f "$STUB_HANDOFF_DIR/2026-01-01-testhost-stub-handoff.md" ]
  done
}

@test "a cwd spelled with .. gets only the resolved rule, never one containing .." {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  run bash "$WORKER" "$SID" "$TXN" "$P/../proj" other
  [ "$status" -eq 0 ]
  log_has "action=done"
  lacks "$(allowed_rules)" ".."
  contains "$(allowed_rules)" "$(edit_rule "$(cd "$P" && pwd -P)/LOGS")"
}

# ---- post-run detection: what the child touched beyond the pair ----------------------
# Detect-only by design: nothing is moved or deleted, the run ends error/unexpected-file with
# no commit, and the path is named in the log. (Writes anywhere else on disk cannot be seen
# from here; that is what the grants, the deny rules and the environment are for.)

# mkother: $OR, a second git repo (the mapped handoff target), with the table row for it.
mkother() {
  OR="$MOCK_HOOK_ROOT/other-repo"
  mkdir -p "$OR"
  git -C "$OR" init -q
  git -C "$OR" config user.email t@example.com
  git -C "$OR" config user.name t
  echo o > "$OR/o.txt"; git -C "$OR" add o.txt; git -C "$OR" commit -q -m base
  age_tree "$OR"
  printf '| proj | %s |\n' "$OR" > "$GRID_PRIVATE_DIR/handoff-locations.md"
}

@test "a stray file the child writes into the fallback dir is detected" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-outside STUB_OUTSIDE_FILE="$GRID_HANDOFF_FALLBACK_DIR/proj/extra.txt"
  mkdir -p "$GRID_HANDOFF_FALLBACK_DIR/proj"
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "extra.txt"
  [ "$(commits "$P")" -eq "$before" ]
}

@test "git internals of the OTHER repo (hook, info/exclude) are detected and nothing is committed" {
  mk_tx 6
  mkother
  export STUB_CLAUDE_MODE=handoff-githook-other STUB_HANDOFF_DIR="$OR"
  before="$(commits "$OR")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "hooks/post-commit"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "info/exclude"
  [ "$(commits "$OR")" -eq "$before" ]
}

@test "a new symlink beside the pair is unexpected-file" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-symlink
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "evil-link"
  [ "$(commits "$P")" -eq "$before" ]
  [ -L "$P/LOGS/evil-link" ]            # detect only: nothing is deleted
}

@test "a pre-planted symlink at the handoff path is not accepted as the handoff" {
  mk_tx 6
  : > "$MOCK_HOOK_ROOT/elsewhere.md"
  ln -s "$MOCK_HOOK_ROOT/elsewhere.md" "$P/LOGS/2026-01-01-testhost-stub-handoff.md"
  touch -h -t 202001010000 "$P/LOGS/2026-01-01-testhost-stub-handoff.md"
  export STUB_CLAUDE_MODE=handoff-logs
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "2026-01-01-testhost-stub-handoff.md"
  [ "$(commits "$P")" -eq "$before" ]
}

@test "a changed shell rc file in HOME is detected" {
  mk_tx 6
  printf 'export A=1\n' > "$HOME/.bashrc"
  export STUB_CLAUDE_MODE=handoff-home-dotfile
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF ".bashrc"
  [ "$(commits "$P")" -eq "$before" ]
}

@test "a HOME rc file the child did not touch is not reported" {
  mk_tx 6
  printf 'export A=1\n' > "$HOME/.bashrc"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
}

# ---- child isolation: no ambient permission config, no ambient secrets ------------------
# disallowed_rules: the --disallowedTools part of the logged stub invocation.
disallowed_rules() {
  local l; l="$(claude_line)"; l="${l#*--disallowedTools }"; printf '%s' "${l%% --add-dir*}"
}

@test "argv carries --permission-mode default, --setting-sources user, --strict-mcp-config and the extra denies" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  line="$(claude_line)"
  contains "$line" "--permission-mode default"
  contains "$line" "--setting-sources user"
  contains "$line" "--strict-mcp-config"
  # the original denies are still first
  contains "$line" "--disallowedTools Edit Bash(git:*)"
  denied="$(disallowed_rules)"
  local d
  for d in .ssh .claude .config .gnupg .aws; do contains "$denied" "$(edit_rule "$HOME/$d")"; done
  contains "$denied" "Edit(/$HOME/.bashrc)"
  contains "$denied" "Edit(/$HOME/.zshrc)"
  contains "$denied" "Edit(**/.git/**)"
}

@test "ambient secrets are absent from the child environment; the basics and the guard are present" {
  mk_tx 6
  export GH_TOKEN="sentinel-gh-$$" ANTHROPIC_API_KEY="sentinel-anthropic-$$" AWS_SECRET_ACCESS_KEY="sentinel-aws-$$"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  refute grep -q "sentinel-" "$STUB_DIR/claude.env"
  grep -qx "GRID_AUTOHANDOFF_CHILD=1" "$STUB_DIR/claude.env"
  grep -qx "HOME=$HOME" "$STUB_DIR/claude.env"
  grep -q '^PATH=' "$STUB_DIR/claude.env"
  # the config dir is how a custom-located login is found, so it is passed on
  grep -qx "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" "$STUB_DIR/claude.env"
}

@test "GRID_AUTOHANDOFF_KEEP_ENV passes named variables and PREFIX* groups, and nothing else" {
  mk_tx 6
  export KEEP_ME=yes KEEP_PFX_A=1 KEEP_PFX_B=2 DROP_ME=no
  export GRID_AUTOHANDOFF_KEEP_ENV='STUB_*,GRID_*,KEEP_ME,KEEP_PFX_*'
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  grep -qx "KEEP_ME=yes" "$STUB_DIR/claude.env"
  grep -qx "KEEP_PFX_A=1" "$STUB_DIR/claude.env"
  grep -qx "KEEP_PFX_B=2" "$STUB_DIR/claude.env"
  refute grep -q "^DROP_ME=" "$STUB_DIR/claude.env"
}

@test "a malformed KEEP_ENV entry is ignored, never evaluated" {
  mk_tx 6
  export GRID_AUTOHANDOFF_KEEP_ENV='STUB_*,GRID_*,a[$(touch '"$BATS_TEST_TMPDIR"'/pwned)]'
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

# ---------------------------------------------------------------------------
# WP-017: concurrency and false failures (hardening, refs private WP-017)
# ---------------------------------------------------------------------------

# lock_dir: the per-session lock the worker takes.
lock_dir() { printf '%s\n' "$GRID_HOOK_STATE_DIR/handoff/$SID.lock"; }

@test "five parallel hooks for one session spawn exactly one claude" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=2
  local i
  for i in 1 2 3 4 5; do fire & done
  wait
  five_logged() { [ "$(grep -cE 'action=(done|error|skip)' "$LOG" 2>/dev/null)" -eq 5 ]; }
  wait_for 30 five_logged
  [ "$(grep -c '^claude ' "$STUB_LOG")" -eq 1 ]
  [ "$(grep -c 'action=spawn' "$LOG")" -eq 1 ]
  [ "$(grep -c 'reason=already-running' "$LOG")" -eq 4 ]
}

@test "a fresh lock for the session skips with already-running; a stale one is taken over" {
  mk_tx 6
  mkdir -p "$(lock_dir)"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=skip reason=already-running"
  [ ! -e "$STUB_DIR/claude.pid" ]
  [ -d "$(lock_dir)" ]                      # not ours: left alone
  touch -t 202001010000 "$(lock_dir)"       # older than TIMEOUT + 300 s
  : > "$LOG"
  run_worker
  log_has "action=done"
  [ ! -d "$(lock_dir)" ]                    # released by the run that took it
}

@test "the session lock is released on every exit path" {
  mk_tx 6
  export STUB_CLAUDE_EXIT=3
  run_worker
  log_has "action=error reason=claude-exit-3"
  [ ! -d "$(lock_dir)" ]
}

# The marker is written before the child spawns, so an error run is not retried by every
# later SessionEnd of the same session (each retry is a paid model call).
@test "an errored run still leaves the turn marker: the next end is no-new-turns" {
  mk_tx 6
  export STUB_CLAUDE_EXIT=3
  run_worker
  log_has "action=error reason=claude-exit-3"
  : > "$LOG"; : > "$STUB_LOG"
  run_worker
  log_has "action=skip reason=no-new-turns"
  [ "$(grep -c '^claude ' "$STUB_LOG")" -eq 0 ]
}

@test "PATH without perl logs skip reason=no-perl and starts nothing" {
  mk_tx 6
  nop="$(path_without 'perl*')"
  sessionend_payload "$SID" "$TXN" "$P" | PATH="$nop" bash "$REPO_ROOT/hooks/run.sh" auto-handoff
  log_has "session=$SID action=skip reason=no-perl"
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "a 300-character session id is bad-payload, in the hook and in the worker" {
  mk_tx 6
  long="$(printf 'a%.0s' $(seq 300))"
  sessionend_payload "$long" "$TXN" "$P" | bash "$REPO_ROOT/hooks/run.sh" auto-handoff
  [ "$(grep -c 'action=skip reason=bad-payload' "$LOG")" -eq 1 ]
  [ ! -e "$STUB_DIR/claude.pid" ]
  : > "$LOG"
  SID="$long"
  run_worker
  log_has "action=skip reason=bad-payload"
  [ ! -e "$STUB_DIR/claude.pid" ]
}

@test "the handoff command tag typed mid-text is not already-ran; a real /handoff line still is" {
  tx human-string "q1 please explain <command-name>/handoff</command-name> to me" > "$TXN"
  local i
  for ((i = 2; i <= 6; i++)); do tx human-string "question $i" >> "$TXN"; done
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  refute log_has "reason=already-ran"
  log_has "action=done"
  : > "$LOG"
  rm -rf "$GRID_HOOK_STATE_DIR/handoff"
  tx slash-handoff "scratch" >> "$TXN"
  run_worker
  log_has "action=skip reason=already-ran"
}

# ---- verification by before/after snapshot (no clock stamp) -------------------------------

# cwd_lock <dir>: the per-cwd lock directory the worker uses for <dir> (same key recipe).
cwd_lock() { printf '%s/handoff/cwd-%s.lock\n' "$GRID_HOOK_STATE_DIR" "$(printf '%s' "$(cd "$1" && pwd -P)" | cksum | cut -d' ' -f1)"; }

@test "race: a file touched right before the hook still ends done" {
  mk_tx 6
  echo edited > "$P/just-edited.txt"          # NOT aged: modified well inside the old 2 s back-dated window
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  refute log_has "reason=unexpected-file"
}

@test "a pre-existing file the child modifies is still unexpected-file" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-modify
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "base.txt"
  [ "$(commits "$P")" -eq "$before" ]
}

@test "two sessions in one cwd each commit their own pair" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=1
  before="$(commits "$P")"
  STUB_HANDOFF_PREFIX=A- bash "$WORKER" "11111111-1111-4111-8111-aaaaaaaaaaaa" "$TXN" "$P" other &
  STUB_HANDOFF_PREFIX=B- bash "$WORKER" "11111111-1111-4111-8111-bbbbbbbbbbbb" "$TXN" "$P" other &
  wait
  [ "$(grep -c 'action=done' "$LOG")" -eq 2 ]
  refute log_has "reason=unexpected-file"
  [ "$(commits "$P")" -eq $((before + 2)) ]
  [ -f "$P/LOGS/A-2026-01-01-testhost-stub-handoff.md" ]
  [ -f "$P/LOGS/B-2026-01-01-testhost-stub-handoff.md" ]
}

@test "a second session waits for the cwd lock, then skips with cwd-busy and no marker" {
  mk_tx 6
  mkdir -p "$(cwd_lock "$P")"
  export GRID_AUTOHANDOFF_WAIT=1 STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=skip reason=cwd-busy"
  [ ! -e "$STUB_DIR/claude.pid" ]
  [ ! -e "$GRID_HOOK_STATE_DIR/handoff/$SID" ]       # no marker: the session may retry later
  [ ! -d "$(lock_dir)" ]                              # the session lock was released
}

@test "cwd = HOME, / or a parent of HOME is skipped with cwd-too-broad and no child spawn" {
  mk_tx 6
  local c n=0
  for c in "$HOME" "/" "$MOCK_HOOK_ROOT"; do
    n=$((n + 1))
    SID="11111111-1111-4111-8111-33333333333$n"
    run bash "$WORKER" "$SID" "$TXN" "$c" other
    log_has "session=$SID action=skip reason=cwd-too-broad"
  done
  [ ! -e "$STUB_DIR/claude.pid" ]
}

# ---- timeouts, signals and orphans ------------------------------------------------------

# The hook's outer alarm must outlast everything the worker can legitimately do:
# child timeout + 60 s (git phase) + 120 s (digest) + the cwd-lock wait.
@test "the hook's outer alarm covers the timeout, the git phase, the digest and the cwd wait" {
  mk_tx 6
  shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  # A perl that only records the alarm argument (the 4th: -MPOSIX -e <code> <alarm> ...).
  printf '#!/bin/sh\nprintf "%%s\\n" "$4" > "%s/alarm"\nexit 0\n' "$shim" > "$shim/perl"
  chmod +x "$shim/perl"
  sessionend_payload "$SID" "$TXN" "$P" | PATH="$shim:$PATH" GRID_AUTOHANDOFF_TIMEOUT=100 GRID_AUTOHANDOFF_WAIT=7 \
    bash "$REPO_ROOT/hooks/run.sh" auto-handoff
  wait_for 5 test -s "$shim/alarm"
  [ "$(cat "$shim/alarm")" -eq 308 ]
}

@test "timeout kills the grandchild too, and the log keeps only decision lines" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=30 STUB_CLAUDE_GRANDCHILD=1 GRID_AUTOHANDOFF_TIMEOUT=2
  fire
  wait_for 20 terminal_logged
  log_has "action=error reason=timeout"
  gp="$(cat "$STUB_DIR/grandchild.pid")"
  gone() { ! kill -0 "$gp" 2>/dev/null; }
  wait_for 5 gone || { kill "$gp" 2>/dev/null; false; }   # never leave the sleeper behind, pass or fail
  gone
  # every line is a decision line, a child| line or blank: no "Alarm clock" job noise
  refute grep -vE '^(ts=|child\||$)' "$LOG"
}

@test "a missing claude binary is still exit 127 through the timeout wrapper" {
  mk_tx 6
  export GRID_CLAUDE=/nonexistent/grid-claude-tripwire
  run_worker
  log_has "action=error reason=claude-exit-127"
}

# The hook's outer alarm is SIGALRM to the worker. A foreground child would defer the
# worker's trap until it finished, so the children run in the background and the worker
# waits; the trap then unstages the pair and leaves nothing behind.
@test "a slow pre-commit hook plus the outer alarm leaves the index clean" {
  mk_tx 6
  # (the worker runs its git with hooks off, so the commit is made slow by a git shim)
  git_shim "touch \"$MOCK_HOOK_ROOT/hook-started\"; sleep 8"
  export STUB_CLAUDE_MODE=handoff-logs
  bash "$WORKER" "$SID" "$TXN" "$P" other > /dev/null 2>&1 &
  wpid=$!
  wait_for 30 test -e "$MOCK_HOOK_ROOT/hook-started"
  kill -ALRM "$wpid"
  wait "$wpid" || true
  [ -z "$(git -C "$P" diff --cached --name-only)" ]
  [ ! -e "$P/.git/index.lock" ]
  log_has "action=error reason=terminated"
  [ ! -d "$(lock_dir)" ]                              # the EXIT trap still ran
}

@test "a terminated worker removes its temp dirs (no leak into TMPDIR)" {
  mk_tx 6
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=20
  bash "$WORKER" "$SID" "$TXN" "$P" other > /dev/null 2>&1 &
  wpid=$!
  wait_for 20 test -s "$STUB_DIR/claude.pid"
  kill -TERM "$wpid"
  wait "$wpid" || true
  [ -z "$(ls -A "$TMPDIR")" ]
  kill "$(cat "$STUB_DIR/claude.pid")" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# WP-018: secrets and logging (hardening, refs private WP-018). Every secret-shaped value
# below is assembled at run time from fragments; none is a real credential.
# ---------------------------------------------------------------------------

# quarantine_has <file>: the quarantined copy of a file for the current session.
quarantine_has() { [ -f "$GRID_STATE_DIR/handoff-quarantine/$SID/$1" ]; }

# The output scan used to honour the "example" exemption, so a model could pass any line by
# adding that word; and it only knew the table's token shapes. The worker's scan is strict:
# no exemptions, plus a few shapes the table does not cover.
@test "strict output scan: six evasion shapes are each quarantined" {
  local pem b64 tok
  pem="$(printf '%s%s' '-----BEGIN RSA PRIV' 'ATE KEY----- (example)')"
  b64="$(printf 'Ab1+%.0s' $(seq 20))"
  tok="$(fake_token)"
  local bodies=("$pem" "$b64" "$tok # example" "DB_PASS=s3cretvalue1" \
                "Authorization: Bearer abcdefghijklmnopqrstuvwxyz" "$(printf 'postgres://admin:s3cr3tpw%sdb.internal/app' @)")
  local n=0 body
  export STUB_CLAUDE_MODE=handoff-logs
  for body in "${bodies[@]}"; do
    n=$((n + 1))
    mk_tx 6
    SID="11111111-1111-4111-8111-44444444444$n"
    export STUB_HANDOFF_BODY="$body"
    clear_run
    run_worker
    log_has "action=error reason=secret" || { echo "row $n not quarantined: $body" >&2; cat "$LOG" >&2; return 1; }
    quarantine_has 2026-01-01-testhost-stub-handoff.md
    quarantine_has 2026-01-01-testhost-stub-context.md
    [ ! -e "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
    # the value never reaches the log
    refute grep -qF -- "$body" "$LOG"
  done
}

# NF-054 (hardening, refs private NF-054): shapes the strict scan once let through, and the
# two human overrides. Each must quarantine the pair; none may be committed.
@test "strict output scan: letters-only value, templated URL password, pragma and placeholder lines are quarantined" {
  local tok bodies n=0 body
  tok="$(fake_token)"
  bodies=("api_key = abcdefghijklmnopqrstuvwxyz" \
          "token = abc(1234567890123456)" \
          "client_secret=abcdefghijklmnop # example" \
          "$(printf 'https://user:$ecretPw9%shost/x' @)" \
          "$(printf 'https://user:pa:ss12345%shost/x' @)" \
          "key = \"$tok\" # grid:allow-secret" \
          "$(printf 'key = "gh%s_example%s"' p "$(printf 'a%.0s' $(seq 30))")")
  export STUB_CLAUDE_MODE=handoff-logs
  for body in "${bodies[@]}"; do
    n=$((n + 1))
    mk_tx 6
    SID="11111111-1111-4111-8111-55555555555$n"
    export STUB_HANDOFF_BODY="$body"
    clear_run
    run_worker
    log_has "action=error reason=secret" || { echo "row $n not quarantined: $body" >&2; cat "$LOG" >&2; return 1; }
    quarantine_has 2026-01-01-testhost-stub-handoff.md
    [ ! -e "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
  done
}

@test "a clean handoff is still committed under the strict scan" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_HANDOFF_BODY="Decisions: use the cache. Next: wire the endpoint."
  before="$(commits "$P")"
  run_worker
  log_has "action=done"
  [ "$(commits "$P")" -eq $((before + 1)) ]
}

# What the model is shown is redacted first: a secret in the transcript would otherwise be
# copied by the model into the handoff, or echoed in a tool call.
@test "digest redacted: a token in a tool input and a Bearer value in user text never reach the child" {
  tok="$(fake_token)"
  : > "$TXN"
  tx human-string "call it with Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123 please" >> "$TXN"
  tx assistant-bash-tool "uses $tok for the call" >> "$TXN"
  local i
  for ((i = 3; i <= 6; i++)); do tx human-string "question $i" >> "$TXN"; done
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  refute grep -qF -- "$tok" "$STUB_DIR/claude.digest"
  refute grep -qF -- "abcdefghijklmnopqrstuvwxyz0123" "$STUB_DIR/claude.digest"
  grep -q '^\[line redacted: ' "$STUB_DIR/claude.digest"
  grep -q "question 3" "$STUB_DIR/claude.digest"           # ordinary lines are untouched
  log_has "redacted=2"
}

# Early exits used to leave an unscanned pair in the tree (the scan came later).
@test "secret-third: an unexpected extra file still quarantines the secret pair" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-secret-third STUB_HANDOFF_BODY="$(fake_token)"
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-file"
  quarantine_has 2026-01-01-testhost-stub-handoff.md
  quarantine_has 2026-01-01-testhost-stub-context.md
  [ ! -e "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
  [ -f "$P/LOGS/third.md" ]                                 # clean extra files are reported, not moved
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "secret="
  [ "$(commits "$P")" -eq "$before" ]
}

@test "timeout with a secret pair on disk quarantines it; the reason stays timeout" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_HANDOFF_BODY="$(fake_token)" STUB_CLAUDE_SLEEP_AFTER=30 GRID_AUTOHANDOFF_TIMEOUT=2
  run_worker
  log_has "action=error reason=timeout"
  quarantine_has 2026-01-01-testhost-stub-handoff.md
  [ ! -e "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
}

@test "a child failure with a secret pair on disk quarantines it too" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_HANDOFF_BODY="$(fake_token)" STUB_CLAUDE_EXIT=3
  run_worker
  log_has "action=error reason=claude-exit-3"
  quarantine_has 2026-01-01-testhost-stub-handoff.md
}

@test "a pre-existing file the child modified is reported with its secret but never moved" {
  mk_tx 6
  tok="$(fake_token)"
  # the "child" appends a secret to a tracked file (handoff-modify appends a plain line, so
  # pre-seed the line it will be compared against: the file must already contain the token)
  printf 'api_key = %s\n' "$tok" > "$P/base.txt"
  touch -t 202001010000 "$P/base.txt"
  export STUB_CLAUDE_MODE=handoff-modify
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "secret="
  [ -f "$P/base.txt" ]                                      # reported, never moved
  refute grep -qF -- "$tok" "$LOG"
}

@test "a token printed by the child is masked in the log" {
  mk_tx 6
  tok="$(fake_token)"
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_PRINT="the key is $tok ok"
  run_worker
  log_has "action=done"
  refute grep -qF -- "$tok" "$LOG"
  log_has "child| [masked: github-token]"
}

@test "a commit failure text is masked in the log" {
  mk_tx 6
  tok="$(fake_token)"
  git_shim "echo \"commit says $tok\" >&2; exit 1"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=error reason=commit-failed"
  refute grep -qF -- "$tok" "$LOG"
}

# 20 MB in ONE message: the digest used to explode the string to code points to measure it
# (about 47 x the message), so it needed roughly a gigabyte.
@test "a 20 MB single-message transcript digests within a memory cap, quickly" {
  [ "$(uname -s)" = Linux ] || skip "ulimit -v is not reliable off Linux"
  # 20 MB cannot go through `tx` (one argv string is capped near 128 KB): read it from a file.
  head -c 20000000 /dev/zero | tr '\0' 'a' > "$BATS_TEST_TMPDIR/big.txt"
  jq -c --rawfile t "$BATS_TEST_TMPDIR/big.txt" 'walk(if . == "__TEXT__" then $t else . end)' \
    "$HOOK_FIXTURES/shapes/human-string.json" > "$TXN"
  tx assistant-text "answer" >> "$TXN"
  local start end
  start="$(date +%s)"
  run bash -c 'ulimit -v 400000; exec bash "$1" "$2" "$3" 300000' _ "$REPO_ROOT/hooks/lib/transcript-digest.sh" "$TXN" "$BATS_TEST_TMPDIR/big-digest.md"
  end="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$BATS_TEST_TMPDIR/big-digest.md")" -le 300400 ]
  grep -q "answer" "$BATS_TEST_TMPDIR/big-digest.md"
  [ $((end - start)) -lt 15 ]
}

# ---------------------------------------------------------------------------
# Review follow-ups (auto-handoff hardening): scan scope, relative rows, nested git dirs
# ---------------------------------------------------------------------------

# mkrepo <dir>: a git repo with one commit (aged so it is not "new").
mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  echo base > "$1/base.txt"; git -C "$1" add base.txt; git -C "$1" commit -q -m base
  age_tree "$1"
}

# --- the scan covers only the directories the child may write to ---------------------

@test "two sessions in different cwds with fallbacks inside one private repo both finish done" {
  mkrepo "$GRID_PRIVATE_DIR"
  export GRID_HANDOFF_FALLBACK_DIR="$GRID_PRIVATE_DIR/handoffs"
  mkproj a; PA="$P"; mkproj b; PB="$P"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-fallback
  STUB_CLAUDE_SLEEP=1 STUB_HANDOFF_PREFIX=A- bash "$WORKER" "11111111-1111-4111-8111-aaaaaaaaaaaa" "$TXN" "$PA" other &
  STUB_CLAUDE_SLEEP=3 STUB_HANDOFF_PREFIX=B- bash "$WORKER" "11111111-1111-4111-8111-bbbbbbbbbbbb" "$TXN" "$PB" other &
  wait
  [ "$(grep -c 'action=done' "$LOG")" -eq 2 ]
  refute log_has "reason=unexpected-file"
}

@test "two sessions whose LOGS link to the same private dir take turns and both finish done" {
  mkrepo "$GRID_PRIVATE_DIR"; mkdir -p "$GRID_PRIVATE_DIR/LOGS"; age_tree "$GRID_PRIVATE_DIR"
  mkproj a; PA="$P"; rmdir "$PA/LOGS"; ln -s "$GRID_PRIVATE_DIR/LOGS" "$PA/LOGS"; touch -h -t 202001010000 "$PA/LOGS"
  mkproj b; PB="$P"; rmdir "$PB/LOGS"; ln -s "$GRID_PRIVATE_DIR/LOGS" "$PB/LOGS"; touch -h -t 202001010000 "$PB/LOGS"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_SLEEP=2
  STUB_CLAUDE_SLEEP=1 STUB_HANDOFF_PREFIX=A- bash "$WORKER" "11111111-1111-4111-8111-aaaaaaaaaaaa" "$TXN" "$PA" other &
  STUB_CLAUDE_SLEEP=3 STUB_HANDOFF_PREFIX=B- bash "$WORKER" "11111111-1111-4111-8111-bbbbbbbbbbbb" "$TXN" "$PB" other &
  wait
  [ "$(grep -c 'action=done' "$LOG")" -eq 2 ]
  refute log_has "reason=unexpected-file"
}

@test "another process writing under the private repo during the run does not fail it" {
  mkrepo "$GRID_PRIVATE_DIR"; mkdir -p "$GRID_PRIVATE_DIR/LOGS"; age_tree "$GRID_PRIVATE_DIR"
  export GRID_HANDOFF_FALLBACK_DIR="$GRID_PRIVATE_DIR/handoffs"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_SIDE_FILE="$GRID_PRIVATE_DIR/LOGS/notes-from-other-agent.md"
  run_worker
  log_has "action=done"
  refute log_has "reason=unexpected-file"
  [ -f "$STUB_SIDE_FILE" ]                       # never quarantined or moved
}

# --- a relative table row must resolve inside the cwd or the private repo ----------------

@test "a relative row that a tracked symlink points at another repo is refused" {
  mkrepo "$MOCK_HOOK_ROOT/victim"; mkdir -p "$MOCK_HOOK_ROOT/victim/sub"
  mkdir -p "$P/docs"; ln -s "$MOCK_HOOK_ROOT/victim/sub" "$P/docs/handoffs"; touch -h -t 202001010000 "$P/docs/handoffs"
  printf '| proj | docs/handoffs |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  lacks "$(allowed_rules)" "$MOCK_HOOK_ROOT/victim"
  log_has "target-refused=outside-cwd"
  [ -z "$(ls -A "$MOCK_HOOK_ROOT/victim/sub")" ]
}

@test "a row that resolves through LOGS into another repo's subdirectory is refused too" {
  mkrepo "$MOCK_HOOK_ROOT/victim"; mkdir -p "$MOCK_HOOK_ROOT/victim/hooks"
  rmdir "$P/LOGS"; ln -s "$MOCK_HOOK_ROOT/victim/hooks" "$P/LOGS"; touch -h -t 202001010000 "$P/LOGS"
  printf '| * | LOGS |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  lacks "$(allowed_rules)" "$MOCK_HOOK_ROOT/victim"
  log_has "target-refused="
}

@test "a relative row to a normal subdirectory still works" {
  mkdir -p "$P/notes/handoffs"; rmdir "$P/LOGS"
  printf '| proj | notes/handoffs |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-target STUB_HANDOFF_DIR="$P/notes/handoffs"
  run_worker
  contains "$(allowed_rules)" "$(edit_rule "$P/notes/handoffs")"
  refute log_has "target-refused"
  log_has "action=done"
}

@test "an absolute row to another repo is still accepted" {
  mkrepo "$MOCK_HOOK_ROOT/other-abs"
  printf '| proj | %s |\n' "$MOCK_HOOK_ROOT/other-abs" > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-target STUB_HANDOFF_DIR="$MOCK_HOOK_ROOT/other-abs"
  run_worker
  contains "$(allowed_rules)" "$(edit_rule "$MOCK_HOOK_ROOT/other-abs")"
  refute log_has "target-refused"
  log_has "action=done"
}

@test "the private repo root is never a target" {
  mkrepo "$GRID_PRIVATE_DIR"
  rmdir "$P/LOGS"; ln -s "$GRID_PRIVATE_DIR" "$P/LOGS"; touch -h -t 202001010000 "$P/LOGS"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  lacks "$(allowed_rules)" "$(edit_rule "$GRID_PRIVATE_DIR")"
  log_has "target-refused=private-root"
}

# Each row check on its own: HOME is made a git work tree (a dotfiles repo) so the
# "inside a git work tree" check cannot be what refuses these.
@test "row checks refuse for their own reason, with HOME itself a git work tree" {
  git -C "$HOME" init -q
  mkdir -p "$HOME/.ssh" "$HOME/.local/bin" "$HOME/.bashrc.d" "$HOME/project"
  mkrepo "$MOCK_HOOK_ROOT/other-abs"
  local rows=("~|home-or-root" "~/.ssh|sensitive-dir" "~/.local/bin|sensitive-dir" "~/.bashrc.d|sensitive-dir" \
              "~/project|home-work-tree" "$MOCK_HOOK_ROOT/work/../other-abs|dotdot")
  local row n=0 loc why
  export STUB_CLAUDE_MODE=handoff-fallback
  for row in "${rows[@]}"; do
    n=$((n + 1)); loc="${row%%|*}"; why="${row##*|}"
    mk_tx 6
    printf '| proj | %s |\n' "$loc" > "$GRID_PRIVATE_DIR/handoff-locations.md"
    SID="11111111-1111-4111-8111-55555555555$n"
    clear_run
    run_worker
    log_has "target-refused=$why" || { echo "row '$loc' expected $why" >&2; cat "$LOG" >&2; return 1; }
  done
}

# --- a git dir the child creates must never run code as the operator --------------------

@test "a nested .git the child plants in the target dir is refused: no canary, no commit" {
  mkdir -p "$P/notes/handoffs"; rmdir "$P/LOGS"
  printf '| proj | notes/handoffs |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  CANARY="$MOCK_HOOK_ROOT/canary"
  export STUB_CLAUDE_MODE=handoff-nested-git STUB_HANDOFF_DIR="$P/notes/handoffs" STUB_CANARY_CMD="touch $CANARY"
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=unexpected-git-dir"
  [ ! -e "$CANARY" ]
  [ "$(commits "$P")" -eq "$before" ]
}

# Defence in depth: with BOTH detections out, a planted fsmonitor must still not run,
# because the worker's own git calls switch it off.
@test "planted git config cannot execute through the worker's git calls (fsmonitor off)" {
  mkdir -p "$P/notes/handoffs"; rmdir "$P/LOGS"
  printf '| proj | notes/handoffs |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  CANARY="$MOCK_HOOK_ROOT/canary"
  # a worker copy with the two detections removed (the real files are untouched)
  W2="$BATS_TEST_TMPDIR/w2root"; mkdir -p "$W2/hooks" "$W2/scripts"
  cp -R "$REPO_ROOT/hooks/lib" "$W2/hooks/lib"; cp "$REPO_ROOT/scripts/run-record.sh" "$W2/scripts/"
  sed -i 's/^  have_gitdir "\$RG" || /  true || /; s/^if \[ "\${#NEWGIT\[@\]}" -gt 0 \]; then/if false; then/' "$W2/hooks/lib/auto-handoff-worker.sh"
  export STUB_CLAUDE_MODE=handoff-nested-git STUB_HANDOFF_DIR="$P/notes/handoffs" STUB_CANARY_CMD="touch $CANARY"
  run bash "$W2/hooks/lib/auto-handoff-worker.sh" "$SID" "$TXN" "$P" other
  [ ! -e "$CANARY" ]
}

# --- review follow-ups on the detection paths -----------------------------------------------

@test "a secret-bearing stray file with no handoff pair is quarantined (no-handoff-file path)" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-leak STUB_HANDOFF_BODY="$(fake_token)"
  run_worker
  log_has "action=error reason=no-handoff-file"
  [ -f "$GRID_STATE_DIR/handoff-quarantine/$SID/leak.txt" ]
  [ ! -e "$P/leak.txt" ]
}

# find -P reports a symlink to a directory as ONE entry; find -L would descend into it and
# report every file inside it under the link's name.
@test "a new symlink to a directory is reported as the link itself, never followed" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-symlink-dir
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "etc-link" || { cat "$LOG" >&2; false; }
  refute bash -c 'grep -F "reason=unexpected-file" "$1" | grep -qF "etc-link/"' _ "$LOG"
}

@test "a child that ignores TERM is killed with its group at the timeout" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs STUB_CLAUDE_IGNORE_TERM=1 GRID_AUTOHANDOFF_TIMEOUT=2
  run_worker
  log_has "action=error reason=timeout"
  pid="$(cat "$STUB_DIR/claude.pid")"
  gone() { ! kill -0 "$pid" 2>/dev/null; }
  wait_for 5 gone || { kill -9 "$pid" 2>/dev/null; false; }
}

# ---------------------------------------------------------------------------
# Delta review follow-ups (auto-handoff hardening)
# ---------------------------------------------------------------------------

# An ssh-style remote must still reach ssh: `-c core.sshCommand=` (an EMPTY command) made git
# fail with "cannot run" before ssh was ever started, so every push to a git@host remote died.
@test "a push to an ssh-style remote invokes ssh (the worker's git does not blank the ssh command)" {
  mk_tx 6
  mkprivate
  git -C "$GRID_PRIVATE_DIR" remote set-url origin git@example.invalid:o/r.git
  mkdir -p "$BATS_TEST_TMPDIR/sshstub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/ssh.called"\nexit 255\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/sshstub/ssh"
  chmod +x "$BATS_TEST_TMPDIR/sshstub/ssh"
  export PATH="$BATS_TEST_TMPDIR/sshstub:$PATH"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  grep -Eq "action=done reason=ok turns=6 commit=[0-9a-f]+ push=failed" "$LOG"
  [ -s "$BATS_TEST_TMPDIR/ssh.called" ]
}

@test "an absolute row inside the cwd that resolves outside through a tracked symlink is refused" {
  mkrepo "$MOCK_HOOK_ROOT/victim"; mkdir -p "$MOCK_HOOK_ROOT/victim/sub"
  mkdir -p "$P/docs"; ln -s "$MOCK_HOOK_ROOT/victim/sub" "$P/docs/handoffs"; touch -h -t 202001010000 "$P/docs/handoffs"
  printf '| proj | %s |\n' "$P/docs/handoffs" > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  lacks "$(allowed_rules)" "$MOCK_HOOK_ROOT/victim"
  log_has "target-refused="
  [ -z "$(ls -A "$MOCK_HOOK_ROOT/victim/sub")" ]
}

@test "a target that resolves into a git dir, or is the whole cwd, is refused" {
  mkrepo "$GRID_PRIVATE_DIR"
  local n=0 what
  export STUB_CLAUDE_MODE=handoff-fallback
  for what in "$P/.git" "$GRID_PRIVATE_DIR/.git" "$P/.git/hooks"; do
    n=$((n + 1))
    mk_tx 6
    rm -rf "$P/LOGS"; ln -s "$what" "$P/LOGS"; touch -h -t 202001010000 "$P/LOGS"
    SID="11111111-1111-4111-8111-66666666666$n"
    clear_run
    run_worker
    log_has "target-refused=git-dir" || { echo "target $what" >&2; cat "$LOG" >&2; return 1; }
    lacks "$(allowed_rules)" "$P/LOGS"
  done
  # the whole cwd as a target (a row of "."): refused as cwd-root
  rm -f "$P/LOGS"; mkdir "$P/LOGS"
  printf '| proj | . |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  SID="11111111-1111-4111-8111-666666666669"
  clear_run
  run_worker
  log_has "target-refused=cwd-root"
}

@test "a relative row with a .. component is refused" {
  mkdir -p "$P/notes/handoffs"
  printf '| proj | notes/../notes/handoffs |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-fallback
  run_worker
  log_has "target-refused=dotdot"
  lacks "$(allowed_rules)" "notes/handoffs"
}

@test "the locations table itself is watched: a change to it is unexpected-file" {
  printf '| nothing | LOGS |\n' > "$GRID_PRIVATE_DIR/handoff-locations.md"
  touch -t 202001010000 "$GRID_PRIVATE_DIR/handoff-locations.md"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-outside STUB_OUTSIDE_FILE="$GRID_PRIVATE_DIR/handoff-locations.md"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF "handoff-locations.md"
}

# ~/.local/bin holds the claude launcher link into a ~1 GB versions dir: it is watched by
# names, types, link targets and sizes, never by content (no hashing, no following links).
@test "a new file in ~/.local/bin is detected; the watch does not hash content" {
  mkdir -p "$HOME/.local/bin"
  ln -s /etc/hostname "$HOME/.local/bin/tool"; touch -h -t 202001010000 "$HOME/.local/bin/tool"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-outside STUB_OUTSIDE_FILE="$HOME/.local/bin/evil"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF ".local/bin/evil"
  # a same-size rewrite of an existing file is NOT seen (documented limit of the cheap watch)
  rm -f "$HOME/.local/bin/evil"; printf 'aaaa' > "$HOME/.local/bin/plain"; touch -t 202001010000 "$HOME/.local/bin/plain"
  SID="11111111-1111-4111-8111-777777777777"
  clear_run
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
}

# NF-054 (hardening, refs private NF-054): ssh reads the files an `Include` points at as
# configuration; the conventional include directory is ~/.ssh/config.d.
@test "a new file in ~/.ssh/config.d is detected like ~/.ssh/config itself" {
  mkdir -p "$HOME/.ssh/config.d"
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-outside STUB_OUTSIDE_FILE="$HOME/.ssh/config.d/evil.conf"
  run_worker
  log_has "action=error reason=unexpected-file"
  grep -F "reason=unexpected-file" "$LOG" | grep -qF ".ssh/config.d/evil.conf"
}

@test "the handoff commit runs with repository hooks off (the repo's own pre-commit does not run)" {
  mk_tx 6
  printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$MOCK_HOOK_ROOT" > "$P/.git/hooks/pre-commit"; chmod +x "$P/.git/hooks/pre-commit"
  export STUB_CLAUDE_MODE=handoff-logs
  run_worker
  log_has "action=done"
  [ ! -e "$MOCK_HOOK_ROOT/hook-ran" ]
}

@test "a locked commit repo ends repo-busy with the pair left on disk, uncommitted" {
  mk_tx 6
  export STUB_CLAUDE_MODE=handoff-logs GRID_AUTOHANDOFF_WAIT=1
  mkdir -p "$GRID_HOOK_STATE_DIR/handoff/repo-$(printf '%s' "$(cd "$P" && pwd -P)" | cksum | cut -d' ' -f1).lock"
  before="$(commits "$P")"
  run_worker
  log_has "action=error reason=repo-busy"
  [ "$(commits "$P")" -eq "$before" ]
  [ -f "$P/LOGS/2026-01-01-testhost-stub-handoff.md" ]
}
