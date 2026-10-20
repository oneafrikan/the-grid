#!/usr/bin/env bats
# scripts/instantiate.sh issue-loop: base branch, modes, labels, quoting, idempotency, the seed.
# Spec: openspec/changes/issue-loop-v2/specs/loop-config-and-seed (instantiate requirement) and
# loop-hooks (.claude ignored).
# Targets are temp git repos; HOME is a temp dir; gh and claude are stubs (tests/helpers/stubs.bash).
# Nothing is scheduled, activated or sent anywhere.

bats_require_minimum_version 1.5.0
load helpers/setup
load helpers/stubs

INST="$BATS_TEST_DIRNAME/../scripts/instantiate.sh"
PAT_DIR="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"

setup() {
  common_setup
  T="$(mktemp -d)"
  T="$(cd "$T" && pwd -P)"
  export HOME="$T/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  # No the-grid checkout is reachable from the target: instantiate must not need one.
  unset GRID_DIR
  make_stubs
  export STUB_GH_STORED_LOGIN=1     # instantiate wants an authenticated gh
  REPO="$T/repo"
  git init -q -b main "$REPO"
  echo seed > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m seed
}

teardown() {
  clean_stubs
  rm -rf "$T"
  common_teardown
}

# inst <args...> — instantiate into $REPO with the repo/context flags every test needs.
inst() {
  run bash "$INST" issue-loop "$REPO" --repo owner/name --project-context "a test project" --review-focus "correctness" "$@"
}

# loop_conf_value <KEY> — the value loop.conf yields when sourced (as the runner does).
loop_conf_value() {
  bash -c 'cd "$1" && . loop/loop.conf && eval "printf %s \"\${$2}\""' _ "$REPO" "$1"
}

# tree_hash — one hash over every file in the target except .git
tree_hash() {
  ( cd "$REPO" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"; sha256sum < "$f"
    done | sha256sum )
}

# ------------------------------------------------------------ idempotency ---

@test "idempotent: a second run prints no 'wrote:' line and the tree is byte-identical" {
  inst --profile work --base-branch next --verify-cmd "pytest -q"
  [ "$status" -eq 0 ]
  contains "$output" "wrote:"
  before="$(tree_hash)"
  export STUB_LABELS='[{"name":"ready-for-agent"},{"name":"ready-for-human"},{"name":"needs-human"},{"name":"blocked"}]'
  inst --profile work --base-branch next --verify-cmd "pytest -q"
  [ "$status" -eq 0 ]
  lacks "$output" "wrote:"
  [ "$(tree_hash)" = "$before" ]
}

@test "loop.conf is rendered once: a hand edit survives and the second run says 'left alone'" {
  inst --profile work
  [ "$status" -eq 0 ]
  sed -i.bak "s/'sonnet'/'haiku'/" "$REPO/loop/loop.conf"
  rm -f "$REPO/loop/loop.conf.bak"
  inst --profile work
  [ "$status" -eq 0 ]
  contains "$output" "left alone: $REPO/loop/loop.conf"
  [ "$(loop_conf_value WORKER_MODEL)" = "haiku" ]
}

@test "the prompt template is copied verbatim, placeholders unfilled, even after the pattern changed (R10.qa.F5)" {
  # a private copy of the instantiate script + pattern, so the pattern can change under it
  mkdir -p "$T/grid/scripts" "$T/grid/automation-factory"
  cp "$INST" "$T/grid/scripts/instantiate.sh"
  cp -R "$BATS_TEST_DIRNAME/../automation-factory/patterns" "$T/grid/automation-factory/patterns"
  echo "<!-- a change made after the first cut -->" >> "$T/grid/automation-factory/patterns/issue-loop/loop-prompt.template.md"
  run bash "$T/grid/scripts/instantiate.sh" issue-loop "$REPO" --repo owner/name --profile work --project-context c --review-focus f
  [ "$status" -eq 0 ]
  cmp "$T/grid/automation-factory/patterns/issue-loop/loop-prompt.template.md" "$REPO/loop/loop-prompt.template.md"
  contains "$(cat "$REPO/loop/loop-prompt.template.md")" "{{GH_REPO}}"
  # and the rendered, gitignored prompt is what holds the values
  contains "$(cat "$REPO/loop/loop-prompt.md")" "owner/name"
}

# ------------------------------------------------------------------ profiles ---

@test "profiles: personal is direct, work and mac-mini are pr" {
  inst --profile personal
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value MODE)" = "direct" ]
  rm -rf "$REPO/loop"
  inst --profile work
  [ "$(loop_conf_value MODE)" = "pr" ]
  rm -rf "$REPO/loop"
  inst --profile mac-mini
  [ "$(loop_conf_value MODE)" = "pr" ]
}

@test "profiles: direct mode copies no guard, no worktree helper, no runner and no worker prompt" {
  inst --profile personal
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/loop/run-issue.sh" ]
  [ ! -e "$REPO/loop/hooks/guard-main-push.sh" ]
  [ ! -e "$REPO/loop/hooks/new-agent-worktree.sh" ]
  [ ! -e "$REPO/loop/worker-prompt.template.md" ]
  [ -f "$REPO/loop/hooks/post-commit-review.sh" ]
  [ -f "$REPO/loop/loop-prompt.md" ]
  contains "$(cat "$REPO/loop/loop-prompt.md")" "git push origin main"
}

@test "profiles: pr mode ships the runner, the worker prompt, the guard and the worktree helper, verbatim and executable" {
  inst --profile work
  [ "$status" -eq 0 ]
  local f
  for f in run-issue.sh worker-prompt.template.md hooks/guard-main-push.sh hooks/new-agent-worktree.sh hooks/post-commit-review.sh setup.sh loop-prompt.template.md; do
    cmp "$PAT_DIR/$f" "$REPO/loop/$f"
  done
  [ -x "$REPO/loop/run-issue.sh" ]
  [ -x "$REPO/loop/hooks/guard-main-push.sh" ]
  [ ! -e "$REPO/loop/run-issue""s.sh" ]
  [ ! -e "$REPO/loop/wake.sh" ]
}

@test "profiles: --mode overrides the profile default" {
  inst --profile personal --mode pr
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value MODE)" = "pr" ]
  [ -x "$REPO/loop/run-issue.sh" ]
}

@test "profiles: a bad --mode or --profile is an error" {
  inst --profile work --mode sideways
  [ "$status" -ne 0 ]
  inst --profile linux
  [ "$status" -ne 0 ]
  run bash "$INST" issue-loop "$REPO" --repo owner/name
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------------------ labels ---

@test "labels: standard and agent: labels are created when absent, not when present; a second run creates none" {
  export STUB_LABELS='[{"name":"blocked"}]'
  inst --profile work --agent-labels grid-backend-dev,grid-devops
  [ "$status" -eq 0 ]
  creates="$(grep '^gh label create' "$STUB_LOG")"
  contains "$creates" "label create ready-for-agent --repo owner/name"
  contains "$creates" "label create ready-for-human"
  contains "$creates" "label create needs-human"
  contains "$creates" "label create agent:grid-backend-dev"
  contains "$creates" "label create agent:grid-devops"
  lacks "$creates" "label create blocked"
  contains "$(grep '^gh label list' "$STUB_LOG")" "--limit 200"
  : > "$STUB_LOG"
  export STUB_LABELS='[{"name":"ready-for-agent"},{"name":"ready-for-human"},{"name":"needs-human"},{"name":"blocked"},{"name":"agent:grid-backend-dev"},{"name":"agent:grid-devops"}]'
  inst --profile work --agent-labels grid-backend-dev,grid-devops
  [ "$status" -eq 0 ]
  refute grep -q '^gh label create' "$STUB_LOG"
}

@test "labels: the default opt-in label is ready-for-agent" {
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value ISSUE_LABEL)" = "ready-for-agent" ]
  contains "$(cat "$REPO/loop/loop-prompt.md")" "ready-for-agent"
}

@test "labels: an agent name with odd characters is refused" {
  inst --profile work --agent-labels 'a b,c'
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------------- issue repo ---

@test "issue repo: --issue-repo is written to loop.conf and the labels are created there" {
  inst --profile work --issue-repo owner/tracker
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value ISSUE_REPO)" = "owner/tracker" ]
  [ "$(loop_conf_value GH_REPO)" = "owner/name" ]
  contains "$(grep '^gh label create ready-for-agent' "$STUB_LOG")" "--repo owner/tracker"
}

@test "issue repo: unset it equals GH_REPO" {
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value ISSUE_REPO)" = "owner/name" ]
}

# --------------------------------------------------------------- loop.conf ---

@test "conf: every key of the table is present, none of the retired ones" {
  inst --profile work
  [ "$status" -eq 0 ]
  local k
  for k in GH_REPO ISSUE_REPO BASE_BRANCH ISSUE_LABEL MODE VERIFY_CMD VERIFY_TIMEOUT SETUP_CMD PROJECT_CONTEXT REVIEW_FOCUS WORKER_MODEL MAX_BUDGET_USD ISSUE_TIMEOUT WORKER_PERMISSIONS WORKER_ALLOWED_TOOLS MAX_ISSUES_PER_DAY TRUST_GATE RUN_ROLE; do
    grep -q "^$k=\${$k:-" "$REPO/loop/loop.conf" || { echo "missing $k"; return 1; }
  done
  for k in MAX_TURNS REVIEW_MODEL LABEL_BUDGETS LOOP_TRUSTED_ACTORS "LOOP_OPERATOR_""HOME" "GH_APP""_" MAX_ISSUES=; do
    refute grep -q "$k" "$REPO/loop/loop.conf"
  done
  [ "$(loop_conf_value VERIFY_TIMEOUT)" = "900" ]
  [ "$(loop_conf_value MAX_BUDGET_USD)" = "5" ]
  [ "$(loop_conf_value ISSUE_TIMEOUT)" = "1800" ]
  [ "$(loop_conf_value WORKER_PERMISSIONS)" = "allowlist" ]
  [ "$(loop_conf_value MAX_ISSUES_PER_DAY)" = "0" ]
  [ "$(loop_conf_value TRUST_GATE)" = "on" ]
  [ "$(loop_conf_value RUN_ROLE)" = "issue-loop" ]
  contains "$(loop_conf_value WORKER_ALLOWED_TOOLS)" "Bash(git commit:*)"
  lacks "$(loop_conf_value WORKER_ALLOWED_TOOLS)" "git push"
}

@test "conf: values with spaces, &&, |, quotes and non-ASCII survive sourcing exactly" {
  inst --profile work --verify-cmd 'a && b | c' --project-context "R&D tool (it's ok) café" --setup-cmd 'npm ci && echo "x y"'
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value VERIFY_CMD)" = 'a && b | c' ]
  [ "$(loop_conf_value PROJECT_CONTEXT)" = "R&D tool (it's ok) café" ]
  [ "$(loop_conf_value SETUP_CMD)" = 'npm ci && echo "x y"' ]
}

@test "conf: the environment overrides the file (MAX_BUDGET_USD=1)" {
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(MAX_BUDGET_USD=1 loop_conf_value MAX_BUDGET_USD)" = "1" ]
}

@test "conf: a value that itself contains {{...}} is written literally" {
  inst --profile work --project-context 'uses {{REVIEW_FOCUS}} syntax'
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value PROJECT_CONTEXT)" = 'uses {{REVIEW_FOCUS}} syntax' ]
}

# ---------------------------------------------------------- base and repo ---

@test "base: a custom base branch is filled into loop.conf and the rendered prompt" {
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value BASE_BRANCH)" = "next" ]
  contains "$(cat "$REPO/loop/loop-prompt.md")" "--base next"
  refute grep -rnE 'origin/main|--base main|git push origin main' "$REPO/loop/loop-prompt.md" "$REPO/CLAUDE.md"
}

@test "base: without --base-branch and without origin/HEAD it is main; with origin/HEAD it is that branch" {
  inst --profile work
  [ "$(loop_conf_value BASE_BRANCH)" = "main" ]
  rm -rf "$REPO/loop"
  git -C "$REPO" update-ref refs/remotes/origin/develop HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value BASE_BRANCH)" = "develop" ]
}

@test "repo: auto-detected from https, scp-with-alias and ssh:// remotes" {
  git -C "$REPO" remote add origin git@some-host-alias:acme/widgets.git
  run bash "$INST" issue-loop "$REPO" --profile work --project-context ctx --review-focus f
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value GH_REPO)" = "acme/widgets" ]
  git init -q -b main "$T/repo3"
  git -C "$T/repo3" remote add origin ssh://git@github.com/acme/gadgets.git
  run bash "$INST" issue-loop "$T/repo3" --profile work --project-context ctx --review-focus f
  [ "$status" -eq 0 ]
  [ "$(cd "$T/repo3" && . loop/loop.conf && printf %s "$GH_REPO")" = "acme/gadgets" ]
}

@test "existing loop.conf is the source of truth for values a flag did not set; a flag still wins for the command" {
  inst --profile work --base-branch next --label agent-ready
  [ "$status" -eq 0 ]
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  inst --profile work
  [ "$status" -eq 0 ]
  contains "$output" "base branch: next"
  [ "$(loop_conf_value BASE_BRANCH)" = "next" ]
  [ "$(loop_conf_value ISSUE_LABEL)" = "agent-ready" ]
  contains "$(cat "$REPO/loop/loop-prompt.md")" "--label agent-ready" || contains "$(cat "$REPO/loop/loop-prompt.md")" "agent-ready"
  inst --profile work --base-branch develop
  [ "$status" -eq 0 ]
  contains "$output" "left alone"
  [ "$(loop_conf_value BASE_BRANCH)" = "next" ]
}

# ---------------------------------------------------------------- the seed ---

@test "seed: loop/loop.conf.seed feeds instantiate when there is no flag and no loop.conf" {
  mkdir -p "$REPO/loop"
  cat > "$REPO/loop/loop.conf.seed" <<'EOF'
VERIFY_CMD='pytest'
SETUP_CMD='scripts/worktree-setup.sh'
BASE_BRANCH='trunk'
MAX_ISSUES_PER_DAY='3'
EOF
  inst --profile work
  [ "$status" -eq 0 ]
  contains "$output" "defaults from: loop/loop.conf.seed"
  [ "$(loop_conf_value VERIFY_CMD)" = "pytest" ]
  [ "$(loop_conf_value SETUP_CMD)" = "scripts/worktree-setup.sh" ]
  [ "$(loop_conf_value BASE_BRANCH)" = "trunk" ]
  [ "$(loop_conf_value MAX_ISSUES_PER_DAY)" = "3" ]
  # the seed is left alone, and a flag still beats it
  [ -f "$REPO/loop/loop.conf.seed" ]
  rm "$REPO/loop/loop.conf"
  inst --profile work --verify-cmd 'make test'
  [ "$(loop_conf_value VERIFY_CMD)" = "make test" ]
}

# ---------------------------------------------------- what it must not do ---

@test "no scheduler: no unit or plist, no scheduler command, no .claude/settings.json, no skip-permissions flag" {
  inst --profile mac-mini
  [ "$status" -eq 0 ]
  refute grep -qE '^(crontab|launchctl|systemctl) ' "$STUB_LOG"
  [ ! -e "$HOME/Library/LaunchAgents" ]
  [ ! -e "$HOME/.config/systemd" ]
  [ ! -e "$REPO/.claude/settings.json" ]
  refute grep -q 'dangerously-skip-permissions' "$INST"
  refute grep -q 'bash -l' "$INST"
  refute grep -q 'launchd' <(grep -v '^#' "$INST")
  contains "$output" "bash loop/run-issue.sh"
  lacks "$output" "crontab -e"
}

@test "settings: default setup leaves the repo's .claude/settings.json without any guard entry" {
  mkdir -p "$REPO/.claude"
  printf '{"permissions":{"allow":["Bash(ls)"]}}\n' > "$REPO/.claude/settings.json"
  cp "$REPO/.claude/settings.json" "$T/before.json"
  inst --profile work
  [ "$status" -eq 0 ]
  cmp "$T/before.json" "$REPO/.claude/settings.json"
}

@test "gitignore: .claude/settings.json is appended once, even when the file lacks a trailing newline" {
  printf 'node_modules' > "$REPO/.gitignore"
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '.claude/settings.json' "$REPO/.gitignore")" -eq 1 ]
  [ "$(head -n1 "$REPO/.gitignore")" = "node_modules" ]
  inst --profile work
  [ "$(grep -cxF '.claude/settings.json' "$REPO/.gitignore")" -eq 1 ]
  lacks "$output" "appended"
}

@test "CLAUDE.md: written once, describes the new flow, never claims the loop is unattended, never overwritten" {
  inst --profile work --verify-cmd "pytest -q"
  [ "$status" -eq 0 ]
  md="$(cat "$REPO/CLAUDE.md")"
  contains "$md" "loop/run-issue.sh"
  contains "$md" "never merges"
  contains "$md" "pytest -q"
  refute grep -qi 'unattended' "$REPO/CLAUDE.md"
  echo "# hand written" > "$REPO/CLAUDE.md"
  inst --profile work
  contains "$output" "CLAUDE.md already exists"
  [ "$(cat "$REPO/CLAUDE.md")" = "# hand written" ]
}

# ----------------------------------------------------- business repo, setup ---

@test "business repo: no the-grid checkout anywhere, instantiation succeeds and the copied guard works on its built-in parser" {
  [ ! -e "$HOME/.the-grid" ]
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  contains "$output" "Guard self-test passed"
  guard() { jq -n --arg c "$1" --arg d "$REPO" '{tool_input:{command:$c},cwd:$d}' | bash "$REPO/loop/hooks/guard-main-push.sh"; }
  run guard "git push origin next"
  [ "$status" -eq 2 ]
  run guard "git push origin 'main'"
  [ "$status" -eq 2 ]
  run guard "/usr/bin/git push origin next"
  [ "$status" -eq 2 ]
  run guard "gh pr merge 4"
  [ "$status" -eq 2 ]
  run guard "git push -u origin issue-3"
  [ "$status" -eq 0 ]
}

@test "setup self-test is skipped for the direct profile (no guard shipped)" {
  inst --profile personal
  [ "$status" -eq 0 ]
  contains "$output" "self-test skipped"
}

@test "unknown option and unknown pattern are errors" {
  run bash "$INST" issue-loop "$REPO" --profile work --frobnicate yes
  [ "$status" -ne 0 ]
  run bash "$INST" cli-cron "$REPO" --profile work
  [ "$status" -ne 0 ]
}

@test "first run: pr mode tells the operator to extend WORKER_ALLOWED_TOOLS; direct mode has no such hint" {
  inst --profile work
  [ "$status" -eq 0 ]
  contains "$output" "WORKER_ALLOWED_TOOLS in loop/loop.conf"
  contains "$output" "DENIED every Bash command"
  rm -rf "$REPO/loop"
  inst --profile personal
  [ "$status" -eq 0 ]
  lacks "$output" "DENIED every Bash command"
}
