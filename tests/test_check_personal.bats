#!/usr/bin/env bats
# Tests for scripts/check-personal.sh (the personal-data scan).
#
# Every test scans a THROWAWAY git repo under $BATS_TEST_TMPDIR (GRID_DIR points
# at it) and sets GRID_PRIVATE_DENYLIST explicitly, so nothing here ever reads
# the real repo, the real $HOME or the real private denylist. The fixtures below
# deliberately contain flaggable strings; this file is on the scan's path
# allowlist for that reason.

REAL_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REAL_ROOT/scripts/check-personal.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/scripts"
  git -C "$REPO" init -q
  # The script reads its rule files from $GRID_DIR/scripts, so seed the temp repo
  # with the real ones (tests that need a different rule edit these copies).
  cp "$REAL_ROOT/scripts/personal-patterns.txt" \
     "$REAL_ROOT/scripts/personal-allow-paths.txt" \
     "$REAL_ROOT/scripts/personal-denylist.example.txt" "$REPO/scripts/"

  # Isolation: scan the temp repo, never a real home or denylist.
  export GRID_DIR="$REPO"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GRID_PRIVATE_DENYLIST=""          # private half off unless a test sets it
  unset GRID_REQUIRE_DENYLIST GRID_MAX_BYTES
}

# put PATH TEXT: write TEXT as a line in PATH (created under the temp repo).
put() {
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "$2" > "$REPO/$1"
}

# track: stage everything so `git ls-files` (what the scan reads) sees it.
track() { git -C "$REPO" add -A; }

# scan [args]: stage then run the scan, leaving $status / $output for assertions.
scan() { track; run bash "$SCRIPT" "$@"; }

# --- (a) things that must be flagged -------------------------------------------

@test "(a) a real-looking email is flagged, exit 1" {
  put notes.md "contact jane.doe@corp-mail.org for access"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1: [email]"* ]]
}

@test "(a) a /Users/<name>/ home path is flagged" {
  put notes.md "see /Users/jsmith/projects/x"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1: [home-mac]"* ]]
}

@test "(a) a /home/<name>/ home path is flagged" {
  put notes.md "see /home/jsmith/projects/x"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1: [home-linux]"* ]]
}

@test "(a) a token-shaped string is flagged" {
  put notes.md "key ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1: [token]"* ]]
}

@test "(a) a private IP is flagged" {
  put notes.md "server at 192.168.1.20"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1: [private-ip]"* ]]
}

# --- (b) placeholders that must NOT be flagged ---------------------------------

@test "(b) documented placeholders and look-alikes are not flagged" {
  put notes.md "mail you@example.com"
  put remote.md "clone git@github.com:o/r.git"
  put url.md "https://user:tok@github.com/o/r.git"
  put home1.md "/Users/you/x"
  put home2.md "/Users/alice/x"
  put aws.md "AKIAIOSFODNN7EXAMPLE"
  put id.md "finance-desk-finance-risk-officer"
  scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"personal: 0 finding(s)"* ]]
}

@test "(b) a dot-dir after /home/ (fake-HOME path) is not a user name" {
  put notes.md 'tmp="$t/home/.claude/skills"; ls /Users/.cache/x'
  scan
  [ "$status" -eq 0 ]
}

# --- (c) / (o) scoped author-name rule -----------------------------------------

@test "(c) Gareth is flagged in skills/ but not in README.md" {
  put skills/x/SKILL.md "Ask Gareth first."
  put README.md "Gareth built this."
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/x/SKILL.md:1: [author-name-in-rendered-text]"* ]]
  [[ "$output" != *"README.md"* ]]
}

@test "(o) Gareth is flagged in hooks/ and automation-factory/patterns/" {
  put hooks/x.sh "# Gareth wrote this"
  put automation-factory/patterns/p/README.md "Gareth's loop"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"hooks/x.sh:1: [author-name-in-rendered-text]"* ]]
  [[ "$output" == *"automation-factory/patterns/p/README.md:1: [author-name-in-rendered-text]"* ]]
}

# --- (d) / (e) / (f) / (l) private denylist -----------------------------------

@test "(d) a denylist hit prints [private:N] and never the matched text" {
  put notes.md "deployed to secretbox-9000 yesterday"
  printf '# comment\n\ndeny-i\t*\tmy-host\tsecretbox-[0-9]+\n' > "$BATS_TEST_TMPDIR/deny.txt"
  GRID_PRIVATE_DENYLIST="$BATS_TEST_TMPDIR/deny.txt" scan
  [ "$status" -eq 1 ]
  # N is the rule's position among rule lines (comments/blanks not counted): 1.
  [[ "$output" == *"notes.md:1: [private:1]"* ]]
  [[ "$output" != *"secretbox"* ]]
  [[ "$output" != *"my-host"* ]]
}

@test "(e) an absent denylist prints the generic-only notice and exits 0 on a clean tree" {
  put notes.md "nothing personal here"
  GRID_PRIVATE_DENYLIST="$BATS_TEST_TMPDIR/does-not-exist.txt" scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"personal: private denylist not found - generic patterns only"* ]]
}

@test "(e) with GRID_PRIVATE_DENYLIST unset the default path is under \$HOME (the fake one)" {
  put notes.md "nothing personal here"
  unset GRID_PRIVATE_DENYLIST
  scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"generic patterns only"* ]]
  # ...and a file at the default location under the fake HOME IS picked up.
  mkdir -p "$HOME/.the-grid-private"
  printf 'deny\t*\tx\tnothing personal\n' > "$HOME/.the-grid-private/denylist.txt"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"[private:1]"* ]]
}

@test "(f) an empty GRID_PRIVATE_DENYLIST disables the private half" {
  put notes.md "deployed to secretbox-9000"
  printf 'deny\t*\tmy-host\tsecretbox\n' > "$BATS_TEST_TMPDIR/deny.txt"
  # With the file: flagged. With the variable set to empty: not.
  GRID_PRIVATE_DENYLIST="$BATS_TEST_TMPDIR/deny.txt" scan
  [ "$status" -eq 1 ]
  GRID_PRIVATE_DENYLIST="" scan
  [ "$status" -eq 0 ]
}

@test "(l) GRID_REQUIRE_DENYLIST=1 with a missing denylist exits 1 with the required line" {
  put notes.md "nothing personal here"
  GRID_REQUIRE_DENYLIST=1 GRID_PRIVATE_DENYLIST="$BATS_TEST_TMPDIR/missing.txt" scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"personal: private denylist required but not found"* ]]
}

# --- (g) path allowlist ---------------------------------------------------------

@test "(g) a path in personal-allow-paths.txt is skipped" {
  put vendor/a.md "mail jane.doe@corp-mail.org"
  put other/b.md "mail jane.doe@corp-mail.org"
  printf 'vendor/*\t# vendored third-party text\n' >> "$REPO/scripts/personal-allow-paths.txt"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"other/b.md:1: [email]"* ]]
  [[ "$output" != *"vendor/a.md"* ]]
}

@test "(g) an allowlist line without a reason is a usage error (exit 2)" {
  put notes.md "clean"
  printf 'vendor/*\n' >> "$REPO/scripts/personal-allow-paths.txt"
  scan
  [ "$status" -eq 2 ]
}

# --- (h) file-type and size blocks ---------------------------------------------

@test "(h) a tracked .zip is flagged" {
  printf 'PK' > "$REPO/x.zip"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"x.zip: [blocked-type:zip]"* ]]
}

@test "(h) a file over GRID_MAX_BYTES is flagged, one under it is not" {
  put big.txt "0123456789012345678901234567890123456789"
  put small.txt "ok"
  GRID_MAX_BYTES=20 scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"big.txt: [too-large]"* ]]
  [[ "$output" != *"small.txt"* ]]
}

# --- (i) positional args -------------------------------------------------------

@test "(i) positional args restrict the scan to those tracked paths" {
  put a.md "mail jane.doe@corp-mail.org"
  put b.md "mail jane.doe@corp-mail.org"
  scan b.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"b.md:1: [email]"* ]]
  [[ "$output" != *"a.md:1"* ]]
  scan a.md b.md
  [[ "$output" == *"personal: 2 finding(s)"* ]]
}

# --- (j) untracked files and gitlinks ------------------------------------------

@test "(j) untracked files are ignored" {
  put clean.md "fine"
  track
  put local-notes.md "mail jane.doe@corp-mail.org"   # written after staging: untracked
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "(j) a gitlink (submodule) is not scanned" {
  put clean.md "fine"
  # A nested repo whose own content is flaggable, recorded in the outer index as a gitlink.
  git init -q "$REPO/sub"
  printf 'mail jane.doe@corp-mail.org\n' > "$REPO/sub/leak.md"
  git -C "$REPO/sub" add leak.md
  git -C "$REPO/sub" -c user.name=t -c user.email=t@example.com commit -q -m x
  git -C "$REPO" add sub 2>/dev/null
  [ "$(git -C "$REPO" ls-files -s sub | cut -c1-6)" = "160000" ]
  scan
  [ "$status" -eq 0 ]
}

# --- (k) isolation -------------------------------------------------------------

@test "(k) the scan reads the repo in GRID_DIR, not the real repo" {
  put notes.md "clean"
  scan
  [ "$status" -eq 0 ]
  # The real repo would not be a 1-file clean tree; "0 finding(s)" on the temp repo
  # and the temp repo's own rule files being used proves GRID_DIR is honoured.
  printf 'deny\t*\tonly-in-temp\tclean\n' >> "$REPO/scripts/personal-patterns.txt"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes.md:1: [only-in-temp]"* ]]
}

# --- (m) token output ----------------------------------------------------------

@test "(m) a token prints exactly path:line: [token] and never the token text" {
  put notes.md "key ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *$'\n'"notes.md:1: [token]"$'\n'* ]]
  [[ "$output" != *"ghp_"* ]]
}

@test "(m) a token on a line that also trips another rule is not echoed either" {
  put notes.md "ghp_abcdefghijklmnopqrstuvwxyz0123456789 at 192.168.1.20"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"[private-ip]"* ]]
  [[ "$output" != *"ghp_"* ]]
}

# --- (n) tailnet and CGNAT range edges -----------------------------------------

@test "(n) a *.ts.net host and the bottom of 100.64/10 are flagged" {
  put a.md "host mybox.tail1234.ts.net"
  put b.md "ip 100.64.0.1"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.md:1: [tailnet]"* ]]
  [[ "$output" == *"b.md:1: [cgnat-ip]"* ]]
}

@test "(n) addresses just outside 100.64/10 are not flagged" {
  put below.md "ip 100.63.255.1"
  put above.md "ip 100.128.0.1"
  scan
  [ "$status" -eq 0 ]
}

@test "(n) the top of 100.64/10 (100.127) is flagged" {
  put top.md "ip 100.127.255.254"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"top.md:1: [cgnat-ip]"* ]]
}

# --- usage ---------------------------------------------------------------------

@test "an unknown option exits 2" {
  run bash "$SCRIPT" --nope
  [ "$status" -eq 2 ]
}

@test "the scan is idempotent: a second run gives the same output" {
  put notes.md "mail jane.doe@corp-mail.org"
  scan
  first="$output"
  scan
  [ "$output" = "$first" ]
}

# --- WP-040: bypasses of the scan ------------------------------------------------------------
# Tokens are assembled at run time so no secret-shaped string sits in the repo.
tok() { printf '%s_%s' "$1" "$(head -c "${2:-36}" /dev/zero | tr '\0' a)"; }

@test "(p) an allowed word does not mask a real hit on the same line" {
  put a.md "jane.doe@corp-mail.org git@github.com:o/r.git"
  put b.md "jane.doe@corp-mail.org noreply"
  put c.md "x@example.com jane.doe@corp-mail.org"
  put d.md "/home/user1/x"
  put e.md "/home/alice2/x"
  put f.md "/home/bobsmith/x"
  put g.md "/Users/namesmith/x"
  put h.md "$(tok ghp) EXAMPLE"
  scan
  [ "$status" -eq 1 ]
  local f
  for f in a b c; do [[ "$output" == *"$f.md:1: [email]"* ]] || { echo "missed $f"; false; }; done
  [[ "$output" == *"d.md:1: [home-linux]"* ]]
  [[ "$output" == *"e.md:1: [home-linux]"* ]]
  [[ "$output" == *"f.md:1: [home-linux]"* ]]
  [[ "$output" == *"g.md:1: [home-mac]"* ]]
  [[ "$output" == *"h.md:1: [token]"* ]]
}

@test "(p) genuine placeholders still pass, also several on one line" {
  put a.md "mail you@example.com or git@github.com:o/r.git, see /home/bob/x and /Users/<name>/y"
  put b.md "AKIAIOSFODNN7EXAMPLE and /home/you/x"
  put c.md "/home/user/x /home/name/x /Users/username/x"
  scan
  [ "$status" -eq 0 ]
}

@test "(q) a file with a NUL byte or UTF-16 text is reported unscannable until path-allowed" {
  printf 'a\0b contact jane.doe@corp-mail.org\n' > "$REPO/blob.dat"
  python3 -c "
import sys
open(sys.argv[1], 'wb').write('contact jane.doe@corp-mail.org\n'.encode('utf-16'))" "$REPO/wide.txt"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"blob.dat: [unscannable-binary]"* ]]
  [[ "$output" == *"wide.txt: [unscannable-binary]"* ]]
  [[ "$output" == *"personal-allow-paths.txt"* ]]
  printf 'blob.dat\t# fixture binary, reviewed\nwide.txt\t# fixture utf-16 text, reviewed\n' >> "$REPO/scripts/personal-allow-paths.txt"
  scan
  [ "$status" -eq 0 ]
}

@test "(q) an empty file and a plain text file are not unscannable" {
  : > "$REPO/empty.txt"
  put plain.md "just text"
  scan
  [ "$status" -eq 0 ]
}

@test "(r) key, credential and archive file names and extensions are blocked" {
  local n
  for n in id_rsa id_rsa.pub id_ed25519 id_ecdsa_work .env.local .env.production .netrc .npmrc \
           credentials.json credentials-prod.json known_hosts \
           x.p12 x.pfx x.jks x.kdbx x.sqlite3 x.7z x.rar x.docx x.xlsx; do
    rm -rf "$REPO/sub"; mkdir -p "$REPO/sub"
    git -C "$REPO" rm -rq --cached sub 2>/dev/null || true
    printf 'x\n' > "$REPO/sub/$n"
    scan
    [ "$status" -eq 1 ] || { echo "not blocked: $n"; false; }
    [[ "$output" == *"sub/$n: [blocked-type:"* ]] || { echo "no label for $n: $output"; false; }
  done
}

@test "(r) .env.example and an ordinary credentials-free json are not blocked" {
  put .env.example "KEY=value"
  put config.json '{"a": 1}'
  scan
  [ "$status" -eq 0 ]
}

@test "(s) more token families are flagged without printing the token" {
  local t
  for t in "$(tok gho)" "$(tok ghu)" "$(tok ghs)" "$(tok ghr)" "glpat-$(head -c 24 /dev/zero | tr '\0' a)" \
           "AIza$(head -c 35 /dev/zero | tr '\0' a)" "npm_$(head -c 36 /dev/zero | tr '\0' a)" \
           "$(printf 'sk_%s' live)_$(head -c 24 /dev/zero | tr '\0' a)"; do
    put notes.md "key $t"
    scan
    [ "$status" -eq 1 ] || { echo "missed ${t:0:6}"; false; }
    [[ "$output" == *"notes.md:1: [token]"* ]]
    [[ "$output" != *"$t"* ]]
  done
}

@test "(s) a Windows home path is flagged; placeholders are not" {
  put a.md 'see C:\Users\jsmith\proj'
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.md:1: [home-win]"* ]]
  put a.md 'see C:\Users\you\proj and C:\Users\<name>\x'
  scan
  [ "$status" -eq 0 ]
}

@test "(s) a tracked file NAMED after an address or a home path is flagged" {
  printf 'x\n' > "$REPO/jane.doe@corp-mail.org.txt"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"[path-name:email]"* ]]
}

@test "(t) the author name is matched case-insensitively and also in dist/personas and evals" {
  put skills/x/SKILL.md "ask gareth first"
  put dist/personas/x.md "GARETH decides"
  put evals/case/c.md "Gareth wants this"
  put README.md "gareth built this"
  scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/x/SKILL.md:1: [author-name-in-rendered-text]"* ]]
  [[ "$output" == *"dist/personas/x.md:1: [author-name-in-rendered-text]"* ]]
  [[ "$output" == *"evals/case/c.md:1: [author-name-in-rendered-text]"* ]]
  [[ "$output" != *"README.md"* ]]
}
