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
  lacks "$line" "--permission-mode"
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
