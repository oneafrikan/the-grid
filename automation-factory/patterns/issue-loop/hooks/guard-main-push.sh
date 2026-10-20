#!/usr/bin/env bash
# guard-main-push — PreToolUse(Bash) hook for the issue-loop pattern.
#
# MISTAKE-CATCHER, NOT THE BOUNDARY. Branch protection (a ruleset requiring a
# pull request on the base branch) and the fact that only a human merges are the
# boundary. This hook only stops an agent from *accidentally* doing the obvious
# wrong thing, and tells it what to do instead.
#
# Where it runs: the issue-loop runner passes it to the headless worker through a
# per-run `--settings` file. It is NOT written into a repo's .claude/settings.json
# unless the operator runs `loop/setup.sh --interactive` for an interactive loop
# session (never in the-grid, whose own sessions must be able to `gh pr merge`).
#
# Exit 2 (with a reason on stderr) when a command segment is:
#   - `git push` with any word that, after stripping a leading `+`, everything
#     up to the last `:` and a `refs/heads/` prefix, equals main, master or the
#     base branch (word match, so `git push -u origin issue-main-fix` is fine)
#   - a bare `git push` (no refspec) while the current branch is one of those
#   - `git push` with --force, -f (or a short cluster containing f),
#     --force-with-lease[=...], --mirror or --all
#   - `gh pr merge`
#   - `gh api` with a word containing /merge, or -X / --method (also -XPUT,
#     --method=PUT) with PUT, PATCH or DELETE (case-insensitive)
#
# Quoting is normalised the way the shell does it: `"`, `'` and `\` are removed
# from words, and `git` / `gh` are recognised by basename, so
#   git push origin 'main'      /usr/bin/git push origin main      gh pr 'merge' 5
# are all caught (R10.qa.F14).
#
# KNOWN GAPS (also in the pattern README): `bash -c '...'`, `eval`, shell aliases
# and scripts that call git internally are NOT inspected. `bash -c 'git push
# origin main'` is allowed on purpose and pinned as such by the test suite.
#
# Parsers. Two paths feed ONE decision function (decide_push below):
#   1. ${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh exists: use its shared
#      tokenizer. grid_git_segments prints NOTHING; it returns through the globals
#      GIT_SUB / GIT_START / GIT_LEN / GIT_FLAG, so it must be called directly in
#      this shell, never inside $(...) or < <(...).
#      R10.qa.F1 history: an earlier version called it inside `< <(...)`, so the
#      guard saw no segments and ALLOWED EVERYTHING on every machine that had
#      the-grid installed.
#   2. Otherwise (a business repo with no the-grid checkout): the built-in
#      splitter below fills the same four globals.
# `gh` segments always use the built-in splitter: the shared parser covers git only.
#
# BASE_BRANCH comes from loop/loop.conf next to this hook's parent dir (default
# main).
#
# Bash 3.2 compatible (macOS). Requires: jq.

set -euo pipefail
# The guard reads words that may contain * or ?; never let the shell expand them.
set -f
# Byte-wise string handling: the shared parser's size caps count bytes.
LC_ALL=C; export LC_ALL

INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"
[ -n "$CWD" ] || CWD="$(pwd)"

# --- base branch from loop.conf (sourced in a subshell: it is only assignments) ---
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
BASE="main"
if [ -f "$HOOK_DIR/../loop.conf" ]; then
  conf_base="$( (. "$HOOK_DIR/../loop.conf" >/dev/null 2>&1; printf '%s' "${BASE_BRANCH:-}") 2>/dev/null || true)"
  [ -z "$conf_base" ] || BASE="$conf_base"
fi

block() {
  echo "BLOCKED by issue-loop guard: $1" >&2
  echo "Work on an issue-<N> branch (bash loop/hooks/new-agent-worktree.sh issue-<N>), push that, and let a human merge the PR." >&2
  exit 2
}

# is_protected <word> — true when a refspec word names a protected branch.
is_protected() {
  local w="${1#+}"
  w="${w##*:}"
  w="${w#refs/heads/}"
  case "$w" in
    main|master) return 0 ;;
  esac
  [ "$w" = "$BASE" ]
}

current_branch() {
  git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null || true
}

# unquote <word> — remove " ' and \ the way the shell would, leaving the content.
unquote() {
  local w="$1"
  w="${w//\"/}"
  w="${w//\'/}"
  w="${w//\\/}"
  printf '%s' "$w"
}

# base_of <word> — basename of a (quote-stripped) command word: /usr/bin/git -> git.
base_of() {
  printf '%s' "${1##*/}"
}

# --- split the command into segments, one per line ---
# Used by the built-in git splitter and by the gh checks. A quoted separator
# (a commit message containing "&&") splits too; that can only add false blocks.
nl=$'\n'
segs="$COMMAND"
segs="${segs//&&/$nl}"
segs="${segs//||/$nl}"
segs="${segs//;/$nl}"
segs="${segs//|/$nl}"

# The result globals, identical for both parsers:
#   GIT_SUB[i]    subcommand of git segment i
#   GIT_START[i]  offset of its first word in GIT_FLAG
#   GIT_LEN[i]    number of words after the subcommand
#   GIT_FLAG[]    those words, quotes and backslashes removed
GIT_SUB=(); GIT_START=(); GIT_LEN=(); GIT_FLAG=()

# builtin_git_segments — fill the GIT_* globals from $segs without the shared parser.
builtin_git_segments() {
  local seg words w i n sub nflag=0
  GIT_SUB=(); GIT_START=(); GIT_LEN=(); GIT_FLAG=()
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    read -r -a words <<< "$seg"
    n=${#words[@]}
    i=0
    # drop leading VAR=value words
    while [ "$i" -lt "$n" ]; do
      case "${words[$i]}" in
        [A-Za-z_]*=*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    w="$(unquote "${words[$i]}")"
    [ "$(base_of "$w")" = "git" ] || continue
    i=$((i + 1))
    # skip git global options: -C <dir>, -c <k=v>, --opt[=v], other -x flags
    while [ "$i" -lt "$n" ]; do
      w="$(unquote "${words[$i]}")"
      case "$w" in
        -C|-c) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    sub="$(unquote "${words[$i]}")"
    i=$((i + 1))
    GIT_SUB[${#GIT_SUB[@]}]="$sub"
    GIT_START[${#GIT_START[@]}]="$nflag"
    GIT_LEN[${#GIT_LEN[@]}]=$((n - i))
    while [ "$i" -lt "$n" ]; do
      GIT_FLAG[$nflag]="$(unquote "${words[$i]}")"
      nflag=$((nflag + 1))
      i=$((i + 1))
    done
  done <<< "$segs"
}

# decide_push <words...> — the words after `git push`. Exits 2 via block().
decide_push() {
  local w refspecs=0 cur
  for w in "$@"; do
    case "$w" in
      --force|--force-with-lease|--force-with-lease=*|--mirror|--all)
        block "git push $w is not allowed" ;;
      --*) ;;
      -*f*) block "git push $w (force) is not allowed" ;;
    esac
  done
  cur="$(current_branch)"
  for w in "$@"; do
    case "$w" in
      -*) continue ;;
    esac
    refspecs=$((refspecs + 1))
    if is_protected "$w"; then
      block "push to protected branch ($w)"
    fi
    # `HEAD` means "the current branch", so it is protected when the branch is.
    if [ "$w" = "HEAD" ] && [ -n "$cur" ] && is_protected "$cur"; then
      block "push of HEAD while on protected branch $cur"
    fi
  done
  # no refspec (only a remote, or nothing): pushes the current branch
  if [ "$refspecs" -le 1 ] && [ -n "$cur" ] && is_protected "$cur"; then
    block "bare git push while on protected branch $cur"
  fi
}

# --- git segments: shared parser when present, built-in splitter otherwise ---
COMMON="${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh"
used_shared=0
if [ -f "$COMMON" ]; then
  # common.sh is written for a shell WITHOUT `set -u` (empty-array expansions
  # misbehave under it on bash 3.2), so relax it for the sourced calls only.
  set +u
  # shellcheck disable=SC1090
  . "$COMMON"
  if command -v grid_git_segments >/dev/null 2>&1; then
    # Called DIRECTLY (no subshell): the parser returns through GIT_* globals.
    grid_check_cmd_cap issue-loop-guard "$COMMAND"
    grid_git_segments "$COMMAND"
    grid_check_balanced issue-loop-guard "$COMMAND"
    used_shared=1
  fi
  set -u
fi
if [ "$used_shared" = 0 ]; then
  builtin_git_segments
fi

i=0
while [ "$i" -lt "${#GIT_SUB[@]}" ]; do
  if [ "${GIT_SUB[$i]}" = "push" ]; then
    # collect this segment's words and hand them to the one decision function
    pw=()
    k="${GIT_START[$i]}"
    end=$((k + GIT_LEN[$i]))
    while [ "$k" -lt "$end" ]; do
      pw[${#pw[@]}]="${GIT_FLAG[$k]}"
      k=$((k + 1))
    done
    decide_push ${pw[@]+"${pw[@]}"}
  fi
  i=$((i + 1))
done

# --- gh segments (always the built-in split, same normalisation) ---
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  read -r -a words <<< "$seg"
  n=${#words[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${words[$i]}" in
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  [ "$(base_of "$(unquote "${words[$i]}")")" = "gh" ] || continue
  rest=()
  k=$((i + 1))
  while [ "$k" -lt "$n" ]; do
    rest[${#rest[@]}]="$(unquote "${words[$k]}")"
    k=$((k + 1))
  done
  m=${#rest[@]}
  k=0
  while [ "$k" -lt "$m" ]; do
    if [ "${rest[$k]}" = "pr" ] && [ $((k + 1)) -lt "$m" ] && [ "${rest[$((k + 1))]}" = "merge" ]; then
      block "gh pr merge is a human action"
    fi
    k=$((k + 1))
  done
  if [ "$m" -gt 0 ] && [ "${rest[0]}" = "api" ]; then
    k=1
    while [ "$k" -lt "$m" ]; do
      w="${rest[$k]}"
      case "$w" in
        */merge*) block "gh api call touching /merge" ;;
      esac
      method=""
      case "$w" in
        -X|--method)
          if [ $((k + 1)) -lt "$m" ]; then method="${rest[$((k + 1))]}"; fi ;;
        --method=*) method="${w#--method=}" ;;
        -X?*) method="${w#-X}" ;;
      esac
      if [ -n "$method" ]; then
        method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
        case "$method" in
          PUT|PATCH|DELETE) block "gh api with method $method" ;;
        esac
      fi
      k=$((k + 1))
    done
  fi
done <<< "$segs"

exit 0
