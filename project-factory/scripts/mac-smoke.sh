#!/usr/bin/env bash
# mac-smoke.sh — manual smoke of the project kit (cut-project.sh + retrofit.py) for a
# machine other than the Linux dev box (written for a Mac: bash 3.2, BSD userland, python 3.9).
#
# Safe by construction:
#   - read-only on the grid checkout; every cut and every git repo lives under one temp dir
#   - HOME and git config are pointed at that temp dir, so the operator's global git config
#     (gpgsign, hooksPath, templateDir) cannot change the result
#   - removes its temp dir on exit unless KEEP=1; running it twice is harmless
# It prints; it does not assert. Compare the output with docs/macbook-check.md.
#
# Usage:  bash project-factory/scripts/mac-smoke.sh 2>&1 | tee ~/mac-check-smoke.txt
#         GRID=/path/to/the-grid bash project-factory/scripts/mac-smoke.sh   (override the checkout)
#         KEEP=1 bash ...                                                     (keep the temp dir)

# Default GRID: two levels above this script (project-factory/scripts/ -> repo root).
# cd -P (no readlink -f: macOS < 12.3 lacks it).
src="${BASH_SOURCE[0]:-$0}"
GRID="${GRID:-$(cd -P "$(dirname "$src")/../.." && pwd -P)}"
CUT="$GRID/project-factory/scripts/cut-project.sh"
RF="$GRID/project-factory/scripts/retrofit.py"
if [ ! -f "$CUT" ] || [ ! -f "$RF" ]; then
  echo "mac-smoke: no project-factory under GRID=$GRID" >&2
  exit 2
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/mac-smoke.XXXXXX")" || exit 2
# Canonical path (macOS /var -> /private/var) so printed paths match what the tools print.
T="$(cd -P "$T" && pwd -P)"
if [ "${KEEP:-0}" != 1 ]; then trap 'rm -rf "$T"' EXIT; fi

# Isolate git from the operator's config (GIT_CONFIG_GLOBAL needs git >= 2.32, so HOME too).
mkdir "$T/home"
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset XDG_CONFIG_HOME
# One commit helper: fixed identity, no signing, no hooks.
gc() { git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q "$@"; }

echo "temp dir: $T"
echo "grid:     $GRID"
echo "bash:     $BASH_VERSION   python3: $(python3 --version 2>&1)   git: $(git --version)"
case_probe="$T/case"; mkdir "$case_probe"; : > "$case_probe/a"; : > "$case_probe/A"
echo "[probe] files visible after touching a and A = $(find "$case_probe" -type f | wc -l | tr -d ' ') (1 = case-insensitive FS, 2 = case-sensitive)"

echo; echo "=== S1 scaffold into a new dir"
bash "$CUT" --generic "$T/a"; echo "rc=$?"
echo "--- S1b map check in the new project"
python3 "$T/a/scripts/map.py" --check --root "$T/a"; echo "rc=$?"

echo; echo "=== S2 rerun (idempotency)"
bash "$CUT" --generic "$T/a" | grep -E 'Mode|unchanged|Done|wrote:'; echo "rc=${PIPESTATUS[0]}"

echo; echo "=== S3 differing file is skipped, not overwritten"
mkdir "$T/b"; echo "mine" > "$T/b/CONVENTIONS.md"
bash "$CUT" --generic "$T/b" | grep -E 'Mode|SKIPPED|Done'
echo "CONVENTIONS.md content: $(cat "$T/b/CONVENTIONS.md")"

echo; echo "=== S4 --grid"
bash "$CUT" --generic --grid "$T/c" | grep -E 'Mode|Done|hooksPath|git init'
echo "core.hooksPath=$(git -C "$T/c" config --get core.hooksPath)"
python3 "$T/c/scripts/map.py" --check --root "$T/c"; echo "map --check rc=$?"

echo; echo "=== S4b Finder-made dir holding only .DS_Store and a ._ file (must be a seed)"
mkdir "$T/d"; : > "$T/d/.DS_Store"; : > "$T/d/._x"
bash "$CUT" --generic "$T/d" | grep -E 'Mode|git init'
echo "--- S4c a real file next to .DS_Store (must be a retrofit)"
mkdir "$T/e"; : > "$T/e/.DS_Store"; echo keep > "$T/e/README.md"
bash "$CUT" --generic "$T/e" | grep -E 'Mode|git init'

echo; echo "=== S5 retrofit: blocks / apply / check / finalize on a tiny repo"
R="$T/r"; mkdir "$R"; cd "$R" || exit 1
git init -q
printf '# Proj\n\nIntro paragraph.\n\n## Rules\n\n- never push to main\n- run tests first\n\n## Notes\n\nSome loose note.\n' > CLAUDE.md
printf '# Conventions\n\n## Common tasks\n\nplaceholder\n' > CONVENTIONS.md
printf '# Guardrails\n\nIntro.\n' > GUARDRAILS.md
git add -A; gc -m init
python3 "$RF" survey . | head -8
echo "--- blocks"
python3 "$RF" blocks CLAUDE.md
python3 "$RF" blocks CLAUDE.md > blocks.out
H=$(sed -n 's/^\(## source: .*\)$/\1/p' blocks.out | head -1)
# B n -> the id of the n-th block line in blocks.out
B() { awk -v n="$1" '/^B[0-9]/ { c++; if (c == n) print $1 }' blocks.out; }
mkdir .retrofit
{ echo "$H"; echo "$(B 1)..$(B 2) -> keep"; echo "$(B 3) -> GUARDRAILS.md"; echo "$(B 4) -> CONVENTIONS.md#Common tasks"
  echo "$(B 5) -> unsorted"; echo "$(B 6)..$(B 7) -> unsorted"; } > .retrofit/plan.md
echo "--- plan"; cat .retrofit/plan.md
echo "--- apply (dry run)"; python3 "$RF" apply .retrofit/plan.md --repo .; echo "rc=$?"
git add -A; gc -m plan
echo "--- apply --yes"; python3 "$RF" apply .retrofit/plan.md --repo . --yes; echo "rc=$?"
echo "--- apply --yes again (must add nothing)"; python3 "$RF" apply .retrofit/plan.md --repo . --yes | grep -E 'already applied|wrote'; echo "rc=${PIPESTATUS[0]}"
echo "--- check"; python3 "$RF" check .retrofit/plan.md --repo .; echo "rc=$?"
python3 "$RF" keep .retrofit/plan.md --repo . > .retrofit/slim.md
git add -A; gc -m applied
echo "--- finalize dry run"; python3 "$RF" finalize .retrofit/plan.md --repo . --replace-with .retrofit/slim.md; echo "rc=$?"
echo "--- finalize --yes"; python3 "$RF" finalize .retrofit/plan.md --repo . --replace-with .retrofit/slim.md --yes; echo "rc=$?"
echo "--- check after finalize"; python3 "$RF" check .retrofit/plan.md --repo . | tail -3; echo "rc=${PIPESTATUS[0]}"
ls docs/archive
echo
if [ "${KEEP:-0}" = 1 ]; then echo "temp dir kept: $T   (remove with: rm -rf \"$T\")"; else echo "temp dir removed on exit"; fi
