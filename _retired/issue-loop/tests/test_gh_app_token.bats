#!/usr/bin/env bats
# scripts/lib/gh-app-token.sh — GitHub App installation-token minting.
# Offline: a throwaway RSA key made at test time, a stub curl (tests/helpers/stubs.bash),
# HOME and TMPDIR in temp dirs. The real GitHub API is never contacted.

bats_require_minimum_version 1.5.0
load helpers/stubs

SCRIPT="$BATS_TEST_DIRNAME/../scripts/lib/gh-app-token.sh"

setup_file() {
  # Two throwaway keys: the signature must verify against the first only.
  openssl genrsa -out "$BATS_FILE_TMPDIR/app.pem" 2048 2>/dev/null
  chmod 600 "$BATS_FILE_TMPDIR/app.pem"
  openssl rsa -in "$BATS_FILE_TMPDIR/app.pem" -pubout -out "$BATS_FILE_TMPDIR/pub.pem" 2>/dev/null
  openssl genrsa -out "$BATS_FILE_TMPDIR/other.pem" 2048 2>/dev/null
  openssl rsa -in "$BATS_FILE_TMPDIR/other.pem" -pubout -out "$BATS_FILE_TMPDIR/other-pub.pem" 2>/dev/null
}

setup() {
  T="$(mktemp -d)"
  export HOME="$T/home" TMPDIR="$T/tmp"
  mkdir -p "$HOME" "$TMPDIR"
  make_stubs
  KEY="$BATS_FILE_TMPDIR/app.pem"
  GOODPATH="$STUB_DIR:/usr/bin:/bin"
}

teardown() {
  clean_stubs
  rm -rf "$T"
}

# mint [args...] — run the script in a clean environment, stdout and stderr separate.
# Reads PATH_OVERRIDE and EXTRA_ENV (space-separated KEY=VAL words) when set.
mint() {
  # shellcheck disable=SC2086
  run --separate-stderr env -i HOME="$HOME" TMPDIR="$TMPDIR" STUB_LOG="$STUB_LOG" \
    PATH="${PATH_OVERRIDE:-$GOODPATH}" \
    GH_APP_ID="${APP_ID-123}" GH_APP_KEY_FILE="${KEY_FILE-$KEY}" \
    ${INSTALL_ID:+GH_APP_INSTALLATION_ID=$INSTALL_ID} \
    ${STUB_INSTALLATIONS_JSON:+STUB_INSTALLATIONS_JSON="$STUB_INSTALLATIONS_JSON"} \
    ${STUB_INSTALLATIONS_CODE:+STUB_INSTALLATIONS_CODE=$STUB_INSTALLATIONS_CODE} \
    ${STUB_TOKEN_JSON:+STUB_TOKEN_JSON="$STUB_TOKEN_JSON"} \
    ${STUB_TOKEN_CODE:+STUB_TOKEN_CODE=$STUB_TOKEN_CODE} \
    bash "$SCRIPT" "$@"
  assert_no_leak
}

# assert_no_leak — case 7: neither stdout nor stderr ever shows the key, the JWT or a PEM header.
assert_no_leak() {
  local all="$output$stderr" jwt keybody
  case "$all" in *BEGIN*) echo "PEM header leaked: $all"; return 1 ;; esac
  keybody="$(sed -n '2p' "$BATS_FILE_TMPDIR/app.pem")"
  case "$all" in *"$keybody"*) echo "key body leaked"; return 1 ;; esac
  jwt="$(logged_jwt)"
  if [ -n "$jwt" ]; then
    case "$all" in *"$jwt"*) echo "JWT leaked"; return 1 ;; esac
  fi
  return 0
}

# logged_jwt — the bearer token of the first curl call in the stub log.
logged_jwt() {
  sed -n 's/.*Authorization: Bearer \([^ ]*\).*/\1/p' "$STUB_LOG" | sed -n '1p'
}

b64url_decode() {
  local s
  s="$(printf '%s' "$1" | tr '_-' '/+')"
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done
  printf '%s' "$s" | openssl base64 -d -A
}

@test "happy path: stdout is exactly the token; GET installations then POST access_tokens, bearer on both" {
  mint
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_FAKE_TOKEN_123" ]
  [ -z "$stderr" ]
  get_line="$(grep -n 'curl .*-X GET .*/app/installations$' "$STUB_LOG" | cut -d: -f1)"
  post_line="$(grep -n 'curl .*-X POST .*/app/installations/4242/access_tokens$' "$STUB_LOG" | cut -d: -f1)"
  [ -n "$get_line" ]
  [ -n "$post_line" ]
  [ "$get_line" -lt "$post_line" ]
  [ "$(grep -c 'Authorization: Bearer ' "$STUB_LOG")" -eq 2 ]
}

@test "JWT: RS256 header, iss/iat/exp claims, valid signature, base64url only" {
  mint
  [ "$status" -eq 0 ]
  jwt="$(logged_jwt)"
  [ -n "$jwt" ]
  case "$jwt" in *[+/=]*) echo "not base64url: $jwt"; false ;; esac
  h="${jwt%%.*}"; rest="${jwt#*.}"; c="${rest%%.*}"; s="${rest#*.}"
  [ "$(printf '%s' "$jwt" | tr -cd '.' | wc -c | tr -d ' ')" -eq 2 ]
  [ "$(b64url_decode "$h")" = '{"alg":"RS256","typ":"JWT"}' ]
  claims="$(b64url_decode "$c")"
  now="$(date +%s)"
  [ "$(printf '%s' "$claims" | jq -r .iss)" = "123" ]
  iat="$(printf '%s' "$claims" | jq -r .iat)"
  exp="$(printf '%s' "$claims" | jq -r .exp)"
  [ "$iat" -le "$now" ]
  [ "$exp" -gt "$now" ]
  [ $((exp - now)) -le 600 ]
  # signature verifies against the key's public half, and not against another key
  printf '%s' "$h.$c" > "$T/msg"
  b64url_decode "$s" > "$T/sig"
  openssl dgst -sha256 -verify "$BATS_FILE_TMPDIR/pub.pem" -signature "$T/sig" "$T/msg"
  refute openssl dgst -sha256 -verify "$BATS_FILE_TMPDIR/other-pub.pem" -signature "$T/sig" "$T/msg"
}

@test "a configured installation id skips the installations lookup" {
  INSTALL_ID=7 mint
  [ "$status" -eq 0 ]
  refute grep -q -- '-X GET' "$STUB_LOG"
  grep -q -- '-X POST .*/app/installations/7/access_tokens' "$STUB_LOG"
}

@test "--json prints the whole response with token and permissions" {
  mint --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.token == "ghs_FAKE_TOKEN_123" and (.permissions | type == "object") and .repository_selection == "selected"'
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "exit 2, empty stdout: GH_APP_ID unset" {
  APP_ID="" mint
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "GH_APP_ID"
}

@test "exit 2, empty stdout: key file missing" {
  KEY_FILE="$T/nope.pem" mint
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "not found"
}

@test "exit 2, empty stdout: key file mode 644" {
  cp "$KEY" "$T/loose.pem"
  chmod 644 "$T/loose.pem"
  KEY_FILE="$T/loose.pem" mint
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "chmod 600"
}

@test "exit 2, empty stdout: mode 640 and 604 are refused too (any group/other bit)" {
  cp "$KEY" "$T/loose.pem"
  chmod 640 "$T/loose.pem"
  KEY_FILE="$T/loose.pem" mint
  [ "$status" -eq 2 ]
  chmod 604 "$T/loose.pem"
  KEY_FILE="$T/loose.pem" mint
  [ "$status" -eq 2 ]
}

@test "exit 2, empty stdout: a file that is not a PEM key" {
  echo "this is not a key" > "$T/junk.pem"
  chmod 600 "$T/junk.pem"
  KEY_FILE="$T/junk.pem" mint
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "could not sign"
}

# A PATH made of symlinks to everything the script needs except one tool.
path_without() {
  local skip="$1" d="$T/path-without-$1" t src
  mkdir -p "$d"
  for t in bash env jq date mktemp rm tr find cat sed openssl curl; do
    [ "$t" = "$skip" ] && continue
    if [ -x "$STUB_DIR/$t" ]; then src="$STUB_DIR/$t"; else src="$(command -v "$t")"; fi
    ln -sf "$src" "$d/$t"
  done
  echo "$d"
}

@test "exit 2, empty stdout: openssl not on PATH" {
  PATH_OVERRIDE="$(path_without openssl)" mint
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "openssl"
}

@test "exit 2, empty stdout: curl not on PATH" {
  PATH_OVERRIDE="$(path_without curl)" mint
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "curl"
}

@test "exit 1, empty stdout: no installation" {
  STUB_INSTALLATIONS_JSON='[]' mint
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "not installed"
}

@test "exit 1, empty stdout: several installations and no GH_APP_INSTALLATION_ID" {
  STUB_INSTALLATIONS_JSON='[{"id":1},{"id":2}]' mint
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "GH_APP_INSTALLATION_ID"
}

@test "exit 1, empty stdout: installations lookup answers 401" {
  STUB_INSTALLATIONS_CODE=401 mint
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "HTTP 401"
}

@test "exit 1, empty stdout: access_tokens answers 404, then 403" {
  STUB_TOKEN_CODE=404 mint
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "HTTP 404"
  STUB_TOKEN_CODE=403 mint
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "HTTP 403"
}

@test "exit 1, empty stdout: a 2xx body without a token" {
  STUB_TOKEN_JSON='{}' mint
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "no token"
}

@test "every failure is exactly one stderr line" {
  STUB_TOKEN_CODE=403 mint
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  APP_ID="" mint
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "an unknown argument is a config error" {
  mint --verbose
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "runs on the system bash (3.2 on macOS): no bash-4 constructs" {
  refute grep -nE 'mapfile|readarray|declare -A|\$\{[A-Za-z_]+(,,|\^\^)\}|\|&|local -n|wait -n' "$SCRIPT"
}
