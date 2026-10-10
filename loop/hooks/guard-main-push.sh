#!/usr/bin/env bash
# guard-main-push — PreToolUse(Bash) hook for the issue-loop pattern.
#
# MISTAKE-CATCHER, NOT THE BOUNDARY. Branch protection (a ruleset requiring a
# pull request on the base branch) and token scope are the boundary; a headless
# worker holds no GitHub token at all. This hook only stops an agent from
# *accidentally* doing the obvious wrong thing, and tells it what to do instead.
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
# Known gaps (also in the README): `bash -c '...'`, `eval`, shell aliases and
# scripts that call git internally are NOT inspected.
#
# BASE_BRANCH comes from loop/loop.conf next to this hook's parent dir
# (default: main). Segmenting uses grid_git_segments from
# ${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh when that file exists (one
# git segment per output line: "<subcommand> <words...>"), else the built-in
# split below. `gh` segments always use the built-in split: the shared parser
# only covers git.
#
# Bash 3.2 compatible (macOS). Requires: jq.

set -euo pipefail

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

# --- split the command into segments, one per line ---
nl=$'\n'
segs="$COMMAND"
segs="${segs//&&/$nl}"
segs="${segs//||/$nl}"
segs="${segs//;/$nl}"
segs="${segs//|/$nl}"

# git_segments — print "<subcommand> <words...>" for each git segment.
git_segments() {
  local common="${GRID_DIR:-$HOME/.the-grid}/hooks/lib/common.sh"
  if [ -f "$common" ]; then
    # shellcheck disable=SC1090
    . "$common"
    if command -v grid_git_segments >/dev/null 2>&1; then
      grid_git_segments "$COMMAND"
      return 0
    fi
  fi
  local seg words w i n
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
    [ "${words[$i]}" = "git" ] || continue
    i=$((i + 1))
    # skip git global options: -C <dir>, -c <k=v>, --opt[=v], other -x flags
    while [ "$i" -lt "$n" ]; do
      w="${words[$i]}"
      case "$w" in
        -C|-c) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || continue
    printf '%s' "${words[$i]}"
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      printf ' %s' "${words[$i]}"
      i=$((i + 1))
    done
    printf '\n'
  done <<< "$segs"
}

# check_push <words...> — the words after `git push`.
check_push() {
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

# --- git segments ---
while IFS= read -r line; do
  [ -n "$line" ] || continue
  read -r -a gw <<< "$line"
  if [ "${gw[0]}" = "push" ]; then
    check_push ${gw[@]+"${gw[@]:1}"}
  fi
done < <(git_segments)

# --- gh segments (always the built-in split) ---
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
  [ "${words[$i]}" = "gh" ] || continue
  rest=("${words[@]:$((i + 1))}")
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
