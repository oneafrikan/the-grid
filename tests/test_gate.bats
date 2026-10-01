#!/usr/bin/env bats
# Tests for scripts/gate.sh — the commit gate. Each test runs a COPY of the gate
# inside a throwaway git repo with stub tools, so it never touches this repo's
# config, hook path or working tree.

load helpers/setup

setup() {
  common_setup
  G=$(mktemp -d)
  mkdir -p "$G/scripts" "$G/.githooks" "$G/tests/lib/bats-core/bin" "$G/stubbin"
  cp "$REPO_ROOT/scripts/gate.sh" "$G/scripts/gate.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/scripts/catalog.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$G/.githooks/pre-commit"
  printf '#!/usr/bin/env bash\necho "1..0"\nexit 0\n' > "$G/tests/lib/bats-core/bin/bats"
  chmod +x "$G"/scripts/*.sh "$G/.githooks/pre-commit" "$G/tests/lib/bats-core/bin/bats"
  ( cd "$G" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init )
  # PATH with essentials but no shellcheck
  for t in git bash env dirname grep cat rm mktemp uname sed; do
    ln -s "$(command -v $t)" "$G/stubbin/$t" 2>/dev/null || true
  done
}

teardown() {
  rm -rf "$G"
  common_teardown
}

run_gate() { ( cd "$G" && env -i HOME="$G" PATH="$G/stubbin" bash scripts/gate.sh "$@" ); }

@test "missing shellcheck, venv and baseline are skipped LOUDLY, not failed" {
  run run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate: PASS (skipped:"* ]] || false
  [[ "$output" == *"shellcheck"* ]] || false
  [[ "$output" == *"catalog"* ]] || false
  [[ "$output" == *"compose"* ]] || false
}

@test "a missing bats submodule is a FAIL with a hint, not a silent pass" {
  rm "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"git submodule update --init"* ]] || false
  [[ "$output" == *"gate: FAIL"* ]] || false
}

@test "--pre-commit aborts on unstaged changes to tracked files" {
  echo x >> "$G/scripts/catalog.sh"
  run run_gate --pre-commit
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABORT"* ]] || false
}

@test "the first run installs the hook path in the repo it runs in" {
  run run_gate
  [ "$(cd "$G" && git config --get core.hooksPath)" = ".githooks" ]
}

@test "a failing check is named in the summary and the rest still run" {
  printf '#!/usr/bin/env bash\necho BOOM\nexit 1\n' > "$G/tests/lib/bats-core/bin/bats"
  run run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate: FAIL — bats"* ]] || false
  [[ "$output" == *"==> catalog"* ]] || false      # earlier/other checks still ran
}
