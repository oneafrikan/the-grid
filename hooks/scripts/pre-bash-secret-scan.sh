#!/usr/bin/env bash
# hooks/scripts/pre-bash-secret-scan.sh — PreToolUse(Bash) guard, launched by hooks/run.sh.
#
# Blocks (exit 2) a `git commit` that would add a line matching a secret pattern
# (hooks/lib/secret-patterns.sh) or commit a sensitive file, and a `git add` of a
# sensitive file (.env, *.pem, private-key names). Rules: design.md "Guard rules".
#
#   - `git commit`: scans the added lines of `git diff --cached`. When the commit
#     names pathspecs or uses -i/-o/-a (or their long forms) it ALSO scans
#     `git diff <HEAD|empty tree> [-- pathspecs]`, because such a commit takes the
#     working-tree content, which --cached does not show.
#   - Never prints a secret value (file, line, pattern name, first 4 chars only) and
#     never mentions the allow pragma in its message.
#   - Exit 0 on non-JSON stdin, a non-Bash tool, no command, a command that is not
#     `git commit` / `git add`, or a cwd that is not inside a git repository.
#   - Exit 2 when jq is missing (fail closed).
#
# A mistake-catcher for an agent, not a security boundary.

LC_ALL=C; export LC_ALL
set -f   # no globbing: word lists below are split on purpose
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=../lib/secret-patterns.sh
. "$HERE/lib/secret-patterns.sh"

grid_require_jq closed

payload="$(cat)"
if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "pre-bash-secret-scan: stdin is not a JSON object, skipping" >&2
  exit 0
fi
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ "$tool" = "Bash" ] || exit 0
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"

# Fast path: nothing here can matter unless the text mentions a commit or an add. The
# test runs on the text with quotes and backslashes removed, as the shell would (comm""it
# and ad\d are commit and add); a command holding $ or a backtick may build a word the
# text test cannot see, so it always goes to the tokenizer.
stripped="${command//[\"\'\\]/}"
case "$stripped" in
  *commit*|*add*) ;;
  *)
    case "$command" in
      *'$'*|*'`'*) ;;
      *) exit 0 ;;
    esac ;;
esac

grid_check_cmd_cap pre-bash-secret-scan "$command"

grid_git_segments "$command"

# Which segments are a commit or an add? Stop early (and never touch git) if none.
want=0
for sub in "${GIT_SUB[@]}"; do
  case "$sub" in commit|add) want=1 ;; esac
done
[ "$want" = 1 ] || exit 0

# Everything below needs a repository; a cwd outside one is not our business.
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || exit 0

findings=()          # "file:line: name (abcd...)" or "file: sensitive-file"
MAX_FINDINGS=10
add_finding() {
  local f
  # The staged diff and the working-tree diff can report the same line twice.
  for f in "${findings[@]}"; do [ "$f" = "$1" ] && return 0; done
  [ "${#findings[@]}" -lt "$MAX_FINDINGS" ] && findings+=("$1")
  return 0
}

# scan_diff <git diff args...>
#   Run git diff in $cwd and test every added line. Header/hunk state machine:
#   inside a file header ("diff --git" up to the first "@@") "+++ b/<path>" names the
#   file; "@@ -a,b +c,d @@" sets the new-file line counter to c; each "+" body line
#   is one added line. Binary notices and /dev/null live in the header and are
#   ignored. Explicit prefixes keep the parse independent of diff.noprefix and
#   diff.mnemonicPrefix; quotepath=false keeps non-ASCII names readable.
#
#   Speed (WP-019): the diff is read by one awk state machine (file + line number for
#   every added line, joined with the unit separator), then one `grep -Ei` with the
#   union of the pattern table keeps only lines some pattern could match, and only
#   those reach the slow per-line bash matcher. Before this, every added line cost
#   about 1.2 ms in bash, so a 6,000-line diff outran the 5 s hook timeout and the
#   commit went through unscanned. More than GRID_SCAN_MAX_LINES candidate lines
#   (default 3000) sets $too_large instead of scanning on: the caller blocks.
MAX_SCAN_LINES="${GRID_SCAN_MAX_LINES:-3000}"
[[ "$MAX_SCAN_LINES" =~ ^[0-9]+$ ]] || MAX_SCAN_LINES=3000
too_large=0
PREFILTER_RE="$(secret_prefilter_re)"
US=$'\037'
scan_diff() {
  local file lineno content n=0
  [ "$too_large" = 0 ] || return 0
  while IFS="$US" read -r file lineno content; do
    n=$((n + 1))
    if [ "$n" -gt "$MAX_SCAN_LINES" ]; then too_large=1; return 0; fi
    if _secret_match "$content"; then
      add_finding "$file:$lineno: $SECRET_MATCH_NAME (${SECRET_MATCH_TEXT:0:4}...)"
    fi
    # Ten findings fill the list; reading on would only burn the timeout.
    [ "${#findings[@]}" -lt "$MAX_FINDINGS" ] || return 0
  done < <(git -C "$cwd" -c core.quotepath=false diff -U0 --no-color --no-ext-diff \
             --src-prefix=a/ --dst-prefix=b/ "$@" 2>/dev/null \
           | awk -v sep="$US" '
               /^diff --git / { hdr = 1; f = ""; next }
               hdr && substr($0, 1, 6) == "+++ b/" {
                 f = substr($0, 7); t = index(f, "\t"); if (t > 0) f = substr(f, 1, t - 1); next }
               /^@@ -[0-9,]+ \+[0-9]+/ {
                 match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; hdr = 0; next }
               !hdr && substr($0, 1, 1) == "+" { print f sep ln sep substr($0, 2); ln++ }
             ' \
           | grep -Ei -e "$PREFILTER_RE")
}

# check_sensitive_names <git diff args...>
#   Test the names of the files the commit adds or changes (deletions excluded:
#   removing a .env from git is the fix, not the leak) against secret_sensitive_name.
#   NUL-separated (-z) so odd file names cannot confuse the loop.
check_sensitive_names() {
  local name
  while IFS= read -r -d '' name; do
    if secret_sensitive_name "${name##*/}"; then
      add_finding "$name: sensitive-file"
    fi
  done < <(git -C "$cwd" -c core.quotepath=false diff --name-only -z --diff-filter=d "$@" 2>/dev/null)
}

for ((i = 0; i < ${#GIT_SUB[@]}; i++)); do
  sub="${GIT_SUB[$i]}"; start="${GIT_START[$i]}"; len="${GIT_LEN[$i]}"

  if [ "$sub" = "add" ]; then
    # `git add` of a sensitive file: name check only, no diff. After `--` every word
    # is a path; before it, option words (leading dash) are skipped.
    after_dd=0
    for ((k = start; k < start + len; k++)); do
      w="${GIT_FLAG[$k]}"
      if [ "$after_dd" = 0 ] && [ "$w" = "--" ]; then after_dd=1; continue; fi
      if [ "$after_dd" = 0 ] && [[ "$w" == -* ]]; then continue; fi
      if secret_sensitive_name "${w##*/}"; then add_finding "$w: sensitive-file"; fi
    done
  fi

  if [ "$sub" = "commit" ]; then
    # Work out pathspecs and whether the commit reads the working tree (-a, -i, -o).
    # Value-taking options consume the next word; a short cluster is read letter by
    # letter: a, i, o set the flag; a value-taking letter (m F C c t) takes either
    # the rest of the word or, when last, the next word.
    pathspecs=(); incl=0; skip_next=0; after_dd=0
    for ((k = start; k < start + len; k++)); do
      w="${GIT_FLAG[$k]}"
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      if [ "$after_dd" = 1 ]; then pathspecs+=("$w"); continue; fi
      case "$w" in
        --) after_dd=1 ;;
        --author|--date|--cleanup|--fixup|--squash|--trailer|--template|--file|--message|--reuse-message|--reedit-message) skip_next=1 ;;
        --include|--only|--all) incl=1 ;;
        --*) ;;
        -?*)
          rest="${w#-}"
          while [ -n "$rest" ]; do
            letter="${rest:0:1}"; rest="${rest:1}"
            case "$letter" in
              a|i|o) incl=1 ;;
              m|F|C|c|t) [ -z "$rest" ] && skip_next=1; break ;;   # value follows (or is attached)
              S) break ;;                                           # -S<keyid>: attached only
            esac
          done ;;
        *) pathspecs+=("$w") ;;
      esac
    done

    # 1. what is staged. The cheap name check runs BEFORE the diff scan: a staged .env
    #    must be reported even when a large diff then fills the list or the cap.
    check_sensitive_names --cached
    scan_diff --cached
    # 2. what a pathspec / -a / -i / -o commit would take from the working tree
    if [ "${#pathspecs[@]}" -gt 0 ] || [ "$incl" = 1 ]; then
      if git -C "$cwd" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        base=HEAD
      else
        base=4b825dc642cb6eb9a060e54bf8d69288fbee4904   # the empty tree: no HEAD yet
      fi
      if [ "${#pathspecs[@]}" -gt 0 ]; then
        check_sensitive_names "$base" -- "${pathspecs[@]}"
        scan_diff "$base" -- "${pathspecs[@]}"
      else
        check_sensitive_names "$base"
        scan_diff "$base"
      fi
    fi
  fi
done

if [ "${#findings[@]}" -gt 0 ] || [ "$too_large" = 1 ]; then
  {
    echo "BLOCKED by the-grid hook pre-bash-secret-scan: possible secret in this commit (values not shown):"
    for f in "${findings[@]}"; do echo "  $f"; done
    if [ "$too_large" = 1 ]; then
      echo "  diff too large to scan (more than $MAX_SCAN_LINES candidate lines): split the commit into smaller ones."
    fi
    echo "Remove the secret (or unstage the file), then retry."
    echo "Human override: launch claude with GRID_DISABLED_HOOKS=pre-bash-secret-scan"
  } >&2
  exit 2
fi
exit 0
