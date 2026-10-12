#!/usr/bin/env bats
# Tests for scripts/stage-site.sh + site-files.txt — what GitHub Pages publishes.
# Fixture cases use a temp GRID_DIR; the last two run against the real repo.

load helpers/setup

setup() {
  FIX="$(mktemp -d)"            # fixture GRID_DIR
  OUT="$BATS_TEST_TMPDIR/site"  # staging output dir
  printf '<html></html>\n' > "$FIX/index.html"
  printf 'png\n' > "$FIX/pic.png"
  printf 'secret\n' > "$FIX/not-listed.txt"
}

teardown() {
  rm -rf "$FIX"
}

stage() { GRID_DIR="$FIX" bash "$REPO_ROOT/scripts/stage-site.sh" "$OUT"; }

@test "stages index.html and an image into the out dir and nothing else" {
  printf '# comment\nindex.html\n\npic.png\n' > "$FIX/site-files.txt"
  run stage
  [ "$status" -eq 0 ]
  [ -f "$OUT/index.html" ]
  [ -f "$OUT/pic.png" ]
  [ "$(find "$OUT" -type f | wc -l | tr -d ' ')" -eq 2 ]
  [ ! -e "$OUT/not-listed.txt" ]
}

@test "a directory entry is copied whole" {
  mkdir -p "$FIX/assets/sub"
  printf 'a\n' > "$FIX/assets/sub/a.txt"
  printf 'index.html\nassets\n' > "$FIX/site-files.txt"
  run stage
  [ "$status" -eq 0 ]
  [ -f "$OUT/assets/sub/a.txt" ]
}

@test "a missing listed path exits 1 and names it" {
  printf 'index.html\nghost.png\n' > "$FIX/site-files.txt"
  run stage
  [ "$status" -eq 1 ]
  [[ "$output" == *"ghost.png"* ]]
}

@test "repos/, .., absolute and .github paths each exit 2" {
  local bad
  for bad in "repos/x" "./repos/x" "../x" "/etc/x" ".github/x" ".git/config"; do
    printf 'index.html\n%s\n' "$bad" > "$FIX/site-files.txt"
    run stage
    if [ "$status" -ne 2 ]; then
      echo "expected exit 2 for '$bad', got $status" >&3
      return 1
    fi
    [ ! -e "$OUT" ] || { echo "out dir created despite bad path '$bad'" >&3; return 1; }
  done
}

@test "a second run into the same out dir gives the same file list (stale files removed)" {
  printf 'index.html\npic.png\n' > "$FIX/site-files.txt"
  stage >/dev/null
  printf 'stale\n' > "$OUT/stale.html"
  local first second
  first="$(cd "$OUT" && find . -type f | LC_ALL=C sort)"
  stage >/dev/null
  second="$(cd "$OUT" && find . -type f | LC_ALL=C sort)"
  [ ! -e "$OUT/stale.html" ]
  [ "$(printf '%s\n' "$first" | grep -v stale)" = "$second" ]
}

@test "refuses an out dir that is the repo itself" {
  printf 'index.html\n' > "$FIX/site-files.txt"
  run env GRID_DIR="$FIX" bash "$REPO_ROOT/scripts/stage-site.sh" "$FIX"
  [ "$status" -eq 2 ]
  [ -f "$FIX/index.html" ]
}

# --- WP-044: dot paths, symlinks, out-dir aliasing ---------------------------------------------

@test "dot entries (., ./, ./., a/./b) each exit 2 and create no out dir" {
  local bad
  mkdir -p "$FIX/a"
  for bad in "." "./" "./." "././" "a/./" "a/./b" "a/."; do
    printf 'index.html\n%s\n' "$bad" > "$FIX/site-files.txt"
    run stage
    if [ "$status" -ne 2 ]; then
      echo "expected exit 2 for '$bad', got $status" >&3
      return 1
    fi
    [ ! -e "$OUT" ] || { echo "out dir created despite dot path '$bad'" >&3; return 1; }
  done
}

@test "a listed symlink file, a listed symlink dir and a dir containing a symlink each exit 2" {
  mkdir -p "$FIX/real" "$FIX/withlink"
  printf 'x\n' > "$FIX/real/f.txt"
  ln -s "$FIX/not-listed.txt" "$FIX/link.txt"
  ln -s "$FIX/real" "$FIX/linkdir"
  ln -s "$FIX/not-listed.txt" "$FIX/withlink/inner"
  local bad
  for bad in "link.txt" "linkdir" "linkdir/f.txt" "withlink"; do
    printf 'index.html\n%s\n' "$bad" > "$FIX/site-files.txt"
    run stage
    if [ "$status" -ne 2 ]; then
      echo "expected exit 2 for symlink entry '$bad', got $status" >&3
      return 1
    fi
    [ ! -e "$OUT" ] || { echo "out dir created despite symlink entry '$bad'" >&3; return 1; }
  done
}

# list_fixture — sorted file list of a dir, to prove a refused run changed nothing.
list_fixture() { (cd "$1" && find . | LC_ALL=C sort); }

@test "an out dir that is, aliases or contains the repo is refused and nothing is deleted" {
  # The fixture sits one level inside ANC so ANC (an ancestor of the repo) can be tried too.
  local ANC; ANC="$(mktemp -d)"
  rm -rf "$FIX"; FIX="$ANC/repo"; mkdir -p "$FIX/docs"
  printf '<html></html>\n' > "$FIX/index.html"
  printf 'doc\n' > "$FIX/docs/d.txt"
  printf 'index.html\n' > "$FIX/site-files.txt"
  ln -s "$FIX" "$BATS_TEST_TMPDIR/alias"
  local before; before="$(list_fixture "$ANC")"
  local bad
  for bad in "$FIX//" "$FIX/." "$FIX/docs" "$FIX/docs/" "$FIX/.git" "$BATS_TEST_TMPDIR/alias" "$BATS_TEST_TMPDIR/alias/" "$ANC" "$ANC/"; do
    run env GRID_DIR="$FIX" bash "$REPO_ROOT/scripts/stage-site.sh" "$bad"
    if [ "$status" -ne 2 ]; then
      echo "expected exit 2 for out dir '$bad', got $status: $output" >&3
      rm -rf "$ANC"
      return 1
    fi
    if [ "$(list_fixture "$ANC")" != "$before" ]; then
      echo "out dir '$bad' changed the fixture tree" >&3
      rm -rf "$ANC"
      return 1
    fi
  done
  rm -rf "$ANC"
}

# --- WP-044: out-dir path normalisation (leading '//', symlink to '/', option-like names) -----------
# SAFETY: every path below lives in a throwaway fixture under BATS_TEST_TMPDIR, and `rm` is a
# stub on PATH that only records its arguments. If the guard ever failed open, nothing would be
# deleted; the test then fails because the stub was called (or the exit code is not 2).
stub_rm_setup() {
  STUBBIN="$BATS_TEST_TMPDIR/stubbin"
  RMLOG="$BATS_TEST_TMPDIR/rm.log"
  mkdir -p "$STUBBIN"
  printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$RMLOG" > "$STUBBIN/rm"
  chmod +x "$STUBBIN/rm"
  : > "$RMLOG"
}

# nested_fixture — ANC/repo (with docs/) entirely inside BATS_TEST_TMPDIR
nested_fixture() {
  ANC="$BATS_TEST_TMPDIR/anc"
  REPO="$ANC/repo"
  mkdir -p "$REPO/docs"
  printf '<html></html>\n' > "$REPO/index.html"
  printf 'doc\n' > "$REPO/docs/d.txt"
  printf 'index.html\n' > "$REPO/site-files.txt"
}

@test "an out dir spelled with a leading '//' or through a symlink to '/' is refused, rm is never called" {
  stub_rm_setup
  nested_fixture
  # a symlink to / is only ever followed to reach the throwaway fixture below it
  ln -s / "$BATS_TEST_TMPDIR/alias_root"
  local before; before="$(list_fixture "$ANC")"
  local bad
  for bad in "/$REPO" "/$ANC" "/$REPO/docs" "/$REPO/." "$BATS_TEST_TMPDIR/alias_root$REPO" "$BATS_TEST_TMPDIR/alias_root$ANC" "$BATS_TEST_TMPDIR/alias_root$REPO/docs"; do
    run env PATH="$STUBBIN:$PATH" GRID_DIR="$REPO" bash "$REPO_ROOT/scripts/stage-site.sh" "$bad"
    if [ "$status" -ne 2 ]; then
      echo "expected exit 2 for out dir '$bad', got $status: $output" >&3
      return 1
    fi
    if [ -s "$RMLOG" ]; then
      echo "rm was called for out dir '$bad': $(cat "$RMLOG")" >&3
      return 1
    fi
    if [ "$(list_fixture "$ANC")" != "$before" ]; then
      echo "out dir '$bad' changed the fixture tree" >&3
      return 1
    fi
  done
}

@test "an out dir spelled with a leading '//' outside the repo is accepted and normalised" {
  stub_rm_setup
  nested_fixture
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run env PATH="$STUBBIN:$PATH" GRID_DIR="$REPO" bash "$REPO_ROOT/scripts/stage-site.sh" "/$BATS_TEST_TMPDIR/elsewhere/site"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere/site/index.html" ]
  # the rm ran on the canonical physical path, not the raw '//...' spelling
  [ "$(cat "$RMLOG")" = "-rf -- $BATS_TEST_TMPDIR/elsewhere/site" ]
}

@test "GRID_DIR spelled with a leading '//' is judged on its canonical path: the repo and its subdir are still refused" {
  stub_rm_setup
  nested_fixture
  local before; before="$(list_fixture "$ANC")"
  local bad
  for bad in "$REPO" "$REPO/docs"; do
    run env PATH="$STUBBIN:$PATH" GRID_DIR="/$REPO" bash "$REPO_ROOT/scripts/stage-site.sh" "$bad"
    if [ "$status" -ne 2 ]; then
      echo "expected exit 2 for out dir '$bad' with a '//' GRID_DIR, got $status: $output" >&3
      return 1
    fi
    if [ -s "$RMLOG" ]; then
      echo "rm was called for out dir '$bad': $(cat "$RMLOG")" >&3
      return 1
    fi
    if [ "$(list_fixture "$ANC")" != "$before" ]; then
      echo "out dir '$bad' changed the fixture tree" >&3
      return 1
    fi
  done
}

@test "a relative out dir that looks like an option is a path, not an option" {
  stub_rm_setup
  nested_fixture
  mkdir -p "$BATS_TEST_TMPDIR/cwd"
  cd "$BATS_TEST_TMPDIR/cwd"
  run env PATH="$STUBBIN:$PATH" GRID_DIR="$REPO" bash "$REPO_ROOT/scripts/stage-site.sh" "-rf"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/cwd/-rf/index.html" ]
  [ "$(cat "$RMLOG")" = "-rf -- $BATS_TEST_TMPDIR/cwd/-rf" ]
}

@test "an out dir under the repo is accepted only as a top-level _name that is not tracked" {
  printf 'index.html\n' > "$FIX/site-files.txt"
  mkdir -p "$FIX/_keep"
  printf 'k\n' > "$FIX/_keep/k.txt"
  ( cd "$FIX" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -q -m init )
  run env GRID_DIR="$FIX" bash "$REPO_ROOT/scripts/stage-site.sh" "$FIX/_keep"
  [ "$status" -eq 2 ]
  [ -f "$FIX/_keep/k.txt" ]
  run env GRID_DIR="$FIX" bash "$REPO_ROOT/scripts/stage-site.sh" "$FIX/_site"
  [ "$status" -eq 0 ]
  [ -f "$FIX/_site/index.html" ]
}

@test "an out dir outside the repo is accepted, even through a not-yet-created parent" {
  printf 'index.html\n' > "$FIX/site-files.txt"
  run env GRID_DIR="$FIX" bash "$REPO_ROOT/scripts/stage-site.sh" "$BATS_TEST_TMPDIR/new/parent/site"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/new/parent/site/index.html" ]
}

# --- WP-044: CI config (workflows are read as text, nothing is run) ----------------------------

@test "every workflow action is pinned to a 40-hex commit SHA" {
  local unpinned
  unpinned="$(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$REPO_ROOT"/.github/workflows/*.yml | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)"
  if [ -n "$unpinned" ]; then
    echo "actions not pinned to a SHA:" >&3
    printf '%s\n' "$unpinned" >&3
    return 1
  fi
  # a vacuous grep (workflow dir moved) must not pass: there are uses: lines to check
  [ "$(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$REPO_ROOT"/.github/workflows/*.yml | wc -l)" -ge 5 ]
}

@test "every actions/checkout step sets persist-credentials: false" {
  local f
  for f in "$REPO_ROOT"/.github/workflows/*.yml; do
    # awk: from each checkout step to the next step, a persist-credentials: false line must appear
    run awk '
      function flush() { if (in_co && !ok) bad++; in_co = 0; ok = 0 }
      /^[[:space:]]*-[[:space:]]/ { flush() }
      /uses:[[:space:]]*actions\/checkout@/ { in_co = 1; seen++ }
      in_co && /persist-credentials:[[:space:]]*false/ { ok = 1 }
      END { flush(); printf "%d %d\n", seen + 0, bad + 0 }
    ' "$f"
    local seen bad
    seen="${output% *}"; bad="${output#* }"
    if [ "$bad" -ne 0 ]; then
      echo "$f: $bad checkout step(s) without persist-credentials: false" >&3
      return 1
    fi
  done
  # the awk must have found the two real checkout steps (tests.yml and pages.yml)
  [ "$(grep -h 'persist-credentials: false' "$REPO_ROOT"/.github/workflows/*.yml | wc -l)" -ge 2 ]
}

@test "tests.yml: only pull_request runs are cancelled, and the job has 25 minutes" {
  grep -qE '^[[:space:]]*cancel-in-progress:.*pull_request' "$REPO_ROOT/.github/workflows/tests.yml"
  grep -qE '^[[:space:]]*timeout-minutes:[[:space:]]*25[[:space:]]*$' "$REPO_ROOT/.github/workflows/tests.yml"
}

@test "dependabot keeps the github-actions pins current" {
  grep -q 'package-ecosystem: "github-actions"' "$REPO_ROOT/.github/dependabot.yml"
}

@test "real repo: stages cleanly, has index.html and no repos/ dir" {
  run bash "$REPO_ROOT/scripts/stage-site.sh" "$BATS_TEST_TMPDIR/realsite"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/realsite/index.html" ]
  [ ! -e "$BATS_TEST_TMPDIR/realsite/repos" ]
}

@test "real repo: every relative src/href in index.html exists in the staged site" {
  bash "$REPO_ROOT/scripts/stage-site.sh" "$BATS_TEST_TMPDIR/realsite" >/dev/null
  local failed=0 seen=0 ref
  while IFS= read -r ref; do
    case "$ref" in http://*|https://*|mailto:*|\#*|"") continue ;; esac
    ref="${ref%%#*}"; ref="${ref%%\?*}"           # drop fragment / query
    [ -n "$ref" ] || continue
    seen=$((seen + 1))
    if [ ! -e "$BATS_TEST_TMPDIR/realsite/$ref" ]; then
      echo "index.html references '$ref' but it is not staged (add it to site-files.txt)" >&3
      failed=1
    fi
  done < <(grep -oE '(src|href)="[^"]*"' "$REPO_ROOT/index.html" | sed -E 's/^(src|href)="//; s/"$//')
  # No local references at all would mean the grep broke, not that the page is fine.
  [ "$seen" -gt 0 ]
  [ "$failed" -eq 0 ]
}
