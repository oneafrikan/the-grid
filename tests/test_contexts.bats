#!/usr/bin/env bats
# Tests for contexts/ (workflow-upgrades group 1): the three context files and the
# sourced alias snippet contexts/aliases.sh.
#
# Safety: a stub `claude` is first on PATH and only records its argv, so the real
# binary can never run. Every alias is invoked through `eval` inside `bash -c` /
# `zsh -c`: aliases are expanded when a command line is PARSED, so a bare
# `claude-dev foo` in the same -c string as `source` would fail with
# "command not found" (the alias does not exist yet when that string is parsed).

load helpers/setup

setup() {
  common_setup
  # Stub claude: write each argument on its own line so tests can compare exactly.
  STUB_DIR=$(mktemp -d)
  ARGV_FILE="$STUB_DIR/argv"
  cat > "$STUB_DIR/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGV_FILE"
EOF
  chmod +x "$STUB_DIR/claude"
  export ARGV_FILE
  ALIASES="$REPO_ROOT/contexts/aliases.sh"
  # A throwaway GRID_DIR tree holding all three context files.
  mkdir -p "$MOCK_GRID/contexts"
  for f in dev research review; do echo "# $f" > "$MOCK_GRID/contexts/$f.md"; done
}

teardown() {
  rm -rf "$STUB_DIR"
  common_teardown
}

# run_in SHELL NAME [ENV...]: source aliases.sh in SHELL from a cwd that is NOT the
# repo root, then invoke alias NAME with the argument "foo" via eval.
# Extra args are env assignments (e.g. GRID_DIR=/x) passed to `env`; GRID_DIR is
# unset first so the caller's environment cannot change the result.
run_in() {
  local sh="$1" name="$2"; shift 2
  cd "$OTHER_DIR"
  run env -u GRID_DIR "$@" PATH="$STUB_DIR:$PATH" \
    "$sh" -c 'shopt -s expand_aliases 2>/dev/null; source "$1"; eval "$2 foo"' _ "$ALIASES" "$name"
}

# Compare the recorded argv with the three expected lines.
assert_argv() {
  local expected
  expected=$(printf '%s\n' "--append-system-prompt-file" "$1" "foo")
  [ "$(cat "$ARGV_FILE")" = "$expected" ]
}

@test "each context file exists and is at most 1200 bytes" {
  for f in dev research review; do
    [ -f "$REPO_ROOT/contexts/$f.md" ]
    size=$(wc -c < "$REPO_ROOT/contexts/$f.md")
    [ "$size" -le 1200 ]
  done
}

@test "review.md hands release-gate reviews to qa-engineer and security-reviewer" {
  grep -q 'qa-engineer' "$REPO_ROOT/contexts/review.md"
  grep -q 'security-reviewer' "$REPO_ROOT/contexts/review.md"
}

@test "claude-dev passes --append-system-prompt-file <dir>/dev.md and extra args (bash, cwd elsewhere)" {
  run_in bash claude-dev
  [ "$status" -eq 0 ]
  assert_argv "$REPO_ROOT/contexts/dev.md"
}

@test "claude-research passes its context file (bash)" {
  run_in bash claude-research
  [ "$status" -eq 0 ]
  assert_argv "$REPO_ROOT/contexts/research.md"
}

@test "claude-review passes its context file (bash)" {
  run_in bash claude-review
  [ "$status" -eq 0 ]
  assert_argv "$REPO_ROOT/contexts/review.md"
}

@test "all three aliases work under zsh" {
  command -v zsh >/dev/null || skip "zsh not installed"
  for pair in dev:claude-dev research:claude-research review:claude-review; do
    rm -f "$ARGV_FILE"
    run_in zsh "${pair#*:}"
    [ "$status" -eq 0 ]
    assert_argv "$REPO_ROOT/contexts/${pair%%:*}.md"
  done
}

@test "GRID_DIR is honoured" {
  run_in bash claude-dev GRID_DIR="$MOCK_GRID"
  [ "$status" -eq 0 ]
  assert_argv "$MOCK_GRID/contexts/dev.md"
}

@test "alias definition uses --append-system-prompt-file, never --system-prompt-file" {
  cd "$OTHER_DIR"
  run env -u GRID_DIR bash -c 'shopt -s expand_aliases; source "$1"; alias claude-dev' _ "$ALIASES"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--append-system-prompt-file"* ]]
  # A bare --system-prompt-file preceded by a space would be the replacing flag.
  [[ "$output" != *" --system-prompt-file"* ]]
}

@test "a missing context file leaves only that alias undefined" {
  rm "$MOCK_GRID/contexts/research.md"
  cd "$OTHER_DIR"
  run env -u GRID_DIR GRID_DIR="$MOCK_GRID" bash -c 'shopt -s expand_aliases; source "$1"; alias claude-dev && alias claude-review' _ "$ALIASES"
  [ "$status" -eq 0 ]
  run env -u GRID_DIR GRID_DIR="$MOCK_GRID" bash -c 'shopt -s expand_aliases; source "$1"; alias claude-research' _ "$ALIASES"
  [ "$status" -ne 0 ]
}

@test "sourcing leaves no helper variables behind and writes no files" {
  cd "$OTHER_DIR"
  run env -u GRID_DIR bash -c 'source "$1"; set | grep -c "^_grid_ctx_"; ls -A "$2" | wc -l' _ "$ALIASES" "$OTHER_DIR"
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "0" ]
}
