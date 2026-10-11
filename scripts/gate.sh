#!/usr/bin/env bash
# gate.sh — the commit gate: everything that must be true before a commit lands.
#
# Checks (each runs even if an earlier one fails; one PASS/FAIL summary at the end):
#   lint         shellcheck warnings and errors in scripts/, contexts/, .githooks/, hooks/ and automation-factory/patterns/
#   catalog      SKILLS.md is current           (catalog.sh --check)
#   lock         grid.lock matches the submodule checkouts (grid lock --check; skipped with a
#                notice if python3 or scripts/grid is absent, or a locked source is not checked out)
#   budget       skill/role description listing stays within docs/budget-target.json
#                (budget.py --check; the baseline half is skipped with a notice where
#                there is no baseline-submodules.txt / initialised submodules)
#   compose      every role lints clean (compose.py --lint-roles) and composed
#                output is current for every public project (compose.py --check; skipped with a notice if the venv is absent)
#   plugins      generated plugin bundles + marketplace.json are current
#                (build-plugins.py --check; skipped with a notice if python3, the script or
#                the agent-factory venv is absent)
#   plugins-validate  claude plugin validate --strict on the marketplace, each plugin and
#                their skills/ and agents/ dirs (skipped with a notice if `claude` or
#                .claude-plugin/marketplace.json is absent; CI has no claude)
#   audit        vetting scan of owned assets + the baseline's wired set (audit.sh --gate --quiet;
#                skipped with a notice if python3 or scripts/audit.sh is absent; the wired half
#                is skipped by audit.sh itself where submodules are uninitialised)
#   personas     dist/personas/*.md is current (build-personas.sh --check; skipped with a
#                notice if the script or the venv is absent)
#   personal     no personal data in the tracked tree (check-personal.sh); with no private
#                denylist on this machine (CI, forks) only the generic patterns run and the
#                skip is listed; skipped if the script is absent
#   rules        rule packs under rules/ lint clean (rules.py lint; offline; skipped with a
#                notice if python3 or scripts/rules.py is absent)
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
SKIPPED=()
# check <name> <cmd...> — run, print status, remember failures.
check() {
  local name="$1"; shift
  echo "==> $name"
  if "$@"; then echo "    PASS"; else echo "    FAIL"; FAILED+=("$name"); fi
}

run_shellcheck() {
  command -v shellcheck >/dev/null || { echo "    shellcheck not installed — skipped"; SKIPPED+=(shellcheck); return 0; }
  shellcheck -S warning scripts/*.sh scripts/lib/*.sh scripts/usage/*.sh contexts/*.sh .githooks/pre-commit \
    automation-factory/patterns/*/*.sh automation-factory/patterns/*/hooks/*.sh \
    hooks/*.sh hooks/lib/*.sh hooks/scripts/*.sh
}

run_compose_check() {
  local py=agent-factory/.venv/bin/python rc=0 cfg
  [ -x "$py" ] || { echo "    agent-factory venv absent — skipped"; SKIPPED+=(compose); return 0; }
  "$py" agent-factory/compose.py --lint-roles || rc=1
  for cfg in core grid finance-desk; do
    # Not yet composed on this machine is not a commit-time failure; stale output is.
    [ -d "agent-factory/projects/$cfg" ] || { echo "    $cfg not composed here — skipped"; continue; }
    "$py" agent-factory/compose.py "agent-factory/examples/$cfg.yaml" --target claude-code --check || rc=1
  done
  return $rc
}

check shellcheck run_shellcheck
# SKILLS.md is generated from the PERSONAL (gitignored) baseline + whichever
# submodules are initialised, so comparing it only means something on a machine
# that has both. Elsewhere the check is skipped loudly, not failed.
run_catalog_check() {
  if [ ! -f baseline-submodules.txt ]; then
    echo "    no baseline-submodules.txt on this machine — skipped"; SKIPPED+=(catalog); return 0
  fi
  if git submodule status 2>/dev/null | grep -q '^-'; then
    echo "    uninitialised submodules — skipped (git submodule update --init)"; SKIPPED+=(catalog); return 0
  fi
  bash scripts/catalog.sh --check
}

# grid.lock must describe the committed submodule state, so a pointer bump or a
# baseline edit without `python3 scripts/grid lock` fails the commit. `grid lock
# --check` exits 3 when a locked source has no checkout (a fork, CI without
# submodules): not checkable here, so skip loudly like the catalog check rather
# than fail. Any other non-zero exit is a real failure. bash never parses the lock.
run_lock_check() {
  if ! command -v python3 >/dev/null || [ ! -f scripts/grid ]; then
    echo "    python3 or scripts/grid absent — skipped"; SKIPPED+=(lock); return 0
  fi
  local rc=0
  # GRID_DIR pinned so a stray exported GRID_DIR cannot point it at another tree.
  GRID_DIR="$GRID_DIR" python3 scripts/grid lock --check || rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "    a locked source is not checked out — skipped"; SKIPPED+=(lock); return 0
  fi
  return "$rc"
}

# Skill/role listing budget. budget.py exits 0 (ok), 1 (regression/limit breach)
# or 3 (owned scope ok, baseline scope not measurable here - same "skip loudly"
# precedent as the catalog check, so 3 counts as a pass).
run_budget_check() {
  if ! command -v python3 >/dev/null || [ ! -f scripts/budget.py ]; then
    echo "    python3 or scripts/budget.py absent — skipped"; SKIPPED+=(budget); return 0
  fi
  local rc=0
  # GRID_DIR pinned so a stray exported GRID_DIR cannot point it at another tree.
  GRID_DIR="$GRID_DIR" python3 scripts/budget.py --check || rc=$?
  if [ "$rc" -eq 3 ]; then SKIPPED+=(budget-baseline); return 0; fi
  return "$rc"
}

# Personal-data scan (depersonalise). Absent script = skipped loudly (G3), so an old
# checkout or a stub grid still gates. A clean scan that could only apply the generic
# patterns (no private denylist here, e.g. CI) still passes but records the skip.
# GRID_REQUIRE_DENYLIST is deliberately NOT set here: only the unattended loop sets it.
run_personal_check() {
  if [ ! -f scripts/check-personal.sh ]; then
    echo "    check-personal.sh absent — skipped"; SKIPPED+=(personal); return 0
  fi
  local out rc=0
  out="$(bash scripts/check-personal.sh 2>&1)" || rc=$?
  printf '%s\n' "$out"
  # Match the script's own notice line (see check-personal.sh), not a loose word.
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^personal: private denylist not found'; then
    SKIPPED+=(personal-denylist)
  fi
  return "$rc"
}

run_bats() {
  if [ ! -x tests/lib/bats-core/bin/bats ]; then
    echo "    bats missing — run: git submodule update --init" >&2; return 1
  fi
  tests/lib/bats-core/bin/bats tests/
}

check catalog    run_catalog_check
check lock       run_lock_check
check budget     run_budget_check
check compose    run_compose_check

# Generated plugin bundles (change `plugin-marketplace`) are committed output of
# build-plugins.py, like SKILLS.md: stale output fails, an absent tool skips loudly (G3).
run_plugins_check() {
  command -v python3 >/dev/null || { echo "    python3 absent — skipped"; SKIPPED+=(plugins); return 0; }
  [ -f scripts/build-plugins.py ] || { echo "    scripts/build-plugins.py absent — skipped"; SKIPPED+=(plugins); return 0; }
  [ -x agent-factory/.venv/bin/python ] || { echo "    agent-factory venv absent — skipped"; SKIPPED+=(plugins); return 0; }
  python3 scripts/build-plugins.py --check
}
check plugins    run_plugins_check

# Claude's own validator, strict, over the marketplace, each plugin and its component
# dirs. Independent of the venv-dependent check above so either can skip alone.
run_plugins_validate() {
  command -v claude >/dev/null || { echo "    claude absent — skipped"; SKIPPED+=(plugins-validate); return 0; }
  [ -f .claude-plugin/marketplace.json ] || { echo "    .claude-plugin/marketplace.json absent — skipped"; SKIPPED+=(plugins-validate); return 0; }
  local rc=0 d
  # A failing target sets rc=1 but the remaining targets still run.
  claude plugin validate --strict . || rc=1
  for d in plugins/*/ plugins/*/skills plugins/*/agents; do
    [ -d "$d" ] || continue   # unmatched glob stays literal; a bundle may lack skills/ or agents/
    claude plugin validate --strict "${d%/}" || rc=1
  done
  return $rc
}
check plugins-validate run_plugins_validate
# Vetting audit (change `vetting`). Absent tool = skipped loudly and recorded, so an
# old checkout or a stub grid still gates; a present tool that finds a high FAILS.
run_audit() {
  [ -f scripts/audit.sh ] || { echo "    scripts/audit.sh absent - skipped"; SKIPPED+=(audit); return 0; }
  command -v python3 >/dev/null || { echo "    python3 absent - skipped"; SKIPPED+=(audit); return 0; }
  bash scripts/audit.sh --gate --quiet
}
check audit      run_audit
# Portable personas (dist/personas) are committed output of compose.py --target portable.
# Skip loudly (and record it) on a fork or machine without the script or the venv: the
# script's own venv-absent exit 0 would otherwise pass silently instead of being listed.
run_personas_check() {
  if [ ! -f scripts/build-personas.sh ] || [ ! -x agent-factory/.venv/bin/python ]; then
    echo "    build-personas.sh or agent-factory/.venv absent — skipped"; SKIPPED+=(personas); return 0
  fi
  bash scripts/build-personas.sh --check
}

# Stale committed personas fail the gate; listed before bats so drift is reported even
# when the (slow) suite also fails.
check personas   run_personas_check
check personal   run_personal_check
# Rule-pack lint (change `rule-packs`). Absent tool = skipped loudly and recorded,
# matching run_compose_check, so an old checkout or a stub grid still gates. An empty
# rules/ (no packs) lints clean. Offline by design: --check-urls is never passed here.
run_rules_check() {
  if ! command -v python3 >/dev/null || [ ! -f scripts/rules.py ]; then
    echo "    python3 or scripts/rules.py absent — skipped"; SKIPPED+=(rules); return 0
  fi
  # GRID_DIR pinned so a stray exported GRID_DIR cannot point the lint at another tree.
  GRID_DIR="$GRID_DIR" python3 scripts/rules.py lint
}
check rules      run_rules_check
check bats       run_bats

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  if [ "${#SKIPPED[@]}" -gt 0 ]; then echo "gate: PASS (skipped: ${SKIPPED[*]})"; else echo "gate: PASS"; fi
else
  echo "gate: FAIL — ${FAILED[*]}" >&2
  exit 1
fi
