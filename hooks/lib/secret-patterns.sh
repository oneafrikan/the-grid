#!/usr/bin/env bash
# hooks/lib/secret-patterns.sh — the one secret-pattern table (sourced, never executed).
#
# Callers: hooks/scripts/pre-bash-secret-scan.sh (added lines of a commit diff) and,
# from a later change group, the auto-handoff worker (the two handoff files). One
# table, two callers, so the commit guard and the worker can never disagree.
#
#   secret_match_line <text>       prints the name of the first matching pattern and
#                                  returns 0; returns 1 for no match or an exempt line
#   secret_scan_file <path>        prints "<path>:<line>: <name> (<4 chars>...)" per hit
#                                  (at most 10); returns 1 when anything was printed
#   secret_sensitive_name <name>   returns 0 for a sensitive file BASENAME
#
# Patterns are POSIX extended regular expressions with POSIX classes only (no \s,
# no PCRE) so they behave the same on GNU and BSD systems. They are matched with
# bash's [[ =~ ]] (the system regcomp, same ERE dialect as grep -E) instead of
# forking grep per line, so a large diff is scanned in seconds, not minutes.
# An explicit non-alphanumeric boundary stands in front of prefix tokens: that is
# what keeps "task-<40 letters>" from matching the sk- pattern.
#
# Only the first four characters of a match are ever printed, never the value.
#
# Exemptions: a match is dropped when the MATCHED TEXT (the token itself, not the line)
# holds a placeholder word (example, changeme, ...), so a real token that merely sits
# next to the word "example" in a comment still blocks. A line carrying the allow pragma
# is skipped as a whole: that is a line-level human override, kept in code only. It is
# deliberately NOT documented in the README or named in a block message, so an agent
# reading either does not learn how to silence the check.
#
# The table is the whole scope: no entropy scoring, no tokens split over lines, and an
# unquoted assigned value made only of letters is not flagged (see _assigned_value).

# --- the table: SECRET_NAMES[i] / SECRET_RES[i] / SECRET_BOUND[i] ----------------
# SECRET_BOUND[i]=1 means capture group 1 of the regex is the boundary character,
# which is stripped before taking the "first 4 chars" shown in a finding.
# assigned-secret MUST stay last: _secret_match gives it the case-insensitive and
# value-checking treatment by name.
SECRET_NAMES=(
  aws-access-key private-key github-token github-pat gitlab-pat npm-token
  stripe-live anthropic-key generic-sk slack-token google-api-key jwt
  azure-account-key bearer-token db-url-password sendgrid-key twilio-key mailgun-key
  huggingface-token digitalocean-token shopify-token stripe-test stripe-webhook
  slack-webhook google-oauth assigned-secret
)
SECRET_RES=(
  '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)'
  '-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----'
  '(^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{36,}'
  '(^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{22,}'
  '(^|[^A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}'
  '(^|[^A-Za-z0-9])npm_[A-Za-z0-9]{36}'
  '(^|[^A-Za-z0-9])[sr]k_live_[A-Za-z0-9]{16,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{32,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  '(^|[^A-Za-z0-9])AIza[0-9A-Za-z_-]{35}'
  '(^|[^A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
  # providers (WP-023, D38)
  'AccountKey=[A-Za-z0-9+/]{86}'
  '[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
  '://[^/:@[:space:]]+:[^/:@[:space:]$<{][^/:@[:space:]]{2,}@'
  '(^|[^A-Za-z0-9])SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}'
  '(^|[^A-Za-z0-9])SK[0-9a-fA-F]{32}([^A-Za-z0-9]|$)'
  '(^|[^A-Za-z0-9])key-[0-9A-Za-z]{32}([^A-Za-z0-9]|$)'
  '(^|[^A-Za-z0-9])hf_[A-Za-z0-9]{30,}'
  '(^|[^A-Za-z0-9])dop_v1_[0-9a-f]{64}'
  '(^|[^A-Za-z0-9])shpat_[0-9a-fA-F]{32}'
  '(^|[^A-Za-z0-9])[sr]k_test_[A-Za-z0-9]{16,}'
  '(^|[^A-Za-z0-9])whsec_[A-Za-z0-9]{16,}'
  'hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+'
  '(^|[^A-Za-z0-9])ya29\.[0-9A-Za-z_-]{20,}'
  # assigned-secret: the KEY side only. The key word may sit inside an identifier
  # (AWS_SECRET_ACCESS_KEY, JWT_SECRET_KEY) and may be followed by a closing quote
  # (a JSON key, "password": ...). Case-insensitive (set by _secret_match). The VALUE
  # side is judged in bash by _assigned_value, because "16+ characters with a digit and
  # no parentheses" cannot be said in one ERE.
  '[A-Za-z0-9_]*(secret|token|passw(or)?d|api[_-]?key|access[_-]?key|private[_-]?key)[A-Za-z0-9_]*["'"'"']?[[:space:]]*[:=]'
)
SECRET_BOUND=(1 0 1 1 1 1 1 0 1 0 1 1  0 0 0 1 1 1 1 1 1 1 1 0 1  0)

# Exempt token text (case-insensitive): documentation keys and templated values. Applied
# to the matched token only, never to the whole line.
_SECRET_EXEMPT='example|placeholder|changeme|your[_-]|xxxxxxxx|redacted'
# The line-level human override (see the header).
_SECRET_PRAGMA='grid:allow-secret'

# secret_prefilter_re
#   Prints one extended regex that matches anything ANY table row could match: the rows
#   joined with |. Callers run `grep -Ei` with it over a large diff and hand only the hits
#   to _secret_match, so a 6,000-line diff costs one grep, not 6,000 bash regex calls
#   (about 1.2 ms each, which blew the 5 s hook timeout). It is a SUPERSET filter: -i
#   widens the case-sensitive rows, and _secret_match stays the only authority, so a
#   false hit is dropped there. Derived from the table, so it cannot drift from it.
secret_prefilter_re() {
  local i out=""
  for ((i = 0; i < ${#SECRET_RES[@]}; i++)); do
    out+="${out:+|}(${SECRET_RES[$i]})"
  done
  printf '%s' "$out"
}

# Set by _secret_match: the matched pattern name and the matched text without its
# boundary character (callers show only its first four characters).
SECRET_MATCH_NAME=""
SECRET_MATCH_TEXT=""

# _assigned_value <text after the : or =>
#   The VALUE half of assigned-secret (the table row matched the key side only). Returns 0
#   and sets _AV_TOKEN to the value (quotes removed) when it counts as a secret:
#     quoted value    16+ characters right after the opening quote, the first not $ < {
#                     (a template marker), no blank or quote inside;
#     unquoted value  16+ characters, the first not $ < {, no ( or ), and at least one
#                     digit.
#   The digit and parenthesis rules keep ordinary code from blocking a commit the agent
#   cannot clear: `has_token = agents_md.is_file() and ...`, `token = request.headers.get(`,
#   `secret: ref+vault://...` each fail one of them. Known miss: an all-letter unquoted
#   value. Chosen over entropy scoring: simple, and the false positives seen each fail one rule.
_AV_RE_Q="^[\"']([^\"'[:space:]\$<{][^\"'[:space:]]{15,})"
_AV_RE_U="^([^\"'[:space:]\$<{][^\"'[:space:]]{15,})"
_AV_TOKEN=""
_assigned_value() {
  local rest="$1" v
  rest="${rest#"${rest%%[![:space:]]*}"}"          # drop leading blanks
  case "$rest" in
    \"*|\'*)
      if [[ "$rest" =~ $_AV_RE_Q ]]; then _AV_TOKEN="${BASH_REMATCH[1]}"; return 0; fi ;;
    *)
      if [[ "$rest" =~ $_AV_RE_U ]]; then
        v="${BASH_REMATCH[1]}"
        case "$v" in *\(*|*\)*) return 1 ;; esac
        case "$v" in *[0-9]*) _AV_TOKEN="$v"; return 0 ;; esac
      fi ;;
  esac
  return 1
}

# _secret_exempt <token text>
#   True when the matched token itself holds a placeholder word (case-insensitive).
_secret_exempt() {
  local was=0 rc=1
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  [[ "$1" =~ $_SECRET_EXEMPT ]] && rc=0
  if [ "$was" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  return "$rc"
}

# _secret_match <text>
#   Core matcher. Returns 0 and fills SECRET_MATCH_NAME / SECRET_MATCH_TEXT on the first
#   row whose match is a real secret, returns 1 otherwise. Runs in the caller's shell (no
#   subshell) so the globals survive.
#     - a line carrying the allow pragma is skipped whole (human override);
#     - a row whose matched token is exempt (placeholder word in the TOKEN, not the line)
#       is passed over and later rows are still tried, so an example key next to a real
#       one does not hide the real one;
#     - assigned-secret matches the key side by regex, then judges the value in bash
#       (_assigned_value); every `key =` on the line is tried in turn.
_secret_match() {
  local line="$1" i name re hit="" text="" was=0 tail key after tok
  shopt -q nocasematch && was=1
  shopt -u nocasematch
  if [[ "$line" == *"$_SECRET_PRAGMA"* ]]; then
    if [ "$was" = 1 ]; then shopt -s nocasematch; fi
    return 1
  fi
  for ((i = 0; i < ${#SECRET_NAMES[@]}; i++)); do
    name="${SECRET_NAMES[$i]}"; re="${SECRET_RES[$i]}"
    if [ "$name" = "assigned-secret" ]; then
      shopt -s nocasematch
      tail="$line"
      while [[ "$tail" =~ $re ]]; do
        key="${BASH_REMATCH[0]}"
        after="${tail#*"$key"}"
        if _assigned_value "$after"; then
          tok="$_AV_TOKEN"
          if ! _secret_exempt "$tok"; then hit="$name"; text="$key"; break; fi
        fi
        tail="$after"
      done
      shopt -u nocasematch
    elif [[ "$line" =~ $re ]]; then
      tok="${BASH_REMATCH[0]}"
      if [ "${SECRET_BOUND[$i]}" = 1 ]; then tok="${tok#"${BASH_REMATCH[1]}"}"; fi
      if ! _secret_exempt "$tok"; then hit="$name"; text="$tok"; fi
    fi
    [ -z "$hit" ] || break
  done
  if [ "$was" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  [ -n "$hit" ] || return 1
  SECRET_MATCH_NAME="$hit"
  SECRET_MATCH_TEXT="$text"
}

# secret_match_line <text>
#   Prints the name of the first matching pattern and returns 0; returns 1 for no
#   match or an exempt line. (Use _secret_match directly to also get the text.)
secret_match_line() {
  _secret_match "$1" || return 1
  printf '%s\n' "$SECRET_MATCH_NAME"
}

# secret_scan_file <path>
#   Scan every line of <path>. Prints one finding per hit, at most 10, and returns 1
#   when anything was printed (0 for a clean file). The value is never printed:
#   only the first four characters of the match.
secret_scan_file() {
  local path="$1" line n=0 found=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if _secret_match "$line"; then
      printf '%s:%s: %s (%s...)\n' "$path" "$n" "$SECRET_MATCH_NAME" "${SECRET_MATCH_TEXT:0:4}"
      found=$((found + 1))
      [ "$found" -ge 10 ] && break
    fi
  done < "$path"
  [ "$found" -eq 0 ]
}

# secret_sensitive_name <basename>
#   Sensitive file names, matched case-insensitively (.ENV is .env on a
#   case-insensitive filesystem): .env, .env.*, *.env, .envrc (but not .env.example),
#   *.pem *.key *.p12 *.pfx *.keystore, .npmrc .netrc, credentials*, *.tfstate, and private
#   key names id_rsa* / id_dsa* / id_ecdsa* / id_ed25519* (a key pair is two files and the
#   .pub half is public, so *.pub is exempt). A bare id_* glob is wrong: it also matches
#   source files like id_mapping.py.
secret_sensitive_name() {
  local was=0 rc=1
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  case "$1" in
    .env.example|*.pub) rc=1 ;;
    .env|.env.*|*.env|.envrc|*.pem|*.key|*.p12|*.pfx|*.keystore|.npmrc|.netrc|credentials*|*.tfstate) rc=0 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*) rc=0 ;;
  esac
  if [ "$was" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  return "$rc"
}
