#!/usr/bin/env bats
# Guards the depersonalise change, group 3: archived material stays out of the
# public tree, and nothing tracked still points at it. Reads the real repo
# (read-only: `git ls-files` / `git grep`), writes nothing.

REAL_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Paths removed in group 3 (the 22 files under __assets/ are covered by the
# directory check below).
REMOVED_PATHS=(
  __assets
  docs/playbook-ai-dev-team.md
  agent-factory/docs/openclaw-paperclip-targets-plan.md
  docs/openclaw-portfolio-desk-blueprint.md
  automation-factory/docs/gh-triage-to-issue-loop.md
  prompts/2026-06-13-openclaw-lamp-team-prompt.md
)

# Removed filenames/dirs that must no longer be referenced anywhere. Generic
# basenames from __assets (README.md, SKILL.md, ...) cannot be grepped, so the
# two distinctive names stand in for that tree.
REMOVED_NAMES=(
  __assets
  ClawGuides.zip
  playbook-ai-dev-team.md
  openclaw-paperclip-targets-plan.md
  openclaw-portfolio-desk-blueprint.md
  gh-triage-to-issue-loop.md
  2026-06-13-openclaw-lamp-team-prompt.md
)

@test "removed paths are absent from the working tree" {
  cd "$REAL_ROOT"
  for p in "${REMOVED_PATHS[@]}"; do
    [ ! -e "$p" ] || { echo "still present: $p"; return 1; }
  done
}

@test "removed paths are not tracked" {
  cd "$REAL_ROOT"
  for p in "${REMOVED_PATHS[@]}"; do
    [ -z "$(git ls-files -- "$p")" ] || { echo "still tracked: $p"; return 1; }
  done
}

@test "no tracked file still references a removed filename" {
  cd "$REAL_ROOT"
  # openspec/ holds the change plan that names these files, repos/ is upstream,
  # and docs/uplift-runbook.md is the runbook that documents this very removal.
  for n in "${REMOVED_NAMES[@]}"; do
    hits="$(git grep -n -F -e "$n" -- . ':!openspec' ':!repos' ':!docs/uplift-runbook.md' ':!tests/test_depersonalise.bats' || true)"
    [ -z "$hits" ] || { printf 'dangling reference to %s:\n%s\n' "$n" "$hits"; return 1; }
  done
}
