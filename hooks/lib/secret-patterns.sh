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
# A line is exempt when it carries the allow pragma or a placeholder word; the pragma
# is documented for humans in hooks/README.md and is deliberately never named in a
# block message (an agent reading the message must not learn how to silence it).

# --- the table: SECRET_NAMES[i] / SECRET_RES[i] / SECRET_BOUND[i] ----------------
# SECRET_BOUND[i]=1 means capture group 1 of the regex is the boundary character,
# which is stripped before taking the "first 4 chars" shown in a finding.
_SP_Q="'\""      # a single and a double quote, for the assigned-secret class below
SECRET_NAMES=(
  aws-access-key private-key github-token github-pat gitlab-pat npm-token
  stripe-live anthropic-key generic-sk slack-token google-api-key jwt assigned-secret
)
SECRET_RES=(
  '(^|[^A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Za-z0-9]|$)'
  '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
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
  # assigned-secret is case-insensitive (_secret_match sets nocasematch for it)
  "(api[_-]?key|secret|token|passw(or)?d)[[:space:]]*[:=][[:space:]]*[${_SP_Q}]?[^${_SP_Q}[:space:]\$<{][^${_SP_Q}[:space:]]{15,}"
)
SECRET_BOUND=(1 0 1 1 1 1 1 0 1 0 1 1 0)

# Exempt lines (case-insensitive): documentation keys and templated values.
_SECRET_EXEMPT='grid:allow-secret|example|placeholder|changeme|your[_-]|xxxxxxxx|redacted'

# Set by _secret_match: the matched pattern name and the matched text without its
# boundary character (callers show only its first four characters).
SECRET_MATCH_NAME=""
SECRET_MATCH_TEXT=""

# _secret_match <text>
#   Core matcher. Returns 0 and fills SECRET_MATCH_NAME / SECRET_MATCH_TEXT on the
#   first match, unless the line is exempt; returns 1 otherwise. Runs in the caller's
#   shell (no subshell) so the globals survive.
_secret_match() {
  local line="$1" i name re hit="" text="" was=0
  shopt -q nocasematch && was=1
  shopt -u nocasematch
  for ((i = 0; i < ${#SECRET_NAMES[@]}; i++)); do
    name="${SECRET_NAMES[$i]}"; re="${SECRET_RES[$i]}"
    # assigned-secret (the last entry) is the only case-insensitive pattern.
    [ "$name" = "assigned-secret" ] && shopt -s nocasematch
    if [[ "$line" =~ $re ]]; then
      hit="$name"
      text="${BASH_REMATCH[0]}"
      if [ "${SECRET_BOUND[$i]}" = 1 ]; then text="${text#"${BASH_REMATCH[1]}"}"; fi
      break
    fi
  done
  if [ -n "$hit" ]; then
    # Exemptions are matched case-insensitively.
    shopt -s nocasematch
    if [[ "$line" =~ $_SECRET_EXEMPT ]]; then hit=""; fi
  fi
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
#   Sensitive file names: .env, .env.* (but not .env.example), *.pem, and private
#   key names id_rsa / id_dsa / id_ecdsa / id_ed25519 (optionally _sk) with NO
#   extension. A bare id_* glob is wrong: it also matches source files like
#   id_mapping.py, and .pub files are public keys.
secret_sensitive_name() {
  case "$1" in
    .env.example) return 1 ;;
    .env|.env.*|*.pem) return 0 ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519|id_rsa_sk|id_dsa_sk|id_ecdsa_sk|id_ed25519_sk) return 0 ;;
  esac
  return 1
}
