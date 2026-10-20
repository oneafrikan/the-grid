#!/usr/bin/env bats
# issue-loop pattern: guard hook, worktree helper, review hook, setup.sh, prompt templates.
# Specs: openspec/changes/issue-loop-v2/specs/loop-hooks and loop-config-and-seed.
# Offline: HOME and every repo live in temp dirs; claude and gh are stubs
# (tests/helpers/stubs.bash). No real model or network call is possible.

bats_require_minimum_version 1.5.0
load helpers/setup
load helpers/stubs

PAT_DIR="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"
# The REAL shared parser. It is copied (never replaced by a fixture) so the F1
# regression tests exercise the contract the real tokenizer has, not one we invented.
REAL_COMMON="$BATS_TEST_DIRNAME/../hooks/lib/common.sh"

# A backgrounded review hook keeps running after the test body ends. If it calls `gh`
# after teardown removed the stub dir, PATH falls through to the REAL gh. This shim sits
# behind the stubs on PATH, so a late call lands here instead: it logs and exits 99, and
# teardown_file fails the file if anything was logged.
setup_file() {
  REAL_GH_SHIM="$BATS_FILE_TMPDIR/real-gh-shim"
  mkdir -p "$REAL_GH_SHIM"
  printf '#!/bin/bash\necho "gh $*" >> "%s/real-gh.log"\nexit 99\n' "$BATS_FILE_TMPDIR" > "$REAL_GH_SHIM/gh"
  chmod +x "$REAL_GH_SHIM/gh"
  export REAL_GH_SHIM
}

# Let any straggling hook finish, then fail the file if one reached the real-gh slot.
teardown_file() {
  sleep 2
  if [ -s "$BATS_FILE_TMPDIR/real-gh.log" ]; then
    echo "a hook reached the REAL gh after stub teardown:" >&2
    cat "$BATS_FILE_TMPDIR/real-gh.log" >&2
    return 1
  fi
}

setup() {
  common_setup
  T="$(mktemp -d)"
  export HOME="$T/home"
  mkdir -p "$HOME"
  # Behind the stubs make_stubs prepends below: reached only once the stub dir is gone.
  export PATH="$REAL_GH_SHIM:$PATH"
  # Never read the real git config; commits need an identity.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  # never consult a real the-grid checkout for the shared parser
  export GRID_DIR="$T/no-grid"
  unset GRID_LOOP_HEADLESS GRID_REVIEW_RUNNING GRID_REVIEW_MODEL GRID_REVIEW_BUDGET_USD
  make_stubs

  # A target repo with the pattern copied into loop/ (what instantiate.sh does).
  REPO="$T/repo"
  git init -q -b next "$REPO"
  mkdir -p "$REPO/loop"
  cp -R "$PAT_DIR/hooks" "$REPO/loop/hooks"
  cp "$PAT_DIR/setup.sh" "$PAT_DIR/loop-prompt.template.md" "$PAT_DIR/.gitignore" "$REPO/loop/"
  {
    echo "GH_REPO=\${GH_REPO:-'owner/name'}"
    echo "BASE_BRANCH=\${BASE_BRANCH:-'next'}"
    echo "PROJECT_CONTEXT=\${PROJECT_CONTEXT:-'a test project'}"
    echo "REVIEW_FOCUS=\${REVIEW_FOCUS:-'correctness'}"
  } > "$REPO/loop/loop.conf"
  echo seed > "$REPO/seed.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "seed"
}

teardown() {
  # The review hook is backgrounded: wait (bounded, 5 s) for it to exit BEFORE the stub
  # dir is removed, so its final `gh` call still lands on the stub, not a real gh.
  local i
  for i in $(seq 1 50); do
    pgrep -f "$T/repo/loop/hooks/" >/dev/null 2>&1 || break
    sleep 0.1
  done
  clean_stubs
  # a backgrounded review may still be writing its log; retry once rather than flake
  rm -rf "$T" 2>/dev/null || { sleep 1; rm -rf "$T"; }
  common_teardown
}

# ---------------------------------------------------------------- guard ---

# guard <command> [cwd] — run the guard with a PreToolUse payload.
guard() {
  local payload
  payload="$(jq -n --arg c "$1" --arg d "${2:-$REPO}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  run bash "$REPO/loop/hooks/guard-main-push.sh" <<< "$payload"
}

# use_parser <none|empty|real> — which parser path the guard takes.
#   none   GRID_DIR names a directory that does not exist (built-in splitter)
#   empty  GRID_DIR is an empty directory (built-in splitter)
#   real   GRID_DIR holds a copy of the REAL hooks/lib/common.sh (shared parser)
use_parser() {
  case "$1" in
    none)  export GRID_DIR="$T/no-grid" ;;
    empty) mkdir -p "$T/empty-grid"; export GRID_DIR="$T/empty-grid" ;;
    real)  mkdir -p "$T/real-grid/hooks/lib"
           cp "$REAL_COMMON" "$T/real-grid/hooks/lib/common.sh"
           export GRID_DIR="$T/real-grid" ;;
  esac
}

# expect_decisions — the full decision table; fails with the offending command.
# Every row must give the same answer on every parser path.
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
git push origin +next:next
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
git push origin 'main'
git push origin "+main:refs/heads/main"
git push origin "next"
/usr/bin/git push origin main
'/usr/bin/git' push origin next
\git push origin main
cd x && git -C y push origin HEAD:main
gh pr merge 4 --squash
gh pr merge 4
gh pr 'merge' 5
/usr/bin/gh pr merge 5
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
git push origin 'issue-3'
git status
git
gh
gh pr
git log --oneline | cat
git commit -m "x #3" && git status
gh pr create --repo o/r --base next --head issue-3 --title t --body b
gh pr create --base next
gh pr view 4
gh issue edit 3 --add-label blocked
gh api repos/o/r/issues/3 -X GET
gh api repos/o/r/issues/3
echo "git push origin next is forbidden"
EOF
}

@test "guard: decision table, built-in splitter (GRID_DIR does not exist)" {
  use_parser none
  expect_decisions
}

@test "guard: decision table, built-in splitter (GRID_DIR is an empty dir)" {
  use_parser empty
  expect_decisions
}

@test "guard: decision table, REAL shared parser gives the same answers (R10.qa.F1)" {
  use_parser real
  expect_decisions
}

@test "guard: F1 regression row, git push origin main is blocked with the real parser present" {
  # On the unfixed code grid_git_segments ran inside < <(...), printed nothing, and
  # this exited 0 on every machine that had the-grid installed.
  use_parser real
  guard "git push origin main"
  [ "$status" -eq 2 ]
  contains "$output" "BLOCKED by issue-loop guard"
  guard "git push origin 'main'"
  [ "$status" -eq 2 ]
}

@test "guard: the real parser really is the one in use (unbalanced quote fails closed)" {
  # grid_check_balanced only exists on the shared path: the built-in splitter has no such check,
  # so this row proves the 'real' runs above are not silently using the fallback.
  use_parser real
  guard "git commit -m 'unclosed"
  [ "$status" -eq 2 ]
  contains "$output" "not closed"
  use_parser empty
  guard "git commit -m 'unclosed"
  [ "$status" -eq 0 ]
}

@test "guard: documented gap, bash -c is not inspected by the built-in splitter (a future fix must change this on purpose)" {
  # KNOWN GAP (guard header + pattern README): on the built-in path bash -c / eval / aliases /
  # scripts calling git are not inspected. This row pins it so closing the gap is a deliberate
  # test change. The shared parser unwraps a `bash -c` string once, so it is stricter (next test).
  use_parser empty
  guard "bash -c 'git push origin main'"
  [ "$status" -eq 0 ]
  use_parser none
  guard "bash -c 'git push origin main'"
  [ "$status" -eq 0 ]
}

@test "guard: the shared parser unwraps bash -c and eval once, so it blocks what the built-in path misses" {
  use_parser real
  guard "bash -c 'git push origin main'"
  [ "$status" -eq 2 ]
  guard "eval 'git push origin main'"
  [ "$status" -eq 2 ]
  # a script that calls git internally is a gap on BOTH paths
  printf '#!/bin/sh\ngit push origin main\n' > "$T/pushit.sh"
  guard "sh $T/pushit.sh"
  [ "$status" -eq 0 ]
}

@test "guard: bare push on the base branch is blocked, on an issue branch allowed (both parsers)" {
  local p
  for p in empty real; do
    use_parser "$p"
    git -C "$REPO" checkout -q next
    guard "git push"
    [ "$status" -eq 2 ]
    guard "git push origin"
    [ "$status" -eq 2 ]
    guard "git push origin HEAD"
    [ "$status" -eq 2 ]
    git -C "$REPO" checkout -q -B issue-3
    guard "git push"
    [ "$status" -eq 0 ]
    guard "git push origin HEAD"
    [ "$status" -eq 0 ]
  done
}

@test "guard: base branch comes from loop.conf, main and master always protected" {
  sed -i.bak "s/'next'/'develop'/" "$REPO/loop/loop.conf"
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

@test "guard: header and README-bound text names the known gaps" {
  local f="$PAT_DIR/hooks/guard-main-push.sh"
  grep -q 'KNOWN GAPS' "$f"
  grep -q 'bash -c' "$f"
  grep -q 'eval' "$f"
  grep -q 'aliases' "$f"
  grep -q 'MISTAKE-CATCHER' "$f"
}

# ------------------------------------------------------ worktree helper ---

# a bare origin with a 'next' branch, wired to $REPO
make_origin() {
  git init -q --bare "$T/origin.git"
  git -C "$REPO" remote add origin "$T/origin.git"
  git -C "$REPO" push -q origin next
}

@test "worktree helper: cuts issue-N off origin/<base> outside the repo, prints only its path, no upstream" {
  make_origin
  export LOOP_WORKTREE_ROOT="$T/wts"
  run --separate-stderr bash -c 'cd "$1" && bash loop/hooks/new-agent-worktree.sh issue-7' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/wts/issue-7" ]
  [ "$(git -C "$T/wts/issue-7" branch --show-current)" = "issue-7" ]
  # no upstream: a bare `git push` must not be able to aim at the base branch
  refute git -C "$T/wts/issue-7" rev-parse --abbrev-ref 'issue-7@{upstream}'
}

@test "worktree helper: run from inside another worktree, the root still derives from the MAIN checkout" {
  make_origin
  unset LOOP_WORKTREE_ROOT
  run --separate-stderr bash -c 'cd "$1" && bash loop/hooks/new-agent-worktree.sh issue-1' _ "$REPO"
  [ "$status" -eq 0 ]
  first="$output"
  [ "$first" = "$T/repo-loop/issue-1" ]
  # now from the linked worktree: the new one must be a sibling, not nested in it
  run --separate-stderr bash -c 'cd "$1" && bash "$2/loop/hooks/new-agent-worktree.sh" issue-2' _ "$first" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/repo-loop/issue-2" ]
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

# wait_for_review_post — the review's LAST action is its `gh ... comment`; waiting for
# the claude call alone returns while the hook is still about to call gh.
wait_for_review_post() { wait_for_log "gh issue comment"; }

# settle — give a backgrounded hook time to do something it should NOT do.
settle() { sleep 0.5; }

@test "review: plain and -C and cd forms are detected as commits" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit -m "x #3"'
  [ "$status" -eq 0 ]
  wait_for_log "claude "
  wait_for_review_post
  : > "$STUB_LOG"; rm -f "$REPO/.git/post-commit-review.last"
  run_review "git -C $REPO commit -m \"x #3\""
  wait_for_log "claude "
  wait_for_review_post
  : > "$STUB_LOG"; rm -f "$REPO/.git/post-commit-review.last"
  run_review "cd $REPO && git commit -m \"x #3\""
  wait_for_log "claude "
  wait_for_review_post
}

@test "review: look-alikes queue nothing" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit-tree HEAD^{tree}'
  [ "$status" -eq 0 ]
  run_review 'echo "git committed"'
  run_review 'echo "git commit"'
  run_review 'git status'
  settle
  refute grep -q '^claude ' "$STUB_LOG"
}

@test "review: a worktree commit is reviewed once, from the payload cwd" {
  git -C "$REPO" worktree add -q -b feature "$T/wt"
  echo wt > "$T/wt/wtfile.txt"
  git -C "$T/wt" add wtfile.txt
  git -C "$T/wt" commit -q -m "work in worktree #3"
  run_review 'git commit -m "work in worktree #3"' "$T/wt"
  wait_for_log "claude "
  wait_for_review_post
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
  refute grep -q 'gh issue comment' "$STUB_LOG"
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
  refute grep -q 'gh issue comment' "$STUB_LOG"
  refute grep -q 'gh pr comment' "$STUB_LOG"
  grep -q 'no reference here' "$HOME/.claude/hooks.log"
}

@test "review: issue comments go to ISSUE_REPO, PR comments to GH_REPO" {
  echo "ISSUE_REPO=\${ISSUE_REPO:-'owner/tracker'}" >> "$REPO/loop/loop.conf"
  git -C "$REPO" commit -q --allow-empty -m "fix thing #9"
  run_review 'git commit -m "fix thing #9"'
  wait_for_log "gh issue comment 9"
  grep 'gh issue comment 9' "$STUB_LOG" | grep -q -- '--repo owner/tracker'
  git -C "$REPO" commit -q --allow-empty -m "fix other #8"
  : > "$STUB_LOG"
  export STUB_PR_NUMBER=5
  run_review 'git commit -m "fix other #8"'
  wait_for_log "gh pr comment 5"
  grep 'gh pr comment 5' "$STUB_LOG" | grep -q -- '--repo owner/name'
}

@test "review: the reviewer call is capped (model, budget, no tools)" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  run_review 'git commit -m "x #3"'
  wait_for_log "claude "
  wait_for_review_post
  line="$(grep '^claude ' "$STUB_LOG")"
  contains "$line" "--model sonnet"
  contains "$line" "--max-budget-usd 1"
  contains "$line" '--tools ""'
}

@test "review: model and budget are overridable by env" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  export GRID_REVIEW_MODEL=haiku GRID_REVIEW_BUDGET_USD=0.25
  run_review 'git commit -m "x #3"'
  wait_for_log "claude "
  wait_for_review_post
  line="$(grep '^claude ' "$STUB_LOG")"
  contains "$line" "--model haiku"
  contains "$line" "--max-budget-usd 0.25"
}

@test "review: stands down for a headless worker and for its own reviewer" {
  git -C "$REPO" commit -q --allow-empty -m "x #3"
  GRID_LOOP_HEADLESS=1 run_review 'git commit -m "x #3"'
  [ "$status" -eq 0 ]
  GRID_REVIEW_RUNNING=1 run_review 'git commit -m "x #3"'
  [ "$status" -eq 0 ]
  settle
  refute grep -q '^claude ' "$STUB_LOG"
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
  wait_for_review_post
  grep -q 'REVIEW_RUNNING=1' "$T/env.log"
}
