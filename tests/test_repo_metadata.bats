#!/usr/bin/env bats
# Tests for scripts/repo-metadata.sh. Only the gh stub from helpers/stubs.bash is ever
# called (argv in $STUB_LOG): no real gh, no network, no change to a real repo.

load helpers/setup
load helpers/stubs

SCRIPT="$REPO_ROOT/scripts/repo-metadata.sh"
DESC='Dotfiles for your AI assistant: curated skills and agent teams, wired identically onto every machine. Claude Code today, more AI tools next.'
HOME_URL='https://oneafrikan.github.io/the-grid/'
TOPICS="claude-code claude-skills claude-code-skills agent-skills ai-agents dotfiles subagents skills-manager developer-tools"

setup() {
  common_setup
  make_stubs
  # Throwaway HOME so git never reads the real global config.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export STUB_GH_STORED_LOGIN=1
  export GRID_REPO=owner/name
}

teardown() {
  clean_stubs
  common_teardown
}

# repo_json <description> <homepage> <shape> <topic>... — gh repo view JSON.
# shape: name = [{"name":..}], nested = [{"topic":{"name":..}}], null = no topics.
repo_json() {
  local d="$1" h="$2" shape="$3" t list=""
  shift 3
  for t in "$@"; do
    if [ "$shape" = nested ]; then list="$list,{\"topic\":{\"name\":\"$t\"}}"; else list="$list,{\"name\":\"$t\"}"; fi
  done
  if [ "$shape" = null ]; then list=null; else list="[${list#,}]"; fi
  printf '{"description":"%s","homepageUrl":"%s","repositoryTopics":%s}' "$d" "$h" "$list"
}

# shellcheck disable=SC2086  # $TOPICS is a word list
@test "--check exits 0 when description, homepage and topics match (name shape)" {
  STUB_REPO_VIEW_JSON="$(repo_json "$DESC" "$HOME_URL" name $TOPICS)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  contains "$output" "matches"
}

# shellcheck disable=SC2086
@test "default mode is --check and accepts the nested topic shape, in any order" {
  # shellcheck disable=SC2046
  STUB_REPO_VIEW_JSON="$(repo_json "$DESC" "$HOME_URL" nested $(printf '%s\n' $TOPICS | sort -r))" run bash "$SCRIPT" --check
  [ "$status" -eq 0 ]
}

@test "repositoryTopics null reports every declared topic missing, exit 1" {
  STUB_REPO_VIEW_JSON="$(repo_json "$DESC" "$HOME_URL" null)" run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  local t
  for t in $TOPICS; do contains "$output" "topic missing: + $t"; done
}

# shellcheck disable=SC2086
@test "a differing description exits 1 and prints a diff" {
  STUB_REPO_VIEW_JSON="$(repo_json "old text" "$HOME_URL" name $TOPICS)" run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  contains "$output" "description differs"
  contains "$output" "- old text"
  contains "$output" "+ $DESC"
}

@test "a missing and an extra topic exit 1 and are both printed" {
  STUB_REPO_VIEW_JSON="$(repo_json "$DESC" "$HOME_URL" name claude-code stray-topic)" run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  contains "$output" "topic missing: + dotfiles"
  contains "$output" "topic extra: - stray-topic"
  # whole-line match: "claude-code" is a prefix of "claude-code-skills"
  refute grep -qx 'topic missing: + claude-code' <<< "$output"
}

@test "--check never calls gh repo edit" {
  STUB_REPO_VIEW_JSON="$(repo_json "old" "" null)" run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  grep -q 'gh repo view owner/name' "$STUB_LOG"
  refute grep -q 'repo edit' "$STUB_LOG"
}

@test "--apply edits description+homepage once and each topic once" {
  STUB_REPO_VIEW_JSON="$(repo_json "old" "" name claude-code stray-topic)" run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ "$(grep -c 'repo edit' "$STUB_LOG")" -eq 10 ]   # 1 meta + 8 missing topics + 1 extra
  grep -qF "gh repo edit owner/name --description $DESC --homepage $HOME_URL" "$STUB_LOG"
  grep -qF 'gh repo edit owner/name --add-topic dotfiles' "$STUB_LOG"
  grep -qF 'gh repo edit owner/name --remove-topic stray-topic' "$STUB_LOG"
  refute grep -q -- '--add-topic claude-code ' "$STUB_LOG"
}

# shellcheck disable=SC2086
@test "--apply on a matching repo calls no gh repo edit" {
  STUB_REPO_VIEW_JSON="$(repo_json "$DESC" "$HOME_URL" name $TOPICS)" run bash "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  refute grep -q 'repo edit' "$STUB_LOG"
}

@test "repo parsed from an ssh host-alias remote" {
  unset GRID_REPO
  git init -q "$BATS_TEST_TMPDIR/r"
  git -C "$BATS_TEST_TMPDIR/r" remote add origin git@work-alias:acme/widgets.git
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  grep -q 'gh repo view acme/widgets --json' "$STUB_LOG"
}

@test "repo parsed from an https remote, with and without .git" {
  unset GRID_REPO
  git init -q "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  git remote add origin https://github.com/acme/widgets.git
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  git remote set-url origin https://github.com/acme/gadgets
  run bash "$SCRIPT" --check
  [ "$status" -eq 1 ]
  grep -q 'gh repo view acme/widgets --json' "$STUB_LOG"
  grep -q 'gh repo view acme/gadgets --json' "$STUB_LOG"
}

@test "no GRID_REPO and no origin remote is a clear error (exit 2)" {
  unset GRID_REPO
  git init -q "$BATS_TEST_TMPDIR/r"
  cd "$BATS_TEST_TMPDIR/r"
  run bash "$SCRIPT" --check
  [ "$status" -eq 2 ]
  contains "$output" "origin"
}

@test "unauthenticated gh fails clearly before any repo call" {
  STUB_GH_STORED_LOGIN=0 run bash "$SCRIPT" --check
  [ "$status" -eq 2 ]
  contains "$output" "not authenticated"
  refute grep -q 'repo view' "$STUB_LOG"
}

@test "missing gh fails clearly" {
  PATH="$(path_without gh)" run bash "$SCRIPT" --check
  [ "$status" -eq 2 ]
  contains "$output" "gh is not installed"
}
