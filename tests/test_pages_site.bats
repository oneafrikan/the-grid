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

@test "real repo: stages cleanly, has index.html and no repos/ dir" {
  run bash "$REPO_ROOT/scripts/stage-site.sh" "$BATS_TEST_TMPDIR/realsite"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/realsite/index.html" ]
  [ ! -e "$BATS_TEST_TMPDIR/realsite/repos" ]
}

@test "real repo: every relative src/href in index.html exists in the staged site" {
  bash "$REPO_ROOT/scripts/stage-site.sh" "$BATS_TEST_TMPDIR/realsite" >/dev/null
  local failed=0 ref
  while IFS= read -r ref; do
    case "$ref" in http://*|https://*|mailto:*|\#*|"") continue ;; esac
    ref="${ref%%#*}"; ref="${ref%%\?*}"           # drop fragment / query
    [ -n "$ref" ] || continue
    if [ ! -e "$BATS_TEST_TMPDIR/realsite/$ref" ]; then
      echo "index.html references '$ref' but it is not staged (add it to site-files.txt)" >&3
      failed=1
    fi
  done < <(grep -oE '(src|href)="[^"]*"' "$REPO_ROOT/index.html" | sed -E 's/^(src|href)="//; s/"$//')
  [ "$failed" -eq 0 ]
}
