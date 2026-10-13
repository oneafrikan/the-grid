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
#   secret_redact_file <path>      rewrites matching lines as "[line redacted: <name>]", prints the count
#   secret_mask_stream             stdin to stdout, a matching line becomes "[masked: <name>]"
#   secret_sensitive_name <name>   returns 0 for a sensitive file BASENAME
#   SECRET_STRICT=1                no exemptions, plus the STRICT_* shapes (the auto-handoff worker)
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
# The table is the whole scope: no entropy scoring, no tokens split over lines, and (in
# default mode) an unquoted assigned value made only of letters is not flagged (see
# _assigned_value; strict mode flags it).

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
# The key words of the assigned-secret row (the last SECRET_RES entry). Also read by
# secret_match_long, which needs the TAIL of each (see _KEYWORD_TAIL_RE).
_SECRET_KEYWORDS='secret|token|passw(or)?d|api[_-]?key|access[_-]?key|private[_-]?key'
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
  # the user name may be empty (redis://:password@host), hence * and not +
  '://[^/:@[:space:]]*:[^/:@[:space:]$<{][^/:@[:space:]]{2,}@'
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
  # (a JSON key, "password": ...), which JSON inside a string literal escapes with one or
  # more backslashes ({\"password\":\"v\"}). Case-insensitive (set by _secret_match). The
  # VALUE side is judged in bash by _assigned_value, because "16+ characters with a digit
  # and no parentheses" cannot be said in one ERE.
  '('"$_SECRET_KEYWORDS"')[A-Za-z0-9_]*\\*["'"'"']?[[:space:]]*[:=]'
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

# Strict mode (SECRET_STRICT=1, set by the auto-handoff worker). A caller whose input is
# model output must not honour the exemptions above: the model can add the word "example"
# to any line it wants to get past the scan. Strict mode therefore (a) ignores
# _SECRET_EXEMPT, including the allow pragma, and (b) also tries the few extra shapes
# below. They are worker-only on purpose: as a commit guard on human diffs they would be
# too noisy (any long hash or `password=...` in code). No entropy scoring: fixed patterns,
# nothing to tune. Known cost: a long base64-looking run (a 64-hex digest, for example) in
# a handoff is quarantined; the operator reviews the quarantine directory.
_STRICT_Q="'\""   # a single and a double quote
STRICT_NAMES=(base64-run bearer-value url-password password-assigned)
STRICT_RES=(
  '[A-Za-z0-9+/=]{64,}'
  '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'
  # Any user:password@ in a URL (the user name may be empty). Wider than the table's
  # db-url-password on purpose: the password may start with $ < { (a model can pick any
  # first character) and may hold a colon (legal in RFC 3986). The cost is a quarantined
  # handoff on a templated URL.
  '://[^/@:[:space:]]*:[^/@[:space:]]{6,}@'
  # case-insensitive; the leading boundary keeps "bypass_cache: enabled" out
  "(^|[^A-Za-z0-9])(pass|pwd|passw(or)?d)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*[${_STRICT_Q}]?[^${_STRICT_Q}[:space:]]{6,}"
)
STRICT_BOUND=(0 0 0 1)

# Most `key =` candidates tried on one scanned line (see _secret_match). A real line has a
# handful; a line over this is a data blob or an attack on the matcher's running time.
SECRET_MAX_KEYS=200
_SM_KEYS_LEFT=""
# A cut inside this is a cut inside a long identifier run (see secret_match_long): 200
# identifier characters, then at most 16 characters that are not.
_IDRUN_RE='[[:alnum:]_]{200}[^[:alnum:]_]{0,16}$'
# The tail of every key word that can sit inside an identifier run: `api-key` has a `-`,
# so only its `key` is part of the run. A superset on purpose (any run holding "key"
# counts); case-insensitive, see _has_keyword_tail.
_KEYWORD_TAIL_RE='secret|token|passw|key'

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
#                     digit. In strict mode (SECRET_STRICT=1) only the length and first-
#                     character rules apply: a letters-only or parenthesised value counts.
#   The digit and parenthesis rules keep ordinary code from blocking a commit the agent
#   cannot clear: `has_token = agents_md.is_file() and ...`, `token = request.headers.get(`,
#   `secret: ref+vault://...` each fail one of them. Known miss in default mode: an
#   all-letter unquoted value. Chosen over entropy scoring: simple, and the false positives
#   seen each fail one rule. Strict mode has no commit to block: a false positive there only
#   quarantines a handoff for review, so it takes the miss out (the pre-merge strict scan
#   did the same).
_AV_RE_Q="^[\"']([^\"'[:space:]\$<{][^\"'[:space:]]{15,})"
_AV_RE_U="^([^\"'[:space:]\$<{][^\"'[:space:]]{15,})"
_AV_TOKEN=""
_assigned_value() {
  local rest="$1" v lead
  rest="${rest#"${rest%%[![:space:]]*}"}"          # drop leading blanks
  # JSON inside a string literal escapes its quotes ({\"k\":\"v\"}): drop the backslashes
  # in front of an opening quote so the quoted-value rule below sees the quote
  lead="${rest%%[!\\]*}"
  if [ -n "$lead" ]; then
    case "${rest#"$lead"}" in \"*|\'*) rest="${rest#"$lead"}" ;; esac
  fi
  case "$rest" in
    \"*|\'*)
      if [[ "$rest" =~ $_AV_RE_Q ]]; then _AV_TOKEN="${BASH_REMATCH[1]}"; return 0; fi ;;
    *)
      if [[ "$rest" =~ $_AV_RE_U ]]; then
        v="${BASH_REMATCH[1]}"
        if [ "${SECRET_STRICT:-0}" = 1 ]; then _AV_TOKEN="$v"; return 0; fi
        case "$v" in *\(*|*\)*) return 1 ;; esac
        case "$v" in *[0-9]*) _AV_TOKEN="$v"; return 0 ;; esac
      fi ;;
  esac
  return 1
}

# _secret_exempt <token text>
#   True when the matched token itself holds a placeholder word (case-insensitive).
_secret_exempt() {
  [ "${SECRET_STRICT:-0}" = 1 ] && return 1   # strict mode: never exempt (see SECRET_STRICT)
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
#       (_assigned_value); every `key =` on the line is tried in turn, but at most
#       SECRET_MAX_KEYS of them per scanned line (_SM_KEYS_LEFT, reset by the public entry
#       points). Each try re-reads the rest of the line, so an unbounded loop is quadratic
#       (about 20 s on a 240 KB line of keys). A line with more keys than the bound is
#       reported as key-dense-line: a scan that cannot finish must block, not pass.
_secret_match() {
  local line="$1" i name re hit="" text="" was=0 tail key after tok
  : "${_SM_KEYS_LEFT:=$SECRET_MAX_KEYS}"
  shopt -q nocasematch && was=1
  shopt -u nocasematch
  if [ "${SECRET_STRICT:-0}" != 1 ] && [[ "$line" == *"$_SECRET_PRAGMA"* ]]; then
    if [ "$was" = 1 ]; then shopt -s nocasematch; fi
    return 1
  fi
  for ((i = 0; i < ${#SECRET_NAMES[@]}; i++)); do
    name="${SECRET_NAMES[$i]}"; re="${SECRET_RES[$i]}"
    if [ "$name" = "assigned-secret" ]; then
      shopt -s nocasematch
      tail="$line"
      while [[ "$tail" =~ $re ]]; do
        if [ "$_SM_KEYS_LEFT" -le 0 ]; then hit="key-dense-line"; text=""; break; fi
        _SM_KEYS_LEFT=$((_SM_KEYS_LEFT - 1))
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
  if [ -z "$hit" ] && [ "${SECRET_STRICT:-0}" = 1 ]; then
    shopt -s nocasematch   # only password-assigned needs it; the others spell their classes out
    for ((i = 0; i < ${#STRICT_NAMES[@]}; i++)); do
      re="${STRICT_RES[$i]}"
      if [[ "$line" =~ $re ]]; then
        hit="${STRICT_NAMES[$i]}"
        text="${BASH_REMATCH[0]}"
        if [ "${STRICT_BOUND[$i]}" = 1 ]; then text="${text#"${BASH_REMATCH[1]}"}"; fi
        break
      fi
    done
  fi
  if [ "$was" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  [ -n "$hit" ] || return 1
  SECRET_MATCH_NAME="$hit"
  SECRET_MATCH_TEXT="$text"
}

# _has_keyword_tail <text>
#   True when the text holds the tail of a key word (case-insensitive).
_has_keyword_tail() {
  local was=0 rc=1
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  [[ "$1" =~ $_KEYWORD_TAIL_RE ]] && rc=0
  if [ "$was" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
  return "$rc"
}

# secret_match_long <text>
#   _secret_match for text of any length. The bash matcher is superlinear on long input,
#   so text over 6,000 characters is matched in 4,352-character pieces that overlap by 256
#   (a token is far shorter than the overlap), at most 64 pieces (262144 characters). Longer
#   text is reported as a finding named oversize-line: a scan that cannot finish must
#   block, not pass. Sets the same globals as _secret_match. Lengths are characters in a
#   UTF-8 locale and bytes in the C locale (bash's ${#x} and ${x:o:n} follow the locale).
#   The other unbounded part of a match is the run of identifier characters between a key
#   word and its `=` (`secret<300 letters>=value`): a cut inside such a run (200+ characters
#   of it before the cut) would leave the word in one piece and the `=` in the next, so the
#   piece is extended to the end of the run plus the usual 256 characters. A run that needs
#   more than 4096 extra characters is reported as oversize-line, like any scan that cannot
#   be shown to be complete. Only a run that holds a key word is treated so: a long hex or
#   base64 word with none cannot hide a key and is cut as before.
#   Blanks are the one unbounded part of a match (`key =<any number of blanks>value`), so
#   a long line first has every run of whitespace squeezed to one space: a pad of any
#   width can then no longer straddle a piece boundary. No row needs more than one blank
#   where it allows blanks, so squeezing loses no detection. sed uses the same locale
#   classes as the bash matcher, so a multibyte space is squeezed too. Oversize is judged
#   on the ORIGINAL length: squeezing must not turn a line the scan could not have
#   finished into a clean one.
secret_match_long() {
  local t="$1" len=${#1} off=0 pieces=0 tlen sq end w rest run piece core lead runl
  _SM_KEYS_LEFT=$SECRET_MAX_KEYS   # the key bound is per line, not per piece
  if [ "$len" -le 6000 ]; then _secret_match "$t"; return; fi
  # if sed fails the unsqueezed text is scanned (fail closed on size, never on emptiness)
  if sq="$(printf '%s' "$t" | sed 's/[[:space:]][[:space:]]*/ /g')"; then t="$sq"; fi
  tlen=${#t}
  while [ "$off" -lt "$tlen" ]; do
    pieces=$((pieces + 1))
    if [ "$pieces" -gt 64 ]; then
      SECRET_MATCH_NAME="oversize-line"; SECRET_MATCH_TEXT=""; return 0
    fi
    end=$((off + 4352))
    if [ "$end" -lt "$tlen" ]; then
      # does the cut fall in, or within 16 characters after, a 200+ character identifier run?
      w="${t:$((end - 216)):216}"
      if [[ "$w" =~ $_IDRUN_RE ]]; then
        run=0; rest=""
        if [[ "$w" == *[[:alnum:]_] ]]; then   # the run goes on past the cut: measure the rest
          rest="${t:$end:4200}"; rest="${rest%%[![:alnum:]_]*}"; run=${#rest}
        fi
        # only a run that holds a key word can hide a key (a long hex or base64 word with
        # none cannot), so only then pay for the extension, or refuse a run too long to keep
        # The run's part before the cut is taken with parameter expansion, which is linear:
        # a regex over the whole piece retries every start and costs piece length x run
        # length (25 s on a 60 KB line of 4000-character runs). The window w already says
        # the piece ends in at most 16 non-identifier characters after the run.
        piece="${t:$off:$((end - off))}"
        core="${piece%"${w##*[[:alnum:]_]}"}"          # without those trailing characters
        lead="${core%[![:alnum:]_]*}"                  # up to the last non-identifier char
        if [ "$lead" = "$core" ]; then runl="$core"; else runl="${core:$((${#lead} + 1))}"; fi
        if _has_keyword_tail "$runl$rest"; then
          if [ "$run" -gt 4096 ]; then SECRET_MATCH_NAME="oversize-line"; SECRET_MATCH_TEXT=""; return 0; fi
          end=$((end + run + 256))
        fi
      fi
    fi
    _secret_match "${t:$off:$((end - off))}" && return 0
    off=$((off + 4096))
  done
  if [ "$len" -gt 262144 ]; then SECRET_MATCH_NAME="oversize-line"; SECRET_MATCH_TEXT=""; return 0; fi
  return 1
}

# secret_match_line <text>
#   Prints the name of the first matching pattern and returns 0; returns 1 for no
#   match or an exempt line. (Use _secret_match directly to also get the text.)
secret_match_line() {
  _SM_KEYS_LEFT=$SECRET_MAX_KEYS
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
    if secret_match_long "$line"; then
      printf '%s:%s: %s (%s...)\n' "$path" "$n" "$SECRET_MATCH_NAME" "${SECRET_MATCH_TEXT:0:4}"
      found=$((found + 1))
      [ "$found" -ge 10 ] && break
    fi
  done < "$path"
  [ "$found" -eq 0 ]
}

# secret_redact_file <path>
#   Rewrites <path> in place: every line that matches becomes "[line redacted: <name>]".
#   Prints the number of lines redacted (0 leaves the file's bytes alone). Used on the
#   digest the model reads, so a secret in the transcript is never shown to it.
secret_redact_file() {
  local path="$1" tmp line n=0
  tmp="$(mktemp "$path.XXXXXX")" || { echo 0; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    if secret_match_long "$line"; then
      printf '[line redacted: %s]\n' "$SECRET_MATCH_NAME"
      n=$((n + 1))
    else
      printf '%s\n' "$line"
    fi
  done < "$path" > "$tmp"
  if [ "$n" -gt 0 ]; then mv -f "$tmp" "$path"; else rm -f "$tmp"; fi
  printf '%s\n' "$n"
}

# secret_mask_stream
#   stdin to stdout, line by line; a matching line becomes "[masked: <name>]". Used on
#   text that goes into a log (child output, git's error text).
secret_mask_stream() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if secret_match_long "$line"; then printf '[masked: %s]\n' "$SECRET_MATCH_NAME"; else printf '%s\n' "$line"; fi
  done
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
