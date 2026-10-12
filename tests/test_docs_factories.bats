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

# --- the abandoned uplift issue-loop is quarantined (WP-043, D01=B) -------------------------
# The loop instance, its token minter, instantiate.sh and its four bats files live under
# _retired/issue-loop/ (not gated, not collected by bats). The factory PATTERN under
# automation-factory/patterns/issue-loop/ is NOT retired: it works and stays as shipped.

@test "retired loop: no live loop dir, minter, instantiate.sh or loop test is tracked" {
  cd "$GRID_ROOT"
  [ -z "$(git ls-files loop scripts/instantiate.sh scripts/lib/gh-app-token.sh)" ]
  # bats collects tests/*.bats only; none of the four loop files may remain there
  [ -z "$(git ls-files tests | grep -E 'issue_loop|instantiate|gh_app_token' || true)" ]
}

@test "retired loop: the quarantine holds the moved files" {
  cd "$GRID_ROOT"
  for f in loop/run-issues.sh scripts/instantiate.sh scripts/lib/gh-app-token.sh \
           tests/test_issue_loop_hooks.bats tests/test_issue_loop_runner.bats \
           tests/test_gh_app_token.bats tests/test_instantiate.bats; do
    [ -f "_retired/issue-loop/$f" ] || { echo "missing _retired/issue-loop/$f"; false; }
  done
}

@test "retired loop: the factory pattern is NOT retired (operator carve-out)" {
  cd "$GRID_ROOT"
  [ -f automation-factory/patterns/issue-loop/run-issues.sh ]
  [ -f automation-factory/patterns/issue-loop/README.md ]
  # nothing under automation-factory/ carries the retired banner: the factory is not retired
  # (its pattern README gets a status note, the generic playbook a neutral one)
  ! grep -rqiE 'retired[ -]+do not deploy' automation-factory
}

@test "retired loop docs carry the banner" {
  cd "$GRID_ROOT"
  run grep -l 'RETIRED - do not deploy' docs/uplift-runbook.md \
    _retired/issue-loop/loop/README.md _retired/issue-loop/RETIRED.md
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 3 ]
}

@test "the generic secure-loop playbook carries a neutral status note, not the retired banner" {
  cd "$GRID_ROOT"
  local f=automation-factory/docs/secure-agent-loop.md
  # the note points at RETIRED.md and says the instance (not the playbook) is retired
  head -n 3 "$f" | grep -q '_retired/issue-loop/RETIRED.md'
  head -n 3 "$f" | grep -qi 'instance'
  head -n 3 "$f" | grep -qi 'validate'
  # the factual status paragraph and the table annotation stay
  grep -q 'Status of the code this playbook drives' "$f"
  grep -q 'not enforced, see RETIRED.md' "$f"
}

@test "retired loop: RETIRED.md exists and names the GitHub cleanup order" {
  cd "$GRID_ROOT"
  [ -f _retired/issue-loop/RETIRED.md ]
  # D01 order: App private keys + App first, then replace the ruleset, then the sandbox repo
  local k r s
  k="$(grep -n 'private key' _retired/issue-loop/RETIRED.md | head -n1 | cut -d: -f1)"
  r="$(grep -n 'next-needs-pr' _retired/issue-loop/RETIRED.md | head -n1 | cut -d: -f1)"
  s="$(grep -n 'grid-loop-sandbox' _retired/issue-loop/RETIRED.md | head -n1 | cut -d: -f1)"
  [ -n "$k" ]
  [ -n "$r" ]
  [ -n "$s" ]
  [ "$k" -lt "$r" ]
  [ "$r" -lt "$s" ]
  # the known-defects table carries every record family
  grep -q 'R10.qa.F1' _retired/issue-loop/RETIRED.md
  grep -q 'R10.sec.F12' _retired/issue-loop/RETIRED.md
  grep -q 'R25.qa.F6' _retired/issue-loop/RETIRED.md
}

@test "retired loop: disproved claims are marked in the docs, not left standing" {
  cd "$GRID_ROOT"
  grep -q 'not enforced, see RETIRED.md' _retired/issue-loop/loop/README.md
  grep -q 'not enforced, see RETIRED.md' docs/uplift-runbook.md
  grep -q 'not enforced, see RETIRED.md' automation-factory/docs/secure-agent-loop.md
  ! grep -q 'specified, not yet merged' automation-factory/docs/secure-agent-loop.md
}

@test "retired loop: the pointer docs say retired" {
  cd "$GRID_ROOT"
  # CLAUDE.md names the loop only to say it is retired
  grep -n 'issue-loop' CLAUDE.md | grep -qi 'retired'
  grep -n 'instantiate.sh' README.md | grep -qi 'retired'
  grep -n 'instantiate.sh' USAGE.md | grep -qi 'retired'
  grep -n 'instantiate.sh' index.html | grep -qi 'retired'
  grep -n 'instantiate.sh' automation-factory/README.md | grep -qi 'retired'
  # the pattern README gets a status note pointing at the quarantine
  grep -q '_retired/issue-loop/RETIRED.md' automation-factory/patterns/issue-loop/README.md
}
