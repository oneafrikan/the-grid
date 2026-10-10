#!/usr/bin/env bats
# issue-loop pattern: guard hook, review hook, setup.sh wiring, prompt template.
# Covers specs/issue-loop-hooks/spec.md and the template scenarios of
# specs/issue-loop-pr-mode/spec.md. Offline; HOME and every repo live in temp dirs;
# claude/gh/timeout are stubs (tests/helpers/stubs.bash).

load helpers/stubs

PAT_DIR="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"

setup() {
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$HOME"
  export GRID_RUN_LOG="$T/runs.jsonl"
  # never consult a real the-grid checkout for the shared parser
  export GRID_DIR="$T/no-grid"
  unset GRID_LOOP_HEADLESS GRID_REVIEW_RUNNING GRID_REVIEW_MODEL GRID_REVIEW_BUDGET_USD
  make_stubs

  # A target repo with the pattern copied into loop/ (what instantiate.sh does).
  REPO="$T/repo"
  git init -q -b next "$REPO"
  git -C "$REPO" config user.name tester
  git -C "$REPO" config user.email tester@example.invalid
  mkdir -p "$REPO/loop"
  cp -R "$PAT_DIR/hooks" "$REPO/loop/hooks"
  cp "$PAT_DIR/setup.sh" "$PAT_DIR/loop-prompt.template.md" "$PAT_DIR/.gitignore" "$REPO/loop/"
  {
    echo 'GH_REPO=${GH_REPO:-owner/name}'
    echo 'BASE_BRANCH=${BASE_BRANCH:-next}'
    echo 'PROJECT_CONTEXT=${PROJECT_CONTEXT:-a test project}'
    echo 'REVIEW_FOCUS=${REVIEW_FOCUS:-correctness}'
  } > "$REPO/loop/loop.conf"
  echo seed > "$REPO/seed.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "seed"
}

teardown() {
  clean_stubs
  rm -rf "$T"
}

# ---------------------------------------------------------------- guard ---

# guard <command> [cwd] — run the guard with a PreToolUse payload.
guard() {
  local payload
  payload="$(jq -n --arg c "$1" --arg d "${2:-$REPO}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  run bash "$REPO/loop/hooks/guard-main-push.sh" <<< "$payload"
}

# expect_decisions — the full guard table; fails with the offending command.
expect_decisions() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    guard "$c"
    [ "$status" -eq 2 ] || { echo "expected BLOCK (2), got $status: $c"; return 1; }
    [ -n "$output" ] || { echo "block printed no reason: $c"; return 1; }
  done <<'EOF'
git push origin next
git push origin HEAD:main
git push origin HEAD:refs/heads/master
git push origin +main
git push --force origin issue-3
git push -f origin issue-3
git push -fu origin issue-3
git push --force-with-lease origin issue-3
git push --force-with-lease=issue-3 origin issue-3
git push --mirror origin
git push --all origin
git push --delete origin next
git -C /some/where push origin next
cd /x && git push origin main
FOO=1 git push origin master
echo hi; git push origin next
git status | cat && git push origin next
gh pr merge 4 --squash
gh pr merge 4
gh api repos/o/r/pulls/4/merge -X PUT
gh api -X DELETE repos/o/r/git/refs/heads/next
gh api -XPUT repos/o/r/x
gh api --method=patch repos/o/r/x
gh api --method delete repos/o/r/x
EOF
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    guard "$c"
    [ "$status" -eq 0 ] || { echo "expected ALLOW (0), got $status: $c"; return 1; }
  done <<'EOF'
git push -u origin issue-12
git push origin issue-main-fix
git push origin issue-3:issue-3
git status
git
gh
gh pr
git log --oneline | cat
git commit -m "x #3" && git status
gh pr create --repo o/r --base next --head issue-3 --title t --body b
gh pr view 4
gh issue edit 3 --add-label blocked
gh api repos/o/r/issues/3 -X GET
gh api repos/o/r/issues/3
echo "git push origin next is forbidden"
EOF
}

# The last heredoc line above (`echo "git push origin next ..."`) is a quoted
# string, not a segment starting with git, so it is allowed: the guard is a
# mistake-catcher over command *segments*, not a substring matcher.

@test "guard: protected and dangerous forms blocked, issue branches allowed (built-in splitter)" {
  expect_decisions
}

@test "guard: bare push on the base branch is blocked, on an issue branch allowed" {
  guard "git push"
  [ "$status" -eq 2 ]
  guard "git push origin"
  [ "$status" -eq 2 ]
  guard "git push origin HEAD"
  [ "$status" -eq 2 ]
  git -C "$REPO" checkout -q -b issue-3
  guard "git push"
  [ "$status" -eq 0 ]
  guard "git push origin HEAD"
  [ "$status" -eq 0 ]
}

@test "guard: base branch comes from loop.conf, main and master always protected" {
  sed -i.bak 's/:-next}/:-develop}/' "$REPO/loop/loop.conf"
  guard "git push origin develop"
  [ "$status" -eq 2 ]
  guard "git push origin next"
  [ "$status" -eq 0 ]
  guard "git push origin main"
  [ "$status" -eq 2 ]
}

@test "guard: without loop.conf the base defaults to main" {
  rm "$REPO/loop/loop.conf"
  guard "git push origin main"
  [ "$status" -eq 2 ]
  guard "git push origin next"
  [ "$status" -eq 0 ]
}

@test "guard: shared grid_git_segments is sourced when present and decisions are unchanged" {
  mkdir -p "$T/gd/hooks/lib"
  cat > "$T/gd/hooks/lib/common.sh" <<'EOF'
# Fixture for hook-profiles#1: one git segment per line, "<subcommand> <words...>".
grid_git_segments() {
  : > "$GRID_MARKER"
  local s="$1" nl=$'\n' seg
  s="${s//&&/$nl}"; s="${s//||/$nl}"; s="${s//;/$nl}"; s="${s//|/$nl}"
  while IFS= read -r seg; do
    # shellcheck disable=SC2086
    set -- $seg
    while [ $# -gt 0 ]; do case "$1" in [A-Za-z_]*=*) shift ;; *) break ;; esac; done
    [ "${1:-}" = git ] || continue
    shift
    while [ $# -gt 0 ]; do case "$1" in -C|-c) shift 2 ;; -*) shift ;; *) break ;; esac; done
    if [ $# -gt 0 ]; then echo "$*"; fi
  done <<< "$s"
}
EOF
  export GRID_DIR="$T/gd"
  export GRID_MARKER="$T/marker"
  expect_decisions
  [ -f "$T/marker" ]
}

@test "guard: an empty GRID_DIR falls back to the built-in splitter" {
  mkdir -p "$T/empty"
  export GRID_DIR="$T/empty"
  expect_decisions
}

# ---------------------------------------------------------- review hook ---

# review_payload <command> [cwd]
review_payload() {
  jq -n --arg c "$1" --arg d "${2:-$REPO}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

# run_review <command> [cwd] — run the review hook from a cwd that is NOT the repo.
run_review() {
  local payload
  payload="$(review_payload "$1" "${2:-$REPO}")"
  run bash -c 'cd "$1" && bash "$2"' _ "$T" "$REPO/loop/hooks/post-commit-review.sh" <<< "$payload"
}

# wait_for_log <fixed string> — poll the stub log (the review is backgrounded).
wait_for_log() {
  local i
  for i in $(seq 1 60); do
    if grep -qF -- "$1" "$STUB_LOG"; then return 0; fi
    sleep 0.1
  done
  echo "timed out waiting for: $1"; cat "$STUB_LOG"
  return 1
}

# settle — give a backgrounded hook time to do something it should NOT do.
settle() { sleep 0.5; }

@test "review: plain and -C and cd forms are detected as commits" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit -m "x #3"'
  [ "$status" -eq 0 ]
  wait_for_log "claude "
  : > "$STUB_LOG"; rm -f "$REPO/.git/post-commit-review.last"
  run_review "git -C $REPO commit -m \"x #3\""
  wait_for_log "claude "
  : > "$STUB_LOG"; rm -f "$REPO/.git/post-commit-review.last"
  run_review "cd $REPO && git commit -m \"x #3\""
  wait_for_log "claude "
}

@test "review: look-alikes queue nothing" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit-tree HEAD^{tree}'
  [ "$status" -eq 0 ]
  run_review 'echo "git committed"'
  run_review 'git status'
  settle
  ! grep -q '^claude ' "$STUB_LOG"
}

@test "review: a worktree commit is reviewed once, from the payload cwd" {
  git -C "$REPO" worktree add -q -b feature "$T/wt"
  echo wt > "$T/wt/wtfile.txt"
  git -C "$T/wt" add wtfile.txt
  git -C "$T/wt" commit -q -m "work in worktree #3"
  run_review 'git commit -m "work in worktree #3"' "$T/wt"
  wait_for_log "claude "
  grep '^claude ' "$STUB_LOG" | grep -q 'wtfile.txt'
  # second payload for the same HEAD: deduped
  run_review 'git commit -m "work in worktree #3"' "$T/wt"
  settle
  [ "$(grep -c '^claude ' "$STUB_LOG")" -eq 1 ]
}

@test "review: posts to the branch's open PR when one exists" {
  git -C "$REPO" commit -q --allow-empty -m "fix thing #9"
  export STUB_PR_NUMBER=5
  run_review 'git commit -m "fix thing #9"'
  wait_for_log "gh pr comment 5"
  ! grep -q 'gh issue comment' "$STUB_LOG"
}

@test "review: falls back to the issue named in the subject, else logs only" {
  git -C "$REPO" commit -q --allow-empty -m "fix thing #9"
  run_review 'git commit -m "fix thing #9"'
  wait_for_log "gh issue comment 9"
  git -C "$REPO" commit -q --allow-empty -m "no reference here"
  : > "$STUB_LOG"
  run_review 'git commit -m "no reference here"'
  wait_for_log "claude "
  settle
  ! grep -q 'gh issue comment' "$STUB_LOG"
  ! grep -q 'gh pr comment' "$STUB_LOG"
  grep -q 'no reference here' "$HOME/.claude/hooks.log"
}

@test "review: the reviewer call is capped (model, budget, no tools)" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit -m "x #3"'
  wait_for_log "claude "
  line="$(grep '^claude ' "$STUB_LOG")"
  [[ "$line" == *"--model sonnet"* ]]
  [[ "$line" == *"--max-budget-usd 1"* ]]
  [[ "$line" == *'--tools ""'* ]]
}

@test "review: model and budget are overridable by env" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  export GRID_REVIEW_MODEL=haiku GRID_REVIEW_BUDGET_USD=0.25
  run_review 'git commit -m "x #3"'
  wait_for_log "claude "
  line="$(grep '^claude ' "$STUB_LOG")"
  [[ "$line" == *"--model haiku"* ]]
  [[ "$line" == *"--max-budget-usd 0.25"* ]]
}

@test "review: stands down for a headless worker and for its own reviewer" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  GRID_LOOP_HEADLESS=1 run_review 'git commit -m "x #3"'
  [ "$status" -eq 0 ]
  GRID_REVIEW_RUNNING=1 run_review 'git commit -m "x #3"'
  [ "$status" -eq 0 ]
  settle
  ! grep -q '^claude ' "$STUB_LOG"
}

@test "review: the reviewer itself runs with GRID_REVIEW_RUNNING=1 (recursion guard)" {
  # the claude stub does not echo its env, so wrap it
  cat > "$STUB_DIR/claude-env" <<EOF
#!/bin/bash
echo "REVIEW_RUNNING=\${GRID_REVIEW_RUNNING:-unset}" >> "$T/env.log"
cat > /dev/null
echo "- [nit] x"
EOF
  chmod +x "$STUB_DIR/claude-env"
  export GRID_CLAUDE="$STUB_DIR/claude-env"
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit -m "x #3"'
  for _ in $(seq 1 60); do [ -f "$T/env.log" ] && break; sleep 0.1; done
  grep -q 'REVIEW_RUNNING=1' "$T/env.log"
}

# -------------------------------------------------------------- setup.sh ---

# install_clone <dir> — a fresh clone-like dir with the pattern in loop/ and no .claude/.
install_clone() {
  mkdir -p "$1/loop"
  cp -R "$REPO/loop/hooks" "$1/loop/hooks"
  cp "$REPO/loop/setup.sh" "$REPO/loop/loop-prompt.template.md" "$REPO/loop/loop.conf" "$1/loop/"
  git init -q -b next "$1"
}

@test "setup: fresh clone gets guard and review entries; second run is byte-identical" {
  install_clone "$T/clone"
  run bash "$T/clone/loop/setup.sh"
  [ "$status" -eq 0 ]
  root="$(cd "$T/clone" && pwd -P)"
  jq -e --arg g "$root/loop/hooks/guard-main-push.sh" \
    '.hooks.PreToolUse[0].matcher == "Bash" and .hooks.PreToolUse[0].hooks[0].command == $g' "$T/clone/.claude/settings.json"
  jq -e --arg r "$root/loop/hooks/post-commit-review.sh" \
    '.hooks.PostToolUse[0].hooks[0].command == $r' "$T/clone/.claude/settings.json"
  cp "$T/clone/.claude/settings.json" "$T/first.json"
  run bash "$T/clone/loop/setup.sh"
  [ "$status" -eq 0 ]
  cmp "$T/first.json" "$T/clone/.claude/settings.json"
  [ -f "$T/clone/loop/loop-prompt.md" ]
}

@test "setup: foreign hooks survive and a stale review path is replaced after a move" {
  install_clone "$T/moved"
  mkdir -p "$T/moved/.claude"
  cat > "$T/moved/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(ls)"]},
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [
        {"type": "command", "command": "/usr/local/bin/other-tool-hook.sh"},
        {"type": "command", "command": "/old/place/loop/hooks/post-commit-review.sh"}
      ]}
    ],
    "PreToolUse": [
      {"matcher": "Write", "hooks": [{"type": "command", "command": "/usr/local/bin/write-guard.sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/old/place/loop/hooks/guard-main-push.sh"}]}
    ]
  }
}
EOF
  run bash "$T/moved/loop/setup.sh"
  [ "$status" -eq 0 ]
  s="$T/moved/.claude/settings.json"
  root="$(cd "$T/moved" && pwd -P)"
  jq -e '.permissions.allow == ["Bash(ls)"]' "$s"
  [ "$(jq '[.hooks.PostToolUse[].hooks[].command | select(endswith("/post-commit-review.sh"))] | length' "$s")" -eq 1 ]
  jq -e --arg r "$root/loop/hooks/post-commit-review.sh" '[.hooks.PostToolUse[].hooks[].command] | index($r) != null' "$s"
  jq -e '[.hooks.PostToolUse[].hooks[].command] | index("/usr/local/bin/other-tool-hook.sh") != null' "$s"
  jq -e '[.hooks.PreToolUse[].hooks[].command] | index("/usr/local/bin/write-guard.sh") != null' "$s"
  [ "$(jq '[.hooks.PreToolUse[].hooks[].command | select(endswith("/guard-main-push.sh"))] | length' "$s")" -eq 1 ]
  ! grep -q '/old/place' "$s"
}

@test "setup: a guard that never blocks makes setup exit non-zero" {
  install_clone "$T/bad"
  printf '#!/bin/bash\nexit 0\n' > "$T/bad/loop/hooks/guard-main-push.sh"
  run bash "$T/bad/loop/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did NOT block"* ]]
}

@test "setup: a missing guard file removes its stale entry instead of wiring it" {
  install_clone "$T/noguard"
  rm "$T/noguard/loop/hooks/guard-main-push.sh"
  mkdir -p "$T/noguard/.claude"
  echo '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/gone/loop/hooks/guard-main-push.sh"}]}]}}' > "$T/noguard/.claude/settings.json"
  run bash "$T/noguard/loop/setup.sh"
  [ "$status" -eq 0 ]
  jq -e '(.hooks.PreToolUse // []) | length == 0' "$T/noguard/.claude/settings.json"
  jq -e '.hooks.PostToolUse | length == 1' "$T/noguard/.claude/settings.json"
}

@test "setup: refuses to touch a settings.json that is not valid JSON" {
  install_clone "$T/broken"
  mkdir -p "$T/broken/.claude"
  echo '{not json' > "$T/broken/.claude/settings.json"
  run bash "$T/broken/loop/setup.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$T/broken/.claude/settings.json")" = '{not json' ]
}

@test "worktree helper: cuts issue-N off origin/<base> outside the repo and prints its path" {
  # a bare origin with a 'next' branch
  git init -q --bare "$T/origin.git"
  git -C "$REPO" remote add origin "$T/origin.git"
  git -C "$REPO" push -q origin next
  export LOOP_WORKTREE_ROOT="$T/wts"
  run bash -c 'cd "$1" && bash loop/hooks/new-agent-worktree.sh issue-7 2>/dev/null' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/wts/issue-7" ]
  [ "$(git -C "$T/wts/issue-7" branch --show-current)" = "issue-7" ]
  # no upstream: a bare `git push` must not be able to aim at the base branch
  ! git -C "$T/wts/issue-7" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null
}

# ------------------------------------------------------ prompt template ---

# select_mode <mode> — what instantiate.sh does with the MODE blocks (awk).
select_mode() {
  awk -v keep="$1" '
    /^<!-- MODE:/ { if ($0 == "<!-- MODE:" keep " -->") { inkeep = 1 } else { inskip = 1 } ; next }
    /^<!-- \/MODE -->$/ { inkeep = 0; inskip = 0; next }
    !inskip { print }' "$PAT_DIR/loop-prompt.template.md"
}

@test "template: both mode blocks are present and balanced" {
  [ "$(grep -c '^<!-- MODE:pr -->$' "$PAT_DIR/loop-prompt.template.md")" -ge 1 ]
  [ "$(grep -c '^<!-- MODE:direct -->$' "$PAT_DIR/loop-prompt.template.md")" -ge 1 ]
  opens="$(grep -c '^<!-- MODE:' "$PAT_DIR/loop-prompt.template.md")"
  closes="$(grep -c '^<!-- /MODE -->$' "$PAT_DIR/loop-prompt.template.md")"
  [ "$opens" -eq "$closes" ]
}

@test "template: pr mode never pushes the base branch or closes the issue, opens a PR to it" {
  out="$(select_mode pr)"
  ! printf '%s\n' "$out" | grep -q 'git push origin {{BASE_BRANCH}}'
  ! printf '%s\n' "$out" | grep -q 'git push origin main'
  ! printf '%s\n' "$out" | grep -q 'gh issue close'
  ! printf '%s\n' "$out" | grep -q '<!-- '
  printf '%s\n' "$out" | grep -q 'gh pr create .*--base {{BASE_BRANCH}}'
  printf '%s\n' "$out" | grep -q 'Closes #<N>'
  printf '%s\n' "$out" | grep -q 'ready-for-human'
  printf '%s\n' "$out" | grep -q 'git push -u origin issue-<N>'
}

@test "template: direct mode keeps the old flow" {
  out="$(select_mode direct)"
  printf '%s\n' "$out" | grep -q 'git push origin {{BASE_BRANCH}}'
  printf '%s\n' "$out" | grep -q 'gh issue close'
  ! printf '%s\n' "$out" | grep -q 'gh pr create'
  ! printf '%s\n' "$out" | grep -q '<!-- '
}

@test "template: no hard-coded main remains" {
  ! grep -nE 'origin/main|--base main|push origin main' "$PAT_DIR/loop-prompt.template.md"
}

@test "template: the verify-failure revert removes tracked changes AND untracked files" {
  cmd="$(grep -o 'git -C {{WORKING_DIR}} reset --hard HEAD && git -C {{WORKING_DIR}} clean -fd' "$PAT_DIR/loop-prompt.template.md" | sed -n '1p')"
  [ -n "$cmd" ]
  echo changed >> "$REPO/seed.txt"
  echo new > "$REPO/untracked.txt"
  [ -n "$(git -C "$REPO" status --porcelain)" ]
  cmd="${cmd//\{\{WORKING_DIR\}\}/$REPO}"
  run bash -c "$cmd"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}
