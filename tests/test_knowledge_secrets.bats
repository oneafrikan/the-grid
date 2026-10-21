#!/usr/bin/env bats
# The commit-time secret scan covers signals/*.md: a token in a signal's warrant line is
# blocked by pre-bash-secret-scan, with file and line named and the value never printed.
# Spec: openspec/changes/knowledge-signals, signal-format ("Committed through Claude Code
# with the guard on"); tasks 5.1 and 5.4. Test only: the hook is not changed here. If case 1
# ever fails because the hook exempts a path or extension, that is a finding for the operator.
#
# The token is assembled from fragments at run time, so this file holds no complete token.

load helpers/setup
load helpers/hooks

setup() {
  common_setup
  # Same sandbox as tests/test_hooks.bats: temp HOME, no real or system git config.
  export HOME="$MOCK_HOOK_ROOT/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
}

teardown() {
  common_teardown
}

# mkrepo: a scratch git repo $R with one committed file (pattern copied from test_hooks.bats).
mkrepo() {
  R="$MOCK_HOOK_ROOT/repo"
  rm -rf "$R"; mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  echo base > "$R/base.txt"
  git -C "$R" add base.txt
  git -C "$R" commit -q -m init
}

# tok_ghp: a GitHub-token-shaped value (40 characters after the prefix), split so no
# whole token sits in this file.
tok_ghp() {
  local body="" i
  for ((i = 0; i < 8; i++)); do body+="Ab3dE"; done
  printf '%s' "gh""p_$body"
}

# SIG: a valid signal file name (<UTC timestamp>-<filer>-<hash6>.md), so the test is about
# secrets and not about signal grammar.
SIG="signals/20261018T101500Z-qa-agent-3f9a1c.md"

# write_signal: write $SIG in $R with the token in its warrant line (line 5 of the file).
write_signal() {
  mkdir -p "$R/signals"
  {
    echo "---"
    echo "filed_by: qa-agent"
    echo "claim: A claim with a warrant."
    echo "stage: provisional"
    echo "warrant: Ran the check and saw $(tok_ghp) in the log."
    echo "status: pending"
    echo "---"
  } > "$R/$SIG"
}

# assert_blocked_without_value: exit 2, file and line named, the token value absent.
assert_blocked_without_value() {
  [ "$status" -eq 2 ] || { echo "expected BLOCK (exit 2), got $status: $output" >&2; return 1; }
  [[ "$output" == *"$SIG:5: github-token"* ]] || { echo "file and line not named: $output" >&2; return 1; }
  [[ "$output" != *"$(tok_ghp)"* ]] || { echo "token value printed: $output" >&2; return 1; }
}

@test "signal secret: a staged signal with a token is blocked, value not printed" {
  mkrepo
  write_signal
  git -C "$R" add "$SIG"
  run_hook pre-bash-secret-scan "$(hook_payload 'git commit -m x' "$R")"
  assert_blocked_without_value
}

@test "signal secret: git add and git commit in one command is blocked too" {
  mkrepo
  write_signal   # not staged: the hook runs before the add, so it must read the working tree
  run_hook pre-bash-secret-scan "$(hook_payload "git add $SIG && git commit -m x" "$R")"
  assert_blocked_without_value
}
