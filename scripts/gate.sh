#!/usr/bin/env bash
# gate.sh — the commit gate: everything that must be true before a commit lands.
#
# Checks (each runs even if an earlier one fails; one PASS/FAIL summary at the end):
#   lint         shellcheck warnings and errors in scripts/ and .githooks/
#   catalog      SKILLS.md is current           (catalog.sh --check)
#   compose      composed agent output is current for every public project
#                (compose.py --check; skipped with a notice if the venv is absent)
#   bats         the test suite
#
# Modes:
#   gate.sh               run all checks
#   gate.sh --pre-commit  same, but first abort if tracked files have unstaged
#                         changes (the checks read the disk, so a divergent index
#                         would pass while a different, unchecked version is committed)
#
# Installing: running this script once sets core.hooksPath=.githooks, so a fresh
# clone is armed by the first manual run. Git refuses to auto-run versioned hooks.
#
# Known limits — fast feedback, not a guarantee:
#   - `git commit --no-verify` skips the hook.
#   - merges / rebases / cherry-picks / reverts do not fire pre-commit.
#   - a fresh clone has no hook until this script has run once.
set -uo pipefail  # NOT -e: aggregate every failure

GRID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$GRID_DIR" || exit 2

# --- self-install the hook -----------------------------------------------------
if [ "$(git config --get core.hooksPath || true)" != ".githooks" ]; then
  git config core.hooksPath .githooks
  echo "gate: installed hook (core.hooksPath=.githooks)"
fi

# --- pre-commit: refuse a divergent index --------------------------------------
if [ "${1:-}" = "--pre-commit" ] && ! git diff --quiet; then
  echo "gate: ABORT — unstaged changes to tracked files; the checks would lint a" >&2
  echo "      different tree than the one being committed. Stage them, or:" >&2
  echo "      git stash push --keep-index" >&2
  exit 1
fi

# git exports GIT_INDEX_FILE / GIT_DIR into hooks; inherited, they make the git
# calls the checks run inside submodules (catalog's tracked-file discovery) look
# at the parent repo's index and fail. The checks must see a plain environment.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_EXEC_PATH

FAILED=()
# check <name> <cmd...> — run, print status, remember failures.
check() {
  local name="$1"; shift
  echo "==> $name"
  if "$@"; then echo "    PASS"; else echo "    FAIL"; FAILED+=("$name"); fi
}

run_shellcheck() {
  command -v shellcheck >/dev/null || { echo "    shellcheck not installed — skipped"; return 0; }
  shellcheck -S warning scripts/*.sh scripts/lib/*.sh .githooks/pre-commit
}

run_compose_check() {
  local py=agent-factory/.venv/bin/python rc=0 cfg
  [ -x "$py" ] || { echo "    agent-factory venv absent — skipped"; return 0; }
  for cfg in core grid finance-desk; do
    # Not yet composed on this machine is not a commit-time failure; stale output is.
    [ -d "agent-factory/projects/$cfg" ] || { echo "    $cfg not composed here — skipped"; continue; }
    "$py" agent-factory/compose.py "agent-factory/examples/$cfg.yaml" --target claude-code --check || rc=1
  done
  return $rc
}

check shellcheck run_shellcheck
check catalog    bash scripts/catalog.sh --check
check compose    run_compose_check
check bats       tests/lib/bats-core/bin/bats tests/

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "gate: PASS"
else
  echo "gate: FAIL — ${FAILED[*]}" >&2
  exit 1
fi
