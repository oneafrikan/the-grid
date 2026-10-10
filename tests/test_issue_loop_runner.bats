#!/usr/bin/env bats
# issue-loop headless runner (loop/run-issues.sh). Covers specs/issue-loop-runner/spec.md.
# Offline: stub gh/claude/timeout/mint (tests/helpers/stubs.bash), a temp BARE origin
# reached through an https:// URL rewritten with `insteadOf`, HOME in a temp dir.
# No model call, no network, nothing under the real ~/.claude or ~/.config.

load helpers/stubs

PAT_DIR="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"

setup() {
  [ "$(id -u)" -ne 0 ] || skip "root can list a chmod 000 dir; the isolation preflight cannot be exercised"
  T="$(mktemp -d)"
  T="$(cd "$T" && pwd -P)"
  export HOME="$T/home"
  mkdir -p "$HOME/.config/the-grid"
  export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
  export GRID_RUN_LOG="$T/runs.jsonl"
  export GRID_RUN_RECORD="$BATS_TEST_DIRNAME/../scripts/run-record.sh"
  export GRID_DIR="$T/no-grid"
  export AGENTS_DIR="$T/agents"; mkdir -p "$AGENTS_DIR"
  export LOOP_WORKTREE_ROOT="$T/wts"
  export GRID_LOOP_ENV="$HOME/.config/the-grid/issue-loop.env"
  export GIT_CONFIG_NOSYSTEM=1
  # the runner must not see (and the worker must not inherit) any of these
  export GH_TOKEN=leak-gh GITHUB_TOKEN=leak-github CLAUDE_CODE_OAUTH_TOKEN=leak-oauth
  unset GRID_LOOP_TOKEN_REMINT_SECS GRID_TIMEOUT_BIN
  make_stubs

  # --- origin: a bare repo with a `next` branch, reached via https:// + insteadOf ---
  ORIGIN="$T/origin.git"
  git init -q --bare -b next "$ORIGIN"
  CLONE="$T/clone"
  git init -q -b next "$CLONE"
  git -C "$CLONE" config user.name tester
  git -C "$CLONE" config user.email tester@example.invalid
  git -C "$CLONE" remote add origin "https://example.invalid/owner/name.git"
  git -C "$CLONE" config "url.file://$ORIGIN.insteadOf" "https://example.invalid/owner/name.git"

  # --- the instantiated loop/ folder (what instantiate.sh produces for --mode pr) ---
  mkdir -p "$CLONE/loop"
  cp -R "$PAT_DIR/hooks" "$CLONE/loop/hooks"
  cp "$PAT_DIR/run-issues.sh" "$PAT_DIR/setup.sh" "$PAT_DIR/.gitignore" "$CLONE/loop/"
  chmod +x "$CLONE/loop/run-issues.sh" "$CLONE/loop/setup.sh" "$CLONE"/loop/hooks/*.sh
  fill_conf > "$CLONE/loop/loop.conf"
  awk -v keep=pr '
    /^<!-- MODE:/ { if ($0 == "<!-- MODE:" keep " -->") { inkeep = 1 } else { inskip = 1 } ; next }
    /^<!-- \/MODE -->$/ { inkeep = 0; inskip = 0; next }
    !inskip { print }' "$PAT_DIR/loop-prompt.template.md" \
    | sed -e 's|{{GH_REPO}}|owner/name|g' -e 's|{{PROJECT_CONTEXT}}|a test project|g' \
          -e 's|{{VERIFY_CMD}}|true|g' -e 's|{{ISSUE_LABEL}}|ready-for-agent|g' -e 's|{{BASE_BRANCH}}|next|g' \
    > "$CLONE/loop/loop-prompt.template.md"
  printf '.claude/settings.json\n' > "$CLONE/.gitignore"
  echo "# test repo" > "$CLONE/README.md"
  git -C "$CLONE" add -A
  git -C "$CLONE" commit -q -m "seed"
  git -C "$CLONE" push -q origin next
  # per-checkout agents (the role-routing tests add some) are machine state, not content
  echo ".claude/agents/" >> "$CLONE/.git/info/exclude"
  # machine wiring (gitignored): the PreToolUse guard entry the preflight demands
  bash "$CLONE/loop/setup.sh" > /dev/null

  # --- the loop user's env file, App key, and an operator home it cannot list ---
  KEYF="$HOME/.config/the-grid/app.pem"
  echo "not-a-real-key" > "$KEYF"; chmod 600 "$KEYF"
  OPHOME="$T/operator-home"
  mkdir -p "$OPHOME"; chmod 000 "$OPHOME"
  write_env
}

teardown() {
  [ -n "${OPHOME:-}" ] && chmod 755 "$OPHOME" 2>/dev/null
  clean_stubs
  # worktree dirs can hold read-only git objects
  [ -n "${T:-}" ] && rm -rf "$T"
}

# fill_conf — loop.conf rendered from the shipped template with test values.
fill_conf() {
  sed -e 's|{{GH_REPO}}|owner/name|g' -e 's|{{BASE_BRANCH}}|next|g' -e 's|{{ISSUE_LABEL}}|ready-for-agent|g' \
      -e 's|{{MODE}}|pr|g' -e 's|{{VERIFY_CMD}}|true|g' -e 's|{{SETUP_CMD}}||g' \
      -e 's|{{PROJECT_CONTEXT}}|a\\ test\\ project|g' -e 's|{{REVIEW_FOCUS}}|correctness|g' \
      -e 's|{{MAX_ISSUES}}|3|g' -e 's|{{MAX_TURNS}}|40|g' -e 's|{{ISSUE_TIMEOUT}}|1800|g' \
      -e 's|{{WORKER_MODEL}}|sonnet|g' -e 's|{{REVIEW_MODEL}}|opus|g' \
      "$PAT_DIR/loop.conf.template"
}

write_env() {
  cat > "$GRID_LOOP_ENV" <<EOF
GH_APP_ID=1
GH_APP_INSTALLATION_ID=2
GH_APP_KEY_FILE=$KEYF
LOOP_TRUSTED_ACTORS=trusted
LOOP_OPERATOR_HOME=$OPHOME
EOF
  chmod 600 "$GRID_LOOP_ENV"
}

# runner — run the runner from the clone's parent dir (cwd must not matter).
runner() { run bash "$CLONE/loop/run-issues.sh"; }

# calls <regex> — count lines of the stub log matching the regex.
calls() { grep -c -E -- "$1" "$STUB_LOG" || true; }

# worker_calls / review_calls — `claude -p` lines by kind.
worker_calls() { grep -c -E -- '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" || true; }
review_calls() { grep -c -E -- '^claude -p .*--tools ""' "$STUB_LOG" || true; }

# expect_preflight_exit2 — status 2, no model call, no worktree, no issue touched.
expect_preflight_exit2() {
  [ "$status" -eq 2 ] || { echo "status=$status output=$output"; return 1; }
  [ "$(calls '^claude -p')" -eq 0 ]
  [ ! -d "$LOOP_WORKTREE_ROOT" ]
  [ "$(calls '^gh issue (edit|comment)')" -eq 0 ]
}

# --------------------------------------------------------------- happy path ---

@test "happy path, two issues: capped tokenless workers, runner pushes + PRs + labels + Opus review + records" {
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  contains "$output" "done: 2 ok, 0 skipped, 0 error"

  # workers: model, caps, isolation flags, wrapped by timeout
  [ "$(worker_calls)" -eq 2 ]
  w="$(grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | sed -n 1p)"
  contains "$w" "--model sonnet"
  contains "$w" "--max-budget-usd 5"
  contains "$w" "--strict-mcp-config"
  contains "$w" '--mcp-config {"mcpServers":{}}'
  contains "$w" "--setting-sources project,local"
  contains "$w" "--output-format json"
  lacks "$w" "--agent"
  lacks "$w" "--max-turns"
  [ "$(calls '^timeout -k 30 1800 .*claude -p')" -eq 2 ]

  # the three token variables never reach ANY claude call (workers and reviews), stdin is EOF for workers
  [ "$(wc -l < "$STUB_ENV_LOG" | tr -d ' ')" -eq 4 ]
  [ "$(grep -c 'GH_TOKEN=<unset> GITHUB_TOKEN=<unset> CLAUDE_CODE_OAUTH_TOKEN=<unset>' "$STUB_ENV_LOG")" -eq 4 ]
  [ "$(grep -c "stdin_bytes=0 cwd=$LOOP_WORKTREE_ROOT/issue-" "$STUB_ENV_LOG")" -eq 2 ]

  # the runner, not the agent, pushes: both branches reached origin
  git -C "$ORIGIN" rev-parse --verify refs/heads/issue-7
  git -C "$ORIGIN" rev-parse --verify refs/heads/issue-8
  # two PRs to next, bodies closing the issue, labels swapped, issues never closed
  [ "$(calls '^gh pr create .*--base next --head issue-')" -eq 2 ]
  grep -q -- '--head issue-7 --title Issue 7 (#7)' "$STUB_LOG"
  [ "$(calls '^gh issue edit [78] .*--add-label ready-for-human --remove-label ready-for-agent')" -eq 2 ]
  [ "$(calls 'gh issue close')" -eq 0 ]

  # Opus review: explicit model, spend cap, no tools, no agent; posted as a PR comment
  [ "$(review_calls)" -eq 2 ]
  r="$(grep -E '^claude -p .*--tools ""' "$STUB_LOG" | sed -n 1p)"
  contains "$r" "--model opus"
  contains "$r" "--max-budget-usd 2"
  lacks "$r" "--agent"
  [ "$(calls '^gh pr comment 101')" -eq 2 ]
  [ "$(grep -c 'stdin_bytes=[1-9]' "$STUB_ENV_LOG")" -eq 2 ]

  # every runner gh call carried the minted token (the unauthenticated probe aside)
  [ "$(grep -E '^gh ' "$STUB_LOG" | grep -v '^gh auth status' | grep -vc '::GH_TOKEN=abc$')" -eq 0 ]
  grep -q '^gh auth status ::GH_TOKEN=<unset>$' "$STUB_LOG"

  # run record: two lines, target owner/name#N, summed cost
  [ "$(wc -l < "$GRID_RUN_LOG" | tr -d ' ')" -eq 2 ]
  [ "$(jq -r '.target' "$GRID_RUN_LOG" | sort | tr '\n' ' ')" = "owner/name#7 owner/name#8 " ]
  [ "$(jq -r '.role' "$GRID_RUN_LOG" | sort -u)" = "issue-loop" ]
  [ "$(jq -r '.outcome' "$GRID_RUN_LOG" | sort -u)" = "ok" ]
  [ "$(jq -r '.cost_usd' "$GRID_RUN_LOG" | sort -u)" = "0.03" ]

  # worktrees gone, branches kept, main checkout untouched
  [ ! -d "$LOOP_WORKTREE_ROOT/issue-7" ]
  git -C "$CLONE" rev-parse --verify issue-7
  [ -z "$(git -C "$CLONE" status --porcelain)" ]
  [ ! -d "$CLONE/.git/issue-loop.lock" ]
}

@test "the worker's stdin is /dev/null, not the runner's (an open pipe would hang claude -p)" {
  mkfifo "$T/fifo"
  exec 9<> "$T/fifo"          # held open read+write: a read of it would block, not hit EOF
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  bash "$CLONE/loop/run-issues.sh" < "$T/fifo" > "$T/out.txt" 2>&1 3>&- 9>&- &
  pid=$!
  for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    exec 9>&-
    echo "the runner hung: a child read the runner's stdin"
    false
  fi
  rc=0
  wait "$pid" || rc=$?
  exec 9>&-
  [ "$rc" -eq 0 ]
  [ "$(worker_calls)" -eq 1 ]
}

@test "comment bodies carry the PR url, never the token" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  grep -q 'issue comment 7: PR opened: https://github.com/owner/name/pull/101' "$STUB_COMMENTS"
  refute grep -q 'abc' "$STUB_COMMENTS"
  refute grep -q 'abc' <<< "$output"
}

@test "a pre-push hook planted by the worker never runs (hooks are off for the runner's push)" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_PLANT_PREPUSH="$T/prepush-ran"
  runner
  [ "$status" -eq 0 ]
  git -C "$ORIGIN" rev-parse --verify refs/heads/issue-7
  [ ! -e "$T/prepush-ran" ]
}

@test "label budget raises the worker cap; other issues keep the default" {
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1 LABEL_BUDGETS="ws:rule-packs=15"
  stub_issue 7 "Pack" "write a pack" ready-for-agent ws:rule-packs
  runner
  [ "$status" -eq 0 ]
  grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | sed -n 1p | grep -q -- '--max-budget-usd 15'
  grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | sed -n 2p | grep -q -- '--max-budget-usd 5 '
}

@test "MAX_ISSUES caps the run at the lowest-numbered issues" {
  export STUB_ISSUES="9 7 10 8" STUB_WORKER_COMMIT=1 MAX_ISSUES=2
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 2 ]
  grep -q "cwd=$LOOP_WORKTREE_ROOT/issue-7" "$STUB_ENV_LOG"
  grep -q "cwd=$LOOP_WORKTREE_ROOT/issue-8" "$STUB_ENV_LOG"
  refute grep -q "issue-9" "$STUB_ENV_LOG"
}

@test "no eligible issue: exit 0 and no model call" {
  export STUB_ISSUES=""
  runner
  [ "$status" -eq 0 ]
  contains "$output" "nothing to do"
  [ "$(calls '^claude -p')" -eq 0 ]
}

@test "MODE=direct is refused before anything else: exit 2, no gh, no claude" {
  export STUB_ISSUES="7" MODE=direct
  runner
  [ "$status" -eq 2 ]
  contains "$output" "interactive /loop"
  [ "$(calls '^claude')" -eq 0 ]
  [ "$(calls '^gh ')" -eq 0 ]
}

@test "--max-turns is passed only when claude --help lists it" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_CLAUDE_HELP="  --max-turns <n>  limit turns"
  runner
  [ "$status" -eq 0 ]
  grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | grep -q -- '--max-turns 40'
}

# ------------------------------------------------------- outcomes / failures ---

@test "done without a commit: no push, no PR, no review; blocked with a reason" {
  export STUB_ISSUES="7"
  runner
  [ "$status" -eq 0 ]
  [ "$(calls '^gh pr create')" -eq 0 ]
  [ "$(review_calls)" -eq 0 ]
  refute git -C "$ORIGIN" rev-parse --verify refs/heads/issue-7 2>/dev/null
  grep -q '^gh issue edit 7 .*--add-label blocked --remove-label ready-for-agent' "$STUB_LOG"
  grep -q 'ended without a commit' "$STUB_COMMENTS"
  [ "$(jq -r '.outcome' "$GRID_RUN_LOG")" = "error" ]
}

@test "needs-human line: label, opt-in removed, reason in the comment, no PR" {
  export STUB_ISSUES="7" STUB_OUTCOME="needs-human ambiguous acceptance criteria" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 7 .*--add-label needs-human --remove-label ready-for-agent' "$STUB_LOG"
  grep -q 'ambiguous acceptance criteria' "$STUB_COMMENTS"
  [ "$(calls '^gh pr create')" -eq 0 ]
  [ "$(jq -r '.outcome' "$GRID_RUN_LOG")" = "skipped" ]
}

@test "missing outcome file: blocked, nothing pushed even with a commit" {
  export STUB_ISSUES="7" STUB_NO_OUTCOME=1 STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 7 .*--add-label blocked' "$STUB_LOG"
  refute git -C "$ORIGIN" rev-parse --verify refs/heads/issue-7 2>/dev/null
}

@test "worker timeout (124, then 137): issue blocked, the run moves on to the next issue" {
  export STUB_ISSUES="5 6" STUB_WORKER_COMMIT_6=1 STUB_CLAUDE_EXIT_5=124
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 5 .*--add-label blocked' "$STUB_LOG"
  grep -q 'timeout' "$STUB_COMMENTS"
  git -C "$ORIGIN" rev-parse --verify refs/heads/issue-6
  [ "$(worker_calls)" -eq 2 ]
  # and 137 (SIGKILL after the -k grace) is the same
  : > "$STUB_LOG"
  git -C "$ORIGIN" branch -q -D issue-6
  export STUB_CLAUDE_EXIT_5=137
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 5 .*--add-label blocked' "$STUB_LOG"
  [ "$(worker_calls)" -eq 2 ]
}

@test "a worker exiting 1 is an infrastructure failure: stop at once, exit 1, label kept" {
  export STUB_ISSUES="5 6" STUB_CLAUDE_EXIT=1
  runner
  [ "$status" -eq 1 ]
  contains "$output" "INFRASTRUCTURE FAILURE"
  [ "$(worker_calls)" -eq 1 ]
  [ "$(calls '^gh issue edit')" -eq 0 ]
  [ "$(jq -r '.outcome' "$GRID_RUN_LOG")" = "error" ]
  [ ! -d "$LOOP_WORKTREE_ROOT/issue-5" ]
  [ ! -d "$CLONE/.git/issue-loop.lock" ]
}

@test "error_max_turns JSON: issue blocked, run continues; any other error result stops the run" {
  export STUB_ISSUES="5 6" STUB_WORKER_COMMIT_6=1
  export STUB_CLAUDE_JSON_5='{"type":"result","subtype":"error_max_turns","is_error":true,"total_cost_usd":0.5}'
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 5 .*--add-label blocked' "$STUB_LOG"
  grep -q 'max-turns' "$STUB_COMMENTS"
  [ "$(worker_calls)" -eq 2 ]
  : > "$STUB_LOG"
  git -C "$ORIGIN" branch -q -D issue-6
  export STUB_CLAUDE_JSON_5='{"type":"result","subtype":"error_during_execution","is_error":true}'
  runner
  [ "$status" -eq 1 ]
  [ "$(worker_calls)" -eq 1 ]
}

@test "an open PR or a pushed branch for the issue: skipped without any model call" {
  export STUB_ISSUES="7 8" STUB_PR_EXISTS_FOR="7" STUB_WORKER_COMMIT=1
  git -C "$CLONE" push -q origin next:refs/heads/issue-8
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 0 ]
  contains "$output" "done: 0 ok, 2 skipped, 0 error"
}

@test "a failing review timeout posts nothing but the PR stays" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_REVIEW_EXIT=124
  runner
  [ "$status" -eq 0 ]
  [ "$(calls '^gh pr create')" -eq 1 ]
  [ "$(calls '^gh pr comment')" -eq 0 ]
  jq -r '.note' "$GRID_RUN_LOG" | grep -q 'review timeout'
}

@test "a rejected push (server-side hook) is an issue-level failure and the run continues" {
  printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = refs/heads/issue-7 ] && { echo "no workflow files" >&2; exit 1; }; done; exit 0\n' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 7 .*--add-label blocked' "$STUB_LOG"
  grep -q 'push rejected' "$STUB_COMMENTS"
  git -C "$ORIGIN" rev-parse --verify refs/heads/issue-8
}

@test "pr create failing after the push: blocked with a reason" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_PR_CREATE_FAIL=1
  runner
  [ "$status" -eq 0 ]
  grep -q 'gh pr create failed' "$STUB_COMMENTS"
  [ "$(review_calls)" -eq 0 ]
}

@test "large diff: the review input says TRUNCATED and the review argv stays small" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_DIFF_LINES=2000 STUB_STDIN_DUMP="$T/review.stdin"
  runner
  [ "$status" -eq 0 ]
  grep -q 'TRUNCATED' "$T/review.stdin"
  r="$(grep -E '^claude -p .*--tools ""' "$STUB_LOG")"
  [ "${#r}" -lt 4096 ]
}

@test "huge issue body: worker prompt body is cut at 60000 bytes, review input at 100000" {
  stub_issue 7 "Big" "$(head -c 150000 /dev/zero | tr '\0' x)" ready-for-agent
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_STDIN_DUMP="$T/review.stdin"
  runner
  [ "$status" -eq 0 ]
  w="$(grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG")"
  contains "$w" "[TRUNCATED]"
  [ "${#w}" -lt 90000 ]
  size="$(wc -c < "$T/review.stdin" | tr -d ' ')"
  [ "$size" -le 100100 ]
  [ "$size" -ge 100000 ]
  grep -q 'TRUNCATED' "$T/review.stdin"
}

# -------------------------------------------------------------- trust gate ---

@test "trust gate: an outsider's issue goes to needs-human with no model call; the next issue still runs" {
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1 STUB_AUTHOR_ASSOC_7=NONE
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 7 .*--add-label needs-human --remove-label ready-for-agent' "$STUB_LOG"
  grep -q 'trust gate: author check' "$STUB_COMMENTS"
  [ "$(worker_calls)" -eq 1 ]
  refute grep -q "issue-7" "$STUB_ENV_LOG"
  git -C "$ORIGIN" rev-parse --verify refs/heads/issue-8
}

@test "trust gate: labelled by an untrusted actor" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  export STUB_EVENTS_JSON_7='[{"event":"labeled","label":{"name":"ready-for-agent"},"actor":{"login":"trusted"}},{"event":"labeled","label":{"name":"ready-for-agent"},"actor":{"login":"stranger"}}]'
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 7 .*--add-label needs-human' "$STUB_LOG"
  grep -q 'label check' "$STUB_COMMENTS"
  [ "$(worker_calls)" -eq 0 ]
}

@test "trust gate: only the LAST labelled event for the opt-in label counts, case-insensitively" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  export STUB_EVENTS_JSON_7='[{"event":"labeled","label":{"name":"ready-for-agent"},"actor":{"login":"stranger"}},{"event":"labeled","label":{"name":"other"},"actor":{"login":"stranger"}},{"event":"labeled","label":{"name":"ready-for-agent"},"actor":{"login":"Trusted"}}]'
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 1 ]
}

@test "trust gate: body edited by an untrusted actor" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  export STUB_EDITORS_JSON_7='{"data":{"repository":{"issue":{"userContentEdits":{"nodes":[{"editor":{"login":"stranger"}}]}}}}}'
  runner
  [ "$status" -eq 0 ]
  grep -q 'edit check' "$STUB_COMMENTS"
  [ "$(worker_calls)" -eq 0 ]
}

@test "trust gate: title renamed by an untrusted actor" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  export STUB_EVENTS_JSON_7='[{"event":"labeled","label":{"name":"ready-for-agent"},"actor":{"login":"trusted"}},{"event":"renamed","actor":{"login":"stranger"}}]'
  runner
  [ "$status" -eq 0 ]
  grep -q 'rename check' "$STUB_COMMENTS"
  [ "$(worker_calls)" -eq 0 ]
}

# ---------------------------------------------------------------- preflight ---

@test "preflight: LOOP_TRUSTED_ACTORS empty" {
  sed -i.bak 's/^LOOP_TRUSTED_ACTORS=.*/LOOP_TRUSTED_ACTORS=/' "$GRID_LOOP_ENV"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "LOOP_TRUSTED_ACTORS"
}

@test "preflight: the operator's home is listable (not isolated)" {
  chmod 755 "$OPHOME"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "dedicated user"
}

@test "preflight: a stored gh login the worker could use" {
  export STUB_ISSUES="7" STUB_GH_STORED_LOGIN=1
  runner
  expect_preflight_exit2
  contains "$output" "gh auth logout"
}

@test "preflight: GH_APP_ID missing from the env file" {
  sed -i.bak '/^GH_APP_ID=/d' "$GRID_LOOP_ENV"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "GH_APP_ID"
}

@test "preflight: App key file missing, and key file mode 644" {
  export STUB_ISSUES="7"
  chmod 644 "$KEYF"
  runner
  expect_preflight_exit2
  contains "$output" "chmod 600"
  rm "$KEYF"
  runner
  expect_preflight_exit2
  contains "$output" "App private key"
}

@test "preflight: the token cannot be minted (script's one-line reason is relayed)" {
  export STUB_ISSUES="7" STUB_APP_MINT_FAIL=1
  runner
  expect_preflight_exit2
  contains "$output" "stub mint failure"
}

@test "preflight: gh api user succeeds with the token (a PAT, not an installation token)" {
  export STUB_ISSUES="7" STUB_API_USER_OK=1
  runner
  expect_preflight_exit2
  contains "$output" "installation token"
}

@test "preflight: the installation does not list this repository" {
  export STUB_ISSUES="7" STUB_INSTALL_REPOS_JSON='{"repositories":[{"full_name":"someone/else"}]}'
  runner
  expect_preflight_exit2
  contains "$output" "installation token"
}

@test "preflight: an App with administration, or with workflows, is refused" {
  export STUB_ISSUES="7"
  STUB_APP_PERMS='{"contents":"write","administration":"write"}' runner
  expect_preflight_exit2
  contains "$output" "Administration or Workflows"
  STUB_APP_PERMS='{"contents":"write","workflows":"write"}' runner
  expect_preflight_exit2
}

@test "preflight: a GH_TOKEN= line in the env file" {
  echo "GH_TOKEN=ghp_longlived" >> "$GRID_LOOP_ENV"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "remove GH_TOKEN"
  lacks "$output" "ghp_longlived"
}

@test "preflight: origin over SSH" {
  git -C "$CLONE" config remote.origin.url "git@github.com:owner/name.git"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "origin must be https"
}

@test "preflight: no rule requiring a pull request on the base branch" {
  export STUB_ISSUES="7" STUB_RULES_JSON='[]'
  runner
  expect_preflight_exit2
  contains "$output" "ruleset requiring a pull request"
}

@test "preflight: claude not logged in" {
  export STUB_ISSUES="7" STUB_CLAUDE_LOGGED_IN=0
  runner
  expect_preflight_exit2
  contains "$output" "not logged in"
}

@test "preflight: git user.email unset" {
  git -C "$CLONE" config --unset user.email
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "user.email"
}

@test "preflight: the guard entry is missing from .claude/settings.json" {
  rm "$CLONE/.claude/settings.json"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "bash loop/setup.sh"
}

@test "preflight: env file mode 644" {
  chmod 644 "$GRID_LOOP_ENV"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "chmod 600"
}

@test "preflight: uncommitted changes in the main checkout" {
  echo dirty >> "$CLONE/README.md"
  export STUB_ISSUES="7"
  runner
  expect_preflight_exit2
  contains "$output" "uncommitted"
}

@test "preflight: the opt-in label is untouched when a preflight fails" {
  chmod 644 "$GRID_LOOP_ENV"
  export STUB_ISSUES="7"
  runner
  [ "$(calls '^gh issue list')" -eq 0 ]
}

# --------------------------------------------------- env file / PATH / token ---

@test "the env file is parsed, never executed" {
  printf '%s\n' '$(touch pwned)' '`touch pwned2`' 'export X=$(touch pwned3)' >> "$GRID_LOOP_ENV"
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  cd "$T"
  runner
  [ "$status" -eq 0 ]
  [ ! -e "$T/pwned" ]
  [ ! -e "$T/pwned2" ]
  [ ! -e "$T/pwned3" ]
  [ ! -e "$CLONE/pwned" ]
  [ "$(grep -E '^gh ' "$STUB_LOG" | grep -v '^gh auth status' | grep -vc '::GH_TOKEN=abc$')" -eq 0 ]
}

@test "quoted values in the env file are unquoted" {
  sed -i.bak "s/^LOOP_TRUSTED_ACTORS=.*/LOOP_TRUSTED_ACTORS=\"trusted, other\"/" "$GRID_LOOP_ENV"
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 1 ]
}

@test "a long run re-mints: later gh calls carry the new token" {
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1 STUB_APP_TOKEN_SEQ=1 GRID_LOOP_TOKEN_REMINT_SECS=0
  runner
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$STUB_MINT_LOG" | tr -d ' ')" -gt 1 ]
  grep -q '::GH_TOKEN=tok1$' "$STUB_LOG"
  grep -q '::GH_TOKEN=tok[3-9]$' "$STUB_LOG"
  # the worker still sees nothing
  [ "$(grep -c 'GH_TOKEN=<unset>' "$STUB_ENV_LOG")" -eq "$(wc -l < "$STUB_ENV_LOG" | tr -d ' ')" ]
}

@test "a failed re-mint mid-run stops the run with exit 1" {
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1 GRID_LOOP_TOKEN_REMINT_SECS=0 STUB_APP_MINT_FAIL_AFTER=1
  runner
  [ "$status" -eq 1 ]
  contains "$output" "re-mint"
  [ "$(worker_calls)" -eq 0 ]
}

@test "claude found only in \$HOME/.local/bin (not on PATH)" {
  clean_stubs
  make_stubs --claude-in-local-bin
  unset GRID_CLAUDE
  # a developer machine may have a real claude on PATH; only system dirs + the stubs may be seen
  export PATH="$STUB_DIR:/usr/bin:/bin"
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 1 ]
}

@test "launchd/cron PATH (/usr/bin:/bin): gh, claude and timeout in \$HOME/.local/bin are still found" {
  mkdir -p "$HOME/.local/bin"
  for t in gh claude timeout; do cp "$STUB_DIR/$t" "$HOME/.local/bin/$t"; done
  # the stubs source their library by absolute path, so the copies keep working
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  unset GRID_CLAUDE
  run env PATH=/usr/bin:/bin bash "$CLONE/loop/run-issues.sh"
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 1 ]
}

@test "bash 3.2 rules: no bash-4 constructs in the runner" {
  code="$(grep -v '^[[:space:]]*#' "$PAT_DIR/run-issues.sh")"
  refute grep -nE 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)\}|\|&|local -n|wait -n|sed -i|stat -[cf]|date -[vd]|readlink -f|xargs -r' <<< "$code"
}

# ------------------------------------------------------------ lock / signals ---

@test "a live lock: the second run exits 0 and says so" {
  mkdir "$CLONE/.git/issue-loop.lock"
  sleep 60 &
  holder=$!
  echo "$holder" > "$CLONE/.git/issue-loop.lock/pid"
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  runner
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  contains "$output" "another run holds the lock"
  [ "$(worker_calls)" -eq 0 ]
  # the live holder's lock is not ours to remove
  [ -d "$CLONE/.git/issue-loop.lock" ]
}

@test "a stale lock (dead pid) is reclaimed and the run proceeds" {
  mkdir "$CLONE/.git/issue-loop.lock"
  true &
  dead=$!
  wait "$dead"
  echo "$dead" > "$CLONE/.git/issue-loop.lock/pid"
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 1 ]
  [ ! -d "$CLONE/.git/issue-loop.lock" ]
  [ -z "$(ls -d "$CLONE"/.git/issue-loop.lock.stale.* 2>/dev/null)" ]
}

@test "the lock path is absolute: a run started from another cwd locks the same place" {
  export STUB_ISSUES="7"
  mkdir "$CLONE/.git/issue-loop.lock"
  sleep 60 &
  holder=$!
  echo "$holder" > "$CLONE/.git/issue-loop.lock/pid"
  cd "$CLONE/loop"
  run bash ./run-issues.sh
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
  contains "$output" "another run holds the lock"
}

@test "SIGTERM while the worker runs: worktree and lock are gone afterwards" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1 STUB_CLAUDE_SLEEP=8 STUB_STARTED="$T/started"
  bash "$CLONE/loop/run-issues.sh" > "$T/out.txt" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$T/started" ] && break; sleep 0.1; done
  [ -e "$T/started" ]
  [ -d "$LOOP_WORKTREE_ROOT/issue-7" ]
  [ -d "$CLONE/.git/issue-loop.lock" ]
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ ! -d "$LOOP_WORKTREE_ROOT/issue-7" ]
  [ ! -d "$CLONE/.git/issue-loop.lock" ]
  # the branch name is free for the next run
  wt_list="$(git -C "$CLONE" worktree list)"
  lacks "$wt_list" "issue-7"
}

# -------------------------------------------------------------- run record ---

@test "a missing run-record.sh is tolerated: same outcome, a warning" {
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  export GRID_RUN_RECORD="$T/nope.sh"
  runner
  [ "$status" -eq 0 ]
  contains "$output" "run-record.sh not found"
  [ ! -e "$GRID_RUN_LOG" ]
  [ "$(calls '^gh pr create')" -eq 1 ]
}

# ------------------------------------------------------------ role routing ---

# agent_file <name> <tools line or ""> — a wired agent in the temp AGENTS_DIR.
agent_file() {
  {
    echo "---"
    echo "name: $1"
    echo "description: test agent"
    [ -n "$2" ] && echo "$2"
    echo "---"
    echo "body"
  } > "$AGENTS_DIR/$1.md"
}

@test "role label routes the worker to that agent; the run record carries the agent as its role" {
  agent_file grid-backend-dev "tools: Read, Edit, Write, Bash"
  stub_issue 7 "Build" "build it" ready-for-agent role:grid-backend-dev
  export STUB_ISSUES="7 8" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | sed -n 1p | grep -q -- '--agent grid-backend-dev'
  second="$(grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | sed -n 2p)"
  lacks "$second" "--agent"
  [ "$(jq -r 'select(.target == "owner/name#7") | .role' "$GRID_RUN_LOG")" = "grid-backend-dev" ]
  [ "$(jq -r 'select(.target == "owner/name#8") | .role' "$GRID_RUN_LOG")" = "issue-loop" ]
  # the review never runs as an agent
  refute grep -qE '^claude -p .*--tools "".*--agent|^claude -p .*--agent .*--tools ""' "$STUB_LOG"
}

@test "an agent without a tools line is allowed; an agent file in the repo's .claude/agents resolves too" {
  mkdir -p "$CLONE/.claude/agents"
  printf -- '---\nname: local-dev\n---\nbody\n' > "$CLONE/.claude/agents/local-dev.md"
  stub_issue 7 "Build" "build it" ready-for-agent role:local-dev
  export STUB_ISSUES="7" STUB_WORKER_COMMIT=1
  runner
  [ "$status" -eq 0 ]
  grep -E '^claude -p .*--dangerously-skip-permissions' "$STUB_LOG" | grep -q -- '--agent local-dev'
}

@test "unwired, read-only and ambiguous roles: blocked with no model call; the next issue still runs" {
  agent_file grid-qa-engineer "tools: Read, Grep, Glob, Bash"
  agent_file a "tools: Edit"
  agent_file b "tools: Edit"
  stub_issue 5 "x" "x" ready-for-agent role:no-such-agent
  stub_issue 6 "x" "x" ready-for-agent role:grid-qa-engineer
  stub_issue 7 "x" "x" ready-for-agent role:a role:b
  stub_issue 8 "x" "x" ready-for-agent
  export STUB_ISSUES="5 6 7 8" STUB_WORKER_COMMIT=1 MAX_ISSUES=4
  runner
  [ "$status" -eq 0 ]
  for n in 5 6 7; do grep -q "^gh issue edit $n .*--add-label blocked --remove-label ready-for-agent" "$STUB_LOG"; done
  [ "$(worker_calls)" -eq 1 ]
  grep -q "issue-8" "$STUB_ENV_LOG"
  grep -q 'read-only' "$STUB_COMMENTS"
  grep -q 'no wired agent' "$STUB_COMMENTS"
  grep -q 'more than one role' "$STUB_COMMENTS"
}

@test "a role label with path characters is refused" {
  stub_issue 7 "x" "x" ready-for-agent "role:../../etc/x"
  export STUB_ISSUES="7"
  runner
  [ "$status" -eq 0 ]
  [ "$(worker_calls)" -eq 0 ]
  grep -q '^gh issue edit 7 .*--add-label blocked' "$STUB_LOG"
}

# ------------------------------------------------------------ real timeout ---

@test "real timeout binary: a worker past ISSUE_TIMEOUT is blocked as a timeout (skipped without GNU timeout)" {
  # (`command -v` would find the stub, so look for the real binaries in their usual homes)
  if [ ! -x /usr/bin/timeout ] && [ ! -x /bin/timeout ] && [ ! -x /opt/homebrew/bin/gtimeout ] && [ ! -x /usr/local/bin/gtimeout ]; then
    skip "no timeout or gtimeout on this machine (macOS: brew install coreutils)"
  fi
  # use the real binary instead of the stub
  rm "$STUB_DIR/timeout"
  export STUB_ISSUES="5" STUB_CLAUDE_SLEEP=20 ISSUE_TIMEOUT=1
  runner
  [ "$status" -eq 0 ]
  grep -q '^gh issue edit 5 .*--add-label blocked' "$STUB_LOG"
  grep -q 'timeout' "$STUB_COMMENTS"
}
