#!/usr/bin/env bash
#
# md-fast.sh — the ONE definition of a "markdown-only" change. Source it, don't run it.
#
# Read by BOTH consumers, so CI and the local gate can never disagree on the rule:
#   - .github/workflows/tests.yml  (`changes` job: decides which gate route a PR/push takes)
#   - scripts/gate.sh --fast       (refuses a change that is not markdown-only)
#
# Input is a list of changed paths, one per line, on stdin (repo-relative, renames listed as
# both sides). Nothing here touches git or the filesystem.
#
# md_fast_class prints exactly one word:
#   docs     the pre-existing docs-only rule, unchanged: every path is *.md and none is under a
#            directory whose markdown is executable content (skills, role prompts, rule packs,
#            plugin bundles, templates, hooks, eval cases, tests, workflows). CI runs the light
#            `docs` job for it.
#   md_fast  markdown-only (below) AND at least one path is under skills/, agents/ or
#            agent-factory/roles/. CI runs `gate.sh --fast` (the `fast` job) for it.
#   full     anything else, including no paths at all: when unsure, run the full gate.
#
# Markdown-only (the rule md_fast_markdown_only tests; every path must pass):
#   - ends in .md (frontmatter edits in SKILL.md / agent .md count: it is still a .md file)
#   - EXCEPT plugins/** and dist/**: regenerated output of the markdown above (plugin bundles,
#     personas), allowed with any extension because gate.sh --fast verifies it byte for byte
#     (build-plugins.py --check, build-personas.sh --check). Without this, any edit to a role or a
#     bundled skill would force the full gate, since its generated copy changes with it.
#   - is not other generated output: SKILLS.md, MAP.md, docs/SOURCES.md, README.<locale>.md
#     translations (--fast cannot verify them; a full gate checks them)
#   - is not under knowledge/canon/ (GUARDRAILS G7: a human merges canon) or tests/
#   - is not under rules/, project-factory/, automation-factory/, hooks/, evals/ or .github/:
#     markdown there is executable content that gate.sh --fast has no check for, so it takes the
#     full gate. (Tighter than the bare rule on purpose: a miss here costs minutes, not safety.)

# One path: is it generated output that --fast cannot verify? (0 = yes)
md_fast_is_generated() {
  case "$1" in
    SKILLS.md|MAP.md|docs/SOURCES.md|README.*.md) return 0 ;;
  esac
  return 1
}

# One path: is it generated output that --fast DOES verify (--check against its sources)? (0 = yes)
md_fast_is_verified_output() {
  case "$1" in plugins/*|dist/*) return 0 ;; esac
  return 1
}

# One path: does it satisfy the markdown-only rule? (0 = yes)
md_fast_path_ok() {
  md_fast_is_verified_output "$1" && return 0
  case "$1" in *.md) ;; *) return 1 ;; esac
  md_fast_is_generated "$1" && return 1
  case "$1" in
    knowledge/canon/*|tests/*|*/tests/*) return 1 ;;
    rules/*|project-factory/*|automation-factory/*|hooks/*|evals/*|.github/*) return 1 ;;
  esac
  return 0
}

# One path: does it satisfy the pre-existing docs-only rule? (0 = yes)
md_fast_path_docs() {
  case "$1" in
    skills/*|agents/*|agent-factory/*|rules/*|plugins/*|project-factory/*|automation-factory/*|hooks/*|evals/*|tests/*|.github/*) return 1 ;;
    *.md) return 0 ;;
  esac
  return 1
}

# md_fast_markdown_only — stdin: paths. Exit 0 when there is at least one path and all pass.
md_fast_markdown_only() {
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    md_fast_path_ok "$f" || return 1
  done
  [ "$n" -gt 0 ]
}

# md_fast_class — stdin: paths. Prints docs | md_fast | full (see the header).
md_fast_class() {
  local f n=0 docs=1 mdok=1 touches=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    md_fast_path_docs "$f" || docs=0
    md_fast_path_ok "$f" || mdok=0
    case "$f" in skills/*|agents/*|agent-factory/roles/*) touches=1 ;; esac
  done
  if [ "$n" -eq 0 ]; then echo full
  elif [ "$docs" = 1 ]; then echo docs
  elif [ "$mdok" = 1 ] && [ "$touches" = 1 ]; then echo md_fast
  else echo full
  fi
}
