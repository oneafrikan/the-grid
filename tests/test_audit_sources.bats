#!/usr/bin/env bats
# Tests for the source and curation checks of scripts/audit.py
# (change `vetting`, group 2): --baseline, baseline_repos(), --check-url and the
# source-not-allowed / source-uncurated findings reported at .gitmodules:<line>.
#
# Every fixture is generated inside the test (temp dirs + printf), nothing is
# committed. These tests verify my own implementation (a self-check); independent
# verification is for qa-engineer / sdet.

load helpers/setup

setup() {
  common_setup
  # T is the mock grid: real policy, a CURATION.md we edit per test, a hand-written
  # .gitmodules. It is both --root and --grid-dir for every scan.
  T="$MOCK_GRID"
  cp "$REPO_ROOT/policy.yaml" "$T/policy.yaml"
  : > "$T/CURATION.md"
  AUDIT="$REPO_ROOT/scripts/audit.py"
  BASE="$T/baseline.txt"
}

teardown() {
  common_teardown
}

# add_repo NAME URL -> a submodule entry in .gitmodules (url on line 3 of its own
# stanza) plus repos/NAME/x/SKILL.md, a clean skill, so only the source checks fire.
add_repo() {
  local name="$1" url="$2"
  printf '[submodule "repos/%s"]\n\tpath = repos/%s\n\turl = %s\n' "$name" "$name" "$url" >> "$T/.gitmodules"
  mkdir -p "$T/repos/$name/x"
  printf -- '---\nname: x\ndescription: clean\n---\nHello\n' > "$T/repos/$name/x/SKILL.md"
}

# audit_json ARGS... -> scanner against the mock grid; JSON (and exit status) in $output/$status.
audit_json() {
  run python3 "$AUDIT" --root "$T" --grid-dir "$T" --format json "$@"
}

# q EXPR -> evaluates a python expression over the JSON report in $output (F = findings).
q() {
  printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
F = d["findings"]
print(eval(sys.argv[1]))' "$1"
}

# --- baseline_repos (design.md "Test fixtures") --------------------------------

@test "baseline_repos returns exactly the plain repos from the 13-line fixture" {
  # Odd spacing and trailing comments are part of the fixture on purpose.
  printf '%s\n' '# comment line' 'project:core' 'rules:python' 'harness:codex' \
    'hook:auto-handoff' '-hook:auto-handoff' '-project:grid' '-gstack/careful' \
    'anthropic/pdf   # trailing comment' 'anthropic/docx' 'openspec' '  obra  ' \
    'future-kind:whatever' > "$BASE"
  # The scripts dir is passed as an argument, not a cwd-relative "scripts", so the test
  # passes from any working directory (R16.qa.F12).
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[2]); import audit; print(sorted(audit.baseline_repos(sys.argv[1])))' "$BASE" "$REPO_ROOT/scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "['anthropic', 'obra', 'openspec']" ]
}

# --- --check-url ---------------------------------------------------------------

@test "--check-url: allowed repo passes in every URL spelling" {
  # Policy lists obra/superpowers; scp-style SSH, ssh://, https, .git, slash and case all normalise to it.
  for u in 'git@github.com:obra/superpowers.git' 'https://github.com/obra/superpowers' \
           'https://github.com/obra/superpowers.git' 'https://github.com/obra/superpowers/' \
           'https://GitHub.com/Obra/SuperPowers.git' 'ssh://git@github.com/obra/superpowers.git'; do
    run python3 "$AUDIT" --grid-dir "$T" --check-url "$u"
    [ "$status" -eq 0 ] || { echo "rejected: $u -> $output"; return 1; }
  done
}

@test "--check-url: unlisted repo exits 1 and says why" {
  run python3 "$AUDIT" --grid-dir "$T" --check-url 'https://github.com/someone/else.git'
  [ "$status" -eq 1 ]
  [[ "$output" == *"someone/else"*"allowed_repos"* ]]
}

@test "--check-url: unlisted host exits 1 even for a listed owner/repo" {
  run python3 "$AUDIT" --grid-dir "$T" --check-url 'https://gitlab.com/obra/superpowers.git'
  [ "$status" -eq 1 ]
  [[ "$output" == *"allowed_hosts"* ]]
}

@test "--check-url: plain http and garbage are rejected" {
  run python3 "$AUDIT" --grid-dir "$T" --check-url 'http://github.com/obra/superpowers'
  [ "$status" -eq 1 ]
  run python3 "$AUDIT" --grid-dir "$T" --check-url 'not a url'
  [ "$status" -eq 1 ]
}

# --- source-not-allowed --------------------------------------------------------

@test "source-not-allowed is high for a baseline repo and blocks (exit 1), at .gitmodules:<url line>" {
  add_repo evil 'https://github.com/someone/evil.git'
  printf 'evil\n' > "$BASE"
  printf '### repos/evil\n' > "$T/CURATION.md"
  audit_json --baseline "$BASE" "$T/repos/evil"
  [ "$status" -eq 1 ]
  [ "$(q '[(f["rule"], f["severity"], f["path"], f["line"]) for f in F]')" = "[('source-not-allowed', 'high', '.gitmodules', 3)]" ]
}

@test "source-not-allowed is low and exit 0 when the repo is not in the baseline; still printed under --quiet" {
  add_repo evil 'https://github.com/someone/evil.git'
  printf '### repos/evil\n' > "$T/CURATION.md"
  printf 'other\n' > "$BASE"
  # overlay-only (baseline present but does not name it) ...
  audit_json --baseline "$BASE" "$T/repos/evil"
  [ "$status" -eq 0 ]
  [ "$(q '[(f["rule"], f["severity"]) for f in F]')" = "[('source-not-allowed', 'low')]" ]
  # ... and no --baseline at all
  audit_json "$T/repos/evil"
  [ "$status" -eq 0 ]
  [ "$(q '[(f["rule"], f["severity"]) for f in F]')" = "[('source-not-allowed', 'low')]" ]
  # text mode with --quiet keeps the warning
  run python3 "$AUDIT" --root "$T" --grid-dir "$T" --quiet "$T/repos/evil"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source-not-allowed"*".gitmodules:3"* ]]
}

@test "allowed sources pass in SSH, HTTPS and case variants" {
  printf '### repos/a\n### repos/b\n### repos/c\n' > "$T/CURATION.md"
  add_repo a 'git@github.com:obra/superpowers.git'
  add_repo b 'https://github.com/obra/superpowers'
  add_repo c 'https://github.com/OBRA/SuperPowers.git'
  printf 'a\nb\nc\n' > "$BASE"
  audit_json --baseline "$BASE" "$T/repos"/a "$T/repos"/b "$T/repos"/c
  [ "$status" -eq 0 ]
  [ "$(q 'len(F)')" = "0" ]
}

@test "a library repo (no target under it) is not checked" {
  add_repo evil 'https://github.com/someone/evil.git'
  add_repo fine 'https://github.com/obra/superpowers.git'
  printf 'evil\nfine\n' > "$BASE"
  printf '### repos/fine\n' > "$T/CURATION.md"
  audit_json --baseline "$BASE" "$T/repos/fine"      # evil is never a target
  [ "$status" -eq 0 ]
  [ "$(q 'len(F)')" = "0" ]
}

@test "no .gitmodules, or a target outside repos/, means no source checks" {
  mkdir -p "$T/repos/evil/x" "$T/skills/s"
  printf -- '---\nname: x\ndescription: clean\n---\nHello\n' > "$T/repos/evil/x/SKILL.md"
  printf 'evil\n' > "$BASE"
  audit_json --baseline "$BASE" "$T/repos/evil"      # no .gitmodules at all
  [ "$status" -eq 0 ]
  [ "$(q 'len(F)')" = "0" ]
  add_repo evil 'https://github.com/someone/evil.git'
  audit_json --baseline "$BASE" "$T/skills/s"        # .gitmodules exists, target is owned content
  [ "$status" -eq 0 ]
  [ "$(q 'len(F)')" = "0" ]
}

# --- source-uncurated ----------------------------------------------------------

@test "source-uncurated is high for a baseline repo (exit 1) and low otherwise (exit 0)" {
  add_repo fine 'https://github.com/obra/superpowers.git'
  printf 'fine\n' > "$BASE"
  audit_json --baseline "$BASE" "$T/repos/fine"
  [ "$status" -eq 1 ]
  [ "$(q '[(f["rule"], f["severity"], f["path"], f["line"]) for f in F]')" = "[('source-uncurated', 'high', '.gitmodules', 3)]" ]
  printf 'other\n' > "$BASE"
  audit_json --baseline "$BASE" "$T/repos/fine"
  [ "$status" -eq 0 ]
  [ "$(q '[(f["rule"], f["severity"]) for f in F]')" = "[('source-uncurated', 'low')]" ]
  audit_json "$T/repos/fine"                          # no --baseline
  [ "$status" -eq 0 ]
  [ "$(q '[(f["rule"], f["severity"]) for f in F]')" = "[('source-uncurated', 'low')]" ]
  run python3 "$AUDIT" --root "$T" --grid-dir "$T" --quiet "$T/repos/fine"
  [[ "$output" == *"source-uncurated"* ]]
}

@test "adding the CURATION.md heading clears source-uncurated" {
  add_repo fine 'https://github.com/obra/superpowers.git'
  printf 'fine\n' > "$BASE"
  printf '## Repos\n\n### repos/fine\n- upstream: x\n' > "$T/CURATION.md"
  audit_json --baseline "$BASE" "$T/repos/fine"
  [ "$status" -eq 0 ]
  [ "$(q 'len(F)')" = "0" ]
}

@test "a heading for a different repo does not curate this one (no prefix match)" {
  add_repo fine 'https://github.com/obra/superpowers.git'
  printf '### repos/fine-extra\n' > "$T/CURATION.md"
  audit_json "$T/repos/fine"
  [ "$(q '[f["rule"] for f in F]')" = "['source-uncurated']" ]
}

# --- one finding per repo; both rules; end-to-end baseline ---------------------

@test "two skills in one repo yield one finding per rule, not two" {
  add_repo evil 'https://github.com/someone/evil.git'
  mkdir -p "$T/repos/evil/y"
  printf -- '---\nname: y\ndescription: clean\n---\nHello\n' > "$T/repos/evil/y/SKILL.md"
  printf 'evil\n' > "$BASE"
  audit_json --baseline "$BASE" "$T/repos/evil/x" "$T/repos/evil/y"
  [ "$status" -eq 1 ]
  [ "$(q 'sorted(f["rule"] for f in F)')" = "['source-not-allowed', 'source-uncurated']" ]
}

@test "end to end: repos/openspec/x/SKILL.md with an unlisted URL is high via --baseline, low without it" {
  mkdir -p "$T/repos/openspec/x"
  printf -- '---\nname: x\ndescription: clean\n---\nHello\n' > "$T/repos/openspec/x/SKILL.md"
  printf '[submodule "repos/openspec"]\n\tpath = repos/openspec\n\turl = https://github.com/unlisted/openspec.git\n' > "$T/.gitmodules"
  printf '### repos/openspec\n' > "$T/CURATION.md"
  printf '# manifest\nopenspec\n' > "$BASE"
  audit_json --baseline "$BASE" "$T/repos/openspec/x"
  [ "$status" -eq 1 ]
  [ "$(q '[(f["rule"], f["severity"]) for f in F]')" = "[('source-not-allowed', 'high')]" ]
  printf '# manifest\nanthropic\n' > "$BASE"           # same repo, absent from the file
  audit_json --baseline "$BASE" "$T/repos/openspec/x"
  [ "$status" -eq 0 ]
  [ "$(q '[(f["rule"], f["severity"]) for f in F]')" = "[('source-not-allowed', 'low')]" ]
}

@test "a typed baseline entry never makes a phantom repo high" {
  add_repo core 'https://github.com/someone/evil.git'
  printf 'project:core\n' > "$BASE"
  printf '### repos/core\n' > "$T/CURATION.md"
  audit_json --baseline "$BASE" "$T/repos/core"
  [ "$status" -eq 0 ]
  [ "$(q '[f["severity"] for f in F]')" = "['low']" ]
}

@test "usage: no target and no --check-url exits 2; unreadable --baseline exits 2" {
  run python3 "$AUDIT" --root "$T" --grid-dir "$T"
  [ "$status" -eq 2 ]
  add_repo fine 'https://github.com/obra/superpowers.git'
  run python3 "$AUDIT" --root "$T" --grid-dir "$T" --baseline "$T/nope.txt" "$T/repos/fine"
  [ "$status" -eq 2 ]
}
