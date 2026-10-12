#!/usr/bin/env bats
# Tests for the hook runtime (hooks/run.sh, hooks/lib/*, hooks/catalogue.json) and the
# two PreToolUse guards pre-bash-no-bypass and pre-bash-secret-scan.
#
# Scenarios come from openspec/changes/hook-profiles/specs/{git-guard-hooks,hook-profiles}
# and the fixture tables in design.md. Hook payloads are built from the captured
# fixtures in tests/fixtures/hooks/ by tests/helpers/hooks.bash, never hand-typed JSON.
# Secret-shaped test values are assembled from fragments at run time, so this file
# itself contains no secret-shaped literal.
#
# These are the author's own checks; independent verification belongs to qa-engineer.

bats_require_minimum_version 1.5.0   # `run -127` below

load helpers/setup
load helpers/hooks

# path_without walks every executable on PATH (about 40 s here), so build the
# jq-less PATH directory ONCE per file and share it; bats removes BATS_FILE_TMPDIR.
setup_file() {
  NOJQ_DIR="$(TMPDIR="$BATS_FILE_TMPDIR" path_without jq)"
  export NOJQ_DIR
}

setup() {
  common_setup
  # Hook tests run with a temp HOME as well (set AFTER common_setup, which has
  # already captured REAL_HOME for the sandbox check).
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  # Keep git away from any real user or system config in these tests.
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
}

teardown() {
  common_teardown
}

# ---------------------------------------------------------------------------
# helpers local to this file
# ---------------------------------------------------------------------------

# mkrepo [dir]: a scratch git repo $R (default $MOCK_HOOK_ROOT/repo) with one committed
# file base.txt.
mkrepo() {
  R="${1:-$MOCK_HOOK_ROOT/repo}"
  rm -rf "$R"; mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  echo base > "$R/base.txt"
  git -C "$R" add base.txt
  git -C "$R" commit -q -m init
}

# rep <text> <n>: <text> repeated n times (builds long token bodies).
rep() {
  local out="" i
  for ((i = 0; i < $2; i++)); do out+="$1"; done
  printf '%s' "$out"
}

# scan <command>: run pre-bash-secret-scan for <command> with cwd=$R.
scan() { run_hook pre-bash-secret-scan "$(hook_payload "$1" "$R")"; }

# run_hook_within <secs> <id> <command> [cwd]: like run_hook, but the whole hook run is
# killed by a perl alarm after <secs> (not `timeout`: it is missing on stock macOS).
# A killed run has status 142, so a hook that is too slow fails the status check.
# The payload goes through a file so a 50 KB command does not hit the argv limit.
run_hook_within() {
  local secs="$1" id="$2" pf="$MOCK_HOOK_ROOT/payload.json"
  hook_payload "$3" "${4:-}" > "$pf"
  run perl -e 'alarm shift; exec @ARGV' "$secs" bash -c 'exec bash "$1/hooks/run.sh" "$2" < "$3" 2>&1' _ "$REPO_ROOT" "$id" "$pf"
}

# stage_line <line> [file]: write <line> to a file in $R and stage it.
stage_line() {
  printf '%s\n' "$1" > "$R/${2:-f.txt}"
  git -C "$R" add "${2:-f.txt}"
}

# Token builders: every secret-shaped value is split so no whole token is in this file.
tok_aws()       { printf '%s' "AK""IA$(rep Q7 8)"; }
tok_asia()      { printf '%s' "AS""IA$(rep Q7 8)"; }
tok_pem()       { printf '%s' "-----BEGIN RSA PRIV""ATE KEY-----"; }
tok_ghp()       { printf '%s' "gh""p_$(rep Ab3dE 8)"; }
tok_ghpat()     { printf '%s' "github""_pat_$(rep Ab3dE_ 5)"; }
tok_glpat()     { printf '%s' "glp""at-$(rep Ab3dE 5)"; }
tok_npm()       { printf '%s' "np""m_$(rep Ab3dEf 6)"; }
tok_stripe()    { printf '%s' "sk_""live_$(rep Ab3dE 4)"; }
tok_anthropic() { printf '%s' "sk-""ant-$(rep Ab3dE 5)"; }
tok_sk()        { printf '%s' "sk""-$(rep Ab3dE 8)"; }
tok_slack()     { printf '%s' "xo""xb-$(rep Ab3dE 3)"; }
tok_google()    { printf '%s' "AI""za$(rep Ab3dE 7)"; }
tok_jwt()       { printf '%s' "ey""JhbGciOiJIUzI1NiJ9.ey""JzdWIiOiIxMjM0NTY3ODkw.Ab3dEfGhIjKlMn"; }

# ===========================================================================
# Sandbox helper (task 1.0): assert_sandboxed refuses unsafe dirs / a disarmed tripwire
# ===========================================================================

@test "common_setup arms the claude tripwire and sandboxes every hook dir" {
  [ "$GRID_CLAUDE" = "/nonexistent/grid-claude-tripwire" ]
  run -127 "$GRID_CLAUDE"      # executing the tripwire fails: command not found
  for v in CLAUDE_CONFIG_DIR GRID_HOOK_LOG_DIR GRID_HOOK_STATE_DIR GRID_HANDOFF_FALLBACK_DIR GRID_PRIVATE_DIR; do
    [ -d "${!v}" ]
  done
  [ -n "$GRID_RUN_LOG" ]
  [ -n "$REAL_HOME" ]
}

@test "assert_sandboxed refuses an empty GRID_CLAUDE" {
  GRID_CLAUDE="" run assert_sandboxed
  [ "$status" -ne 0 ]
  [[ "$output" == *"GRID_CLAUDE"* ]] || false
}

@test "assert_sandboxed refuses a hook dir under the real ~/.grid" {
  rh="$MOCK_HOOK_ROOT/realhome"
  mkdir -p "$rh/.grid/hook-logs"
  REAL_HOME="$rh" GRID_HOOK_LOG_DIR="$rh/.grid/hook-logs" run assert_sandboxed
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSING"* ]] || false
}

# ===========================================================================
# Launcher (hooks/run.sh)
# ===========================================================================

@test "launcher: Global off, a blocking input exits 0" {
  GRID_HOOKS=off run_hook pre-bash-no-bypass "$(hook_payload 'git commit --no-verify -m x')"
  [ "$status" -eq 0 ]
}

@test "launcher: Single hook disabled exits 0 while other hooks still run" {
  GRID_DISABLED_HOOKS=pre-bash-no-bypass run_hook pre-bash-no-bypass "$(hook_payload 'git commit --no-verify -m x')"
  [ "$status" -eq 0 ]
  # a list with spaces and another id is also honoured
  GRID_DISABLED_HOOKS="other-hook, pre-bash-no-bypass" run_hook pre-bash-no-bypass "$(hook_payload 'git commit --no-verify -m x')"
  [ "$status" -eq 0 ]
  # the other hook is NOT disabled: it still blocks its own input
  mkrepo
  stage_line "token = \"$(tok_ghp)\""
  GRID_DISABLED_HOOKS=pre-bash-no-bypass run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x' "$R")"
  [ "$status" -eq 2 ]
}

@test "launcher: Path traversal id exits non-zero without running anything" {
  run bash "$REPO_ROOT/hooks/run.sh" '../../etc/passwd' < /dev/null
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/hooks/run.sh" 'Pre-Bash' < /dev/null
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/hooks/run.sh" 'no-such-hook' < /dev/null
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/hooks/run.sh" < /dev/null
  [ "$status" -eq 2 ]
}

@test "launcher: unknown well-formed id obeys the kill switches (WP-019)" {
  # A stale settings entry naming a removed hook must be switchable off; without a
  # switch it still exits 2 (and an invalid id exits 2 even with the switch).
  GRID_HOOKS=off run bash "$REPO_ROOT/hooks/run.sh" gone-hook < /dev/null
  [ "$status" -eq 0 ]
  GRID_DISABLED_HOOKS=gone-hook run bash "$REPO_ROOT/hooks/run.sh" gone-hook < /dev/null
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/hooks/run.sh" gone-hook < /dev/null
  [ "$status" -eq 2 ]
  GRID_HOOKS=off run bash "$REPO_ROOT/hooks/run.sh" '../../etc/passwd' < /dev/null
  [ "$status" -eq 2 ]
  GRID_DISABLED_HOOKS='Bad_Id' run bash "$REPO_ROOT/hooks/run.sh" 'Bad_Id' < /dev/null
  [ "$status" -eq 2 ]
}

@test "launcher: works without jq (fail open for an open hook, closed for a guard)" {
  # auto-handoff does not exist until a later change group, so stand in for it with a
  # scratch copy of hooks/ that holds an open-fail stub script using the real
  # grid_require_jq. This exercises run.sh + common.sh in the fail-open mode.
  T="$MOCK_HOOK_ROOT/gridcopy"
  mkdir -p "$T"
  cp -R "$REPO_ROOT/hooks" "$T/hooks"
  cat > "$T/hooks/scripts/auto-handoff.sh" <<'STUB'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$HERE/lib/common.sh"
grid_require_jq open
cat > /dev/null
exit 0
STUB
  noj="$NOJQ_DIR"
  payload="$(sessionend_payload s1 /tmp/transcript.jsonl /tmp/project)"
  PATH="$noj" run bash -c 'printf "%s" "$1" | bash "$2/hooks/run.sh" auto-handoff 2>&1' _ "$payload" "$T"
  [ "$status" -eq 0 ]
  # the real guard fails closed with no jq
  PATH="$noj" run_hook pre-bash-no-bypass "$(hook_payload 'git status')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"jq"* ]] || false
}

# ===========================================================================
# Catalogue and scripts agree
# ===========================================================================

@test "catalogue and scripts agree (ids, scripts, non-empty cost, required fields)" {
  run catalogue_problems "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output" >&2; false; }
  # the two guard entries carry the fields design.md requires (the four opt-in instincts
  # entries are checked in tests/test_instincts_register.bats, so they are excluded here)
  run jq -e '.version == 1 and (.hooks | length) == 7
    and all(.hooks[] | select(.scope == "project" and (has("opt_in") | not)); .event == "PreToolUse" and .matcher == "Bash"
      and .fail == "closed" and .timeout == 5 and .model_cost == false and (.cost | length) > 0)' \
    "$REPO_ROOT/hooks/catalogue.json"
  [ "$status" -eq 0 ]
  # the user-scope auto-handoff entry: SessionEnd, no matcher, no min_profile, fail open
  run jq -e '.hooks[] | select(.id == "auto-handoff")
    | .scope == "user" and .event == "SessionEnd" and (has("matcher") | not) and (has("min_profile") | not)
      and .fail == "open" and .timeout == 5 and .model_cost == true and (.cost | length) > 0' \
    "$REPO_ROOT/hooks/catalogue.json"
  [ "$status" -eq 0 ]
  run jq -r '.hooks[] | "\(.id) \(.min_profile)"' "$REPO_ROOT/hooks/catalogue.json"
  [[ "$output" == *"pre-bash-no-bypass minimal"* ]] || false
  [[ "$output" == *"pre-bash-secret-scan standard"* ]] || false
}

@test "the agreement check can fail (empty cost and a renamed script are both reported)" {
  T="$MOCK_HOOK_ROOT/mutated"
  mkdir -p "$T"
  cp -R "$REPO_ROOT/hooks" "$T/hooks"
  jq '(.hooks[0].cost) = ""' "$T/hooks/catalogue.json" > "$T/c.json"
  mv "$T/c.json" "$T/hooks/catalogue.json"
  mv "$T/hooks/scripts/pre-bash-secret-scan.sh" "$T/hooks/scripts/renamed.sh"
  run catalogue_problems "$T"
  [[ "$output" == *"pre-bash-no-bypass"*"empty cost"* ]] || false
  [[ "$output" == *"pre-bash-secret-scan"*"has no hooks/scripts/pre-bash-secret-scan.sh"* ]] || false
  [[ "$output" == *"renamed.sh"*"no catalogue entry"* ]] || false
}

# ===========================================================================
# common.sh helpers
# ===========================================================================

@test "grid_log creates its directory 0700 and appends lines" {
  . "$REPO_ROOT/hooks/lib/common.sh"
  f="$GRID_HOOK_LOG_DIR/sub/dir/x.log"
  grid_log "$f" "first"
  grid_log "$f" "second"
  [ "$(cat "$f")" = "$(printf 'first\nsecond')" ]
  # permission bits of the created directory: owner only
  perm="$(stat -c '%a' "$GRID_HOOK_LOG_DIR/sub/dir" 2>/dev/null || stat -f '%Lp' "$GRID_HOOK_LOG_DIR/sub/dir")"
  [ "$perm" = "700" ]
}

# ===========================================================================
# pre-bash-no-bypass: scenarios from specs/git-guard-hooks/spec.md
# ===========================================================================

@test "no-bypass: No-verify commit blocked, message names the human bypass" {
  expect_block 'git commit -m "x" --no-verify'
  [[ "$output" == *"GRID_DISABLED_HOOKS=pre-bash-no-bypass"* ]] || false
}

@test "no-bypass: Short no-verify blocked" {
  expect_block 'git commit -nm "x"'
}

@test "no-bypass: Force push blocked" {
  expect_block 'git push --force origin next'
  expect_block 'git push -f'
  expect_block 'git push -fu origin next'
  expect_block 'git push origin +next'
}

@test "no-bypass: Lease push allowed" {
  expect_pass 'git push --force-with-lease origin next'
}

@test "no-bypass: Push dry-run flag is not force" {
  expect_pass 'git push -n origin next'
}

@test "no-bypass: Quoted mention does not block" {
  expect_pass 'git commit -m "docs: explain why --no-verify is banned"'
}

@test "no-bypass: Chained command is inspected" {
  expect_block 'git add . && git commit --no-verify -m x'
}

@test "no-bypass: One-level wrapper is inspected" {
  expect_block "bash -c 'git commit --no-verify -m x'"
  expect_block 'eval "git commit --no-verify -m x"'
  expect_block 'sudo -u root git push --force'
}

@test "no-bypass: Normalised git spelling is inspected" {
  expect_block '\git commit --no-verify -m x'
  expect_block '/usr/bin/git push -f'
}

@test "no-bypass: Hook-disabling config is blocked" {
  expect_block 'git config core.hooksPath /dev/null'
  expect_block 'git config alias.ci "commit --no-verify"'
  expect_block 'HUSKY=0 git commit -m x'
  expect_block 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
}

@test "no-bypass: Harmless wrapped and config commands pass" {
  expect_pass "bash -c 'git status'"
  expect_pass 'git config --get core.hooksPath'
  expect_pass 'git config alias.st status'
}

@test "no-bypass: Unrelated command passes and a non-Bash tool is ignored" {
  expect_pass 'ls -la'
  payload="$(hook_payload 'git commit --no-verify -m x' | jq '.tool_name = "Read"')"
  run_hook pre-bash-no-bypass "$payload"
  [ "$status" -eq 0 ]
}

@test "no-bypass: Real payload shape (captured fixture, only the command replaced)" {
  # The fixture is the real Claude Code payload; if a future version renames
  # .tool_name or .tool_input.command this test fails instead of the guard
  # silently doing nothing.
  jq -e '.tool_name == "Bash" and (.tool_input.command | type) == "string"' "$HOOK_FIXTURES/pretooluse-bash.json"
  expect_block 'git commit --no-verify -m x'
  expect_pass 'git status'
}

@test "no-bypass: Malformed input does not block" {
  run bash -c 'printf "%s" "this is not json" | bash "$1/hooks/run.sh" pre-bash-no-bypass 2>&1' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  payload="$(hook_payload 'git commit --no-verify -m x' | jq 'del(.tool_input.command)')"
  run_hook pre-bash-no-bypass "$payload"
  [ "$status" -eq 0 ]
  payload="$(hook_payload 'git commit --no-verify -m x' | jq 'del(.tool_input)')"
  run_hook pre-bash-no-bypass "$payload"
  [ "$status" -eq 0 ]
}

@test "no-bypass: jq missing fails closed and names jq" {
  PATH="$NOJQ_DIR" run_hook pre-bash-no-bypass "$(hook_payload 'git status')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"jq"* ]] || false
  # WP-019: the message names what the operator can do (install, or restart with the switch)
  [[ "$output" == *"GRID_HOOKS=off"* ]] || false
  [[ "$output" == *"install"* ]] || false
  [[ "$output" == *"every Bash call"* ]] || false
}

# --- the command block table (design.md "Command block table"): one test, row printed on failure

@test "no-bypass: Every row of the block table is blocked" {
  rows=(
    'git commit --no-verify -m x'
    'git commit -m "x" --no-verify'
    'git commit -nm "x"'
    'git commit -anm "x"'
    'git -C /tmp/r commit --no-verify -m x'
    'git -c user.name=x commit --no-verify -m x'
    'FOO=1 git commit --no-verify -m x'
    'git add . && git commit --no-verify -m x'
    'git add .; git commit -n -m x'
    'git push --no-verify'
    'git merge --no-verify topic'
    'git -c core.hooksPath=/dev/null commit -m x'
    'git push --force origin next'
    'git push origin next --force'
    'git push -f'
    'git push -fu origin next'
    'git push -uf origin next'
    'git push origin +next'
    'git push --mirror'
    $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" --no-verify'
  )
  for row in "${rows[@]}"; do expect_block "$row"; done
}

@test "no-bypass: Every row of the pass table is allowed" {
  rows=(
    'ls -la'
    'git status'
    'git log -n 5'
    'git log --oneline -n 3'
    'git commit -m "x"'
    'git commit -am "x"'
    'git commit -mnotes'
    'git commit --amend --no-edit'
    'git commit -m "x" --no-gpg-sign'
    'git commit -F msg.txt'
    'git commit -m "docs: explain why --no-verify is banned"'
    "git commit -m 'docs: git push --force is banned'"
    "git commit -m \"don't use --no-verify\""
    'git commit -m "x" -m "git push -f"'
    $'git commit -m "$(cat <<\'EOF\'\nfix: stop using git push --force and --no-verify\n\nbody\nEOF\n)"'
    'git push origin next'
    'git push -u origin next'
    'git push -n origin next'
    'git push --dry-run origin next'
    'git push --force-with-lease origin next'
    'git push --force-with-lease=next:abc123 origin next'
    'git push origin feature:feature'
    'git push origin :old-branch'
    'git push origin a+b'
    'git push origin --delete old'
    'git fetch -f origin'
    'git branch -f topic HEAD~1'
    'git pull --no-rebase'
    'git config --get core.hooksPath'
    'echo "git push --force"'
    'grep -rn -- "--no-verify" .'
  )
  for row in "${rows[@]}"; do expect_pass "$row"; done
}

# --- WP-019: a slow guard is a silent guard (Claude Code treats a timed-out hook as
# non-blocking), so a large input must be decided well inside the 5 s hook timeout.

@test "no-bypass: 50 KB padded --no-verify command exits 2 within 5 s" {
  pad="$(rep 'abcdefghi ' 5000)"
  run_hook_within 5 pre-bash-no-bypass "git commit --no-verify -m x; echo $pad"
  [ "$status" -eq 2 ] || { echo "status $status (142 = killed by the 5 s alarm)" >&2; false; }
  [[ "$output" == *"BLOCKED"* ]] || false
}

@test "no-bypass: 50 KB single-word padding exits 2 within 5 s" {
  pad="$(rep 'abcdefghij' 5000)"
  run_hook_within 5 pre-bash-no-bypass "git commit --no-verify -m x; echo $pad"
  [ "$status" -eq 2 ] || { echo "status $status (142 = killed by the 5 s alarm)" >&2; false; }
}

@test "no-bypass: a large harmless git-mentioning command passes within 5 s" {
  pad="$(rep 'abcdefghi ' 5000)"
  run_hook_within 5 pre-bash-no-bypass "git status; echo $pad"
  [ "$status" -eq 0 ] || { echo "status $status (142 = killed by the 5 s alarm)" >&2; false; }
}

@test "no-bypass: tokenizer is correct across its 2048-byte window boundary" {
  # The tokenizer reads through a sliding window; a quote, an escape or && landing on
  # the refill point must not change the result.
  for len in 2036 2040 2043 2044 2045 2046 2047 2048 2049 2052; do
    pad="$(rep a "$len")"
    expect_block "git commit -m x$pad --no-verify" || { echo "len $len: bare flag after padding" >&2; false; }
    expect_pass "git commit -m \"$pad --no-verify\"" || { echo "len $len: quoted mention" >&2; false; }
    expect_block "echo $pad && git commit --no-verify -m x" || { echo "len $len: && at boundary" >&2; false; }
    expect_block "echo \"$pad\" && git push -f" || { echo "len $len: close quote at boundary" >&2; false; }
  done
}

@test "no-bypass: a command over GRID_GUARD_MAX_CMD that mentions git exits 2 with the file hint" {
  pad="$(rep 'abcdefghi ' 200)"
  GRID_GUARD_MAX_CMD=1000 run_hook pre-bash-no-bypass "$(hook_payload "git status; echo $pad")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"too long to inspect"* ]] || false
  [[ "$output" == *"Write tool"* ]] || false
  # the same size without git is not our business
  GRID_GUARD_MAX_CMD=1000 run_hook pre-bash-no-bypass "$(hook_payload "echo $pad")"
  [ "$status" -eq 0 ]
}

# --- WP-020: quoting, escaping and abbreviating a flag must not hide it from the guard.
# The shell removes the quotes, so git sees the flag; the guard must too.

@test "no-bypass: quoted and escaped flag forms are blocked" {
  rows=(
    'git commit "--no-verify" -m x'
    "git commit '-n' -m x"
    'git commit \--no-verify'
    'git commit --no-ver""ify'
    "git commit \$'--no-verify' -m x"
    'git commit -m x "-n"'
    'git push "--force"'
    "git push origin '+HEAD:main'"
  )
  for row in "${rows[@]}"; do expect_block "$row"; done
}

@test "no-bypass: unique long-option prefixes are blocked (--no-verify from 7 chars, --mirror from 5)" {
  rows=(
    'git commit --no-verif -m x'
    'git commit --no-veri -m x'
    'git commit --no-ve -m x'
    'git push --mirr'
    'git push --mirro'
    "git config alias.ci \"commit --no-verif\""
    "git config alias.ci 'commit \"--no-verify\"'"
  )
  for row in "${rows[@]}"; do expect_block "$row"; done
}

@test "no-bypass: the fast path cannot be skipped by quoting or escaping inside a keyword" {
  rows=(
    'g""it commit --no-verify'
    'g\it commit --no-verify'
    '"g"it push -f'
    "git comm\\it -n -m x"
  )
  for row in "${rows[@]}"; do expect_block "$row"; done
}

@test "no-bypass: --config-env with core.hooksPath is a hook-disabling override" {
  expect_block 'git --config-env=core.hooksPath=VAR commit -m x'
  expect_block 'git --config-env core.hooksPath=VAR commit -m x'
  expect_pass 'git --config-env=user.name=VAR commit -m x'
}

@test "no-bypass: look-alikes that are not the flag still pass" {
  rows=(
    'git commit -m "fix --no-verify"'
    "git commit -m '--no-verify'"
    'git commit -m x -m "--no-verify"'
    'git commit --message "-n" --allow-empty'
    'git commit --author "A -n" -m x'
    'git push --force-with-lease'
    'git log --oneline'
    'git commit --no-verbose-thing-not-a-prefix'
    'git commit --no-ed'
    'git push --mirrored-not-a-prefix-of-it origin'
  )
  for row in "${rows[@]}"; do expect_pass "$row"; done
}

# --- WP-021: a git call is a git call wherever shell syntax puts it.

@test "no-bypass: compound keywords, subshells, wrappers and redirections do not hide a git call" {
  rows=(
    'if true; then git commit -n; fi'
    'for i in 1; do git commit -n; done'
    'while read x; do git push -f; done'
    '(git commit -n)'
    '{ git commit -n; }'
    '! git commit -n'
    'timeout 5 git commit -n'
    'nohup git commit -n'
    'setsid git commit -n'
    'env -u X git commit -n'
    'find . -exec git commit -n {} \;'
    '>/dev/null git commit -n'
    "dash -c 'git commit -n'"
    "timeout 5 bash -c 'git commit -n'"
    'env -S "git commit -n"'
    'sudo -u git git push -f'
    'echo $(git commit -n)'
    'f() { git push -f; }; f'
  )
  for row in "${rows[@]}"; do expect_block "$row"; done
}

@test "no-bypass: git in any letter case is still git" {
  expect_block 'GIT commit --no-verify'
  expect_block 'Git commit -n'
  expect_block '/usr/bin/GIT push -f'
}

@test "no-bypass: hook-disabling routes the guard now models are blocked" {
  rows=(
    'GIT_CONFIG_GLOBAL=f git commit -m x'
    'GIT_CONFIG_SYSTEM=f git commit -m x'
    'GIT_DIR=/tmp/x git commit -m x'
    'GIT_EXEC_PATH=/tmp/x git commit -m x'
    'git config --unset core.hooksPath'
    'git config --unset-all core.hooksPath'
    'git config set core.hooksPath /dev/null'
    'git config core.HooksPath x'
    'git config unset core.hooksPath'
    'printf x >> .git/config'
    'echo y > .git/hooks/pre-commit'
    'rm .git/hooks/pre-commit'
    'mv .git/hooks/pre-commit /tmp/x'
    'chmod -x .git/hooks/pre-commit'
    'sed -i s/a/b/ .git/config'
    'tee .githooks/pre-commit < /dev/null'
    'truncate -s 0 .git/hooks/pre-push'
    'HUSKY_SKIP_HOOKS=1 git commit -m x'
    'LEFTHOOK=0 git commit -m x'
    'LEFTHOOK_EXCLUDE=lint git commit -m x'
    'PRE_COMMIT_ALLOW_NO_CONFIG=1 git commit -m x'
  )
  for row in "${rows[@]}"; do expect_block "$row"; done
}

@test "no-bypass: ordinary commands near those forms still pass" {
  rows=(
    'git commit # -n'
    'git commit -m x'
    'git commit -m "$(cat <<'"'"'EOF'"'"'
fix: do not use --no-verify
EOF
)"'
    'SKIP=eslint git commit -m x'
    'git config --get core.hooksPath'
    'cat .git/config'
    'ls .git/hooks 2>&1'
    'git add .githooks/pre-commit'
    'echo hello # git push -f'
    'echo $((1 + 2))'
    'git log --oneline | head -3'
  )
  for row in "${rows[@]}"; do expect_pass "$row"; done
}

@test "no-bypass: known by-design false blocks are pinned" {
  # D37: HUSKY=0 on a non-git command and a hooksPath write are blocked on purpose.
  expect_block 'HUSKY=0 npm ci'
  expect_block 'git config core.hooksPath .githooks'
  # the catch-all treats any word that is git as a git call
  expect_block 'echo git commit -n'
}

@test "secret: both guards see a git call inside compound and wrapper forms" {
  mkrepo
  stage_line "key = \"$(tok_ghp)\""
  for row in 'if true; then git commit -m x; fi' '(git commit -m x)' 'timeout 5 git commit -m x' \
             '>/dev/null git commit -m x' 'GIT commit -m x' 'dash -c "git commit -m x"'; do
    scan "$row"
    [ "$status" -eq 2 ] || { echo "expected BLOCK for: $row: $output" >&2; false; }
  done
}

@test "no-bypass: only the word that is an option's value is skipped" {
  # an attached value (-mc) is not a separate word, so the next word is still checked
  expect_block 'git commit -mc --no-verify'
  expect_block 'git commit -am x --no-verify'
  expect_block 'git commit -m x --no-verify -m "second"'
  expect_block 'git commit -m "a" -m "b" -n'
  # the value after -m / -nm / -am / --message is skipped, the flag next to it is not
  expect_pass 'git commit -am "use --no-verify never"'
  expect_pass 'git commit --message "-n" -m "git push -f"'
  expect_block 'git commit -nm "msg"'
}

@test "no-bypass: a flag-looking value of an option that is not listed is a known false block" {
  # D37: quoted-flag false positives are accepted and documented, not special-cased.
  expect_block 'git log --grep "--no-verify"'
}

@test "secret: the fast path cannot be skipped by quoting or escaping inside a keyword" {
  mkrepo
  stage_line "key = \"$(tok_ghp)\""
  scan 'git comm""it -m x'
  [ "$status" -eq 2 ] || { echo "comm\"\"it: $output" >&2; false; }
  scan 'git comm\it -m x'
  [ "$status" -eq 2 ] || { echo "comm\\it: $output" >&2; false; }
  scan 'git "commit" -m x'
  [ "$status" -eq 2 ] || { echo "\"commit\": $output" >&2; false; }
  scan 'git ad""d .env'
  [ "$status" -eq 2 ] || { echo "ad\"\"d .env: $output" >&2; false; }
  [[ "$output" == *"sensitive-file"* ]] || false
}

# --- the bypass-form table (SEC5): one @test per row so a regression names its form.
# B rows must exit 2, P rows must exit 0.

@test "bypass B01: bash -c wrapper"            { expect_block "bash -c 'git commit --no-verify -m x'"; }
@test "bypass B02: sh -c wrapper, force push"  { expect_block 'sh -c "git push --force"'; }
@test "bypass B03: zsh -lc cluster"            { expect_block "zsh -lc 'git commit -nm x'"; }
@test "bypass B04: eval"                       { expect_block 'eval "git commit --no-verify -m x"'; }
@test "bypass B05: exec"                       { expect_block 'exec git commit --no-verify -m x'; }
@test "bypass B06: env with assignment"        { expect_block 'env FOO=1 git commit --no-verify -m x'; }
@test "bypass B07: command"                    { expect_block 'command git push -f'; }
@test "bypass B08: xargs after a pipe"         { expect_block 'echo m | xargs git commit --no-verify -m x'; }
@test "bypass B09: nice -n 5"                  { expect_block 'nice -n 5 git push --force'; }
@test "bypass B10: time"                       { expect_block 'time git commit --no-verify -m x'; }
@test "bypass B11: sudo -u root"               { expect_block 'sudo -u root git push --force'; }
@test "bypass B12: backslash-escaped git"      { expect_block '\git commit --no-verify -m x'; }
@test "bypass B13: absolute path to git"       { expect_block '/usr/bin/git push -f'; }
@test "bypass B14: config core.hooksPath"      { expect_block 'git config core.hooksPath /dev/null'; }
@test "bypass B15: config --global core.hooksPath" { expect_block 'git config --global core.hooksPath .nohooks'; }
@test "bypass B16: config alias with --no-verify" { expect_block 'git config alias.ci "commit --no-verify"'; }
@test "bypass B17: config alias with -n"       { expect_block "git config alias.c 'commit -n'"; }
@test "bypass B18: GIT_CONFIG_COUNT assignments" {
  expect_block 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
}
@test "bypass B19: GIT_CONFIG_PARAMETERS quoted value" {
  expect_block "GIT_CONFIG_PARAMETERS=\"'core.hooksPath=/dev/null'\" git commit -m x"
}
@test "bypass B20: HUSKY=0 prefix"             { expect_block 'HUSKY=0 git commit -m x'; }
@test "bypass B21: export HUSKY=0"             { expect_block 'export HUSKY=0'; }
@test "bypass P01: bash -c harmless"           { expect_pass "bash -c 'git status'"; }
@test "bypass P02: bash -c quoted force text"  { expect_pass "bash -c 'echo \"git push --force\"'"; }
@test "bypass P03: env harmless commit"        { expect_pass 'env FOO=1 git commit -m x'; }
@test "bypass P04: sudo ls"                    { expect_pass 'sudo ls'; }
@test "bypass P05: time harmless push"         { expect_pass 'time git push origin next'; }
@test "bypass P06: config alias harmless"      { expect_pass 'git config alias.st status'; }
@test "bypass P07: HUSKY=1"                    { expect_pass 'HUSKY=1 git commit -m x'; }

# ===========================================================================
# pre-bash-secret-scan: scenarios from specs/git-guard-hooks/spec.md
# ===========================================================================

# One must-flag test per pattern name. flag_case <pattern-name> <added line> <full token>
flag_case() {
  mkrepo
  stage_line "$2"
  scan 'git commit -m x'
  [ "$status" -eq 2 ] || { echo "$output" >&2; false; }
  [[ "$output" == *"$1"* ]] || { echo "pattern name $1 missing: $output" >&2; false; }
  # the message shows file and line, never the pragma, never the whole value
  [[ "$output" == *"f.txt:1:"* ]] || false
  [[ "$output" != *"allow-secret"* ]] || false
  if [ -n "${3:-}" ]; then [[ "$output" != *"$3"* ]] || false; fi
}

@test "secret: aws-access-key (AKIA) is detected" { t="$(tok_aws)";       flag_case aws-access-key "KEY=\"$t\"" "$t"; }
@test "secret: aws-access-key (ASIA) is detected" { t="$(tok_asia)";      flag_case aws-access-key "KEY=\"$t\"" "$t"; }
@test "secret: private-key is detected"           { t="$(tok_pem)";       flag_case private-key "$t" "$t"; }
@test "secret: github-token is detected"          { t="$(tok_ghp)";       flag_case github-token "KEY=\"$t\"" "$t"; }
@test "secret: github-pat is detected"            { t="$(tok_ghpat)";     flag_case github-pat "KEY=\"$t\"" "$t"; }
@test "secret: gitlab-pat is detected"            { t="$(tok_glpat)";     flag_case gitlab-pat "KEY=\"$t\"" "$t"; }
@test "secret: npm-token is detected"             { t="$(tok_npm)";       flag_case npm-token "KEY=\"$t\"" "$t"; }
@test "secret: stripe-live is detected"           { t="$(tok_stripe)";    flag_case stripe-live "KEY=\"$t\"" "$t"; }
@test "secret: anthropic-key is detected"         { t="$(tok_anthropic)"; flag_case anthropic-key "KEY=\"$t\"" "$t"; }
@test "secret: generic-sk is detected"            { t="$(tok_sk)";        flag_case generic-sk "KEY=\"$t\"" "$t"; }
@test "secret: slack-token is detected"           { t="$(tok_slack)";     flag_case slack-token "KEY=\"$t\"" "$t"; }
@test "secret: google-api-key is detected"        { t="$(tok_google)";    flag_case google-api-key "KEY=\"$t\"" "$t"; }
@test "secret: jwt is detected"                   { t="$(tok_jwt)";       flag_case jwt "KEY=\"$t\"" "$t"; }
@test "secret: assigned-secret (quoted, spaced) is detected" {
  flag_case assigned-secret 'password = "Zx9fQ2mK7vB4nL8pR3tY"' 'Zx9fQ2mK7vB4nL8pR3tY'
}
@test "secret: Unquoted assignment detected" {
  flag_case assigned-secret 'API_KEY=Zx9fQ2mK7vB4nL8pR3tY' 'Zx9fQ2mK7vB4nL8pR3tY'
}
@test "secret: assigned-secret (colon form) is detected" {
  flag_case assigned-secret 'passwd: Zx9fQ2mK7vB4nL8pR3tY' 'Zx9fQ2mK7vB4nL8pR3tY'
}

@test "secret: Staged AWS key blocked, stderr names file, line and pattern but not the key" {
  mkrepo
  t="$(tok_aws)"
  stage_line "key = \"$t\""
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"f.txt:1: aws-access-key"* ]] || false
  [[ "$output" != *"$t"* ]] || false
  [[ "$output" == *"GRID_DISABLED_HOOKS=pre-bash-secret-scan"* ]] || false
}

@test "secret: Block message hides the pragma" {
  mkrepo
  stage_line "key = \"$(tok_ghp)\""
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" != *"allow-secret"* ]] || false
  [[ "$output" != *"pragma"* ]] || false
}

@test "secret: Line number is correct after an earlier hunk" {
  mkrepo
  # 50 clean lines committed, then line 5 edited (hunk 1) and a secret added on line 40 (hunk 2)
  for i in $(seq 1 50); do echo "line $i"; done > "$R/big.txt"
  git -C "$R" add big.txt
  git -C "$R" commit -q -m big
  { for i in $(seq 1 50); do
      if [ "$i" = 5 ]; then echo "edited five"
      elif [ "$i" = 40 ]; then echo "key = \"$(tok_ghp)\""
      else echo "line $i"; fi
    done; } > "$R/big.txt"
  git -C "$R" add big.txt
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"big.txt:40:"* ]] || { echo "$output" >&2; false; }
}

@test "secret: Commit with -a scans unstaged tracked changes" {
  mkrepo
  printf 'key = "%s"\n' "$(tok_ghp)" >> "$R/base.txt"        # tracked, NOT staged
  scan 'git commit -am x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"base.txt:2:"* ]] || false
}

@test "secret: a plain commit does not scan unstaged changes" {
  mkrepo
  printf 'key = "%s"\n' "$(tok_ghp)" >> "$R/base.txt"
  scan 'git commit -m x'
  [ "$status" -eq 0 ]
}

@test "secret: Pathspec commit scans the working tree" {
  mkrepo
  echo one > "$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m f
  printf 'key = "%s"\n' "$(tok_ghp)" >> "$R/f.txt"            # unstaged
  scan 'git commit -m x f.txt'
  [ "$status" -eq 2 ]
  [[ "$output" == *"f.txt:2:"* ]] || false
  scan 'git commit -o -m x f.txt'
  [ "$status" -eq 2 ]
  scan 'git commit -m x -- f.txt'
  [ "$status" -eq 2 ]
}

@test "secret: a pathspec commit in a repo with no HEAD yet uses the empty tree" {
  R="$MOCK_HOOK_ROOT/fresh"
  rm -rf "$R"; mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  # staged content is clean; the secret exists only in the working tree
  echo clean > "$R/f.txt"
  git -C "$R" add f.txt
  printf 'key = "%s"\n' "$(tok_ghp)" > "$R/f.txt"
  git -C "$R" rev-parse --verify -q HEAD && false   # really no HEAD yet
  scan 'git commit -m x f.txt'
  [ "$status" -eq 2 ]
}

@test "secret: an untracked file is not scanned" {
  mkrepo
  printf 'key = "%s"\n' "$(tok_ghp)" > "$R/untracked.txt"
  scan 'git commit -m x'
  [ "$status" -eq 0 ]
}

@test "secret: Removed secret lines are ignored" {
  mkrepo
  printf 'key = "%s"\n' "$(tok_ghp)" > "$R/old.txt"
  git -C "$R" add old.txt && git -C "$R" commit -q -m old
  git -C "$R" rm -q old.txt          # staged diff only DELETES the secret line
  scan 'git commit -m x'
  [ "$status" -eq 0 ]
}

@test "secret: Clean commit passes" {
  mkrepo
  stage_line 'just an ordinary line of text'
  scan 'git commit -m x'
  [ "$status" -eq 0 ]
}

@test "secret: Look-alikes and placeholders pass (every must-pass row)" {
  mkrepo
  rows=(
    "AKIAIOSFODNN7EXAMPLE"
    "token = \"gh""p_$(rep x 36)\""
    'password = "changeme-changeme-changeme"'
    'api_key: "${API_KEY_FROM_ENVIRONMENT}"'
    'token = "<paste-your-token-here-please>"'
    'secret: "{{ vault_secret_value_here }}"'
    'password = os.environ["APP_PASSWORD"]'
    "x = \"task-$(rep abcd 10)\""
    "sha512-$(rep Ab3d 22)"
    "$(rep 0123456789abcdef 2)01234567"
    "id: 123e4567-e89b-12d3-a456-426614174000"
    "key = \"$(tok_ghp)\" # grid:allow-secret"
  )
  for row in "${rows[@]}"; do
    stage_line "$row"
    scan 'git commit -m x'
    if [ "$status" -ne 0 ]; then echo "expected PASS for row: $row" >&2; echo "$output" >&2; false; fi
  done
}

@test "secret: Pragma allows a known false positive on its own line only" {
  mkrepo
  printf '%s\n%s\n' "key = \"$(tok_ghp)\" # grid:allow-secret" "other = \"$(tok_ghp)\"" > "$R/f.txt"
  git -C "$R" add f.txt
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"f.txt:2:"* ]] || false
  [[ "$output" != *"f.txt:1:"* ]] || false
}

@test "secret: Sensitive files blocked on add" {
  mkrepo
  mkdir -p "$R/config"
  for name in .env config/.env.local server.pem id_ed25519; do
    scan "git add $name"
    if [ "$status" -ne 2 ]; then echo "expected BLOCK for git add $name: $output" >&2; false; fi
    [[ "$output" == *"sensitive-file"* ]] || false
  done
  for name in .env.example id_mapping.py; do
    scan "git add $name"
    if [ "$status" -ne 0 ]; then echo "expected PASS for git add $name: $output" >&2; false; fi
  done
}

@test "secret: a commit with .env already staged is blocked naming sensitive-file" {
  mkrepo
  echo 'A=1' > "$R/.env"
  git -C "$R" add -f .env
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" == *".env: sensitive-file"* ]] || false
}

@test "secret: Superset of the audit's secret prefixes" {
  . "$REPO_ROOT/hooks/lib/secret-patterns.sh"
  # the secret-shape rule's regex line in the real policy.yaml
  rx="$(awk '/id: secret-shape/{f=1} f && /regex:/{print; exit}' "$REPO_ROOT/policy.yaml")"
  [ -n "$rx" ]
  for lit in AKIA ghp_ github_pat_ sk- xox AIza 'PRIVATE KEY' eyJ; do
    [[ "$rx" == *"$lit"* ]] || { echo "policy.yaml secret-shape lost prefix: $lit" >&2; false; }
  done
  # a token built with each prefix is flagged by the hook's own matcher
  samples=(
    "k=$(tok_aws)" "k=$(tok_ghp)" "k=$(tok_ghpat)" "k=$(tok_sk)" "k=$(tok_slack)"
    "k=$(tok_google)" "$(tok_pem)" "k=$(tok_jwt)"
  )
  for s in "${samples[@]}"; do
    secret_match_line "$s" > /dev/null || { echo "not flagged: ${s:0:6}..." >&2; false; }
  done
}

@test "secret: Non-commit commands are skipped fast (no git diff call)" {
  mkrepo
  stubdir="$MOCK_HOOK_ROOT/stub"; mkdir -p "$stubdir"
  real_git="$(command -v git)"
  # a git stub that records its arguments, then runs the real git
  cat > "$stubdir/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$stubdir/git.log"
exec "$real_git" "\$@"
STUB
  chmod +x "$stubdir/git"
  PATH="$stubdir:$PATH" run_hook pre-bash-secret-scan "$(hook_payload 'git status' "$R")"
  [ "$status" -eq 0 ]
  ! grep -q 'diff' "$stubdir/git.log" 2>/dev/null || false
  # positive control: a commit DOES go through the stub and run a diff
  PATH="$stubdir:$PATH" run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x' "$R")"
  grep -q 'diff' "$stubdir/git.log"
}

@test "secret: Outside a repository exits 0" {
  nr="$MOCK_HOOK_ROOT/notarepo"; mkdir -p "$nr"
  run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x' "$nr")"
  [ "$status" -eq 0 ]
}

@test "secret: Malformed input and non-Bash tools do not block" {
  run bash -c 'printf "%s" "not json" | bash "$1/hooks/run.sh" pre-bash-secret-scan 2>&1' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  mkrepo
  stage_line "key = \"$(tok_ghp)\""
  payload="$(hook_payload 'git commit -m x' "$R" | jq '.tool_name = "Read"')"
  run_hook pre-bash-secret-scan "$payload"
  [ "$status" -eq 0 ]
}

@test "secret: jq missing fails closed and names jq" {
  PATH="$NOJQ_DIR" run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"jq"* ]] || false
  [[ "$output" == *"GRID_HOOKS=off"* ]] || false
  [[ "$output" == *"install"* ]] || false
  [[ "$output" == *"every Bash call"* ]] || false
}

# --- WP-019: the scan must finish inside the 5 s hook timeout on a large diff, because a
# timed-out hook does not block (the commit would go through unscanned).

# The tests use 10,000 lines rather than the 6,000 the audit measured: the old
# per-line scan took 4.6 s for 6,000 lines on a fast box, which would not fail reliably.
# big_file <lines> <secret-line-number|0>: write $R/big.txt of filler lines, with one
# secret on the given line (0 = none), and stage it.
big_file() {
  local n="$1" at="$2" i
  { for ((i = 1; i <= n; i++)); do
      if [ "$i" = "$at" ]; then echo "key = \"$(tok_ghp)\""; else echo "filler line number $i of the big file"; fi
    done; } > "$R/big.txt"
  git -C "$R" add big.txt
}

@test "secret: staged 10,000-line file with a secret exits 2 within 5 s" {
  mkrepo
  big_file 10000 10000
  run_hook_within 5 pre-bash-secret-scan 'git commit -m x' "$R"
  [ "$status" -eq 2 ] || { echo "status $status (142 = killed by the 5 s alarm)" >&2; false; }
  [[ "$output" == *"big.txt:10000: github-token"* ]] || { echo "$output" >&2; false; }
}

@test "secret: a large clean (10,000-line) staged file passes within 5 s" {
  mkrepo
  big_file 10000 0
  run_hook_within 5 pre-bash-secret-scan 'git commit -m x' "$R"
  [ "$status" -eq 0 ] || { echo "status $status (142 = killed by the 5 s alarm)" >&2; echo "$output" >&2; false; }
}

@test "secret: a staged .env plus a large diff reports the .env" {
  mkrepo
  echo 'A=1' > "$R/.env"
  git -C "$R" add -f .env
  # every line of the big file is a finding, so the 10-finding list would fill up
  # before the .env if the (cheap) name check ran after the diff scan
  t="$(tok_ghp)"
  { for ((i = 1; i <= 10000; i++)); do echo "k$i = \"$t\""; done; } > "$R/big.txt"
  git -C "$R" add big.txt
  run_hook_within 5 pre-bash-secret-scan 'git commit -m x' "$R"
  [ "$status" -eq 2 ] || { echo "status $status (142 = killed by the 5 s alarm)" >&2; false; }
  [[ "$output" == *".env: sensitive-file"* ]] || { echo "$output" >&2; false; }
}

@test "secret: an over-cap diff exits 2 with the split message" {
  mkrepo
  # exempt (documentation) keys: they pass the prefilter, so each costs a loop turn
  { for ((i = 1; i <= 30; i++)); do echo "k$i = AKIAIOSFODNN7EXAMPLE"; done; } > "$R/many.txt"
  git -C "$R" add many.txt
  GRID_SCAN_MAX_LINES=20 run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x' "$R")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"diff too large to scan"* ]] || false
  [[ "$output" == *"split the commit"* ]] || false
  # at or under the cap it passes
  GRID_SCAN_MAX_LINES=30 run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x' "$R")"
  [ "$status" -eq 0 ]
}

@test "secret: a commit command over GRID_GUARD_MAX_CMD exits 2 with the file hint" {
  mkrepo
  pad="$(rep 'abcdefghi ' 200)"
  GRID_GUARD_MAX_CMD=1000 run_hook pre-bash-secret-scan "$(hook_payload "git commit -m \"$pad\"" "$R")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"too long to inspect"* ]] || false
  # over the cap but no git: not the scan's business
  GRID_GUARD_MAX_CMD=1000 run_hook pre-bash-secret-scan "$(hook_payload "echo commit $pad" "$R")"
  [ "$status" -eq 0 ]
}

@test "secret: at most 10 findings are listed" {
  mkrepo
  for i in $(seq 1 15); do echo "k$i = \"$(tok_ghp)\""; done > "$R/many.txt"
  git -C "$R" add many.txt
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  n="$(printf '%s\n' "$output" | grep -c 'many.txt:')"
  [ "$n" -eq 10 ]
}

# --- WP-022: the scan covers what the command will really commit.

@test "secret: a chained add then commit scans what the add would stage" {
  mkrepo
  echo "key = \"$(tok_ghp)\"" > "$R/leak.txt"            # untracked, the add would stage it
  echo "k=1" > "$R/tracked.txt"; git -C "$R" add tracked.txt; git -C "$R" commit -q -m t
  rows=(
    'git add -A && git commit -m x'
    'git add . && git commit -m x'
    'git add leak.txt && git commit -m x'
    'git add -A; git commit -m x'
    'git stage . && git commit -m x'
    'git add --all && git commit -m x'
  )
  for row in "${rows[@]}"; do
    scan "$row"
    [ "$status" -eq 2 ] || { echo "expected BLOCK for: $row: $output" >&2; false; }
    [[ "$output" == *"leak.txt:1: github-token"* ]] || { echo "no finding for: $row: $output" >&2; false; }
  done
  # same-command writes cannot be seen on disk yet: the command text itself is scanned
  scan "echo 'k=\"$(tok_ghp)\"' >> tracked.txt && git commit -am x"
  [ "$status" -eq 2 ] || { echo "$output" >&2; false; }
}

@test "secret: a chained add of a sensitive name is blocked, an unrelated add is not" {
  mkrepo
  echo 'A=1' > "$R/.env"
  scan 'git add -A && git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" == *".env: sensitive-file"* ]] || false
  # only the named pathspec is looked at: the .env is outside it
  echo ok > "$R/fine.txt"
  scan 'git add fine.txt && git commit -m x'
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "secret: an oversize chained add exits 2 with the split message" {
  mkrepo
  for i in 1 2 3 4 5; do echo "file $i" > "$R/f$i.txt"; done
  GRID_SCAN_MAX_FILES=3 run_hook pre-bash-secret-scan "$(hook_payload 'git add -A && git commit -m x' "$R")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stage in a separate call"* ]] || false
  rep 'x' 400 > "$R/big.txt"
  GRID_SCAN_MAX_BYTES=100 run_hook pre-bash-secret-scan "$(hook_payload 'git add -A && git commit -m x' "$R")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stage in a separate call"* ]] || false
}

@test "secret: the repo the command targets is scanned, not the payload cwd" {
  A="$MOCK_HOOK_ROOT/repoA"; B="$MOCK_HOOK_ROOT/repoB"
  mkrepo "$A"; stage_line "key = \"$(tok_ghp)\""        # secret staged in A
  mkrepo "$B"                                           # B (the cwd) is clean
  rows=(
    "git -C $A commit -m x"
    "cd $A && git commit -m x"
    "git --git-dir=$A/.git commit -m x"
    "git --git-dir $A/.git commit -m x"
    "git -C $A -c core.editor=true commit -m x"
  )
  for row in "${rows[@]}"; do
    run_hook pre-bash-secret-scan "$(hook_payload "$row" "$B")"
    [ "$status" -eq 2 ] || { echo "expected BLOCK for: $row: $output" >&2; false; }
  done
  # a clean target passes even when the payload cwd has the secret
  run_hook pre-bash-secret-scan "$(hook_payload "git -C $B commit -m x" "$A")"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  # a relative -C resolves against the payload cwd
  run_hook pre-bash-secret-scan "$(hook_payload "git -C ../repoA commit -m x" "$B")"
  [ "$status" -eq 2 ]
  # a target the hook cannot resolve ($VAR, or a path that is not there) falls back to the
  # payload cwd's repository instead of making the commit invisible
  run_hook pre-bash-secret-scan "$(hook_payload 'git -C $NOPE commit -m x' "$A")"
  [ "$status" -eq 2 ] || { echo "$output" >&2; false; }
  run_hook pre-bash-secret-scan "$(hook_payload 'cd $NOPE && git commit -m x' "$A")"
  [ "$status" -eq 2 ] || { echo "$output" >&2; false; }
}

@test "secret: commit-creating subcommands, aliases and pathspec files are covered" {
  mkrepo
  stage_line "key = \"$(tok_ghp)\""
  for row in 'git merge topic' 'git cherry-pick -n abc' 'git revert -n HEAD' 'git am p.mbox' 'git rebase main' 'git commit-tree HEAD^{tree}'; do
    scan "$row"
    [ "$status" -eq 2 ] || { echo "expected BLOCK for: $row: $output" >&2; false; }
  done
  git -C "$R" config alias.ci commit
  scan 'git ci -m x'
  [ "$status" -eq 2 ] || { echo "alias: $output" >&2; false; }
  # an unrelated alias is not a commit
  git -C "$R" config alias.st status
  scan 'git st'
  [ "$status" -eq 0 ]
  # --pathspec-from-file, -p and --interactive take the working tree like -a does
  git -C "$R" reset -q
  printf 'key = "%s"\n' "$(tok_ghp)" >> "$R/base.txt"
  scan 'git commit --pathspec-from-file=list -m x'
  [ "$status" -eq 2 ] || { echo "pathspec-from-file: $output" >&2; false; }
  scan 'git commit -p -m x'
  [ "$status" -eq 2 ] || { echo "-p: $output" >&2; false; }
  scan 'git commit --interactive -m x'
  [ "$status" -eq 2 ] || { echo "--interactive: $output" >&2; false; }
}

@test "secret: files git treats as binary or non-diffable are still scanned" {
  mkrepo
  line="key = \"$(tok_ghp)\""
  # attribute -diff
  printf '*.dat -diff\n' > "$R/.gitattributes"
  printf '%s\n' "$line" > "$R/a.dat"
  git -C "$R" add .gitattributes a.dat
  scan 'git commit -m x'
  [ "$status" -eq 2 ] || { echo "-diff: $output" >&2; false; }
  [[ "$output" == *"a.dat:1:"* ]] || false
  git -C "$R" reset -q
  # UTF-16 (a NUL between characters)
  printf '%s\n' "$line" | perl -pe 's/(.)/$1\0/gs' > "$R/u16.txt"
  git -C "$R" add u16.txt
  scan 'git commit -m x'
  [ "$status" -eq 2 ] || { echo "utf-16: $output" >&2; false; }
  git -C "$R" reset -q
  # a NUL byte anywhere makes git call the file binary
  { printf '%s\n' "$line"; printf '\0'; } > "$R/nul.bin"
  git -C "$R" add nul.bin
  scan 'git commit -m x'
  [ "$status" -eq 2 ] || { echo "nul: $output" >&2; false; }
}

@test "secret: a secret in the commit message is blocked" {
  mkrepo
  stage_line 'harmless line'
  scan "git commit -m 'token=$(tok_aws)'"
  [ "$status" -eq 2 ] || { echo "$output" >&2; false; }
  [[ "$output" == *"aws-access-key"* ]] || false
  [[ "$output" != *"$(tok_aws)"* ]] || false
  scan "git commit --message='token=$(tok_aws)'"
  [ "$status" -eq 2 ]
  scan "git commit -am 'token=$(tok_aws)'"
  [ "$status" -eq 2 ]
  scan "git commit -m 'a plain message'"
  [ "$status" -eq 0 ]
}

@test "secret: more sensitive file names are blocked on add and in a commit" {
  mkrepo
  for name in .envrc credentials.json .npmrc server.key key.pfx .ENV sub.env cert.p12 store.keystore .netrc terraform.tfstate id_rsa_work; do
    scan "git add $name"
    [ "$status" -eq 2 ] || { echo "expected BLOCK for git add $name: $output" >&2; false; }
    [[ "$output" == *"sensitive-file"* ]] || false
  done
  for name in .env.example id_rsa.pub notes.txt keys.md; do
    scan "git add $name"
    [ "$status" -eq 0 ] || { echo "expected PASS for git add $name: $output" >&2; false; }
  done
}

@test "secret: file names in the block message are single-line and at most 100 characters" {
  mkrepo
  nl=$'evil\nINJECTED-LINE.env'
  printf 'x' > "$R/$nl"
  git -C "$R" add -f -- "$nl"
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" == *"evil?INJECTED-LINE.env: sensitive-file"* ]] || { echo "$output" >&2; false; }
  [[ "$output" != *$'\nINJECTED-LINE'* ]] || false
  git -C "$R" reset -q
  long="$(rep a 150).env"
  printf 'x' > "$R/$long"
  git -C "$R" add -f -- "$long"
  scan 'git commit -m x'
  [ "$status" -eq 2 ]
  [[ "$output" != *"$(rep a 101)"* ]] || { echo "$output" >&2; false; }
}

# --- secret_scan_file and secret_sensitive_name (the shared library API)

@test "secret_scan_file prints path:line: name (4 chars...) and returns 1; clean file returns 0" {
  . "$REPO_ROOT/hooks/lib/secret-patterns.sh"
  printf 'clean\nkey = "%s"\n' "$(tok_ghp)" > "$MOCK_HOOK_ROOT/h.md"
  run secret_scan_file "$MOCK_HOOK_ROOT/h.md"
  [ "$status" -eq 1 ]
  [[ "$output" == "$MOCK_HOOK_ROOT/h.md:2: github-token (ghp_...)" ]] || { echo "$output" >&2; false; }
  printf 'all clean\n' > "$MOCK_HOOK_ROOT/ok.md"
  run secret_scan_file "$MOCK_HOOK_ROOT/ok.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "secret_sensitive_name: sensitive and ordinary names" {
  . "$REPO_ROOT/hooks/lib/secret-patterns.sh"
  for n in .env .env.local .env.production server.pem id_rsa id_dsa id_ecdsa id_ed25519 id_ed25519_sk; do
    secret_sensitive_name "$n" || { echo "should be sensitive: $n" >&2; false; }
  done
  for n in .env.example id_mapping.py id_rsa.pub envrc README.md; do
    ! secret_sensitive_name "$n" || { echo "should not be sensitive: $n" >&2; false; }
  done
}
