#!/usr/bin/env bats
# A project cut from a template carries the whole knowledge layout and a working helper, so it can
# file and check signals with no the-grid install. Cuts only into temp dirs.

load helpers/setup

setup() {
  common_setup
  CUT="$REPO_ROOT/project-factory/scripts/cut-project.sh"
  P=$(mktemp -d)
  # Every stage directory the seed must carry, each with a .gitkeep so git tracks it empty.
  STAGES="wip provisional established canon superseded retired"
}

teardown() {
  rm -rf "$P"
  common_teardown
}

# knowledge_files — checksum of every file this feature seeds, to prove a re-cut leaves bytes alone.
knowledge_files() {
  (cd "$P" && sha256sum signals/README.md knowledge/README.md scripts/knowledge.py \
    $(for s in $STAGES; do echo "knowledge/$s/.gitkeep"; done))
}

@test "seeding an empty directory creates the signals and knowledge layout and the helper" {
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ -f "$P/signals/README.md" ]
  grep -q 'YYYYMMDDTHHMMSSZ>-<filer>-<hash6>.md' "$P/signals/README.md"
  grep -q 'No secrets or personal data in a signal' "$P/signals/README.md"
  [ -f "$P/knowledge/README.md" ]
  for s in $STAGES; do [ -f "$P/knowledge/$s/.gitkeep" ] || { echo "missing: knowledge/$s/.gitkeep"; return 1; }; done
  [ -f "$P/scripts/knowledge.py" ]
  cmp "$P/scripts/knowledge.py" "$REPO_ROOT/scripts/knowledge.py"
}

@test "the seeded helper files a signal that its own check accepts, and an untouched seed checks clean" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  cd "$P"
  # The seed has no .git: --root names the project explicitly.
  run python3 -I scripts/knowledge.py check --root "$P"
  [ "$status" -eq 0 ]
  KNOWLEDGE_NOW=20261018T101500Z run python3 -I scripts/knowledge.py file --root "$P" \
    --filer agent-a --claim "use the gate" --stage provisional --warrant "seen in CI"
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  run python3 -I scripts/knowledge.py check --root "$P"
  [ "$status" -eq 0 ]
}

@test "a retrofit keeps a differing signals/README.md, lists it as SKIPPED, and still writes the rest" {
  mkdir -p "$P/signals"
  echo "my own signals readme" > "$P/signals/README.md"
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ "$(cat "$P/signals/README.md")" = "my own signals readme" ]
  [[ "$output" == *"SKIPPED"*"signals/README.md"* ]] || false
  [ -f "$P/knowledge/README.md" ]
  [ -f "$P/knowledge/canon/.gitkeep" ]
  cmp "$P/scripts/knowledge.py" "$REPO_ROOT/scripts/knowledge.py"
}

@test "a second cut into the same directory leaves the knowledge files byte-identical" {
  bash "$CUT" python-agents-base "$P" >/dev/null
  before=$(knowledge_files)
  run bash "$CUT" python-agents-base "$P"
  [ "$status" -eq 0 ]
  [ "$(knowledge_files)" = "$before" ]
}
