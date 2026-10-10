#!/usr/bin/env bash
# gh-app-token.sh — mint a short-lived GitHub App INSTALLATION token.
#
# Why: the unattended issue-loop must not hold a long-lived credential. A GitHub
# App installed on one repository (no Administration, no Workflows permission)
# mints a 1-hour token per run from its private key; nothing valid-until-revoked
# sits on disk except the key, which can be deleted in the App settings.
#
# Usage:  gh-app-token.sh [--json]
#   (no flag)  stdout is the installation token and nothing else
#   --json     stdout is the whole token response as one JSON line
#              (token, expires_at, permissions, repository_selection)
#
# Input (environment):
#   GH_APP_ID               required  the App ID
#   GH_APP_KEY_FILE         optional  PEM private key; default $HOME/.config/the-grid/app.pem
#                                     (must not be group/world accessible)
#   GH_APP_INSTALLATION_ID  optional  installation id; when absent the App's single
#                                     installation is looked up (GET /app/installations)
#   GH_API_URL              optional  default https://api.github.com (a test hook)
#
# Exit codes (on any failure: ONE line on stderr, NOTHING on stdout):
#   0  token printed
#   1  GitHub API error (non-2xx, no/ambiguous installation, response without a token)
#   2  configuration error (GH_APP_ID unset, key missing/unreadable/group-or-world
#      accessible/unusable, openssl, curl or jq missing, bad argument)
#
# Method: RS256 JWT { iat: now-60, exp: now+540, iss: GH_APP_ID } signed with
# `openssl dgst -sha256 -sign`, then POST /app/installations/<id>/access_tokens
# with curl. The key and the JWT are never printed or logged, and this script
# never runs under `set -x`.
#
# Needs only openssl, curl, jq (+ coreutils). Bash 3.2 compatible.

set -euo pipefail

# fail <code> <message> — one stderr line, nothing on stdout.
fail() {
  local code="$1"; shift
  echo "gh-app-token: $*" >&2
  exit "$code"
}

WANT_JSON=0
case "${1:-}" in
  "") ;;
  --json) WANT_JSON=1 ;;
  *) fail 2 "unknown argument '$1' (usage: gh-app-token.sh [--json])" ;;
esac

for tool in openssl curl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail 2 "$tool is required but not on PATH"
done

APP_ID="${GH_APP_ID:-}"
[ -n "$APP_ID" ] || fail 2 "GH_APP_ID is not set"
# The id goes into JSON unescaped, so only a plain token is accepted.
case "$APP_ID" in
  *[!A-Za-z0-9_-]*) fail 2 "GH_APP_ID must be the numeric App ID" ;;
esac

KEY="${GH_APP_KEY_FILE:-$HOME/.config/the-grid/app.pem}"
[ -f "$KEY" ] || fail 2 "App private key not found at $KEY (see the issue-loop README)"
[ -r "$KEY" ] || fail 2 "App private key at $KEY is not readable"
# Refuse a key that group/other can touch. (`find -perm -077` would need ALL six
# bits set, so each bit is tested on its own; works the same on GNU and BSD find.)
if [ -n "$(find "$KEY" \( -perm -040 -o -perm -020 -o -perm -010 -o -perm -004 -o -perm -002 -o -perm -001 \) -print 2>/dev/null)" ]; then
  fail 2 "App private key $KEY is group/world accessible; run: chmod 600 $KEY"
fi

INSTALL_ID="${GH_APP_INSTALLATION_ID:-}"
case "$INSTALL_ID" in
  *[!0-9]*) fail 2 "GH_APP_INSTALLATION_ID must be numeric" ;;
esac

API="${GH_API_URL:-https://api.github.com}"
API="${API%/}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# b64url — stdin to base64url without padding.
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# --- JWT: header.claims.signature ---
now="$(date +%s)"
header='{"alg":"RS256","typ":"JWT"}'
claims="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"$APP_ID\"}"
signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$claims" | b64url)"
if ! signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY" 2>/dev/null | b64url)" \
    || [ -z "$signature" ]; then
  fail 2 "openssl could not sign with $KEY (is it an RSA private key in PEM form?)"
fi
JWT="$signing_input.$signature"

# api <METHOD> <url> — response body in $TMP, status in $HTTP_CODE.
# Status comes from -w (not --fail-with-body, which older macOS curl lacks).
HTTP_CODE=""
api() {
  HTTP_CODE="$(curl -sS -o "$TMP" -w '%{http_code}' -X "$1" \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$2" 2>/dev/null)" || fail 1 "request to $2 failed (network error)"
}

# --- installation id ---
if [ -z "$INSTALL_ID" ]; then
  api GET "$API/app/installations"
  case "$HTTP_CODE" in
    2??) ;;
    *) fail 1 "GET /app/installations returned HTTP $HTTP_CODE" ;;
  esac
  count="$(jq -r 'if type == "array" then length else -1 end' "$TMP" 2>/dev/null || echo -1)"
  case "$count" in
    0) fail 1 "App is not installed on any account" ;;
    1) INSTALL_ID="$(jq -r '.[0].id' "$TMP")" ;;
    -1) fail 1 "GET /app/installations returned an unexpected body" ;;
    *) fail 1 "App has $count installations; set GH_APP_INSTALLATION_ID" ;;
  esac
  case "$INSTALL_ID" in
    ""|null|*[!0-9]*) fail 1 "GET /app/installations returned an installation without a numeric id" ;;
  esac
fi

# --- installation token ---
api POST "$API/app/installations/$INSTALL_ID/access_tokens"
case "$HTTP_CODE" in
  2??) ;;
  *) fail 1 "POST /app/installations/$INSTALL_ID/access_tokens returned HTTP $HTTP_CODE" ;;
esac
token="$(jq -r '.token // empty' "$TMP" 2>/dev/null || true)"
[ -n "$token" ] || fail 1 "access_tokens response (HTTP $HTTP_CODE) had no token"

if [ "$WANT_JSON" = 1 ]; then
  jq -c . "$TMP"
else
  printf '%s\n' "$token"
fi
