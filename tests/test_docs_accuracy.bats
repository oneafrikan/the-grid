#!/usr/bin/env bats
# Doc-vs-code guards for WP-071 (docs accuracy sweep). Each case pins one class of drift the
# review found in README / BOOTSTRAP / CLAUDE / USAGE / TODO / the factory docs, by reading the
# tracked tree (grep and git ls-files; no submodules needed). Counts are never typed here: they
# are derived from SKILLS.md (which the gate renders from the example baseline) and from
# `compose.py --dry-run` per example config, so a doc that drifts from the code fails.

load helpers/setup
load helpers/venv

# common_setup sandboxes every home-derived dir; these tests only read the repo, but the
# sandbox (and its tripwire) is the house rule for every test file.
setup() {
  common_setup
  cd "$REPO_ROOT"
}

teardown() {
  common_teardown
}

# --- F2: "add a skill" / "override a repo skill" must use skills/<name>, which wire.sh wires ---

@test "F2: BOOTSTRAP and CLAUDE do not tell the reader to add a skill at the repo root" {
  # a root-level dir is silently not wired (wire.sh wires skills/<name> only)
  ! grep -n -E 'directory at the repo root|~/\.the-grid/my-skill' BOOTSTRAP.md CLAUDE.md || false
  ! grep -n -E '~/\.the-grid/(caveman|tdd)/?' BOOTSTRAP.md || false
}

@test "F2: the documented skills/ path is the one wire.sh wires" {
  grep -q 'skills/<name>' CLAUDE.md
  grep -q 'mkdir ~/.the-grid/skills/my-skill' BOOTSTRAP.md
  [ -d skills/caveman ]
}

# --- F3: wire.sh writes ~/.claude/settings.json (the auto-handoff SessionEnd hook) ---

@test "F3: the architecture doc's wire.sh section and the README Status safety line mention settings.json" {
  # the wire.sh walkthrough moved from README.md to docs/architecture.md (front-door change)
  sec="$(awk '/^## How wire.sh works/{f=1;next} /^## /{f=0} f' docs/architecture.md)"
  [[ "$sec" == *settings.json* ]]
  [[ "$sec" == *-hook:auto-handoff* ]]
  # the README safety bullet must name settings.json and the opt-out, and not claim "only symlinks"
  status="$(awk '/^## Status/{f=1;next} /^## /{f=0} f' README.md)"
  [[ "$status" == *settings.json* ]]
  [[ "$status" == *-hook:auto-handoff* ]]
  ! grep -n 'wire.sh` only ever touches symlinks' README.md || false
  # the code does write it (guards the doc against a removed feature)
  grep -q 'deploy_hooks.py' scripts/wire.sh
}

@test "F3: the README does not promise 'no config files' for wire.sh without the hook" {
  grep -q 'settings.json' README.md
}

# --- F7: no <your-username> placeholder in a runnable clone command ---

@test "F7: README, BOOTSTRAP and index.html carry no <your-username> placeholder" {
  ! grep -n -E '<your-username>|&lt;your-username&gt;' README.md BOOTSTRAP.md index.html || false
}

# --- F9 / R18.F14: targets that exist are not described as planned ---

@test "F9: built harness targets are not listed as scoped, planned or not implemented" {
  # compose.py really does accept these targets
  run python3 -c '
import re, sys
src = open("agent-factory/compose.py").read()
for t in ("codex", "gemini-cli", "opencode", "portable"):
    assert re.search(r"[\"\x27]%s[\"\x27]" % t, src), t
'
  [ "$status" -eq 0 ]
  ! grep -n -i -E '(opencode|codex|gemini|portable).*(not implemented|scoped|not built|none implemented)' \
      README.md index.html agent-factory/README.md || false
  ! grep -n -E 'scoped but not built|none implemented|no regression suite' README.md agent-factory/README.md || false
  ! grep -n -i 'Scoped but not built' index.html || false
}

@test "F9: the agent-factory usage block shows the harness targets" {
  for t in codex gemini-cli opencode; do
    grep -q -e "--target $t" agent-factory/README.md
  done
}

@test "R18.F14: docs/harnesses.md does not hard-code a stale read-only role list or a 'later' note" {
  ! grep -n 'today `qa-engineer` and `security-reviewer`' docs/harnesses.md || false
  ! grep -n 'are added as those parts land' docs/harnesses.md || false
}

# --- F10: documented commands resolve to tracked files ---

@test "F10: every bash/python3 script path in README, BOOTSTRAP and CLAUDE exists" {
  # first word after bash|python3, with an optional ~/.the-grid/ prefix; flags (-m, --version) skipped
  paths="$(grep -ohE '(bash|python3) +(~/\.the-grid/)?[A-Za-z0-9_./-]+' README.md BOOTSTRAP.md CLAUDE.md \
    | sed -E 's/^(bash|python3) +//; s#^~/\.the-grid/##' | grep -v '^-' | sort -u)"
  [ -n "$paths" ]
  missing=""
  while IFS= read -r p; do
    [ -e "$p" ] || missing="$missing $p"
  done <<< "$paths"
  [ -z "$missing" ] || { echo "documented but not in the tree:$missing"; false; }
}

@test "F10: cut-project.sh is only named by its real path (project-factory/scripts/)" {
  [ -f project-factory/scripts/cut-project.sh ]
  [ ! -e scripts/cut-project.sh ]
  ! grep -n -E '(^|[^/])scripts/cut-project\.sh' README.md CLAUDE.md BOOTSTRAP.md USAGE.md index.html project-factory/README.md || false
}

@test "F10: the catalogue header (generator text and SKILLS.md) names scripts/catalog.sh" {
  ! grep -n 'bash catalog.sh' scripts/catalog.sh SKILLS.md || false
  grep -q 'bash scripts/catalog.sh' SKILLS.md
}

# --- F11: typed counts equal what the tree says ---

@test "F11: README skill counts equal the SKILLS.md headline" {
  head="$(grep -m1 'skills indexed' SKILLS.md)"
  total="$(printf '%s\n' "$head" | sed -E 's/^\*\*([0-9]+) skills indexed.*/\1/')"
  wired="$(printf '%s\n' "$head" | sed -E 's/.*— ([0-9]+) wired live.*/\1/')"
  owned="$(printf '%s\n' "$head" | sed -E 's/.*\(([0-9]+) root-owned.*/\1/')"
  upstream="$(printf '%s\n' "$head" | sed -E 's/.*\+ ([0-9]+) from allowlisted.*/\1/')"
  lib="$(printf '%s\n' "$head" | sed -E 's/.*, ([0-9]+) in library.*/\1/')"
  # README counts are generated markers (scripts/stamp-counts.py), never typed: the markers that
  # the README uses (wired, library) must hold the SKILLS.md values.
  grep -qF "<!--count:wired-->$wired<!--/count-->" README.md
  grep -qF "<!--count:library-->$lib<!--/count-->" README.md
}

@test "F11: index.html wired-skill counts equal the SKILLS.md headline" {
  head="$(grep -m1 'skills indexed' SKILLS.md)"
  wired="$(printf '%s\n' "$head" | sed -E 's/.*— ([0-9]+) wired live.*/\1/')"
  owned="$(printf '%s\n' "$head" | sed -E 's/.*\(([0-9]+) root-owned.*/\1/')"
  upstream="$(printf '%s\n' "$head" | sed -E 's/.*\+ ([0-9]+) from allowlisted.*/\1/')"
  lib="$(printf '%s\n' "$head" | sed -E 's/.*, ([0-9]+) in library.*/\1/')"
  flat="$(tr '\n' ' ' < index.html | tr -s ' ')"
  [[ "$flat" == *"<strong>$wired wired live</strong> ($owned root-owned + $upstream from allowlisted repos)"* ]]
  [[ "$flat" == *"Another $lib exist in those same partial repos"* ]]
  # the dedicated library submodules, counted from the generated catalogue
  nlib="$(awk '/^## Library submodules/{f=1;next} /^## /{f=0} f && /^- \*\*repos\//{n++} END{print n+0}' SKILLS.md)"
  [[ "$flat" == *"indexed across $nlib dedicated library submodules"* ]]
}

@test "F11: index.html library and reference summary and table equal SKILLS.md" {
  flat="$(tr '\n' ' ' < index.html | tr -s ' ')"
  nlib="$(awk '/^## Library submodules/{f=1;next} /^## /{f=0} f && /^- \*\*repos\//{n++} END{print n+0}' SKILLS.md)"
  nref="$(awk '/^## Reference submodules/{f=1;next} /^## /{f=0} f && /^- \*\*repos\//{n++} END{print n+0}' SKILLS.md)"
  sum="$(awk '/^## Library submodules/{f=1;next} /^## /{f=0} f && /^- \*\*repos\//{s+=$(NF-1)} END{print s+0}' SKILLS.md)"
  # the "over 1,000" wording is only true while the sum stays above it
  [ "$sum" -gt 1000 ]
  [[ "$flat" == *"over 1,000 more skills across $nlib library submodules"* ]]
  case "$nref" in 7) w=Seven ;; 8) w=Eight ;; 9) w=Nine ;; 10) w=Ten ;; *) w="?$nref" ;; esac
  [[ "$flat" == *"$w more repos are reference-only"* ]]
  # the per-repo table: one row per SKILLS.md entry, same counts and tier
  [ "$(grep -c '<td>Library</td>' index.html)" -eq "$nlib" ]
  [ "$(grep -c '<td>Reference (index)</td>' index.html)" -eq "$nref" ]
  while read -r repo n; do
    grep -q "<tr><td><code>repos/$repo</code></td><td>$n</td><td>Library</td></tr>" index.html || { echo "index.html row wrong for $repo ($n)"; false; }
  done < <(sed -n -E '/^## Library submodules/,/^## Reference/ s/^- \*\*repos\/([^*]+)\*\* — ([0-9]+) skills.*/\1 \2/p' SKILLS.md)
}

# NF-063: the index.html wired catalogue lists exactly the names SKILLS.md lists as wired.
# Sorted lists (not sets) are compared, so a missing, extra or duplicated name all fail. A
# name that two repos both ship (grill-me) appears twice in both files, which is correct.
@test "F11: index.html wired-skill names equal the SKILLS.md wired names, one for one" {
  awk '/^## Library submodules/{exit} /^- \*\*/{match($0,/\*\*[^*]+\*\*/); print substr($0,RSTART+2,RLENGTH-4)}' SKILLS.md | sort > "$BATS_TEST_TMPDIR/md"
  grep -o 'class="skill-name">[^<]*' index.html | sed 's/.*">//' | sort > "$BATS_TEST_TMPDIR/html"
  [ -s "$BATS_TEST_TMPDIR/md" ]
  run diff "$BATS_TEST_TMPDIR/md" "$BATS_TEST_TMPDIR/html"
  echo "$output"
  [ "$status" -eq 0 ]
}

# The reference rows were only checked by count above; check each name too.
@test "F11: every SKILLS.md reference submodule has its own index.html table row" {
  n=0
  while read -r repo; do
    n=$((n + 1))
    grep -q "<tr><td><code>repos/$repo</code></td><td>—</td><td>Reference (index)</td></tr>" index.html || { echo "index.html reference row missing for $repo"; false; }
  done < <(sed -n -E '/^## Reference submodules/,$ s/^- \*\*repos\/([^*]+)\*\*.*/\1/p' SKILLS.md)
  [ "$n" -gt 0 ]
}

@test "F11: BOOTSTRAP gives no hard-coded test or skill totals that drift" {
  ! grep -n -E 'All [0-9]+ tests|the other ~?[0-9]+ skills' BOOTSTRAP.md || false
}

@test "F11: README and USAGE role counts equal compose.py's per-project counts" {
  PY="$REPO_ROOT/agent-factory/.venv/bin/python"
  require_venv "$PY"
  total=0; orch=0; spec=0
  for cfg in agent-factory/examples/*.yaml; do
    out="$("$PY" agent-factory/compose.py "$cfg" --target claude-code --dry-run)"
    total=$((total + $(printf '%s\n' "$out" | grep -c ' -> CC ')))
    orch=$((orch + $(printf '%s\n' "$out" | grep -c 'CC skill (orchestrator)')))
    spec=$((spec + $(printf '%s\n' "$out" | grep -c 'CC subagent (specialist)')))
    # CLAUDE.md types the grid project's own split (VD8/VD9): remember it for the check below
    if [ "$cfg" = agent-factory/examples/grid.yaml ]; then
      gt=$(printf '%s\n' "$out" | grep -c ' -> CC ')
      go=$(printf '%s\n' "$out" | grep -c 'CC skill (orchestrator)')
      gs=$(printf '%s\n' "$out" | grep -c 'CC subagent (specialist)')
    fi
  done
  [ "$total" -eq $((orch + spec)) ]
  # the README role count is a generated marker; it must equal compose.py's total
  grep -qF "<!--count:roles-->$total<!--/count-->" README.md
  grep -q "the other $spec roles" USAGE.md
  # CLAUDE.md's hand-typed counts: the grid project's split and the all-public-roles total
  flatc="$(tr '\n' ' ' < CLAUDE.md | tr -s ' ')"
  [[ "$flatc" == *"$gt roles: $go orchestrators → CC skills, $gs specialists → CC subagents"* ]]
  [[ "$flatc" == *"all $total composed public roles"* ]]
}

# gsd is a standalone bare orchestrator: composed in grid.yaml, never under the CEO, and named
# in the docs that list the orchestrators (the counts above come from compose.py, not typed here).
@test "F11: gsd is a bare standalone orchestrator listed in USAGE and the grid-help orientation" {
  grep -q '^  - role: gsd$' agent-factory/examples/grid.yaml
  awk '/^  - role: gsd$/,/^  # product/' agent-factory/examples/grid.yaml | grep -q 'bare: true'
  ! grep -q 'delegates_to: \[tech-lead, product-manager, growth-hacker, gsd' agent-factory/examples/grid.yaml || false
  grep -q '`gsd`' USAGE.md
  grep -q '`gsd`' skills/grid-help/sections/orientation.md
}

# --- F12: four public projects, four factories ---

@test "F12: no 'three' project wording while four example configs exist" {
  [ "$(ls agent-factory/examples/*.yaml | wc -l)" -eq 4 ]
  ! grep -n -i -E 'three (sibling|public|composed)|the three projects|three public' \
      CLAUDE.md BOOTSTRAP.md USAGE.md agent-factory/README.md || false
}

@test "F12: CLAUDE.md gates learning-desk and names tron in the core roster" {
  grep -q 'project:learning-desk' CLAUDE.md
  # both core roster mentions list tron (examples/core.yaml is where it is composed)
  grep -q '^    - role: tron\|role: tron' agent-factory/examples/core.yaml
  ! grep -n 'project:core` (gh-triage, librarian, researcher, platform-engineer)' CLAUDE.md || false
  awk '/`examples\/core.yaml`/,/regardless of which/' CLAUDE.md | grep -q 'tron'
  # context-engineer is a core role, so the same roster paragraph names it
  grep -q '^    - role: context-engineer\|role: context-engineer' agent-factory/examples/core.yaml
  awk '/`examples\/core.yaml`/,/regardless of which/' CLAUDE.md | grep -q 'context-engineer'
}

@test "F12: the golden-output note does not give a stale target count" {
  # compose-goldens.sh covers every compose target (8 today), not four
  ! grep -n 'all four targets' CLAUDE.md agent-factory/README.md || false
  [ "$(sed -n -E 's/^TARGETS=\((.*)\)$/\1/p' scripts/compose-goldens.sh | wc -w | tr -d ' ')" -ge 8 ]
}

@test "F12: the rollout note points at the real BOOTSTRAP step" {
  ! grep -n 'BOOTSTRAP step 4' CLAUDE.md || false
}

# --- F14: layout lists and residual stale wording ---

@test "F14: the architecture doc's layout block lists every tracked top-level directory" {
  # the repo layout moved from README.md to docs/architecture.md (front-door change)
  block="$(awk '/^## Repo layout/{f=1;next} /^## /{f=0} f' docs/architecture.md)"
  for d in $(git ls-files | awk -F/ 'NF>1 && $1 !~ /^\./ {print $1}' | sort -u); do
    [[ "$block" == *"  $d/"* ]] || { echo "architecture layout lacks $d/"; false; }
  done
  for f in policy.yaml grid.yaml grid.lock; do
    [[ "$block" == *"$f"* ]] || { echo "architecture layout lacks $f"; false; }
  done
}

@test "F14: no 'a later step' / 'from the hook-profiles change' / 'will collapse' wording" {
  ! grep -n 'a later step' docs/usage.md || false
  ! grep -n 'from the hook-profiles change' docs/instincts.md || false
  ! grep -n 'will collapse' USAGE.md || false
  ! grep -n 'done history' USAGE.md || false
}

@test "F14: the hooks README status note covers the instincts hooks" {
  sed -n '1,20p' hooks/README.md | grep -q -i 'instincts'
}

@test "F14: the BOOTSTRAP precedence list follows the example baseline order" {
  order="$(grep -m1 '^# Intentional order:' baseline-submodules.example.txt | sed -E 's/.*order: //; s/\.$//')"
  [ -n "$order" ]
  # "anthropic → gstack → ..." in the baseline becomes a comma list in BOOTSTRAP, same order
  want="$(printf '%s\n' "$order" | sed 's/ → /, /g')"
  grep -q "$want" BOOTSTRAP.md
}

# --- F15: TODO.md reflects the tree ---

@test "F15: TODO.md does not list the SSH-clone-URL item while .gitmodules has no SSH urls" {
  [ "$(grep -c 'git@github' .gitmodules || true)" -eq 0 ]
  ! grep -n 'SSH clone URLs' TODO.md || false
  ! grep -n -E 'skills-factory' TODO.md || false
}

@test "F15: TODO.md does not call the built compose targets 'not built'" {
  ! grep -n -i -E 'not built|scoped from the' TODO.md || false
}

# --- F16: maintainer mode ---

@test "F16: CLAUDE.md does not say grid doctor has nothing to check in maintainer mode" {
  ! grep -n 'doctor` and `grid repair` have nothing to check' CLAUDE.md || false
  grep -q '`grid repair` has nothing to repair; `grid doctor` still checks the links' CLAUDE.md
}

# --- F17: the dry-run claim is true for the repo tree (the code side is in test_grid_install.bats) ---

@test "F17: scripts/grid exports PYTHONDONTWRITEBYTECODE for its children" {
  grep -q '^os.environ\["PYTHONDONTWRITEBYTECODE"\] = "1"' scripts/grid
}

# --- F19: check-grid.sh is the whole suite, not a fast check ---

@test "F19: nothing calls check-grid.sh a fast health check" {
  ! grep -n -i 'fast health check\|fast "is the grid healthy' USAGE.md README.md BOOTSTRAP.md scripts/check-grid.sh || false
  grep -q 'full test suite' scripts/check-grid.sh
  grep -q 'full test suite' USAGE.md
}

# --- NF-037 VF1: reconcile.sh moves shadows aside (dated backup dir) and learns names from a dry wire ---

@test "NF-037: reconcile docs say moves-aside and dry wire, not removes or parses wire output" {
  # the code: GRID_DRY_HOME wire for the names, `mv` into .grid-reconcile-backup-<stamp>
  grep -q "GRID_DRY_HOME" scripts/reconcile.sh
  grep -q "grid-reconcile-backup" scripts/reconcile.sh
  ! grep -n -E "removes them so the-grid|parses wire.sh.s own|remove those shadows|only ever removes a path" BOOTSTRAP.md CLAUDE.md README.md || false
  grep -q "dry wire" CLAUDE.md
}
