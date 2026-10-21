#!/usr/bin/env bats
# scripts/map.py --check, knowledge lint scaffold (change `epistemic-enforcement`, spec
# `map-lint`): after the MAP.md drift check it lints signals/ and knowledge/ through
# knowledge.check_tree. Every case runs in a throwaway git repo under the test temp dir.

load helpers/setup

setup() {
  common_setup
  P="$BATS_TEST_TMPDIR/proj"
}

teardown() {
  # A chmod 000 file would make the temp dir cleanup noisy; restore it first.
  chmod -R u+rwX "$P" 2>/dev/null || true
  common_teardown
}

# mk_proj [with-signals] — a temp git repo holding copies of map.py and knowledge.py and a
# current, committed MAP.md. With `with-signals` it also holds one valid pending signal, so
# the lint has something to read. Identity comes from the environment (no address in this
# file) and no user or system git config is read.
mk_proj() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL="t@${HOSTNAME:-h}.test" GIT_COMMITTER_NAME=t \
    GIT_COMMITTER_EMAIL="t@${HOSTNAME:-h}.test" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$P/scripts"
  cp "$REPO_ROOT/scripts/map.py" "$REPO_ROOT/scripts/knowledge.py" "$P/scripts/"
  git -C "$P" init -q
  if [ "${1:-}" = with-signals ]; then
    mkdir -p "$P/signals"
    printf -- '---\nfiled_by: agent-a\nclaim: use the gate\nstage: wip\nwarrant: seen in CI\nstatus: pending\n---\n' \
      > "$P/signals/$SIG"
  fi
  git -C "$P" add -A
  git -C "$P" commit -q -m base
  # MAP.md lists tracked files, so it is generated after the first commit, then committed.
  python3 "$P/scripts/map.py" --root "$P"
  git -C "$P" add -A
  git -C "$P" commit -q -m map
}

SIG=20261018T101500Z-agent-a-abc123.md

# lint — run the check against the fixture; stderr is part of $output.
lint() {
  run python3 "$P/scripts/map.py" --check --root "$P"
}

@test "clean tree: exit 0 and no E_ line" {
  mk_proj with-signals
  lint
  [ "$status" -eq 0 ]
  ! grep -q '^E_' <<<"$output" || false
  [ -z "$output" ]
}

@test "no knowledge.py: one notice, and the exit code is the drift result" {
  mk_proj with-signals
  rm "$P/scripts/knowledge.py"
  lint
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == "map.py: knowledge lint skipped ("*")" ]]
  # A stale MAP.md still fails, with the drift text first and the same single notice.
  printf 'extra\n' >> "$P/MAP.md"
  lint
  [ "$status" -eq 1 ]
  [ "$(grep -c 'knowledge lint skipped' <<<"$output")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | head -n 1)" = "MAP.md is stale" ]
}

@test "neither signals/ nor knowledge/: one notice and exit 0" {
  mk_proj
  lint
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [[ "$output" == "map.py: knowledge lint skipped ("*")" ]]
}

@test "an unreadable linted file exits 2 and names the file" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a chmod 000 file"
  mk_proj with-signals
  chmod 000 "$P/signals/$SIG"
  lint
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read signals/$SIG"* ]]
}

@test "a tree with findings: exit 1, findings after drift output, git status unchanged" {
  mk_proj with-signals
  # An unknown stage is a finding; the committed file is not edited, only replaced by a new one.
  printf -- '---\nfiled_by: agent-b\nclaim: a draft\nstage: draft\nwarrant: seen in CI\nstatus: pending\n---\n' \
    > "$P/signals/20261018T101600Z-agent-b-abc124.md"
  git -C "$P" add -A
  git -C "$P" commit -q -m second
  # The signals dir is already tracked, so MAP.md is still current: only the lint speaks.
  before=$(git -C "$P" status --porcelain)
  lint
  after=$(git -C "$P" status --porcelain)
  [ "$status" -eq 1 ]
  [[ "$output" == "E_"*" signals/20261018T101600Z-agent-b-abc124.md: "* ]]
  [ "$before" = "$after" ]
  [ -z "$after" ]
}
