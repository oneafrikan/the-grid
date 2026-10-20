#!/usr/bin/env bats
# Guards against re-documenting the dropped skills-factory (#40).

GRID_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "public docs do not mention skills-factory" {
  cd "$GRID_ROOT"
  run grep -n "skills-factory" README.md CLAUDE.md automation-factory/README.md project-factory/README.md agent-factory/README.md
  # grep exits 1 when nothing matches
  [ "$status" -eq 1 ]
}

@test "skills-factory/ is absent or has tracked files" {
  cd "$GRID_ROOT"
  # An untracked/empty directory would be a dangling reference; absent or tracked is fine.
  if [ -d skills-factory ]; then
    [ -n "$(git ls-files skills-factory)" ]
  fi
}

# --- the issue-loop pattern is live (issue-loop-v2) --------------------------------------------
# The factory pattern under automation-factory/patterns/issue-loop/ is the one loop; the docs
# describe it as it is. The two greps below keep the old design's names and any retirement
# language from coming back. Their patterns use a one-character class ([p], [d]) so this file
# does not match its own search text.

@test "issue-loop pattern: the runner and its README ship; the multi-issue runner is gone" {
  cd "$GRID_ROOT"
  local p=automation-factory/patterns/issue-loop
  [ -f "$p/run-issue.sh" ]
  [ -f "$p/README.md" ]
  [ -f "$p/worker-prompt.template.md" ]
  [ -f scripts/instantiate.sh ]
  # wake.sh arrives with the waker stage (B2); that stage adds it to this list
  [ -z "$(git ls-files "$p" | grep -E 'run-issue[s]\.sh' || true)" ]
}

@test "no retirement language: automation-factory/ never calls the pattern retired, quarantined or abandoned" {
  cd "$GRID_ROOT"
  # this path holds no role archive, so no exclusion is needed
  run grep -rniE 'retired|quarantin|abandoned' automation-factory
  # grep exits 1 when nothing matches
  [ "$status" -eq 1 ]
}

# The paths a reader of the live docs sees. Never _retired/, openspec/, agent-factory/roles, dist/
# or plugins/: their copies of "do not deploy" are legitimate and the result must not depend on
# whether _retired/ still exists.
LIVE_DOC_PATHS="automation-factory scripts tests docs project-factory hooks README.md USAGE.md CLAUDE.md index.html"

@test "nothing left of the old design: its names appear in no live doc, script or test" {
  cd "$GRID_ROOT"
  # shellcheck disable=SC2086
  run git grep -nIiE '[L]OOP_OPERATOR_HOM[E]|GH_APP_I[D]|gh-app-toke[n]|run-issue[s]\.sh|secure-agent-loo[p]|RETIRE[D]\.md|_retired/issue-loo[p]' -- $LIVE_DOC_PATHS
  [ "$status" -eq 1 ]
}

@test "no live doc says the pattern is retired, quarantined or not to be deployed" {
  cd "$GRID_ROOT"
  # shellcheck disable=SC2086
  # Any non-alphanumeric run before "do not deploy" counts (dash, em dash, colon), not just " - ".
  run git grep -nIiE 'retire[d].*[l]oop|[l]oop.*retire[d]|quarantine[d].*[l]oop|RETIRE[D][^[:alnum:]]+do not deploy' -- $LIVE_DOC_PATHS
  [ "$status" -eq 1 ]
}

@test "shipped skills, plugins and the landing page pin the openspec CLI (no @latest)" {
  cd "$GRID_ROOT"
  # An unpinned npm install in text a user pastes is a supply-chain hole; the pin matches
  # skills/openspec-help/sections/the-grid-specifics.md.
  run grep -rn 'openspec@latest' skills plugins index.html
  [ "$status" -eq 1 ]
  grep -qF 'openspec@1.12.0' skills/grid-help/sections/orientation.md
}

# --- WP-071 (R25.qa.F12): count words equal what the tree has -----------------------------------

# word_to_num: one..eight as a number (the docs spell small counts out)
word_to_num() {
  case "$1" in
    one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;; five) echo 5 ;;
    six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;; *) echo "unknown count word: $1" >&2; echo -1 ;;
  esac
}

@test "README: the factory count word equals the rows of its factories table" {
  cd "$GRID_ROOT"
  rows="$(awk '/^\| Factory /{f=1; next} f && /^\|[-| ]+\|$/{next} f && /^\|/{n++; next} f{f=0} END{print n+0}' README.md)"
  word="$(grep -o -E 'one of [a-z]+ sibling factories' README.md | sed -E 's/one of ([a-z]+) .*/\1/')"
  [ -n "$word" ]
  [ "$rows" -ge 1 ]
  [ "$(word_to_num "$word")" -eq "$rows" ]
}

@test "README and CLAUDE: the public project count equals agent-factory/examples/*.yaml" {
  cd "$GRID_ROOT"
  n="$(ls agent-factory/examples/*.yaml | wc -l | tr -d ' ')"
  grep -q "$n public projects" README.md
  case "$n" in 3) w=three ;; 4) w=four ;; 5) w=five ;; *) w=unknown ;; esac
  grep -q -i "$w public projects" CLAUDE.md
}
