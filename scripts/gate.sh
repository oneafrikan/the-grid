#!/usr/bin/env bash
# gate.sh — the commit gate: everything that must be true before a commit lands.
#
# Checks (each runs even if an earlier one fails; one PASS/FAIL summary at the end):
#   lint         shellcheck warnings and errors in scripts/, contexts/, .githooks/, hooks/, automation-factory/patterns/,
#                the factory scripts (agent-factory/scripts, project-factory/scripts + lamp templates) and tests/helpers/
#                (_retired/ is archived and never linted)
#   pysyntax     every tracked *.py and scripts/grid parses (stdlib ast; no new dependency; skipped with a notice
#                if python3 is absent)
#   catalog      SKILLS.md is current           (catalog.sh --check, rendered from the TRACKED example
#                baseline so CI and every machine agree; skipped with a notice if submodules are uninitialised)
#   sources      docs/SOURCES.md is current     (sources.sh --check-drift; offline, example baseline)
#   lock         grid.lock matches the submodule checkouts (grid lock --check; skipped with a
#                notice if python3 or scripts/grid is absent, or a locked source is not checked out)
#   budget       skill/role description listing stays within docs/budget-target.json
#                (budget.py --check against the example baseline; the baseline half is skipped
#                with a notice where submodules are not initialised)
#   compose      every role lints clean (compose.py --lint-roles) and composed
#                output is current for every public project (compose.py --check; skipped with a notice if the venv is absent)
#   plugins      generated plugin bundles + marketplace.json are current
#                (build-plugins.py --check; skipped with a notice if python3, the script or
#                the agent-factory venv is absent)
#   plugins-validate  claude plugin validate --strict on the marketplace, each plugin and
#                their skills/ and agents/ dirs (skipped with a notice if `claude` or
#                .claude-plugin/marketplace.json is absent; CI has no claude)
#   audit        vetting scan of owned assets + the baseline's wired set (audit.sh --gate --quiet;
#                skipped with a notice if python3 or scripts/audit.sh is absent; an uninitialised
#                baseline submodule fails it in CI, locally it is --allow-partial and `audit-wired`
#                is listed as skipped)
#   personas     dist/personas/*.md is current (build-personas.sh --check; skipped with a
#                notice if the script or the venv is absent)
#   personal     no personal data in the tracked tree (check-personal.sh); with no private
#                denylist on this machine (CI, forks) only the generic patterns run and the
#                skip is listed; skipped if the script is absent
#   rules        rule packs under rules/ lint clean (rules.py lint; offline; skipped with a
#                notice if python3 or scripts/rules.py is absent)
#   map          MAP.md is current              (map.py --check: drift only, never signal counts;
#                skipped with a notice if python3 or scripts/map.py is absent)
#   counts       generated counts in README/index.html are current (stamp-counts.py --check; compares
#                committed files only; skipped with a notice if python3 or scripts/stamp-counts.py is absent)
#   bats         the test suite
#   translations README translations are current (check-translations.sh, non-strict, run after bats;
#                a stale one only prints a WARN, it never fails the gate; skipped with a notice if
#                the script is absent)
#
# Modes:
#   gate.sh               run all checks (the heavy, merge-time gate; CI runs it via --strict)
#   gate.sh --pre-commit  FAST check of what is STAGED only (the commit hook): shellcheck on
#                         staged *.sh/*.bash, a python syntax parse of staged *.py (both read
#                         the staged blob from the index, so partial staging is fine) and bats
#                         for staged tests/*.bats files only (not tests that merely mention a
#                         changed script). Everything else is skipped, with a one-line note:
#                         the full gate runs in CI and via a plain `bash scripts/gate.sh`.
#                         bats runs the file on disk, so a staged .bats file that also has
#                         unstaged changes aborts (a different version would be tested).
#   gate.sh --strict      the full gate, but a check that was SKIPPED and is not named in
#                         GRID_GATE_EXPECT_SKIPPED (space-separated) fails the gate:
#                         "gate: FAIL (unexpected skip: ...)". CI runs this, so a removed
#                         venv step or check script cannot silently drop a check. An
#                         explicit flag, not CI=true detection, so a local run under a
#                         CI-like environment behaves as before.
#   gate.sh --no-bats     every check EXCEPT bats. CI's `checks` job; the suite runs in the shard jobs.
#   gate.sh --shard <n>   ONLY the bats files listed for shard <n> in tests/shards.txt (same version
#                         pin, GRID_REQUIRE_VENV and per-run TMPDIR leak check as the full suite).
#                         CI runs one per matrix entry; tests/test_gate.bats proves the shards
#                         together are exactly tests/test_*.bats. Not combinable with the others.
#   (--pre-commit and --strict combine, in any order; --pre-commit keeps its fast scope and
#   --strict then applies to its skips, e.g. a missing shellcheck)
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

# --- arguments -------------------------------------------------------------------
PRE_COMMIT=0
STRICT=0
NO_BATS=0
SHARD=""
GATE_USAGE="usage: gate.sh [--pre-commit] [--strict] [--no-bats | --shard <name>]"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pre-commit) PRE_COMMIT=1 ;;
    --strict)     STRICT=1 ;;
    --no-bats)    NO_BATS=1 ;;
    --shard)      [ "$#" -ge 2 ] || { echo "$GATE_USAGE" >&2; exit 2; }; SHARD="$2"; shift ;;
    *) echo "$GATE_USAGE" >&2; exit 2 ;;
  esac
  shift
done
# A shard is the bats stage alone: it excludes the other modes.
if [ -n "$SHARD" ] && { [ "$PRE_COMMIT" = 1 ] || [ "$NO_BATS" = 1 ]; }; then
  echo "$GATE_USAGE" >&2; exit 2
fi

# --- self-install the hook -----------------------------------------------------
if [ "$(git config --get core.hooksPath || true)" != ".githooks" ]; then
  git config core.hooksPath .githooks
  echo "gate: installed hook (core.hooksPath=.githooks)"
fi

# --- pre-commit: collect the STAGED files (fast mode only) ----------------------
# Done BEFORE the git env is unset below: inside a hook GIT_INDEX_FILE may name a temporary
# index (git commit -a / <paths>), and only that index holds what is being committed.
# Staged .sh/.bash/.py blobs are copied to a scratch dir, so the checks see exactly what
# will be committed even when the working tree differs (partial staging).
STAGE_DIR=""
STAGED_SH=()
STAGED_PY=()
STAGED_BATS=()
if [ "$PRE_COMMIT" = 1 ]; then
  STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grid-stage.XXXXXX")"
  trap 'rm -rf "$STAGE_DIR"' EXIT
  # ACMR: added/copied/modified/renamed (a deleted file has nothing to check).
  while IFS= read -r -d '' f; do
    case "$f" in
      _retired/*|*/_retired/*|tests/lib/*) continue ;;   # archived / vendored: never linted
      *.sh|*.bash) STAGED_SH+=("$f") ;;
      *.py)        STAGED_PY+=("$f") ;;
      tests/*.bats)
        # bats runs the file on disk; a staged file with unstaged edits would test other code.
        if ! git diff --quiet -- "$f"; then
          echo "gate: ABORT — $f has unstaged changes; bats would run a different version" >&2
          echo "      than the one being committed. Stage them, or: git stash push --keep-index" >&2
          exit 1
        fi
        STAGED_BATS+=("$f")
        continue ;;
      *) continue ;;
    esac
    # A failed extraction must not read as "nothing to check".
    if ! { mkdir -p "$STAGE_DIR/$(dirname "$f")" && git show ":$f" > "$STAGE_DIR/$f"; }; then
      echo "gate: ABORT — could not read the staged version of $f" >&2
      exit 1
    fi
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
  echo "pre-commit: fast check; the full gate runs in CI and via 'bash scripts/gate.sh'" >&2
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

# summarise — print the verdict and exit. Shared by the full gate and the fast pre-commit path.
summarise() {
  echo
  # --strict: every skip must be expected. GRID_GATE_EXPECT_SKIPPED is a space-separated list of
  # check names (the names in the "skipped:" summary). Whole-word match, so `compose` does not
  # hide behind `compose-core`.
  local UNEXPECTED=() s
  if [ "$STRICT" = 1 ]; then
    for s in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
      case " ${GRID_GATE_EXPECT_SKIPPED:-} " in
        *" $s "*) ;;
        *) UNEXPECTED+=("$s") ;;
      esac
    done
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "gate: FAIL — ${FAILED[*]}" >&2
    [ "${#UNEXPECTED[@]}" -eq 0 ] || echo "gate: FAIL (unexpected skip: ${UNEXPECTED[*]})" >&2
    exit 1
  elif [ "${#UNEXPECTED[@]}" -gt 0 ]; then
    echo "gate: FAIL (unexpected skip: ${UNEXPECTED[*]})" >&2
    exit 1
  elif [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "gate: PASS (skipped: ${SKIPPED[*]})"
  else
    echo "gate: PASS"
  fi
  exit 0
}

run_shellcheck() {
  command -v shellcheck >/dev/null || { echo "    shellcheck not installed — skipped"; SKIPPED+=(shellcheck); return 0; }
  local files
  # nullglob: a group with no match (a stub grid, a fork that dropped a dir) adds nothing,
  # instead of reaching shellcheck as a literal pattern it reports as a missing file.
  # _retired/ is deliberately not listed: it is archived, with stale paths.
  shopt -s nullglob
  files=(scripts/*.sh scripts/lib/*.sh scripts/usage/*.sh contexts/*.sh .githooks/pre-commit
    automation-factory/patterns/*/*.sh automation-factory/patterns/*/hooks/*.sh
    hooks/*.sh hooks/lib/*.sh hooks/scripts/*.sh
    agent-factory/scripts/*.sh project-factory/scripts/*.sh project-factory/templates/*/scripts/*.sh
    project-factory/templates/_common/.githooks/*
    tests/helpers/*.bash)
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ] || return 0
  shellcheck -S warning "${files[@]}"
}

run_compose_check() {
  local py=agent-factory/.venv/bin/python rc=0 cfg
  [ -x "$py" ] || { echo "    agent-factory venv absent — skipped"; SKIPPED+=(compose); return 0; }
  "$py" agent-factory/compose.py --lint-roles || rc=1
  for cfg in core grid finance-desk learning-desk; do
    # Not yet composed on this machine is not a commit-time failure; stale output is. The skip
    # is RECORDED (compose-<cfg>) so `--strict` and the summary show which projects were not
    # checked: composed output is git-ignored, so CI never composes and always lists all four.
    [ -d "agent-factory/projects/$cfg" ] || { echo "    $cfg not composed here — skipped"; SKIPPED+=("compose-$cfg"); continue; }
    "$py" agent-factory/compose.py "agent-factory/examples/$cfg.yaml" --target claude-code --check || rc=1
  done
  return $rc
}

# Every tracked *.py plus scripts/grid (a python CLI with no .py extension) must parse. Stdlib
# `ast` only: a linter such as pyflakes would be a new CI dependency. A bare syntax slip in a
# script no test imports would otherwise ship. Names the files that fail.
run_pysyntax() {
  command -v python3 >/dev/null || { echo "    python3 absent — skipped"; SKIPPED+=(pysyntax); return 0; }
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.py')
  [ -f scripts/grid ] && files+=(scripts/grid)
  [ "${#files[@]}" -gt 0 ] || return 0
  py_parse_files "${files[@]}"
}

# py_parse_files <path>... — ast.parse each file (relative to the cwd); names the ones that fail.
py_parse_files() {
  python3 - "$@" <<'PYEOF'
import ast, sys
bad = 0
for name in sys.argv[1:]:
    try:
        with open(name, "rb") as fh:
            ast.parse(fh.read(), filename=name)
    except (SyntaxError, ValueError) as exc:
        print(f"    {name}: {exc}", file=sys.stderr)
        bad += 1
sys.exit(1 if bad else 0)
PYEOF
}

# The full gate's first two checks; --pre-commit runs its own staged-only versions below
# (the fast path ends in `summarise`, which exits, so nothing after it runs in that mode).
# A shard is the bats stage alone, so it skips these too.
if [ "$PRE_COMMIT" = 0 ] && [ -z "$SHARD" ]; then
  check shellcheck run_shellcheck
  check pysyntax   run_pysyntax
fi
# SKILLS.md, docs/SOURCES.md and the budget ratchet are all rendered/measured from the TRACKED
# example baseline (baseline-submodules.example.txt), never the personal gitignored one, so the
# same inputs give the same answer in CI and on every machine (a personal baseline is not gated).
# GRID_BASELINE_PIN is empty only where that file is absent (a stub grid, an odd checkout), and
# then each check skips loudly instead of silently judging a different baseline.
GRID_BASELINE_PIN=""
[ ! -f "$GRID_DIR/baseline-submodules.example.txt" ] || GRID_BASELINE_PIN="$GRID_DIR/baseline-submodules.example.txt"

run_catalog_check() {
  if [ -z "$GRID_BASELINE_PIN" ]; then
    echo "    no baseline-submodules.example.txt — skipped"; SKIPPED+=(catalog); return 0
  fi
  # Uninitialised submodules mean the skill counts cannot match the committed file: skip loudly.
  if git submodule status 2>/dev/null | grep -q '^-'; then
    echo "    uninitialised submodules — skipped (git submodule update --init)"; SKIPPED+=(catalog); return 0
  fi
  GRID_BASELINE="$GRID_BASELINE_PIN" bash scripts/catalog.sh --check
}

# docs/SOURCES.md is a pure function of .gitmodules + the example baseline: offline, needs no
# submodule checkout, so it is checked everywhere (no uninitialised-submodule skip).
run_sources_check() {
  if [ ! -f scripts/sources.sh ] || [ -z "$GRID_BASELINE_PIN" ]; then
    echo "    scripts/sources.sh or baseline-submodules.example.txt absent — skipped"; SKIPPED+=(sources); return 0
  fi
  GRID_BASELINE="$GRID_BASELINE_PIN" bash scripts/sources.sh --check-drift
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
  # Pinned to the example baseline (empty = unset where that file is absent).
  GRID_DIR="$GRID_DIR" GRID_BASELINE="$GRID_BASELINE_PIN" python3 scripts/budget.py --check || rc=$?
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

# The bats-core version the suite is written for; must equal tests/lib/bats-core's package.json
# (tests/test_gate.bats checks that). Bump both together when the submodule pointer moves.
PINNED_BATS_VERSION="1.13.0"

# run_bats [<bats file>...] — no arguments runs the whole suite (tests/); the fast pre-commit
# path passes only the staged test files.
run_bats() {
  # A fresh worktree has no submodule checkouts, so the hook would block every commit there
  # until someone ran the init by hand. Try that one init (only this submodule; it reuses the
  # shared module objects, no network when they are present) before failing.
  if [ ! -x tests/lib/bats-core/bin/bats ]; then
    echo "    bats missing — trying: git submodule update --init tests/lib/bats-core"
    git submodule update --init tests/lib/bats-core >/dev/null 2>&1 || true
  fi
  if [ ! -x tests/lib/bats-core/bin/bats ]; then
    echo "    bats missing — run: git submodule update --init" >&2; return 1
  fi
  # A moved submodule pointer or a wrong checkout must not pass silently (R16.qa.F14).
  # `bats --version` prints "Bats X.Y.Z".
  local bats_ver
  bats_ver="$(tests/lib/bats-core/bin/bats --version 2>/dev/null)" || bats_ver=""
  # Compare the whole string: `${bats_ver#Bats }` is a no-op on a bare "1.13.0" and let it pass.
  if [ "$bats_ver" != "Bats $PINNED_BATS_VERSION" ]; then
    echo "    bats version is '${bats_ver:-unknown}', the gate pins $PINNED_BATS_VERSION" >&2
    echo "    fix: git submodule update --init tests/lib/bats-core (or bump PINNED_BATS_VERSION with the submodule)" >&2
    return 1
  fi
  # Run under a per-run TMPDIR so a test that forgets its rm -rf is caught here: bats
  # removes its own run dir on exit, so anything still in this dir was leaked by a test.
  # Bash builtins only (the gate's own tests run with a minimal PATH).
  local tmp rc=0 leftovers
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/grid-bats.XXXXXX")"
  # GRID_REQUIRE_VENV=1: the venv-gated tests (agent-factory) must RUN here. Without it
  # they skip, bats exits 0, and a machine with no venv passes the gate (R16.qa.F5).
  TMPDIR="$tmp" GRID_REQUIRE_VENV=1 tests/lib/bats-core/bin/bats "${@:-tests/}" || rc=$?
  shopt -s nullglob dotglob
  leftovers=("$tmp"/*)
  shopt -u nullglob dotglob
  if [ "${#leftovers[@]}" -gt 0 ]; then
    echo "    tests leaked temp files into their TMPDIR:" >&2
    printf '      %s\n' "${leftovers[@]:0:20}" >&2
    # Say what each entry is and who might still be running, so a leak seen only on a CI
    # runner can be traced to its test without reproducing it. Best effort: a minimal PATH
    # (the gate's own tests) simply prints less. This output goes to a public CI log, so it
    # carries NAMES, SIZES and process NAMES only: never a leaked file's contents (it may hold
    # a token a test wrote) and never process arguments (a command line may carry one).
    local e
    for e in "${leftovers[@]:0:20}"; do
      { ls -ldA -- "$e"
        if [ -d "$e" ]; then find "$e" -maxdepth 2 | head -n 20; fi
      } 2>/dev/null | sed 's/^/        /' >&2 || true
    done
    { echo "      processes still running:"; ps -eo pid,etime,comm --sort=etimes 2>/dev/null | grep -v -e ' ps$' -e grep | head -n 25 | cut -c1-200 | sed 's/^/        /'; } >&2 || true
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# run_bats_shard — the bats files that tests/shards.txt lists for $SHARD ("<shard> <file>" lines,
# `#` comments). An unknown or empty shard FAILS: a typo in the CI matrix must not pass by
# running nothing.
run_bats_shard() {
  local s f files=()
  [ -f tests/shards.txt ] || { echo "    tests/shards.txt missing" >&2; return 1; }
  while read -r s f; do
    case "$s" in ''|'#'*) continue ;; esac
    [ "$s" = "$SHARD" ] && files+=("tests/$f")
  done < tests/shards.txt
  if [ "${#files[@]}" -eq 0 ]; then
    echo "    no bats files listed for shard '$SHARD' in tests/shards.txt" >&2; return 1
  fi
  run_bats "${files[@]}"
}

# --- pre-commit: the fast path ------------------------------------------------------
# Only what is staged (collected above). Everything else belongs to the full gate, which CI
# and a plain `bash scripts/gate.sh` run. Same check functions and flags as the full gate.
if [ "$PRE_COMMIT" = 1 ]; then
  # The shell and python checks lint the staged blobs in STAGE_DIR (subshell: cwd stays the repo root).
  fast_shellcheck() {
    [ "${#STAGED_SH[@]}" -gt 0 ] || { echo "    no staged shell files"; return 0; }
    command -v shellcheck >/dev/null || { echo "    shellcheck not installed — skipped"; SKIPPED+=(shellcheck); return 0; }
    ( cd "$STAGE_DIR" && shellcheck -S warning "${STAGED_SH[@]}" )
  }
  fast_pysyntax() {
    [ "${#STAGED_PY[@]}" -gt 0 ] || { echo "    no staged python files"; return 0; }
    command -v python3 >/dev/null || { echo "    python3 absent — skipped"; SKIPPED+=(pysyntax); return 0; }
    ( cd "$STAGE_DIR" && py_parse_files "${STAGED_PY[@]}" )
  }
  fast_bats() {
    [ "${#STAGED_BATS[@]}" -gt 0 ] || { echo "    no staged tests/*.bats files"; return 0; }
    run_bats "${STAGED_BATS[@]}"
  }
  check shellcheck fast_shellcheck
  check pysyntax   fast_pysyntax
  check bats       fast_bats
  summarise
fi

# --- shard: the bats stage alone (CI matrix entry) ---------------------------------------
if [ -n "$SHARD" ]; then
  check "bats-$SHARD" run_bats_shard
  summarise
fi

check catalog    run_catalog_check
check sources   run_sources_check
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
  # Locally a fresh clone has no wired submodules: scan the owned assets, say so, and list it
  # as skipped. CI (CI set) stays strict: an unscanned wired set is a failure there.
  local args=(--gate --quiet) out rc=0
  [ -n "${CI:-}" ] || args+=(--allow-partial)
  out="$(bash scripts/audit.sh "${args[@]}" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  # audit.sh says so in its output when the wired half was not scanned. Record that as a skip too
  # (same technique as personal-denylist), so it reaches the summary and `--strict` instead of
  # passing silently. Match the script's own marker line (either spelling).
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qi '^audit: wired set not scanned'; then
    SKIPPED+=(audit-wired)
  fi
  return "$rc"
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
# MAP.md is generated (like SKILLS.md): a stale or missing one fails, an absent tool skips loudly
# and is recorded. map.py --check exits 1 on drift, 2 on an error; both fail the gate.
run_map_check() {
  if ! command -v python3 >/dev/null || [ ! -f scripts/map.py ]; then
    echo "    python3 or scripts/map.py absent — skipped"; SKIPPED+=(map); return 0
  fi
  python3 scripts/map.py --check --root "$GRID_DIR"
}
check map        run_map_check
# Counts stamped into README/index.html come from the committed SKILLS.md headline and the team
# yamls, so a stale one fails here. Absent tool = skipped loudly and recorded, like the checks above.
run_counts_check() {
  if ! command -v python3 >/dev/null || [ ! -f scripts/stamp-counts.py ]; then
    echo "    python3 or stamp-counts.py absent - skipped"; SKIPPED+=(counts); return 0
  fi
  # GRID_DIR pinned so a stray exported GRID_DIR cannot point the check at another tree.
  GRID_DIR="$GRID_DIR" python3 scripts/stamp-counts.py --check
}
check counts     run_counts_check
if [ "$NO_BATS" = 1 ]; then
  echo "==> bats"; echo "    not run here (--no-bats): CI runs it in the shard jobs"
else
  check bats       run_bats
fi
# Stale README translations are a reminder, not a blocker: regenerating costs model tokens and an
# unattended loop must not be stopped by every README edit. So this check always returns 0; it
# prints the stale locales as a WARN. Absent script = skipped loudly and recorded (G3).
run_translations_check() {
  if [ ! -f scripts/check-translations.sh ]; then
    echo "    check-translations.sh absent - skipped"; SKIPPED+=(translations); return 0
  fi
  local out line stale=""
  out="$(bash scripts/check-translations.sh 2>&1)" && return 0
  while IFS= read -r line; do
    case "$line" in "STALE "*) stale="$stale${stale:+ }${line#STALE }" ;; esac
  done <<EOF
$out
EOF
  if [ -n "$stale" ]; then
    echo "    WARN: stale translations: $stale (fix: bash scripts/translate-readme.sh --all)"
  else
    echo "    WARN: check-translations.sh failed: $out"
  fi
  return 0
}
check translations run_translations_check

summarise
