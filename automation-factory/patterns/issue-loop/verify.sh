#!/usr/bin/env bash
# loop/verify.sh — an optional FAST VERIFY_CMD for the issue-loop (select it with
# `VERIFY_CMD='bash loop/verify.sh'` in loop/loop.conf, or `instantiate.sh --fast-verify`).
#
# A full test suite can take far longer than a loop run should. This is the quick sanity pass
# over what the branch changed; the repo's full CI on the pull request stays the authoritative
# gate. Steps, each SKIPPED (with a line saying so) when its tool or input is absent:
#   1. shellcheck on changed shell scripts
#   2. a syntax check on changed Python files
#   3. bats files the branch changed, plus every tests/*.bats that mentions a changed script
#   4. changed Markdown: no leftover merge-conflict markers
#   5. rules/ changed and scripts/rules.py exists: `python3 scripts/rules.py lint`
# Run from the issue worktree. Exit 1 if any step fails, or if there are no changes at all.
#
# Bash 3.2 compatible (macOS): no mapfile, no associative arrays, empty arrays guarded for set -u.
set -uo pipefail

# Base to diff against: VERIFY_BASE, else origin/<BASE_BRANCH from loop.conf>, else origin/main.
# loop.conf is only assignments; read it in a subshell so nothing leaks into this script.
if [ -z "${VERIFY_BASE:-}" ]; then
  _conf="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)/loop.conf"
  _branch=""
  # shellcheck disable=SC1090
  [ ! -f "$_conf" ] || _branch="$( . "$_conf" >/dev/null 2>&1; printf '%s' "${BASE_BRANCH:-}" )"
  VERIFY_BASE="origin/${_branch:-main}"
fi
BASE="$VERIFY_BASE"
rc=0

# Everything this branch changes against its merge-base with BASE: committed, staged, unstaged
# and untracked (the worker may run this before it commits). Deletions are skipped.
mb="$(git merge-base "$BASE" HEAD)" || { echo "verify: no merge-base with $BASE" >&2; exit 1; }
changed="$({ git diff --name-only --diff-filter=d "$mb"; git ls-files -o --exclude-standard; } | sort -u)"
if [ -z "$changed" ]; then
  echo "verify: no changes yet against $BASE; make your edits first (uncommitted edits count)" >&2
  exit 1
fi

sh_files=(); py_files=(); bats_files=(); md_files=(); rules_changed=0
while IFS= read -r f; do
  case "$f" in
    repos/*) continue ;;                   # submodule pointers are not ours to lint
    rules/*) rules_changed=1 ;;
  esac
  case "$f" in
    *.sh|*.bash) sh_files+=("$f") ;;
    *.py) py_files+=("$f") ;;
    tests/*.bats) bats_files+=("$f") ;;
    *.md) md_files+=("$f") ;;
  esac
done <<EOF
$changed
EOF

# Tests that mention a changed script by basename (scripts/stage-site.sh -> test_pages_site.bats).
if [ "${#sh_files[@]}" -gt 0 ]; then
  for f in "${sh_files[@]}"; do
    while IFS= read -r t; do bats_files+=("$t"); done <<EOF
$(grep -l -F "$(basename "$f")" tests/*.bats 2>/dev/null || true)
EOF
  done
fi
# De-duplicate; keep only files that exist.
uniq_bats=()
if [ "${#bats_files[@]}" -gt 0 ]; then
  while IFS= read -r t; do
    [ -n "$t" ] && [ -f "$t" ] && uniq_bats+=("$t")
  done <<EOF
$(printf '%s\n' "${bats_files[@]}" | sort -u)
EOF
fi

# 1. shellcheck
if [ "${#sh_files[@]}" -gt 0 ]; then
  if command -v shellcheck >/dev/null 2>&1; then
    echo "verify: shellcheck ${sh_files[*]}"
    shellcheck -S warning "${sh_files[@]}" || rc=1
  else
    echo "verify: skip shellcheck (not installed)"
  fi
fi

# 2. python syntax
if [ "${#py_files[@]}" -gt 0 ]; then
  if command -v python3 >/dev/null 2>&1; then
    for f in "${py_files[@]}"; do
      echo "verify: py syntax $f"
      python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || rc=1
    done
  else
    echo "verify: skip python syntax (python3 not installed)"
  fi
fi

# 3. bats (the repo's vendored copy, else one on PATH)
if [ "${#uniq_bats[@]}" -gt 0 ]; then
  bats_bin=""
  if [ -x tests/lib/bats-core/bin/bats ]; then bats_bin="tests/lib/bats-core/bin/bats"
  elif command -v bats >/dev/null 2>&1; then bats_bin="bats"
  fi
  if [ -n "$bats_bin" ]; then
    echo "verify: bats ${uniq_bats[*]}"
    "$bats_bin" "${uniq_bats[@]}" || rc=1
  else
    echo "verify: skip bats (no tests/lib/bats-core and no bats on PATH)"
  fi
fi

# 4. changed Markdown: leftover conflict markers. Only the two unambiguous ones; a line of
# '=======' is a legal setext heading underline.
if [ "${#md_files[@]}" -gt 0 ]; then
  echo "verify: markdown conflict markers in ${md_files[*]}"
  if grep -nE '^(<<<<<<< |>>>>>>> )' "${md_files[@]}"; then
    echo "verify: leftover merge-conflict markers in changed Markdown" >&2
    rc=1
  fi
fi

# 5. rules lint, when this repo has one
if [ "$rules_changed" -eq 1 ] && [ -f scripts/rules.py ]; then
  if command -v python3 >/dev/null 2>&1; then
    echo "verify: python3 scripts/rules.py lint"
    python3 scripts/rules.py lint || rc=1
  else
    echo "verify: skip rules lint (python3 not installed)"
  fi
fi

[ "$rc" -eq 0 ] && echo "verify: PASS (fast check; the full CI gate on the pull request is authoritative)"
exit "$rc"
