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
# nothing to tune. Known cost: a long base64-looking run in a handoff is quarantined (a bare
# sha256/sha512 hex digest is the one exemption); the operator reviews the quarantine directory.
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
  "(^|[^A-Za-z0-9])(pass|pwd|passw(or)?d)[A-Za-z0-9_]*[${_STRICT_Q}]?[[:space:]]*[:=][[:space:]]*[${_STRICT_Q}]?[^${_STRICT_Q}[:space:]]{6,}"
)
STRICT_BOUND=(0 0 0 1)

# Most `key =` candidates tried on one scanned line (see _secret_match). A real line has a
# handful; a line over this is a data blob or an attack on the matcher's running time.
SECRET_MAX_KEYS=200
_SM_KEYS_LEFT=""
# H-05 (NF-062): _secret_match starts every call with a full key count, except while
# _match_pieces runs the pieces of ONE line (it sets this to 1 around each piece), where the
# count is shared. A direct caller of _secret_match no longer has to reset anything.
_SM_KEYS_SHARED=0

# H-05: the wall-clock budget of a scan. A caller (the commit guard) starts it with
# secret_budget_start <whole seconds>; _secret_match then checks it before every table row and
# every `key =` candidate, so a single dense or hostile line cannot run past it, and
# secret_match_long reports scan-budget (a finding, like oversize-line: a scan that cannot
# finish must block, not pass). Not started (SECRET_DEADLINE_US empty) means no limit, which
# is what the other callers (the auto-handoff worker's file scans) get. One regex call is not
# interruptible, so a scan can overshoot by the work between two clock reads.
# The clock is read once per 32 units of work, not on every table row: a call of _secret_match
# is _SM_ROWS units (one per row) and each `key =` candidate is one more. Reading it per row
# cost about 65% more per candidate line, and the default 3 s budget then refused benign diffs
# that the unbudgeted scan passed. The countdown is global and runs on across lines (about 0.8
# reads per candidate line); secret_budget_start zeroes it, so the first call checks at once.
_SM_ROWS=${#SECRET_NAMES[@]}
_SM_CLOCK_EVERY=32
_SM_CLOCK_LEFT=0
SECRET_DEADLINE_US=""
_NOW_US=0
# _secret_now_us: sets _NOW_US to microseconds since the epoch (bash 5: EPOCHREALTIME, whose
# decimal mark follows the locale), else to whole seconds since the shell started. The tests
# replace this function with a counter, so no test depends on how busy the machine is.
_secret_now_us() {
  if [ -n "${EPOCHREALTIME:-}" ]; then _NOW_US="${EPOCHREALTIME//[.,]/}"; else _NOW_US=$((SECONDS * 1000000)); fi
}
# secret_budget_start <seconds>: the scan has this many whole seconds from now. Anything but 1
# to 9 digits counts as 0, which fails closed (a budget that fails to start would be no budget).
# 10# keeps 008 a decimal number: bash would read it as a bad octal and the assignment fail.
secret_budget_start() {
  local s="$1"
  [[ "$s" =~ ^[0-9]{1,9}$ ]] || s=0
  s=$((10#$s))
  _secret_now_us
  SECRET_DEADLINE_US=$((_NOW_US + s * 1000000))
  _SM_CLOCK_LEFT=0
}
secret_budget_stop() { SECRET_DEADLINE_US=""; }
# _secret_tick: the countdown ran out; start the next 32 units and report whether the budget is spent.
_secret_tick() {
  _SM_CLOCK_LEFT=$_SM_CLOCK_EVERY
  # a spent budget stays spent: the next call reads the clock again at once
  if _secret_over_budget; then _SM_CLOCK_LEFT=0; return 0; fi
  return 1
}
# _secret_over_budget: true when a budget is running and spent.
_secret_over_budget() {
  [ -n "$SECRET_DEADLINE_US" ] || return 1
  _secret_now_us
  [ "$_NOW_US" -ge "$SECRET_DEADLINE_US" ]
}
# A cut inside this is a cut inside a long identifier run (see secret_match_long): 200
# identifier characters, then at most 16 characters that are not.
_IDRUN_RE='[[:alnum:]_]{200}[^[:alnum:]_]{0,16}$'
# The tail of every key word that can sit inside an identifier run: `api-key` has a `-`,
# so only its `key` is part of the run. A superset on purpose (any run holding "key"
# counts); case-insensitive, see _has_keyword_tail.
# H-26 (VS4): also `pass`, `pwd`, `passphrase` (the strict password-assigned row's keys).
_KEYWORD_TAIL_RE='secret|token|pass|pwd|key'
# H-01: the open-key check of secret_match_long (see _open_key_pos). A glob that finds the
# last character that cannot belong to the unbounded middle of an assignment. That middle is
# identifier characters, backslashes, quotes, : and = (and, with up to three single blanks
# around them, the blanks of `key = "value"`).
_OPEN_BREAK='[![:alnum:]_\\"'"'"':=]*'
# The last characters of a piece that may be a value still being read: a value is judged on
# its first 16 characters (64 here, because a letters-only value without a digit is judged on
# the whole run in default mode), and in front of it come at most a blank, a quote and a :
# or =.
_OPEN_TAIL=80
# A key word that still reads like an assignment when the piece ends: key word, identifier
# characters, backslashes, a quote, then optionally the : or = and a value of up to 64
# characters. A superset of the key side of the assigned-secret row plus the start of its value.
# H-26 (VS3): the value may also be an unbounded run of letters: in default mode an unquoted
# value is judged on its whole run and a letters-only run is no finding until a digit comes,
# which may be past the cut.
# H-26 (VS4): the strict-only key words (pass, pwd, passphrase) are open keys too.
_OPEN_KEYWORDS="$_SECRET_KEYWORDS|pass|pwd"
_OPEN_RE='^('"$_OPEN_KEYWORDS"')[[:alnum:]_]*\\*["'"'"']?[[:space:]]*([:=][[:space:]]*\\*["'"'"']?[[:space:]]*([^"'"'"'[:space:]]{0,64}|[A-Za-z]+))?$'
_OPEN_KW='('"$_OPEN_KEYWORDS"')'
_OPEN_POS=-1

# H-01 (N6), strict mode only. The blanks that [[:space:]] knows only in a UTF-8 locale (and
# the no-break ones it never knows): NEL, NBSP, U+1680, U+2000 to U+200A, U+2028, U+2029,
# U+202F, U+205F, U+3000. In the C locale `token<U+3000>=value` hid the assignment from the
# key regex. Strict callers turn each into one ASCII blank first (see _unblank); the commit
# guard keeps its behaviour. Zero-width characters (U+200B and the like) are not blanks and
# are not touched.
_MB_BLANKS=(
  $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80'
  $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83' $'\xe2\x80\x84' $'\xe2\x80\x85'
  $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a'
  $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf' $'\xe2\x81\x9f' $'\xe3\x80\x80'
)
_UB=""
# H-26 (VS6/VF10): characters that are invisible or zero-width: soft hyphen, U+200B to U+200D,
# U+2060, U+FEFF and the combining marks U+0300 to U+036F. `token<U+200B>=value` hides the
# key from the key regex, and a value cut by a multibyte blank (`Abcdefgh<U+3000>ijklmnop12`)
# is two short words once the blanks become spaces, yet one value in a shell. The third strict
# reading (_unblank ... strip) deletes these and the blanks above. It is scanned in addition
# to the other two, never instead of them.
_MB_INVIS=($'\xc2\xad' $'\xe2\x80\x8b' $'\xe2\x80\x8c' $'\xe2\x80\x8d' $'\xe2\x81\xa0' $'\xef\xbb\xbf')
for _b in $(seq 768 879); do
  printf -v _b '\\x%02x\\x%02x' $((0xC0 | _b >> 6)) $((0x80 | _b & 0x3F))
  printf -v _b "$_b"
  _MB_INVIS+=("$_b")
done
unset _b
# _unblank <text> [strip]: sets _UB to the text, with the blanks above replaced by a space (or,
# with "strip", deleted together with the invisible characters above) when the scan is
# strict. Callers scan the ORIGINAL text first and this one after (see secret_match_long): in
# the C locale the bytes of a multibyte blank inside a value are value characters, and
# replacing them can only shorten a value.
_unblank() {
  local b out repl=" " list=("${_MB_BLANKS[@]}") sedargs=()
  _UB="$1"
  [ "${SECRET_STRICT:-0}" = 1 ] || return 0
  if [ "${2:-}" = strip ]; then repl=""; list+=("${_MB_INVIS[@]}"); fi
  if [ "${#1}" -gt 6000 ]; then
    # bash's ${x//pat/ } copies the whole text once per pattern and a long line made of such
    # blanks cost seconds (about 4x per doubling): one linear sed pass instead; if sed fails
    # the text is left as it is (the original was scanned)
    for b in "${list[@]}"; do sedargs+=(-e "s/$b/$repl/g"); done
    if out="$(printf '%s' "$1" | sed "${sedargs[@]}")"; then _UB="$out"; fi
    return 0
  fi
  for b in "${list[@]}"; do _UB="${_UB//"$b"/$repl}"; done
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
#                     digit. In strict mode (SECRET_STRICT=1) only the length and first-
#                     character rules apply: a letters-only or parenthesised value counts.
#   The digit and parenthesis rules keep ordinary code from blocking a commit the agent
#   cannot clear: `has_token = agents_md.is_file() and ...`, `token = request.headers.get(`,
#   `secret: ref+vault://...` each fail one of them. Known miss in default mode: an
#   all-letter unquoted value. Chosen over entropy scoring: simple, and the false positives
#   seen each fail one rule. Strict mode has no commit to block: a false positive there only
#   quarantines a handoff for review, so it takes the miss out (the pre-merge strict scan
#   did the same).
#   Strict mode (H-01, the auto-handoff worker only; the commit guard keeps the rules above):
#     (d) a first character of $ < { does not exempt a value, quoted or not: a model can put
#         one in front of any value, and a real password may start with one;
#     (b) a quote may be followed by blanks before the value (`api_key = " value"`);
#     VH3 a run of 16 or more backslashes is a value of its own even when a quote follows
#         it (the escaped-quote rule above would otherwise swallow the run).
_AV_RE_Q="^[\"']([^\"'[:space:]\$<{][^\"'[:space:]]{15,})"
_AV_RE_U="^([^\"'[:space:]\$<{][^\"'[:space:]]{15,})"
_AV_RE_QS="^[\"'][[:space:]]*([^\"'[:space:]][^\"'[:space:]]{15,})"
_AV_RE_US="^([^\"'[:space:]][^\"'[:space:]]{15,})"
_AV_TOKEN=""
_assigned_value() {
  local rest="$1" v lead whole
  rest="${rest#"${rest%%[![:space:]]*}"}"          # drop leading blanks
  whole="$rest"
  # JSON inside a string literal escapes its quotes ({\"k\":\"v\"}): drop the backslashes
  # in front of an opening quote so the quoted-value rule below sees the quote
  lead="${rest%%[!\\]*}"
  if [ -n "$lead" ]; then
    case "${rest#"$lead"}" in \"*|\'*) rest="${rest#"$lead"}" ;; esac
  fi
  if [ "${SECRET_STRICT:-0}" = 1 ]; then
    # strict: a quoted value (blanks after the quote allowed), else any run of 16 or more
    # characters, read from the text as it stood before the backslashes were dropped
    case "$rest" in
      \"*|\'*) if [[ "$rest" =~ $_AV_RE_QS ]]; then _AV_TOKEN="${BASH_REMATCH[1]}"; return 0; fi ;;
    esac
    if [[ "$whole" =~ $_AV_RE_US ]]; then _AV_TOKEN="${BASH_REMATCH[1]}"; return 0; fi
    return 1
  fi
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
#     - a matched token that is exempt (placeholder word in the TOKEN, not the line) is
#       passed over: the rest of the line is searched for another match of the same row
#       (H-09) and later rows are still tried, so an example key next to a real one does
#       not hide the real one, before it or after it;
#     - assigned-secret matches the key side by regex, then judges the value in bash
#       (_assigned_value); every `key =` on the line is tried in turn, but at most
#       SECRET_MAX_KEYS of them per scanned line (_SM_KEYS_LEFT, reset by the public entry
#       points). Each try re-reads the rest of the line, so an unbounded loop is quadratic
#       (about 20 s on a 240 KB line of keys). A line with more keys than the bound is
#       reported as key-dense-line: a scan that cannot finish must block, not pass.
_secret_match() {
  local line="$1" i name re hit="" text="" was=0 tail key after tok full
  [ "$_SM_KEYS_SHARED" = 1 ] || _SM_KEYS_LEFT=$SECRET_MAX_KEYS   # H-05: see _SM_KEYS_SHARED
  shopt -q nocasematch && was=1
  shopt -u nocasematch
  # H-05: the wall-clock budget, read once per 32 units of work (see secret_budget_start)
  if (( (_SM_CLOCK_LEFT -= _SM_ROWS) <= 0 )) && _secret_tick; then
    if [ "$was" = 1 ]; then shopt -s nocasematch; fi
    SECRET_MATCH_NAME="scan-budget"; SECRET_MATCH_TEXT=""
    return 0
  fi
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
        if (( --_SM_CLOCK_LEFT <= 0 )) && _secret_tick; then hit="scan-budget"; text=""; break; fi
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
    else
      # H-09: every token the row matches is judged on its own. An exempt one is passed over
      # and the rest of the line is searched again, so an example key in front of a real one
      # of the same kind does not hide it. The key count and the clock budget of the
      # assigned-secret loop above bound the work (each pass re-reads the rest of the line);
      # only a token that is passed over costs a unit, so a line with no exempt token is
      # judged exactly as before.
      tail="$line"
      while [[ "$tail" =~ $re ]]; do
        full="${BASH_REMATCH[0]}"; tok="$full"
        if [ "${SECRET_BOUND[$i]}" = 1 ]; then tok="${tok#"${BASH_REMATCH[1]}"}"; fi
        if ! _secret_exempt "$tok"; then hit="$name"; text="$tok"; break; fi
        if [ "$_SM_KEYS_LEFT" -le 0 ]; then hit="key-dense-line"; text=""; break; fi
        if (( --_SM_CLOCK_LEFT <= 0 )) && _secret_tick; then hit="scan-budget"; text=""; break; fi
        _SM_KEYS_LEFT=$((_SM_KEYS_LEFT - 1))
        tail="${tail#*"$full"}"
      done
    fi
    [ -z "$hit" ] || break
  done
  if [ -z "$hit" ] && [ "${SECRET_STRICT:-0}" = 1 ]; then
    shopt -s nocasematch   # only password-assigned needs it; the others spell their classes out
    for ((i = 0; i < ${#STRICT_NAMES[@]}; i++)); do
      re="${STRICT_RES[$i]}"
      if [[ "$line" =~ $re ]]; then
        # A bare sha256 / sha512 (all hex, exactly 64 or 128 characters) is a checksum a
        # handoff legitimately quotes, and quarantining it loses the handoff. A hex value
        # with a key name in front of it is still caught by the assigned-secret row above.
        if [ "${STRICT_NAMES[$i]}" = base64-run ] && [[ "${BASH_REMATCH[0]}" =~ ^([0-9a-fA-F]{64}|[0-9a-fA-F]{128})$ ]]; then
          continue
        fi
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

# _open_key_pos <piece> <limit>
#   H-01. Sets _OPEN_POS to the offset (below <limit>) of the first key word in <piece> that
#   still reads like an assignment when the piece ends, or -1. An assignment is a key word,
#   any number of identifier characters or backslashes, a quote, a : or =, any number of
#   backslashes, a quote, and the value: the filler runs have no length limit, so such an
#   assignment can be longer than the overlap of two pieces, and the next piece must then
#   start at the key word, not 4096 characters on. Cheap by construction: the run that ends
#   the piece is found with a linear parameter expansion (as in secret_match_long), and only
#   key words inside it are tested, with a regex anchored at both ends. At most 32 key words
#   are tried; the 32nd counts as open, because a scan that cannot finish must block.
_open_key_pos() {
  local p="$1" lim="$2" n=${#1} w lead start ks base rest kw pre k tries=0 blanks=0 was=0
  _OPEN_POS=-1
  [ "$n" -gt "$_OPEN_TAIL" ] || return 0
  w="${p:0:$((n - _OPEN_TAIL))}"
  # the run that ends the piece: walk left over the class characters, and over up to two
  # blanks (one in front of the : or =, one behind it; the third, behind a quote, is in the
  # last _OPEN_TAIL characters) which are the only blanks an assignment can hold once a long
  # line is squeezed
  while :; do
    lead="${w%$_OPEN_BREAK}"
    if [ "$lead" = "$w" ]; then start=0; break; fi
    start=$((${#lead} + 1))
    if [ "$blanks" -lt 2 ] && [[ "${w:${#lead}:1}" == [[:space:]] ]]; then
      blanks=$((blanks + 1)); w="$lead"; continue
    fi
    break
  done
  # `api-key`: the - ends the run, so look 11 characters (the longest key word) further left
  ks=$((start > 11 ? start - 11 : 0))
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  base=$ks
  while [ "$base" -lt "$lim" ] && [ "$base" -lt "$n" ]; do
    rest="${p:$base:$((lim + 11 - base))}"   # 11 more: a key word that starts below the limit
    [[ "$rest" =~ $_OPEN_KW ]] || break
    kw="${BASH_REMATCH[0]}"
    pre="${rest%%"$kw"*}"
    k=$((base + ${#pre}))
    [ "$k" -lt "$lim" ] || break
    tries=$((tries + 1))
    if [[ "${p:$k}" =~ $_OPEN_RE ]] || [ "$tries" -ge 32 ]; then _OPEN_POS=$k; break; fi
    base=$((k + 1))
  done
  if [ "$was" = 1 ]; then shopt -s nocasematch; else shopt -u nocasematch; fi
}

# H-26 (VS5): the other table rows with an unbounded part (a JWT's payload, the user name in
# front of a URL password, the gap in a private key header, a slack webhook's ids) can also be
# longer than the overlap of two pieces. A token whose first characters are still open when a
# piece ends (a run of the characters the token allows, ending at the piece end) makes the next
# piece start there. Only the last 1024 characters of the piece are looked at, so the next
# piece moves on by at least 3328: a token with a longer open run than that is not caught.
_OPEN_TOK_RE='(eyJ[A-Za-z0-9_.-]*|://[^/@[:space:]]*|-----BEGIN [A-Z0-9 ]*|hooks\.slack\.com/services/[A-Za-z0-9/]*)$'
_open_token_pos() {
  local p="$1" n=${#1} w
  _OPEN_POS=-1
  [ "$n" -gt 1024 ] || return 0
  w="${p:$((n - 1024))}"
  [[ "$w" =~ $_OPEN_TOK_RE ]] && _OPEN_POS=$((n - ${#BASH_REMATCH[0]}))
  return 0
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
#   The other half of that: the same run can be longer than the overlap even when it is
#   not 200 characters long (`secret<240 characters>=<value>`, or a value of 100 characters
#   after a 150-character run), and a backslash run is as unbounded as an identifier run. So
#   after every piece _open_key_pos asks whether a key word's assignment is still open at the
#   piece's end; if so the next piece starts at that key word (H-01) instead of 4096 on.
#   Blanks are the one unbounded part of a match (`key =<any number of blanks>value`), so
#   a long line first has every run of whitespace squeezed to one space: a pad of any
#   width can then no longer straddle a piece boundary. No row needs more than one blank
#   where it allows blanks, so squeezing loses no detection. sed uses the same locale
#   classes as the bash matcher, so a multibyte space is squeezed too. Oversize is judged
#   on the ORIGINAL length: squeezing must not turn a line the scan could not have
#   finished into a clean one.
secret_match_long() {
  # strict mode (H-01): the original text first, so nothing origin/next found is lost, then
  # the text with multibyte blanks turned into spaces, which only changes the verdict for a
  # line that has such a blank. A line too long for the first scan never reaches the second:
  # it is a finding (oversize-line) before any rewrite.
  _match_pieces "$1" && return 0
  [ "${SECRET_STRICT:-0}" = 1 ] || return 1
  _unblank "$1"
  if [ "$_UB" != "$1" ]; then _match_pieces "$_UB" && return 0; fi
  _unblank "$1" strip   # H-26 (VS6/VF10): the third reading, see _MB_INVIS
  [ "$_UB" != "$1" ] || return 1
  _match_pieces "$_UB"
}

# _match_pieces <text>: the piece-wise matcher behind secret_match_long (see above).
_match_pieces() {
  local t="$1" len=${#1} off=0 pieces=0 tlen sq end w rest run piece core lead runl cur next
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
    cur="${t:$off:$((end - off))}"
    # the pieces of one line share one key count (H-05, see _SM_KEYS_SHARED)
    _SM_KEYS_SHARED=1
    if _secret_match "$cur"; then _SM_KEYS_SHARED=0; return 0; fi
    _SM_KEYS_SHARED=0
    next=$((off + 4096))
    if [ "$end" -lt "$tlen" ]; then
      # H-01: a key word whose filler run, = and value are still open when the piece ends
      # may be longer than the overlap. The next piece then starts at the key word, so it
      # holds the whole assignment. A key word at the very start of the piece with the
      # assignment still open at its end cannot be shown to be complete: fail closed.
      _open_key_pos "$cur" 4096
      if [ "$_OPEN_POS" -eq 0 ]; then SECRET_MATCH_NAME="oversize-line"; SECRET_MATCH_TEXT=""; return 0; fi
      if [ "$_OPEN_POS" -gt 0 ]; then next=$((off + _OPEN_POS)); fi
      # H-26 (VS5): a token still open at the end of the piece; the earlier restart wins
      _open_token_pos "$cur"
      if [ "$_OPEN_POS" -gt 0 ] && [ "$((off + _OPEN_POS))" -lt "$next" ]; then next=$((off + _OPEN_POS)); fi
    fi
    off=$next
  done
  if [ "$len" -gt 262144 ]; then SECRET_MATCH_NAME="oversize-line"; SECRET_MATCH_TEXT=""; return 0; fi
  return 1
}

# secret_match_line <text>
#   Prints the name of the first matching pattern and returns 0; returns 1 for no
#   match or an exempt line. (Use _secret_match directly to also get the text.)
secret_match_line() {
  local mode
  _SM_KEYS_LEFT=$SECRET_MAX_KEYS
  if ! _secret_match "$1"; then
    # strict: then the text with multibyte blanks turned into spaces, then with them and the
    # invisible characters deleted (see secret_match_long); a reading equal to the original
    # is skipped
    [ "${SECRET_STRICT:-0}" = 1 ] || return 1
    for mode in "" strip; do
      _unblank "$1" $mode
      [ "$_UB" != "$1" ] || continue
      _SM_KEYS_LEFT=$SECRET_MAX_KEYS
      if _secret_match "$_UB"; then printf '%s\n' "$SECRET_MATCH_NAME"; return 0; fi
    done
    return 1
  fi
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
      # 2>/dev/null: a reader that closes the pipe early (| head -1) must not leave a printf write-error line in a caller's stderr
      printf '%s:%s: %s (%s...)\n' "$path" "$n" "$SECRET_MATCH_NAME" "${SECRET_MATCH_TEXT:0:4}" 2>/dev/null
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
