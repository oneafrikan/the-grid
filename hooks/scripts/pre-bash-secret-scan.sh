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

# Fast path: nothing here can matter unless the text mentions a commit or an add.
case "$command" in
  *commit*|*add*) ;;
  *) exit 0 ;;
esac

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
scan_diff() {
  local out line file="" lineno=0 in_header=0 re_hunk='^@@ -[0-9,]+ \+([0-9]+)'
  out="$(git -C "$cwd" -c core.quotepath=false diff -U0 --no-color --no-ext-diff \
          --src-prefix=a/ --dst-prefix=b/ "$@" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    if [[ "$line" == "diff --git "* ]]; then
      in_header=1; file=""
    elif [ "$in_header" = 1 ]; then
      if [[ "$line" == "+++ b/"* ]]; then
        file="${line#+++ b/}"; file="${file%%$'\t'*}"
      elif [[ "$line" =~ $re_hunk ]]; then
        in_header=0; lineno="${BASH_REMATCH[1]}"
      fi
    elif [[ "$line" =~ $re_hunk ]]; then
      lineno="${BASH_REMATCH[1]}"
    elif [[ "$line" == "+"* ]]; then
      if _secret_match "${line#+}"; then
        add_finding "$file:$lineno: $SECRET_MATCH_NAME (${SECRET_MATCH_TEXT:0:4}...)"
      fi
      lineno=$((lineno + 1))
    fi
  done <<< "$out"
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
      w="${GIT_RAW[$k]}"
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
      w="${GIT_RAW[$k]}"
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

    # 1. what is staged
    scan_diff --cached
    check_sensitive_names --cached
    # 2. what a pathspec / -a / -i / -o commit would take from the working tree
    if [ "${#pathspecs[@]}" -gt 0 ] || [ "$incl" = 1 ]; then
      if git -C "$cwd" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        base=HEAD
      else
        base=4b825dc642cb6eb9a060e54bf8d69288fbee4904   # the empty tree: no HEAD yet
      fi
      if [ "${#pathspecs[@]}" -gt 0 ]; then
        scan_diff "$base" -- "${pathspecs[@]}"
        check_sensitive_names "$base" -- "${pathspecs[@]}"
      else
        scan_diff "$base"
        check_sensitive_names "$base"
      fi
    fi
  fi
done

if [ "${#findings[@]}" -gt 0 ]; then
  {
    echo "BLOCKED by the-grid hook pre-bash-secret-scan: possible secret in this commit (values not shown):"
    for f in "${findings[@]}"; do echo "  $f"; done
    echo "Remove the secret (or unstage the file), then retry."
    echo "Human override: launch claude with GRID_DISABLED_HOOKS=pre-bash-secret-scan"
  } >&2
  exit 2
fi
exit 0
