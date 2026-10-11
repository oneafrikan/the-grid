#!/usr/bin/env bash
# check-personal.sh - scan the tracked tree for personal data that must not be
# in a public repo (emails, home paths, tokens, private IPs, named hosts, ...).
#
# Usage:
#   check-personal.sh [path ...]     scan all tracked files, or only the given
#                                    tracked paths (a directory means "all under it")
#   check-personal.sh --help
#
# Where the rules come from (merged):
#   1. scripts/personal-patterns.txt        PUBLIC generic rules, always loaded
#   2. the private denylist                 concrete terms (hosts, handles, employers)
#                                           kept OUTSIDE this repo; see below
#   3. scripts/personal-allow-paths.txt     paths skipped entirely, each with a reason
# Rule file format is documented at the top of personal-patterns.txt.
#
# Besides line rules, it blocks (in code, because they act on files, not lines):
# tracked archive/binary/key file types, a tracked .env, and oversized files.
#
# Environment:
#   GRID_DIR               repo to scan (default: the repo this script lives in)
#   GRID_PRIVATE_DENYLIST  private denylist path. Default
#                          $HOME/.the-grid-private/denylist.txt. Set to the EMPTY
#                          string to disable the private half on purpose (CI).
#   GRID_REQUIRE_DENYLIST  1 = a missing/disabled private denylist is an error
#                          (exit 1) instead of a notice; stops an unattended build
#                          from passing on the generic half alone.
#   GRID_MAX_BYTES         size limit per file (default 1048576)
#
# Output:
#   path:line: [label] <matched line, max 120 chars>   public rules
#   path:line: [token]                                 token rule: text NEVER printed
#   path:line: [private:N]                             denylist rule N: text NEVER printed
#   path: [blocked-type:ext] / [blocked-type:.env] / [too-large] ...   file blocks
#   personal: N finding(s)                             always the last line
# Exit: 0 clean, 1 findings (or required denylist missing), 2 usage/config error.
#
# Only TRACKED files are read (git ls-files), so untracked local files and
# submodules (gitlinks) are never scanned. Bash 3.2-safe (macOS): no mapfile,
# no associative arrays, no ${x,,}.
set -uo pipefail

# Pin the locale so byte handling and grep behave the same on every machine.
export LC_ALL=C

GRID_DIR="${GRID_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
MAX_BYTES="${GRID_MAX_BYTES:-1048576}"

die() { echo "personal: $*" >&2; exit 2; }

# --- arguments ----------------------------------------------------------------
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]:-$0}" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) a="${1#./}"; ARGS+=("$a"); shift ;;
  esac
done

case "$MAX_BYTES" in ''|*[!0-9]*) die "GRID_MAX_BYTES must be a number" ;; esac

cd "$GRID_DIR" 2>/dev/null || die "GRID_DIR is not a directory: $GRID_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $GRID_DIR"

# --- helpers --------------------------------------------------------------------
# trim: strip leading and trailing whitespace (pure bash, no subprocess).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# scope_match GLOB PATH: does the repo-relative PATH match the scope glob?
# `case` patterns let `*` cross `/`, so `skills/*` covers nested directories.
scope_match() {
  # shellcheck disable=SC2254  # the glob is meant to be unquoted here
  case "$2" in
    $1) return 0 ;;
  esac
  return 1
}

# --- load the rules -------------------------------------------------------------
# Parallel arrays (bash 3.2 has no associative arrays): index i is one rule.
R_KIND=(); R_SCOPE=(); R_LABEL=(); R_RE=()
TOKEN_RE=()        # regexes of public rules labelled `token`, used to redact lines

# load_rules FILE SOURCE   (SOURCE is "public" or "private")
# Parses the four-column TAB format. Private rules get the label private:N where
# N counts rule lines in that file (1-based) so the term itself is never printed.
load_rules() {
  local file="$1" src="$2" lineno=0 n=0 kind scope label re rc shown
  # Error messages for the private file never quote its content.
  shown="$file"; [ "$src" = private ] && shown="the private denylist"
  while IFS=$'\t' read -r kind scope label re || [ -n "$kind" ]; do
    lineno=$((lineno + 1))
    # Skip blank lines and comments.
    [ -z "${kind//[[:space:]]/}" ] && continue
    case "$kind" in '#'*) continue ;; esac
    n=$((n + 1))
    case "$kind" in
      deny|deny-i|allow) ;;
      *) die "bad rule kind on line $lineno of $shown (want deny|deny-i|allow)" ;;
    esac
    if [ -z "$scope" ] || [ -z "$label" ] || [ -z "$re" ]; then
      die "line $lineno of $shown needs 4 TAB-separated columns"
    fi
    # grep exits 2 on an invalid regex (1 just means "no match").
    printf '' | grep -E -e "$re" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] && die "invalid regex on line $lineno of $shown"
    [ "$src" = private ] && label="private:$n"
    R_KIND+=("$kind"); R_SCOPE+=("$scope"); R_LABEL+=("$label"); R_RE+=("$re")
    if [ "$src" = public ] && [ "$label" = token ] && [ "$kind" != allow ]; then
      TOKEN_RE+=("$re")
    fi
  done < "$file"
}

PATTERNS_FILE="$GRID_DIR/scripts/personal-patterns.txt"
[ -f "$PATTERNS_FILE" ] || die "missing $PATTERNS_FILE"
load_rules "$PATTERNS_FILE" public

# Private half. `${VAR-default}` (no colon) keeps an explicitly EMPTY value empty,
# which is how a caller disables the private half on purpose.
if [ "${GRID_PRIVATE_DENYLIST+set}" = set ]; then
  PRIVATE_FILE="$GRID_PRIVATE_DENYLIST"
elif [ -n "${HOME:-}" ]; then
  PRIVATE_FILE="$HOME/.the-grid-private/denylist.txt"
else
  PRIVATE_FILE=""
fi

if [ -n "$PRIVATE_FILE" ] && [ -f "$PRIVATE_FILE" ]; then
  load_rules "$PRIVATE_FILE" private
elif [ "${GRID_REQUIRE_DENYLIST:-}" = 1 ]; then
  # Unattended builds must never pass on the generic half alone.
  echo "personal: private denylist required but not found"
  exit 1
else
  # A visible skip, not a failure: CI and fresh forks have no private repo.
  # gate.sh keys off this exact line to record the skip.
  echo "personal: private denylist not found - generic patterns only"
fi

# --- load the path allowlist ----------------------------------------------------
# One glob per line followed by a mandatory `# reason`.
ALLOW_PATHS=()
ALLOW_FILE="$GRID_DIR/scripts/personal-allow-paths.txt"
if [ -f "$ALLOW_FILE" ]; then
  lineno=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    t="$(trim "$raw")"
    case "$t" in ''|'#'*) continue ;; esac
    case "$raw" in
      *'#'*) ;;
      *) die "line $lineno of personal-allow-paths.txt has no '# reason'" ;;
    esac
    glob="$(trim "${raw%%#*}")"
    reason="$(trim "${raw#*#}")"
    { [ -n "$glob" ] && [ -n "$reason" ]; } || die "line $lineno of personal-allow-paths.txt needs a glob and a reason"
    ALLOW_PATHS+=("$glob")
  done < "$ALLOW_FILE"
fi

# path_allowed PATH: is the path exempt from scanning?
path_allowed() {
  local g
  [ "${#ALLOW_PATHS[@]}" -eq 0 ] && return 1
  for g in "${ALLOW_PATHS[@]}"; do
    scope_match "$g" "$1" && return 0
  done
  return 1
}

# --- build the input file set ---------------------------------------------------
# `git ls-files -s -z` gives "<mode> <sha> <stage><TAB><path>" NUL-separated; mode
# 160000 is a gitlink (submodule), which is never ours to scan.
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  # An argument that is not tracked would otherwise silently "pass".
  [ -n "$(git ls-files -- "$a")" ] || echo "personal: warning: not a tracked path: $a" >&2
done

FILES=()
while IFS= read -r -d '' entry; do
  mode="${entry%% *}"
  path="${entry#*$'\t'}"
  [ "$mode" = 160000 ] && continue
  path_allowed "$path" && continue
  # Positional args restrict the scan (exact path, or everything under a directory).
  if [ "${#ARGS[@]}" -gt 0 ]; then
    keep=0
    for a in "${ARGS[@]}"; do
      case "$path" in "$a"|"$a"/*) keep=1 ;; esac
    done
    [ "$keep" -eq 1 ] || continue
  fi
  # Only regular files: skip symlinks and paths deleted from the working tree.
  [ -L "$path" ] && continue
  [ -f "$path" ] || continue
  FILES+=("$path")
done < <(git ls-files -s -z)

# --- scanning -------------------------------------------------------------------
FINDINGS=0
report() { printf '%s\n' "$1"; FINDINGS=$((FINDINGS + 1)); }

# line_allowed PATH TEXT: does an `allow` rule scoped to PATH match this line?
line_allowed() {
  local i=0 n="${#R_KIND[@]}"
  while [ "$i" -lt "$n" ]; do
    if [ "${R_KIND[$i]}" = allow ] && scope_match "${R_SCOPE[$i]}" "$1" \
       && grep -qE -e "${R_RE[$i]}" <<< "$2"; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# redact_if_token TEXT: echo TEXT, or a placeholder if the line also looks like a
# token, so a secret that trips a non-token rule is still not printed.
redact_if_token() {
  local re
  if [ "${#TOKEN_RE[@]}" -gt 0 ]; then
    for re in "${TOKEN_RE[@]}"; do
      if grep -qE -e "$re" <<< "$1"; then
        printf '%s' "<line also matches a token rule; text withheld>"
        return
      fi
    done
  fi
  printf '%s' "${1:0:120}"
}

# 1) Line rules: one grep per deny rule over the files in that rule's scope.
if [ "${#FILES[@]}" -gt 0 ]; then
  i=0
  while [ "$i" -lt "${#R_KIND[@]}" ]; do
    kind="${R_KIND[$i]}"
    if [ "$kind" != allow ]; then
      scope="${R_SCOPE[$i]}"; label="${R_LABEL[$i]}"; re="${R_RE[$i]}"

      # Files this rule applies to.
      in_scope=()
      for f in "${FILES[@]}"; do
        scope_match "$scope" "$f" && in_scope+=("$f")
      done

      if [ "${#in_scope[@]}" -gt 0 ]; then
        # -H file name, -n line number, -I skip binary files, --null NUL after the
        # file name (so odd paths parse safely). xargs batches long file lists.
        gflags=(-H -n -I -E --null)
        [ "$kind" = deny-i ] && gflags+=(-i)

        # Each hit arrives as: path NUL "lineno:text" NL.
        while IFS= read -r -d '' hit_path && IFS= read -r rest; do
          hit_line="${rest%%:*}"
          hit_text="${rest#*:}"
          # An allow rule on the same line suppresses the hit.
          line_allowed "$hit_path" "$hit_text" && continue
          case "$label" in
            token|private:*)
              # Secrets and denylist terms: location only, never the text.
              report "$hit_path:$hit_line: [$label]" ;;
            *)
              report "$hit_path:$hit_line: [$label] $(redact_if_token "$hit_text")" ;;
          esac
        done < <(printf '%s\0' "${in_scope[@]}" | xargs -0 grep "${gflags[@]}" -e "$re" -- 2>/dev/null)
      fi
    fi
    i=$((i + 1))
  done

  # 2) File blocks: types that should never be tracked, and oversized files.
  for f in "${FILES[@]}"; do
    base="${f##*/}"
    [ "$base" = .env ] && report "$f: [blocked-type:.env] tracked .env file"
    case "$base" in
      *.*) ext="$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')" ;;
      *) ext="" ;;
    esac
    for blocked in zip pdf tar tgz gz sqlite db pem key; do
      [ "$ext" = "$blocked" ] && report "$f: [blocked-type:$blocked] tracked .$blocked file"
    done
    size="$(wc -c < "$f" | tr -d ' ')"
    if [ "$size" -gt "$MAX_BYTES" ]; then
      report "$f: [too-large] $size bytes (limit $MAX_BYTES)"
    fi
  done
fi

echo "personal: $FINDINGS finding(s)"
[ "$FINDINGS" -eq 0 ]
