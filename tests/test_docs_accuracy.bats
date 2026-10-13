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

@test "F3: the README wire.sh section and its safety line mention settings.json" {
  sec="$(awk '/^## How wire.sh works/{f=1;next} /^## /{f=0} f' README.md)"
  [[ "$sec" == *settings.json* ]]
  [[ "$sec" == *-hook:auto-handoff* ]]
  # the safety claim must not say symlinks are the only thing wire.sh touches
  ! grep -n 'wire.sh` only ever touches symlinks' README.md || false
  # the code does write it (guards the doc against a removed feature)
  grep -q 'deploy_hooks.py' scripts/wire.sh
}

@test "F3: the README intro does not promise 'no config files' for wire.sh without the hook" {
  intro="$(sed -n '1,100p' README.md)"
  [[ "$intro" == *settings.json* ]]
}

# --- F7: no <your-username> placeholder in a runnable clone command ---

@test "F7: README, BOOTSTRAP and index.html carry no <your-username> placeholder" {
  ! grep -n -E '<your-username>|&lt;your-username&gt;' README.md BOOTSTRAP.md index.html || false
}

@test "F7: BOOTSTRAP and PLUGINS say next content applies until next is promoted to main" {
  grep -q 'promoted to `main`' BOOTSTRAP.md
  grep -q 'promoted to `main`' docs/PLUGINS.md
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
  # the README paragraph wraps across lines: compare on one flattened line
  flat="$(tr '\n' ' ' < README.md | tr -s ' ')"
  [[ "$flat" == *"**$total skills indexed, $wired wired live** ($owned built by Gareth, $upstream from curated upstream repos) **+ $lib more in a searchable library**"* ]]
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
  done
  [ "$total" -eq $((orch + spec)) ]
  flat="$(tr '\n' ' ' < README.md | tr -s ' ')"
  [[ "$flat" == *"$total composed AI agents across 4 ready-to-run teams ($orch orchestrators, $spec specialists)"* ]]
  [[ "$flat" == *"$total ready-made AI roles"* ]]
  grep -q "the other $spec roles" USAGE.md
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

@test "F14: the README layout block lists every tracked top-level directory" {
  block="$(awk '/^## Repo layout/{f=1;next} /^## /{f=0} f' README.md)"
  for d in $(git ls-files | awk -F/ 'NF>1 && $1 !~ /^\./ {print $1}' | sort -u); do
    [[ "$block" == *"  $d/"* ]] || { echo "README layout lacks $d/"; false; }
  done
  for f in policy.yaml grid.yaml grid.lock; do
    [[ "$block" == *"$f"* ]] || { echo "README layout lacks $f"; false; }
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
