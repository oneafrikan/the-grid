#!/usr/bin/env bats
# scripts/instantiate.sh issue-loop: base branch, modes, labels, escaping, idempotency,
# the linux/mac-mini scheduler files. Covers specs/issue-loop-pr-mode/spec.md (instantiate
# scenarios) and specs/issue-loop-scheduling/spec.md (profile scenarios).
# Targets are temp git repos; HOME, SYSTEMD_USER_DIR and LAUNCH_AGENTS_DIR are temp dirs;
# gh/claude/loginctl/systemctl/launchctl/crontab are stubs. Nothing is activated.

bats_require_minimum_version 1.5.0
load helpers/stubs

INST="$BATS_TEST_DIRNAME/../scripts/instantiate.sh"

setup() {
  T="$(mktemp -d)"
  T="$(cd "$T" && pwd -P)"
  export HOME="$T/home"
  mkdir -p "$HOME"
  export SYSTEMD_USER_DIR="$T/units"
  export LAUNCH_AGENTS_DIR="$T/launchagents"
  export GIT_CONFIG_NOSYSTEM=1
  unset XDG_CONFIG_HOME
  make_stubs
  export STUB_GH_STORED_LOGIN=1     # instantiate wants an authenticated gh
  REPO="$T/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.name tester
  git -C "$REPO" config user.email tester@example.invalid
  echo seed > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m seed
}

teardown() {
  clean_stubs
  rm -rf "$T"
}

# inst <args...> — instantiate into $REPO with the repo/context flags every test needs.
inst() {
  run bash "$INST" issue-loop "$REPO" --repo owner/name --project-context "a test project" --review-focus "correctness" "$@"
}

# loop_conf_value <KEY> — the value loop.conf yields when sourced (as the runner does).
loop_conf_value() {
  bash -c 'cd "$1" && . loop/loop.conf && eval "printf %s \"\${$2}\""' _ "$REPO" "$1"
}

# ------------------------------------------------------------------ base ---

@test "custom base branch is filled everywhere; no main leaks into generated files" {
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  contains "$(cat "$REPO/loop/loop-prompt.template.md")" "--base next"
  [ "$(loop_conf_value BASE_BRANCH)" = "next" ]
  contains "$(cat "$REPO/loop/loop-prompt.template.md")" "Base branch:       next"
  refute grep -rnE 'origin/main|--base main|git push origin main' "$REPO/loop" "$REPO/CLAUDE.md"
}

@test "without --base-branch and without origin/HEAD the base is main" {
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value BASE_BRANCH)" = "main" ]
}

@test "without --base-branch the base is origin/HEAD's branch" {
  git -C "$REPO" update-ref refs/remotes/origin/develop HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value BASE_BRANCH)" = "develop" ]
}

@test "the repo is auto-detected from the git remote when --repo is omitted" {
  git -C "$REPO" remote add origin https://github.com/acme/widgets.git
  run bash "$INST" issue-loop "$REPO" --profile work --project-context ctx --review-focus f
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value GH_REPO)" = "acme/widgets" ]
}

# ----------------------------------------------------------------- modes ---

@test "pr mode (work profile): loop.conf MODE pr; prompt opens a PR to the base and never pushes it" {
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  contains "$(cat "$REPO/loop/loop.conf")" 'MODE=${MODE:-pr}'
  prompt="$(cat "$REPO/loop/loop-prompt.template.md")"
  contains "$prompt" "gh pr create"
  contains "$prompt" "--base next"
  contains "$prompt" "Closes #"
  lacks "$prompt" "git push origin next"
  lacks "$prompt" "gh issue close"
  lacks "$prompt" "<!-- MODE"
  lacks "$prompt" "<!-- /MODE"
}

@test "direct mode keeps the old flow and ships no runner, guard or worktree helper" {
  inst --profile personal --base-branch main
  [ "$status" -eq 0 ]
  contains "$(cat "$REPO/loop/loop.conf")" 'MODE=${MODE:-direct}'
  prompt="$(cat "$REPO/loop/loop-prompt.template.md")"
  contains "$prompt" "git push origin main"
  contains "$prompt" "gh issue close"
  lacks "$prompt" "gh pr create"
  lacks "$prompt" "<!-- MODE"
  [ ! -e "$REPO/loop/run-issues.sh" ]
  [ ! -e "$REPO/loop/gh-app-token.sh" ]
  [ ! -e "$REPO/loop/hooks/guard-main-push.sh" ]
  [ ! -e "$REPO/loop/hooks/new-agent-worktree.sh" ]
  [ -x "$REPO/loop/hooks/post-commit-review.sh" ]
}

@test "--mode direct on a scheduled profile is refused" {
  inst --profile linux --mode direct
  [ "$status" -eq 1 ]
  contains "$output" "pr-only"
}

@test "pr mode ships the runner, the token minter, the guard and the worktree helper, all executable and wired" {
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  for f in loop/run-issues.sh loop/gh-app-token.sh loop/setup.sh loop/hooks/guard-main-push.sh loop/hooks/new-agent-worktree.sh loop/hooks/post-commit-review.sh; do
    [ -x "$REPO/$f" ]
  done
  cmp "$REPO/loop/run-issues.sh" "$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop/run-issues.sh"
  cmp "$REPO/loop/gh-app-token.sh" "$BATS_TEST_DIRNAME/../scripts/lib/gh-app-token.sh"
  root="$(cd "$REPO" && pwd -P)"
  jq -e --arg g "$root/loop/hooks/guard-main-push.sh" '[.hooks.PreToolUse[].hooks[].command] | index($g) != null' "$REPO/.claude/settings.json"
  jq -e --arg r "$root/loop/hooks/post-commit-review.sh" '[.hooks.PostToolUse[].hooks[].command] | index($r) != null' "$REPO/.claude/settings.json"
}

@test "the heredoc workaround comments and the personal launchd label are gone" {
  refute grep -nE 'com\.gareth|heredoc-scanner|bash heredoc' "$INST"
}

# ---------------------------------------------------------------- labels ---

@test "labels: the four state labels and one role label per --role-labels entry are created once" {
  export STUB_LABELS='[]'
  inst --profile work --role-labels grid-devops,grid-sdet
  [ "$status" -eq 0 ]
  for l in ready-for-agent ready-for-human needs-human blocked role:grid-devops role:grid-sdet; do
    grep -q "^gh label create $l " "$STUB_LOG"
  done
  [ "$(grep -c '^gh label create ' "$STUB_LOG")" -eq 6 ]
  grep -q '^gh label create role:grid-devops .*--color 5319E7' "$STUB_LOG"
  grep -q '^gh label list .*--limit 200' "$STUB_LOG"
  # second run: everything listed -> no create at all
  : > "$STUB_LOG"
  export STUB_LABELS='[{"name":"ready-for-agent"},{"name":"ready-for-human"},{"name":"needs-human"},{"name":"blocked"},{"name":"role:grid-devops"},{"name":"role:grid-sdet"}]'
  inst --profile work --role-labels grid-devops,grid-sdet
  [ "$status" -eq 0 ]
  [ "$(grep -c '^gh label create ' "$STUB_LOG")" -eq 0 ]
}

@test "--label sets the opt-in label everywhere" {
  inst --profile work --label agent-ready
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value ISSUE_LABEL)" = "agent-ready" ]
  contains "$(cat "$REPO/loop/loop-prompt.template.md")" "--label agent-ready"
  grep -q '^gh label create agent-ready ' "$STUB_LOG"
}

# ------------------------------------------------------------- escaping ---

@test "a verify command with && is filled intact in the prompt and survives sourcing loop.conf" {
  inst --profile work --verify-cmd "make lint && make test"
  [ "$status" -eq 0 ]
  contains "$(cat "$REPO/loop/loop-prompt.template.md")" "make lint && make test"
  [ "$(loop_conf_value VERIFY_CMD)" = "make lint && make test" ]
}

@test "ampersands, pipes and backslashes in values come through unchanged" {
  inst --profile work --verify-cmd 'a | b & c \ d' --setup-cmd 'npm ci && echo "x"'
  [ "$status" -eq 0 ]
  contains "$(cat "$REPO/loop/loop-prompt.template.md")" 'a | b & c \ d'
  [ "$(loop_conf_value VERIFY_CMD)" = 'a | b & c \ d' ]
  [ "$(loop_conf_value SETUP_CMD)" = 'npm ci && echo "x"' ]
  # a fresh target takes the project context verbatim too
  git init -q -b main "$T/repo2"
  run bash "$INST" issue-loop "$T/repo2" --repo owner/name --profile work --project-context 'Tom & Jerry | x \ y' --review-focus 'a&b'
  [ "$status" -eq 0 ]
  contains "$(cat "$T/repo2/loop/loop-prompt.template.md")" 'Tom & Jerry | x \ y'
  [ "$(cd "$T/repo2" && . loop/loop.conf && printf %s "$PROJECT_CONTEXT")" = 'Tom & Jerry | x \ y' ]
}

@test "tunables land in loop.conf" {
  inst --profile work --max-issues 5 --max-turns 25 --issue-timeout 900 --worker-model haiku --review-model sonnet
  [ "$status" -eq 0 ]
  [ "$(loop_conf_value MAX_ISSUES)" = "5" ]
  [ "$(loop_conf_value MAX_TURNS)" = "25" ]
  [ "$(loop_conf_value ISSUE_TIMEOUT)" = "900" ]
  [ "$(loop_conf_value WORKER_MODEL)" = "haiku" ]
  [ "$(loop_conf_value REVIEW_MODEL)" = "sonnet" ]
  [ "$(loop_conf_value MAX_BUDGET_USD)" = "5" ]
  [ "$(loop_conf_value REVIEW_BUDGET_USD)" = "2" ]
  [ "$(loop_conf_value LABEL_BUDGETS)" = "" ]
}

@test "bad numeric options are refused" {
  inst --profile work --max-issues zero
  [ "$status" -eq 1 ]
  inst --profile work --schedule-hour 25
  [ "$status" -eq 1 ]
}

# ----------------------------------------------------------- idempotency ---

@test "a second identical run writes nothing; a hand-tuned cap survives" {
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  contains "$output" "wrote:"
  sed -i.bak 's/MAX_ISSUES:-3/MAX_ISSUES:-7/' "$REPO/loop/loop.conf"
  rm "$REPO/loop/loop.conf.bak"
  inst --profile work --base-branch next
  [ "$status" -eq 0 ]
  lacks "$output" "wrote:"
  contains "$output" "loop.conf exists, left alone"
  [ "$(loop_conf_value MAX_ISSUES)" = "7" ]
}

@test "a second run with no hand edits reports loop.conf unchanged" {
  inst --profile work
  inst --profile work
  [ "$status" -eq 0 ]
  lacks "$output" "wrote:"
  contains "$output" "unchanged: $REPO/loop/loop.conf"
}

@test "an existing CLAUDE.md is never overwritten" {
  echo "my own notes" > "$REPO/CLAUDE.md"
  inst --profile work
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/CLAUDE.md")" = "my own notes" ]
}

@test "the generated CLAUDE.md names the base branch, the runner and the PR flow" {
  inst --profile linux --base-branch next
  [ "$status" -eq 0 ]
  md="$(cat "$REPO/CLAUDE.md")"
  contains "$md" "base branch: **next**"
  contains "$md" "loop/run-issues.sh"
  contains "$md" "PR to \`next\`"
  contains "$md" "systemd user timer"
}

# ----------------------------------------------------------------- linux ---

@test "linux: units written, nothing activated, activation printed, env file not created" {
  inst --profile linux --schedule-hour 3
  [ "$status" -eq 0 ]
  svc="$SYSTEMD_USER_DIR/issue-loop-owner-name.service"
  tmr="$SYSTEMD_USER_DIR/issue-loop-owner-name.timer"
  [ -f "$svc" ]
  [ -f "$tmr" ]
  contains "$(cat "$svc")" "Type=oneshot"
  contains "$(cat "$svc")" "WorkingDirectory=$REPO"
  contains "$(cat "$svc")" "Environment=PATH=%h/.local/bin:"
  contains "$(cat "$svc")" "ExecStart=/bin/bash $REPO/loop/run-issues.sh"
  contains "$(cat "$svc")" "TimeoutStartSec=7800"
  lacks "$(cat "$svc")" "EnvironmentFile"
  lacks "$(cat "$svc")" "network-online.target"
  contains "$(cat "$tmr")" "OnCalendar=*-*-* 03:00:00"
  contains "$(cat "$tmr")" "Persistent=true"
  lacks "$(cat "$tmr")" "RandomizedDelaySec"
  contains "$(cat "$tmr")" "Unit=issue-loop-owner-name.service"
  # printed, not run
  contains "$output" "systemctl --user daemon-reload && systemctl --user enable --now issue-loop-owner-name.timer"
  contains "$output" "sudo loginctl enable-linger"
  contains "$output" "GH_APP_ID"
  contains "$output" "GH_APP_INSTALLATION_ID"
  contains "$output" "GH_APP_KEY_FILE"
  contains "$output" "LOOP_TRUSTED_ACTORS"
  contains "$output" "LOOP_OPERATOR_HOME"
  contains "$output" '$HOME/.config/the-grid/issue-loop.env'
  [ ! -e "$HOME/.config/the-grid/issue-loop.env" ]
  [ ! -e "$HOME/.config/the-grid/app.pem" ]
  refute grep -qE '^(systemctl|launchctl|crontab) ' "$STUB_LOG"
  refute grep -q 'enable-linger' "$STUB_LOG"
}

@test "linux: TimeoutStartSec follows the effective (tuned) caps of an existing loop.conf" {
  inst --profile linux
  sed -i.bak 's/MAX_ISSUES:-3/MAX_ISSUES:-2/' "$REPO/loop/loop.conf"
  rm "$REPO/loop/loop.conf.bak"
  inst --profile linux
  [ "$status" -eq 0 ]
  contains "$output" "unit changed: run systemctl --user daemon-reload"
  contains "$(cat "$SYSTEMD_USER_DIR/issue-loop-owner-name.service")" "TimeoutStartSec=5400"
}

@test "linux: unit changes are announced only when a unit differs from disk" {
  inst --profile linux --schedule-hour 3
  lacks "$output" "unit changed"
  inst --profile linux --schedule-hour 3
  lacks "$output" "unit changed"
  inst --profile linux --schedule-hour 4
  contains "$output" "unit changed: run systemctl --user daemon-reload"
  contains "$(cat "$SYSTEMD_USER_DIR/issue-loop-owner-name.timer")" "OnCalendar=*-*-* 04:00:00"
}

@test "linux: linger on prints no warning and no crontab alternative" {
  export STUB_LINGER=yes
  inst --profile linux
  [ "$status" -eq 0 ]
  lacks "$output" "WARNING"
  lacks "$output" "crontab"
}

@test "linux: linger off warns, prints the enable command and one crontab line; nothing is run" {
  export STUB_LINGER=no
  inst --profile linux --schedule-hour 3
  [ "$status" -eq 0 ]
  contains "$output" "WARNING: linger is 'no'"
  contains "$output" "will NOT fire while you are logged out"
  contains "$output" "loginctl enable-linger"
  contains "$output" "00 03 * * * mkdir -p $HOME/.grid/logs && cd $REPO && /bin/bash $REPO/loop/run-issues.sh >> $HOME/.grid/logs/issue-loop-owner-name.log 2>&1"
  grep -q '^loginctl show-user .*--property=Linger --value' "$STUB_LOG"
  refute grep -q 'enable-linger' "$STUB_LOG"
  refute grep -qE '^(systemctl|launchctl|crontab) ' "$STUB_LOG"
}

@test "linux: a failing loginctl probe still exits 0 and is treated as unknown" {
  export STUB_LOGINCTL_FAIL=1
  inst --profile linux
  [ "$status" -eq 0 ]
  contains "$output" "WARNING: linger is 'unknown'"
  contains "$output" "crontab"
  refute grep -q 'enable-linger' "$STUB_LOG"
}

@test "an install path with a space is refused with exit 2 before anything is written" {
  mkdir "$T/my repo"
  git init -q -b main "$T/my repo"
  run --separate-stderr bash "$INST" issue-loop "$T/my repo" --repo owner/name --profile linux --project-context c --review-focus f
  [ "$status" -eq 2 ]
  contains "$stderr" "unsafe characters"
  contains "$stderr" "my repo"
  [ ! -d "$T/my repo/loop" ]
  [ ! -d "$SYSTEMD_USER_DIR" ]
  run --separate-stderr bash "$INST" issue-loop "$T/my repo" --repo owner/name --profile mac-mini --project-context c --review-focus f
  [ "$status" -eq 2 ]
  [ ! -d "$T/my repo/loop" ]
}

# -------------------------------------------------------------- mac-mini ---

@test "mac-mini defaults to pr mode and writes a launchd plist that runs the runner directly" {
  inst --profile mac-mini --schedule-hour 4
  [ "$status" -eq 0 ]
  contains "$(cat "$REPO/loop/loop.conf")" 'MODE=${MODE:-pr}'
  plist="$LAUNCH_AGENTS_DIR/io.the-grid.issue-loop.owner-name.plist"
  [ -f "$plist" ]
  p="$(cat "$plist")"
  contains "$p" "<string>io.the-grid.issue-loop.owner-name</string>"
  contains "$p" "run-issues.sh"
  contains "$p" "/.local/bin:"
  contains "$p" "/opt/homebrew/bin"
  lacks "$p" "<string>-l</string>"
  lacks "$p" "bash -l"
  contains "$p" "<integer>4</integer>"
  contains "$p" "$HOME/.grid/logs/io.the-grid.issue-loop.owner-name.log"
  [ -d "$HOME/.grid/logs" ]
  contains "$output" "launchctl bootstrap gui/"
  contains "$output" "auto-login"
  refute grep -qE '^(systemctl|launchctl|crontab) ' "$STUB_LOG"
  [ ! -d "$SYSTEMD_USER_DIR" ]
}

@test "--launchd-hour is an alias of --schedule-hour" {
  inst --profile mac-mini --launchd-hour 5
  [ "$status" -eq 0 ]
  contains "$(cat "$LAUNCH_AGENTS_DIR/io.the-grid.issue-loop.owner-name.plist")" "<integer>5</integer>"
}

# ------------------------------------------------------- no private values ---

@test "shipped scripts carry no absolute home paths, usernames or private repo names" {
  P="$BATS_TEST_DIRNAME/../automation-factory/patterns/issue-loop"
  refute grep -nE '/Users/|/home/|com\.gareth|oneafrikan|gkwilderness|garethknight|FinanceFlow' \
    "$INST" "$BATS_TEST_DIRNAME/../scripts/lib/render-schedule.sh" "$BATS_TEST_DIRNAME/../scripts/lib/gh-app-token.sh" \
    "$P/run-issues.sh" "$P/setup.sh" "$P/loop.conf.template" "$P/loop-prompt.template.md" "$P"/hooks/*.sh
}
