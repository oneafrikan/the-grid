#!/usr/bin/env bats
# Fidelity of the fake external commands in tests/helpers/stubs.bash (R16.qa.F10): a stub
# that answers differently from the real tool lets a caller's mistake pass unseen. Each
# test pins ONE behaviour of the real tool the stub must copy.

load helpers/setup
load helpers/stubs

setup() {
  common_setup
  make_stubs
  # Tripwire: every call below must reach a stub, never the real tool.
  case "$(command -v claude)" in "$STUB_DIR"/*) ;; *) echo "claude is not the stub" >&2; return 1 ;; esac
}

teardown() {
  clean_stubs
  common_teardown
}

@test "claude stub: auth status exits 0 when logged in" {
  run claude auth status --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"loggedIn": true'* ]]
}

@test "claude stub: auth status exits 1 when logged out, like the real claude" {
  STUB_CLAUDE_LOGGED_IN=0 run claude auth status --json
  [ "$status" -eq 1 ]
  [[ "$output" == *'"loggedIn": false'* ]]
}

@test "gh stub: issue create prints the new issue URL (STUB_NEW_ISSUE, default 201) and is logged" {
  run gh issue create --repo owner/name --title t --body b
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/owner/name/issues/201" ]
  STUB_NEW_ISSUE=7 run gh issue create --repo owner/name --title t --body b
  [ "$output" = "https://github.com/owner/name/issues/7" ]
  [ "$(grep -c '^gh issue create' "$STUB_LOG")" -eq 2 ]
}

@test "timeout stub: drops -k/--kill-after, -s/--signal, --foreground and --preserve-status" {
  local opts
  for opts in "-k 5" "--kill-after 5" "--kill-after=5" "-k5" "-s KILL" "--signal KILL" "--signal=KILL" \
              "-sKILL" "--foreground" "--preserve-status" "-k 5 -s TERM --foreground --preserve-status"; do
    # $opts is deliberately unquoted: it is a list of separate words.
    # shellcheck disable=SC2086
    run timeout $opts 30 echo ran
    echo "options '$opts': $output"
    [ "$status" -eq 0 ]
    [ "$output" = "ran" ]
  done
}

@test "timeout stub: a plain SECS command still runs it" {
  run timeout 30 echo ran
  [ "$status" -eq 0 ]
  [ "$output" = "ran" ]
}
